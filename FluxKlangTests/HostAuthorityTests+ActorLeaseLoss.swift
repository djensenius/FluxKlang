import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

/// The holder's phase when its lease is lost involuntarily (table T1, #62 H5d-1).
enum LeaseLossPhase: CaseIterable, Sendable {
    case idle, preparing, awaitingReview, committingQueued, committingDelivered, acknowledged
    case commitFailed, partial, prepareFailed, recovering

    func engine() throws -> ScriptedActivationEngine {
        self == .prepareFailed ? try ScriptedActivationEngine(failing: [1: .prepareFailed])
            : try ScriptedActivationEngine()
    }

    /// Brings A into this phase (everything but a queued `.commit` drained) and
    /// returns the phase T1 leaves A in after `leaseLost`.
    func setUp(_ authority: HostAuthority, _ engine: inout ScriptedActivationEngine) async throws
    -> ActivationPhase {
        switch self {
        case .idle: return .idle
        case .preparing:
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectA).get()
            await engine.drain(authority)
            return .preparing
        case .awaitingReview:
            _ = try await Bench.review(authority, &engine)
            return .awaitingReview
        case .committingQueued:
            return .recovering(try await Bench.commitQueued(authority, &engine), cause: .leaseLost)
        case .committingDelivered:
            return .recovering(try await Bench.commitDelivered(authority, &engine), cause: .leaseLost)
        case .acknowledged:
            _ = try await Bench.commitDelivered(authority, &engine)
            _ = try #require(await engine.report(authority, .succeeded)).verdict.get()
            await engine.drain(authority)
            return .acknowledged(try ContractRevision.initial.next())
        case .commitFailed, .partial:
            let reviewed = try await Bench.commitDelivered(authority, &engine, withAux: true)
            _ = try #require(await engine.report(authority, self == .partial ? .partial : .failed)).verdict.get()
            return .recovering(reviewed, cause: .leaseLost)
        case .prepareFailed:
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectA).get()
            await engine.drain(authority)
            _ = try #require(await engine.answerNext(authority)).verdict.get()
            return .prepareFailed(.engineRefused)
        case .recovering:
            let reviewed = try await Bench.commitQueued(authority, &engine)
            try await authority.abandonCommit(try await Bench.attempt(authority), reason: .outcomeUnknown).get()
            await engine.drain(authority)
            return .recovering(reviewed, cause: .commitOutcomeUnknown)
        }
    }
}

extension HostAuthorityTests {
    /// Involuntary lease loss (table T1) and the fail-closed mute lane (H5d-1).
    struct ActorLeaseLoss {
        @Test(arguments: LeaseLossPhase.allCases)
        func leaseLossFollowsPhaseTable(_ phase: LeaseLossPhase) async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try phase.engine()
            let expected = try await phase.setUp(authority, &engine)
            let before = await authority.snapshot()
            let token = try await Bench.leaseToken(authority)
            #expect(await authority.leaseLost(token) == .success(Bench.projectA))
            let after = await authority.snapshot()
            let state = try #require(after.projects[Bench.projectA])
            #expect(state.phase == expected && state.lifecycle == .recovering)
            #expect(state.running == before.projects[Bench.projectA]?.running)
            #expect(after.projects[Bench.projectB] == before.projects[Bench.projectB])
            #expect(after.lease == nil && after.inFlight.isEmpty && after.authorizedWindows.isEmpty)
            #expect(after.outstanding == before.outstanding && after.abandoned == before.abandoned)
            #expect(after.outputsMuted && after.pendingOutput == true)
            #expect(Bench.context(after) == (try Bench.context(before)?.next()))
            // Only the lane's mute reaches the engine: nothing discarded, kept or committed.
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let drained = await authority.snapshot()
            #expect(drained.pendingOutput == nil && drained.outputsMuted)
            #expect(engine.pendingCommits.isEmpty || phase == .committingDelivered)
        }

        @Test func leaseLostWithStaleTokenChangesNothing() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.review(authority, &engine)
            let old = try await Bench.leaseToken(authority)
            try await authority.release(project: Bench.projectA).get()
            _ = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            _ = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            let held = await authority.snapshot()
            #expect(Bench.refusal(await authority.leaseLost(old)) == .lease(.staleToken))
            #expect(await authority.snapshot() == held)
            #expect(await authority.nextEngineCommand() == nil)

