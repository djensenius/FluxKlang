import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

extension HostAuthorityTests {
    struct ActorCapabilityLoss {
        @Test func currentHolderLossIsIdempotentAndCanonical() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let before = await authority.snapshot()
            let token = try await Bench.leaseToken(authority)
            let network = CapabilityID(validated: "cap.network")

            try await authority.capabilityLost(network, project: Bench.projectA, token: token).get()
            let first = await authority.snapshot()
            #expect(first.projects[Bench.projectA]?.lifecycle == .degraded([network]))
            #expect(first.live == before.live && first.ledger == before.ledger)
            #expect(first.plans == before.plans && first.queue == before.queue)
            #expect(first.retirementOutbox == before.retirementOutbox)
            #expect(first.outstanding == before.outstanding && first.inFlight == before.inFlight)
            #expect(first.authorizedWindows == before.authorizedWindows)
            #expect(first.pendingOutput == before.pendingOutput && first.outputsMuted == before.outputsMuted)
            #expect(first.projects[Bench.projectA]?.running == before.projects[Bench.projectA]?.running)
            #expect(first.projects[Bench.projectA]?.installed == before.projects[Bench.projectA]?.installed)
            #expect(first.projects[Bench.projectA]?.reviewed == before.projects[Bench.projectA]?.reviewed)

            try await authority.capabilityLost(Bench.audio, project: Bench.projectA, token: token).get()
            let expected = [Bench.audio, network].sorted()
            #expect(try await Bench.state(authority).lifecycle == .degraded(expected))
            let beforeRepeat = await authority.snapshot()
            try await authority.capabilityLost(network, project: Bench.projectA, token: token).get()
            #expect(await authority.snapshot() == beforeRepeat)
        }

        @Test func lossRequiresTheExactCurrentHolderLease() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let old = try await Bench.leaseToken(authority)
            try await authority.release(project: Bench.projectA).get()
            let current = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let beforeStale = await authority.snapshot()
            #expect(Bench.refusal(await authority.capabilityLost(Bench.audio, project: Bench.projectA,
                                                                  token: old)) == .lease(.staleToken))
            #expect(await authority.snapshot() == beforeStale)

            try await authority.release(project: Bench.projectA).get()
            let other = try await authority.acquire(project: Bench.projectB, window: Bench.windowB).get().token
            let beforeOther = await authority.snapshot()
            #expect(Bench.refusal(await authority.capabilityLost(Bench.audio, project: Bench.projectA,
                                                                  token: other))
                    == .activation(.leaseHeldByOtherProject(Bench.projectB)))
            #expect(await authority.snapshot() == beforeOther)

            try await authority.release(project: Bench.projectB).get()
            let beforeUnheld = await authority.snapshot()
            #expect(Bench.refusal(await authority.capabilityLost(Bench.audio, project: Bench.projectA,
                                                                  token: current))
                    == .activation(.leaseNotHeld))
            #expect(await authority.snapshot() == beforeUnheld)
        }

        @Test func capabilityLossDuringPreparationBecomesTheRecoveryBase() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let runningRevision = try await Bench.state(authority).running.revision
            try await Bench.begin(authority)
            #expect(await engine.drain(authority).count == 1)
            let before = await authority.snapshot()
            let token = try await Bench.leaseToken(authority)

            try await authority.capabilityLost(Bench.audio, project: Bench.projectA, token: token).get()
            let preparing = EngineLifecycle.preparing(try runningRevision.next(),
                                                       over: .degraded([Bench.audio]))
            #expect(try await Bench.state(authority).lifecycle == preparing)
            #expect(await authority.snapshot().projects[Bench.projectA]?.record
                    == before.projects[Bench.projectA]?.record)
            #expect(await authority.snapshot().outstanding == before.outstanding)
            #expect(await authority.snapshot().inFlight == before.inFlight)

            try await authority.leaseLost(token).get()
            #expect(try await Bench.state(authority).recoveryBase == .degraded([Bench.audio]))
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let newToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let restore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [
                .restore(restore.attempt, restore.revision, restore.target, newToken)
            ])
            #expect(await engine.completeRestore(authority) == .success(preparing))
        }

        @Test func lossDuringCommitAndRecoveryRetainsSortedDegradation() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            _ = try await Bench.commitDelivered(authority, &engine)
            let token = try await Bench.leaseToken(authority)
            let before = await authority.snapshot()
            let attempt = try await Bench.attempt(authority)
            let runningRevision = try #require(before.projects[Bench.projectA]?.running.revision)

            try await authority.capabilityLost(Bench.audio, project: Bench.projectA, token: token).get()
            let duringCommit = await authority.snapshot()
            #expect(duringCommit.projects[Bench.projectA]?.phase == before.projects[Bench.projectA]?.phase)
            #expect(duringCommit.projects[Bench.projectA]?.record == before.projects[Bench.projectA]?.record)
            #expect(duringCommit.inFlight == before.inFlight)
            #expect(duringCommit.projects[Bench.projectA]?.lifecycle
                    == .preparing(try runningRevision.next(), over: .degraded([Bench.audio])))

            try await authority.abandonCommit(attempt, reason: .outcomeUnknown).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let midi = CapabilityID(validated: "cap.midi")
            try await authority.capabilityLost(midi, project: Bench.projectA, token: token).get()
            let retained = [Bench.audio, midi].sorted()
            let recovering = await authority.snapshot()
            #expect(recovering.projects[Bench.projectA]?.lifecycle == .recovering)
            #expect(recovering.projects[Bench.projectA]?.recoveryBase == .degraded(retained))
            #expect(recovering.inFlight.isEmpty && recovering.outputsMuted)

            #expect(await authority.resolveRecovery(project: Bench.projectA)
                    == .success(.restoring(runningRevision)))
            let restore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [
                .restore(restore.attempt, restore.revision, restore.target, token),
                .discard(try #require(before.projects[Bench.projectA]?.reviewed))
            ])
            #expect(await engine.completeRestore(authority) == .success(.degraded(retained)))
            #expect(await authority.nextEngineCommand() == .setOutputsMuted(false))
            #expect(await authority.lifecycle(of: Bench.projectA, window: Bench.windowA) == .degraded(retained))
        }
    }
}
