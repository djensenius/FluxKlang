import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

/// How the lease changes between a queued commit and its delivery.
enum CommitLeaseChange: CaseIterable, Sendable { case released, transferred, reacquired }

extension HostAuthorityTests {
    /// The delivery guard, commit abandonment, and lease release and transfer (H5c-1).
    struct ActorCommit {
        @Test func commitWithCurrentLeaseIsDelivered() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let reviewed = try await Bench.commitQueued(authority, &engine)
            let attempt = try await Bench.attempt(authority)
            let token = try #require(await authority.snapshot().lease?.token)
            #expect(await engine.drain(authority) == [.commit(reviewed, attempt, token)])
            #expect(engine.pendingCommits == [ScriptedCommit(prepared: reviewed, attempt: attempt, token: token)])
            let after = await authority.snapshot()
            #expect(after.inFlight == [Bench.projectA: attempt] && after.authorizedWindows.isEmpty)
            let state = try await Bench.state(authority)
            #expect(state.phase == .committing && state.reviewed == reviewed)
            #expect(state.lifecycle == .preparing(try ContractRevision.initial.next(), over: .running))
        }

        @Test(arguments: CommitLeaseChange.allCases)
        func commitWithReplacedLeaseIsNotDelivered(_ change: CommitLeaseChange) async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let reviewed = try await Bench.commitQueued(authority, &engine)
            let committed = try #require(Bench.context(await authority.snapshot()))
            let bumps: Generation
            switch change {
            case .released:
                try await authority.release(project: Bench.projectA).get()
                bumps = try committed.next()
            case .transferred:
                _ = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
                bumps = try committed.next()
            case .reacquired:
                try await authority.release(project: Bench.projectA).get()
                _ = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
                bumps = try committed.next().next()
            }
            #expect(Bench.context(await authority.snapshot()) == bumps)
            // B's prepare is queued after the commit; the mute keeps the commit's place.
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectB).get()
            let prepareB = try #require(try await Bench.state(authority, Bench.projectB).lastPrepareAttempt)
            let taken = await engine.drain(authority)
            #expect(taken.count == 2 && taken.first == .setOutputsMuted(true))
            guard taken.count == 2, case .prepare(_, prepareB) = taken[1] else {
                Issue.record("Expected the mute, then B's prepare; got \(taken)")
                return
            }
            #expect(engine.pendingCommits.isEmpty && engine.discarded.isEmpty)
            let state = try await Bench.state(authority)
            #expect(state.phase == .recovering(reviewed, cause: .leaseLost))
            #expect(state.lifecycle == .recovering && state.reviewed == reviewed)
            #expect(await authority.snapshot().inFlight.isEmpty)
        }

        @Test func abandonedCommitIsNeverDelivered() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let reviewed = try await Bench.commitQueued(authority, &engine)
            let attempt = try await Bench.attempt(authority)
            try await authority.abandonCommit(attempt, reason: .outcomeUnknown).get()
            // The queued `.commit` is dropped: its attempt is no longer committing.
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            #expect(engine.pendingCommits.isEmpty)
            let state = try await Bench.state(authority)
            #expect(state.phase == .recovering(reviewed, cause: .commitOutcomeUnknown))
            #expect(state.lifecycle == .recovering)
            #expect(await authority.snapshot().inFlight.isEmpty)
        }

        @Test func abandoningADeliveredCommitEndsItsFlight() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.commitQueued(authority, &engine)
            await engine.drain(authority)
            let attempt = try await Bench.attempt(authority)
            #expect(await authority.snapshot().inFlight == [Bench.projectA: attempt])
            try await authority.abandonCommit(attempt, reason: .outcomeUnknown).get()
            #expect(await authority.snapshot().inFlight.isEmpty)
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            // Nothing is in flight any more, so the lease can be released.
            try await authority.release(project: Bench.projectA).get()
        }

        @Test func abandonCommitRefusalsChangeNothing() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.commitQueued(authority, &engine)
            let attempt = try await Bench.attempt(authority)
            let foreign = try await Bench.makeAuthority()
            var foreignEngine = try ScriptedActivationEngine()
            _ = try await Bench.commitQueued(foreign, &foreignEngine)
            let foreignAttempt = try await Bench.attempt(foreign)
            let before = await authority.snapshot()
            for reason in [CommitAbandonment.leaseLost, .revisionOverflow] {
                let refused = await authority.abandonCommit(attempt, reason: reason)
                #expect(Bench.refusal(refused) == .abandonmentReserved(reason))
            }
            let stale = await authority.abandonCommit(foreignAttempt, reason: .outcomeUnknown)
            #expect(Bench.refusal(stale) == .activation(.staleReport))
            #expect(await authority.snapshot() == before)
            // A second abandon of the same attempt is the transaction's refusal.
            try await authority.abandonCommit(attempt, reason: .outcomeUnknown).get()
            let recovering = await authority.snapshot()
            let again = await authority.abandonCommit(attempt, reason: .outcomeUnknown)
            let phase = try await Bench.state(authority).phase
            #expect(Bench.refusal(again) == .activation(.unexpectedPhase(phase)))
            #expect(await authority.snapshot() == recovering)
            // Room is checked before the transaction: a full queue refuses `.queueFull` first.
            try await Bench.fillQueue(authority)
            let full = await authority.snapshot()
            let crowded = await authority.abandonCommit(attempt, reason: .outcomeUnknown)
            #expect(Bench.refusal(crowded) == .queueFull)
            #expect(await authority.snapshot() == full)
        }

        @Test func releaseRefusedWhileDeliveredCommitUnreported() async throws {
            // Only queued: release is allowed, and the guard then withholds the commit.
            let queued = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.commitQueued(queued, &engine)
            try await queued.release(project: Bench.projectA).get()
            #expect(await engine.drain(queued) == [.setOutputsMuted(true)])

            let delivered = try await Bench.makeAuthority()
            var deliveredEngine = try ScriptedActivationEngine()
            _ = try await Bench.commitQueued(delivered, &deliveredEngine)
            await deliveredEngine.drain(delivered)
            let before = await delivered.snapshot()
            #expect(!before.inFlight.isEmpty)
            #expect(Bench.refusal(await delivered.release(project: Bench.projectA)) == .activation(.busy))
            let transfer = await delivered.transfer(to: Bench.projectB, window: Bench.windowB)
            #expect(Bench.refusal(transfer) == .activation(.busy))
            #expect(await delivered.snapshot() == before)
        }

        @Test func releaseAndTransferRefusalsChangeNothing() async throws {
            let unheld = try await Bench.makeAuthority(holding: nil)
            let idle = await unheld.snapshot()
            #expect(Bench.refusal(await unheld.release(project: Bench.projectA)) == .lease(.notHeld))
            let unheldTransfer = await unheld.transfer(to: Bench.projectB, window: Bench.windowB)
            #expect(Bench.refusal(unheldTransfer) == .lease(.notHeld))
            #expect(await unheld.snapshot() == idle)

            let authority = try await Bench.makeAuthority()
            let held = await authority.snapshot()
            #expect(Bench.refusal(await authority.release(project: Bench.projectC)) == .unknownProject(Bench.projectC))
            let foreign = await authority.release(project: Bench.projectB)
            #expect(Bench.refusal(foreign) == .lease(.heldByOtherProject(Bench.projectA)))
            let toSelf = await authority.transfer(to: Bench.projectA, window: Bench.windowA2)
            #expect(Bench.refusal(toSelf) == .lease(.alreadyHeld))
            let toUnknown = await authority.transfer(to: Bench.projectC, window: Bench.windowB)
            #expect(Bench.refusal(toUnknown) == .unknownProject(Bench.projectC))
            #expect(await authority.snapshot() == held)
        }

        @Test func openRefusesARecoveringPlan() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let reviewed = try await Bench.commitQueued(authority, &engine)
            try await authority.abandonCommit(try await Bench.attempt(authority), reason: .outcomeUnknown).get()
            await engine.drain(authority)
            let before = await authority.snapshot()
            let opened = await authority.open(project: Bench.projectC,
                                              running: RunningGraph(revision: .initial, prepared: reviewed))
            #expect(Bench.refusal(opened) == .activation(.preparedIDInUse))
            #expect(await authority.snapshot() == before)
        }
    }
}