            try await authority.release(project: Bench.projectA).get()
            let unheld = await authority.snapshot()
            #expect(Bench.refusal(await authority.leaseLost(old)) == .lease(.notHeld))
            #expect(await authority.snapshot() == unheld)
            #expect(await authority.nextEngineCommand() == nil)
        }

        @Test func lossMuteOvertakesQueuedCommands() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            for _ in 0..<3 {
                try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectB).get()
                try await authority.abandonPrepare(project: Bench.projectB).get()
            }
            let queued = await authority.snapshot().queue.pending
            #expect(queued.count == 3)
            try await authority.leaseLost(try await Bench.leaseToken(authority)).get()
            #expect(await authority.snapshot().queue.pending == queued)
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)] + queued)
        }

        @Test func leaseLossNeverRefusedForAFullQueue() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            try await Bench.fillQueue(authority)
            let full = await authority.snapshot().queue
            #expect(!full.canAccept(1))
            #expect(await authority.leaseLost(try await Bench.leaseToken(authority)) == .success(Bench.projectA))
            let after = await authority.snapshot()
            #expect(after.queue == full && after.pendingOutput == true && after.lease == nil)
            let taken = await engine.drain(authority)
            #expect(taken.first == .setOutputsMuted(true) && Array(taken.dropFirst()) == full.pending)
        }

        @Test func leaseLossWhileCommitDeliveredEndsItsFlight() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let reviewed = try await Bench.commitDelivered(authority, &engine)
            #expect(Bench.refusal(await authority.release(project: Bench.projectA)) == .activation(.busy))
            #expect(await !authority.snapshot().inFlight.isEmpty)
            try await authority.leaseLost(try await Bench.leaseToken(authority)).get()
            #expect(await authority.snapshot().inFlight.isEmpty)
            #expect(try await Bench.state(authority).phase == .recovering(reviewed, cause: .leaseLost))
            // The engine's late report on the ended flight is refused, with nothing changed.
            let lost = await authority.snapshot()
            let late = try #require(await engine.report(authority, .succeeded))
            #expect(late.verdict == .failure(.activation(.staleReport)))
            #expect(await authority.snapshot() == lost)
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
        }

        @Test func queuedCommitAfterLeaseLossIsDropped() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let reviewed = try await Bench.commitQueued(authority, &engine)
            try await authority.leaseLost(try await Bench.leaseToken(authority)).get()
            #expect(try await Bench.state(authority).phase == .recovering(reviewed, cause: .leaseLost))
            // One mute (the lane's); the queued `.commit` is dropped, not withheld into a second mute.
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            #expect(engine.pendingCommits.isEmpty && engine.discarded.isEmpty)
        }

        @Test func leaseLossClearsAuthorizingWindow() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let reviewed = try await Bench.review(authority, &engine)
            let authorization = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            #expect(await authority.snapshot().authorizedWindows == [Bench.projectA: Bench.windowA])
            try await authority.leaseLost(try await Bench.leaseToken(authority)).get()
            #expect(await authority.snapshot().authorizedWindows.isEmpty)
            let reacquired = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let held = await authority.snapshot()
            let refused = await authority.commit(project: Bench.projectA, authorization: authorization)
            #expect(Bench.refusal(refused) == .lifecycleRejectsChanges(.recovering))
            #expect(await authority.snapshot() == held)
            // The reviewed plan stays live and can still be withdrawn.
            try await authority.cancel(project: Bench.projectA).get()
            #expect(await engine.drain(authority) == [
                .setOutputsMuted(true), .restore(.initial, Bench.runningPlan, reacquired.token), .discard(reviewed)
            ])
        }

        @Test func lossKeepsOtherProjectsAndStalesTheirPlans() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let reviewedB = try await Bench.review(authority, &engine, project: Bench.projectB)
            let before = await authority.snapshot()
            try await authority.leaseLost(try await Bench.leaseToken(authority)).get()
            let after = await authority.snapshot()
            #expect(after.projects[Bench.projectB] == before.projects[Bench.projectB])
            let adopt = await authority.open(project: Bench.projectC,
                                             running: RunningGraph(revision: .initial, prepared: reviewedB))
            #expect(Bench.refusal(adopt) == .activation(.preparedIDInUse))
            _ = try await authority.acquire(project: Bench.projectB, window: Bench.windowB).get()
            let authorization = try await authority.authorize(project: Bench.projectB,
                                                              gesture: Bench.gesture(Bench.windowB)).get()
            let acquired = await authority.snapshot()
            let refused = Bench.refusal(await authority.commit(project: Bench.projectB, authorization: authorization))
            // H5d-2's Rule G turns B `.recovering`; until then the context bump stales B's plan.
            let stale: [HostAuthorityRefusal] = [.activation(.staleContext), .lifecycleRejectsChanges(.recovering)]
            #expect(refused.map { stale.contains($0) } == true)
            #expect(await authority.snapshot() == acquired)
        }

        @Test func fifoMutesAlsoMarkOutputsMuted() async throws {
            // abandonCommit's mute (queued in the FIFO).
            let abandoned = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.commitQueued(abandoned, &engine)
            #expect(await !abandoned.snapshot().outputsMuted)
            try await abandoned.abandonCommit(try await Bench.attempt(abandoned), reason: .outcomeUnknown).get()
            let queued = await abandoned.snapshot()
            #expect(queued.outputsMuted && queued.pendingOutput == nil)

            // The delivery guard's mute, in a withheld commit's place.
            let withheld = try await Bench.makeAuthority()
            var withheldEngine = try ScriptedActivationEngine()
            _ = try await Bench.commitQueued(withheld, &withheldEngine)
            try await withheld.release(project: Bench.projectA).get()
            #expect(await !withheld.snapshot().outputsMuted)
            #expect(await withheldEngine.drain(withheld) == [.setOutputsMuted(true)])
            let delivered = await withheld.snapshot()
            #expect(delivered.outputsMuted && delivered.pendingOutput == nil)
        }

        @Test func latePrepareSuccessAfterLossRoutesButStaysRecovering() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectA).get()
            await engine.drain(authority)
            try await authority.leaseLost(try await Bench.leaseToken(authority)).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            // The outstanding prepare's late success is still routed to A, which stays muted.
            let answer = try #require(await engine.answerNext(authority))
            #expect(answer.verdict == .success(.routed))
            let plan = try answer.answer.get()
            let routed = try await Bench.state(authority)
            #expect(routed.phase == .awaitingReview && routed.reviewed == plan && routed.lifecycle == .recovering)
            #expect(await authority.snapshot().outstanding.isEmpty)
            // Even under a reacquired lease and a fresh authorization, it cannot commit.
            _ = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let authorization = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            let held = await authority.snapshot()
            let refused = await authority.commit(project: Bench.projectA, authorization: authorization)
            #expect(Bench.refusal(refused) == .lifecycleRejectsChanges(.recovering))
            #expect(await authority.snapshot() == held)
            // It can be withdrawn: its discard is queued and A stays recovering.
            try await authority.cancel(project: Bench.projectA).get()
            let cancelled = try await Bench.state(authority)
            #expect(cancelled.phase == .idle && cancelled.reviewed == nil && cancelled.lifecycle == .recovering)
            // `contains`: H5d-2's Rule G may queue a restore on reacquire; this asserts nothing about it.
            #expect(await engine.drain(authority).contains(.discard(plan)))
            #expect(engine.pendingCommits.isEmpty)
        }

        @Test func latePrepareFailureAfterLossKeepsRecovering() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine(failing: [1: .prepareFailed])
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectA).get()
            await engine.drain(authority)
            try await authority.leaseLost(try await Bench.leaseToken(authority)).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let answer = try #require(await engine.answerNext(authority))
            #expect(answer.verdict == .success(.routed))
            let failed = try await Bench.state(authority)
            #expect(failed.phase == .prepareFailed(.engineRefused) && failed.lifecycle == .recovering)
            let after = await authority.snapshot()
            #expect(after.outstanding.isEmpty && after.outputsMuted && after.queue.pending.isEmpty)
            #expect(await engine.drain(authority).isEmpty)
        }
    }
}
