import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

extension HostAuthorityTests {
    /// The converse of Rule M's resolve guard: consume no commit authorization
    /// while an identified restore is queued or awaiting acknowledgement.
    struct RestoreCommitGate {
        @Test(arguments: [EngineLifecycle.running, .degraded([Bench.audio])])
        func unmutedRestoreGatesOnlyCommitConsumption(lifecycle: EngineLifecycle) async throws {
            let authority = try await Bench.makeAuthority(lifecycleA: lifecycle)
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.commitDelivered(authority, &engine)
            _ = try #require(await engine.report(authority, .failed)).verdict.get()
            _ = try await authority.resolveRecovery(project: Bench.projectA).get()
            let old = try await Bench.restore(authority)
            _ = await engine.drain(authority)
            #expect(await engine.completeRestore(authority) == .success(lifecycle))

            let failed = try await Bench.commitDelivered(authority, &engine)
            _ = try #require(await engine.report(authority, .failed)).verdict.get()
            _ = try await authority.resolveRecovery(project: Bench.projectA).get()
            let current = try await Bench.restore(authority)
            #expect(current.attempt != old.attempt && current.token == old.token)
            #expect(current.revision == old.revision && current.prepared == old.prepared)
            #expect(await authority.snapshot().projects[Bench.projectA]?.lifecycle == lifecycle)

            // Preparation and authorization remain legal. An early adapter answer
            // (accepted by the existing prepare API) reaches the pre-delivery gate
            // without injecting actor state or pulling the restore ahead of time.
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectA).get()
            let prepare = try #require(await authority.snapshot().projects[Bench.projectA]?.lastPrepareAttempt)
            let fresh = PreparedActivationID(validated: "prep.fresh")
            #expect(await authority.prepareAnswered(.success(fresh), attempt: prepare) == .success(.routed))
            let authorization = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            let queued = await authority.snapshot()
            #expect(queued.projects[Bench.projectA]?.phase == .awaitingReview)
            #expect(queued.projects[Bench.projectA]?.reviewed == fresh)
            #expect(queued.authorizedWindows == [Bench.projectA: Bench.windowA])
            #expect(!queued.outputsMuted && queued.pendingOutput == nil && queued.restoring?.delivered == false)
            await expectCommitBusy(authority, authorization: authorization)
            #expect(Bench.refusal(await Bench.acknowledge(old, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == queued)
            #expect(Bench.refusal(await Bench.acknowledge(current, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == queued)
            await expectCommitBusy(authority, authorization: authorization)

            #expect(await engine.drain(authority) == [
                Bench.restoreCommand(current), .discard(failed), .prepare(Bench.candidate(), prepare)
            ])
            let delivered = await authority.snapshot()
            #expect(delivered.restoring?.delivered == true && delivered.inFlight.isEmpty)
            await expectCommitBusy(authority, authorization: authorization)
            #expect(Bench.refusal(await Bench.acknowledge(old, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == delivered)
            await expectCommitBusy(authority, authorization: authorization)

            let preparing = try #require(delivered.projects[Bench.projectA]?.lifecycle)
            #expect(await engine.completeRestore(authority) == .success(preparing))
            let acknowledged = await authority.snapshot()
            #expect(acknowledged.restoring == nil && acknowledged.ledger == queued.ledger)
            #expect(acknowledged.projects == delivered.projects)
            #expect(acknowledged.authorizedWindows == queued.authorizedWindows)
            #expect(!acknowledged.outputsMuted && acknowledged.pendingOutput == nil)
            // No re-prepare, re-authorization, window change or context refresh.
            try await authority.commit(project: Bench.projectA, authorization: authorization).get()
            let attempt = try await Bench.attempt(authority)
            #expect(await engine.drain(authority) == [.commit(fresh, attempt, current.token)])
            #expect(await authority.snapshot().restoring == nil)
            #expect(!engine.commands.contains(.setOutputsMuted(false)))
        }

        private func expectCommitBusy(_ authority: HostAuthority, authorization: ActivationAuthorization) async {
            let before = await authority.snapshot()
            #expect(Bench.refusal(await authority.commit(project: Bench.projectA, authorization: authorization))
                    == .activation(.busy))
            #expect(await authority.snapshot() == before)
        }
    }
}
