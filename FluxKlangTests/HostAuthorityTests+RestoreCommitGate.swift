import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

enum RestoreLeaseStage: CaseIterable, Sendable {
    case queued, restoreDelivered, discardDelivered
}

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

        @Test(arguments: RestoreLeaseStage.allCases, RecoveryEntryBaseline.allCases)
        func leaseRetryKeepsObligationUntilExactAcknowledgement(
            stage: RestoreLeaseStage, baseline: RecoveryEntryBaseline
        ) async throws {
            var engine = try ScriptedActivationEngine()
            let (authority, old) = try await unmutedRetryFixture(&engine, stage: stage, baseline: baseline)
            let failed = try #require(old.discardAfterRestore.first)
            let beforeRelease = await authority.snapshot()
            try await authority.release(project: Bench.projectA).get()
            let released = await authority.snapshot()
            #expect(released.restoring == nil && !released.outputsMuted && released.pendingOutput == nil)
            #expect(released.projects[Bench.projectA]?.lifecycle == .recovering)
            #expect(released.projects[Bench.projectA]?.recoveryBase == baseline.base)
            #expect(released.projects[Bench.projectA]?.phase == .idle)
            #expect(released.projects[Bench.projectB] == beforeRelease.projects[Bench.projectB])
            #expect(released.deferredRestoreDiscards ==
                    (stage == .discardDelivered ? [:] : [Bench.projectA: [failed]]))
            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let current = try await Bench.restore(authority)
            #expect(current.attempt != old.attempt && token != old.token && current.token == token)
            #expect(current.revision == old.revision && current.prepared == old.prepared && !current.delivered)
            let queued = await authority.snapshot()
            #expect(current.discardAfterRestore == (stage == .discardDelivered ? [] : [failed]))
            #expect(queued.deferredRestoreDiscards.isEmpty)
            #expect(Bench.refusal(await Bench.acknowledge(old, on: authority)) == .staleRestore)
            #expect(Bench.refusal(await Bench.acknowledge(current, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == queued)
            if stage != .discardDelivered {
                let reuse = await authority.open(project: Bench.projectC,
                                                 running: RunningGraph(revision: .initial, prepared: failed))
                #expect(Bench.refusal(reuse) == .activation(.preparedIDInUse))
                #expect(await authority.snapshot() == queued)
            }
            #expect(await engine.drain(authority) == [Bench.restoreCommand(current)] +
                    (stage == .discardDelivered ? [] : [.discard(failed)]))
            #expect(await authority.snapshot().restoring?.discardAfterRestore.isEmpty == true)
            // The discarded ID is now free even though acknowledgement is still owed.
            try await authority.open(project: Bench.projectC,
                                     running: RunningGraph(revision: .initial, prepared: failed)).get()
            let fresh = try await Bench.review(authority, &engine)
            let authorization = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            await expectRetryGate(authority, authorization: authorization)
            let delivered = await authority.snapshot()
            #expect(Bench.refusal(await Bench.acknowledge(old, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == delivered)
            await expectRetryGate(authority, authorization: authorization)
            let preparing = EngineLifecycle.preparing(try ContractRevision.initial.next(), over: baseline.base)
            #expect(await engine.completeRestore(authority) == .success(preparing))
            let acknowledged = await authority.snapshot()
            #expect(acknowledged.projects[Bench.projectA]?.recoveryBase == nil)
            #expect(!acknowledged.outputsMuted && acknowledged.pendingOutput == nil)
            #expect(acknowledged.ledger == queued.ledger && acknowledged.restoring == nil)
            #expect(acknowledged.authorizedWindows == delivered.authorizedWindows)
            // No re-prepare or re-authorization after this exact acknowledgement.
            try await authority.commit(project: Bench.projectA, authorization: authorization).get()
            #expect(await engine.drain(authority) == [
                .commit(fresh, try await Bench.attempt(authority), token)
            ])
            _ = try #require(await engine.report(authority, .succeeded)).verdict.get()
            #expect(await engine.drain(authority) == [.discard(Bench.runningPlan)])
            let settled = try await Bench.state(authority)
            #expect(settled.lifecycle == (baseline == .degraded ? baseline.lifecycle : .running))
            try await authority.release(project: Bench.projectA).get()
            _ = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let done = await authority.snapshot()
            #expect(done.restoring == nil && done.deferredRestoreDiscards.isEmpty && done.queue.isEmpty)
            #expect(done.projects[Bench.projectA] == settled)
            #expect(engine.discarded == [failed, Bench.runningPlan])
            #expect(!engine.commands.contains(.setOutputsMuted(true)))
            #expect(!engine.commands.contains(.setOutputsMuted(false)))
        }

        @Test(arguments: RestoreLeaseStage.allCases, RecoveryEntryBaseline.allCases)
        func leaseRetryUnderPressureRetainsGateWithoutAnAttempt(
            stage: RestoreLeaseStage, baseline: RecoveryEntryBaseline
        ) async throws {
            var engine = try ScriptedActivationEngine()
            let (authority, old) = try await unmutedRetryFixture(&engine, stage: stage, baseline: baseline)
            let failed = try #require(old.discardAfterRestore.first)
            try await authority.release(project: Bench.projectA).get()
            try await Bench.fillQueue(authority)
            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let full = await authority.snapshot()
            #expect(full.restoring == nil && full.queue.count == EngineCommandQueue.capacity)
            #expect(full.projects[Bench.projectA]?.lifecycle == .recovering)
            #expect(full.projects[Bench.projectA]?.recoveryBase == baseline.base)
            #expect(!full.outputsMuted && full.pendingOutput == nil)
            #expect(Bench.refusal(await authority.resolveRecovery(project: Bench.projectA)) == .queueFull)
            #expect(Bench.refusal(await Bench.acknowledge(old, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == full)
            #expect(await engine.drain(authority) == full.queue.pending.filter {
                if case .restore = $0 { false } else { true }
            })
            // Drop only the fixture's already-abandoned B prepare callbacks, bounded by capacity.
            for _ in 0..<EngineCommandQueue.capacity { _ = engine.withholdNext() }
            #expect(engine.pending.isEmpty && engine.pendingRestores.isEmpty)
            let fresh = try await Bench.review(authority, &engine)
            let authorization = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            #expect(await authority.snapshot().restoring == nil)
            await expectRetryGate(authority, authorization: authorization)
            let beforeRetry = await authority.snapshot()
            #expect(Bench.refusal(await Bench.acknowledge(old, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == beforeRetry)
            _ = try await authority.resolveRecovery(project: Bench.projectA).get()
            let current = try await Bench.restore(authority)
            #expect(current.token == token && current.attempt != old.attempt)
            #expect(current.prepared == old.prepared && current.revision == old.revision)
            await expectRetryGate(authority, authorization: authorization)
            let queued = await authority.snapshot()
            #expect(Bench.refusal(await Bench.acknowledge(current, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == queued)
            #expect(await engine.drain(authority) == [Bench.restoreCommand(current)] +
                    (stage == .discardDelivered ? [] : [.discard(failed)]))
            #expect(engine.discarded == [failed])
            #expect(await authority.snapshot().restoring?.discardAfterRestore.isEmpty == true)
            await expectRetryGate(authority, authorization: authorization)
            let preparing = EngineLifecycle.preparing(try ContractRevision.initial.next(), over: baseline.base)
            #expect(await engine.completeRestore(authority) == .success(preparing))
            let acknowledged = await authority.snapshot()
            #expect(acknowledged.deferredRestoreDiscards.isEmpty && acknowledged.queue.isEmpty)
            #expect(acknowledged.ledger == full.ledger && !acknowledged.outputsMuted)
            #expect(acknowledged.pendingOutput == nil && acknowledged.restoring == nil)
            try await authority.commit(project: Bench.projectA, authorization: authorization).get()
            #expect(await engine.drain(authority) == [
                .commit(fresh, try await Bench.attempt(authority), token)
            ])
            #expect(!engine.commands.contains(.setOutputsMuted(true)))
            #expect(!engine.commands.contains(.setOutputsMuted(false)))
        }

        @Test(arguments: [false, true], RecoveryEntryBaseline.allCases)
        func retryAfterPreparationPreservesBaseAndAllowsCancellation(
            reviewed: Bool, baseline: RecoveryEntryBaseline
        ) async throws {
            var engine = try ScriptedActivationEngine()
            let (authority, old) = try await unmutedRetryFixture(
                &engine, stage: .discardDelivered, baseline: baseline
            )
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectA).get()
            _ = await engine.drain(authority)
            var reviewedPlan: PreparedActivationID?
            if reviewed {
                _ = try #require(await engine.answerNext(authority)).verdict.get()
                reviewedPlan = try #require(await authority.snapshot().projects[Bench.projectA]?.reviewed)
            } else {
                #expect(engine.withholdNext() != nil)
            }
            let beforeTransfer = await authority.snapshot()
            _ = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
            let transferred = await authority.snapshot()
            #expect(transferred.restoring == nil && !transferred.outputsMuted)
            #expect(transferred.projects[Bench.projectA]?.lifecycle == .recovering)
            #expect(transferred.projects[Bench.projectA]?.recoveryBase == baseline.base)
            #expect(transferred.projects[Bench.projectA]?.phase == (reviewed ? .awaitingReview : .preparing))
            #expect(transferred.projects[Bench.projectB] == beforeTransfer.projects[Bench.projectB])
            // A's unresolved obligation must not gate an unrelated current holder.
            _ = try await Bench.review(authority, &engine, project: Bench.projectB)
            let authorization = try await authority.authorize(
                project: Bench.projectB, gesture: Bench.gesture(Bench.windowB)
            ).get()
            try await authority.commit(project: Bench.projectB, authorization: authorization).get()
            _ = await engine.drain(authority)
            _ = try #require(await engine.report(authority, .succeeded)).verdict.get()
            _ = try await authority.transfer(to: Bench.projectA, window: Bench.windowA).get()
            let current = try await Bench.restore(authority)
            #expect(current.attempt != old.attempt && current.token != old.token)
            if reviewed {
                try await authority.cancel(project: Bench.projectA).get()
            } else {
                try await authority.abandonPrepare(project: Bench.projectA).get()
            }
            let cancelled = await authority.snapshot()
            #expect(cancelled.projects[Bench.projectA]?.lifecycle == .recovering)
            #expect(cancelled.projects[Bench.projectA]?.recoveryBase == baseline.base)
            #expect(cancelled.projects[Bench.projectA]?.phase == .idle)
            #expect(Bench.refusal(await Bench.acknowledge(old, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == cancelled)
            #expect(await engine.drain(authority) ==
                    [Bench.restoreCommand(current)] + (reviewedPlan.map { [.discard($0)] } ?? []))
            #expect(await engine.completeRestore(authority) == .success(baseline.lifecycle))
            #expect(await authority.snapshot().projects[Bench.projectA]?.recoveryBase == nil)
            #expect(await authority.snapshot().ledger == cancelled.ledger)
            #expect(await engine.drain(authority).isEmpty)
        }

        private func unmutedRetryFixture(
            _ engine: inout ScriptedActivationEngine, stage: RestoreLeaseStage, baseline: RecoveryEntryBaseline
        ) async throws -> (HostAuthority, RestoreRecord) {
            let authority = try await Bench.makeAuthority(lifecycleA: baseline.lifecycle)
            let failed = try await Bench.commitDelivered(authority, &engine)
            _ = try #require(await engine.report(authority, .failed)).verdict.get()
            _ = try await authority.resolveRecovery(project: Bench.projectA).get()
            let old = try await Bench.restore(authority)
            if stage != .queued {
                #expect(await authority.nextEngineCommand() == Bench.restoreCommand(old))
            }
            if stage == .discardDelivered {
                #expect(await engine.drain(authority) == [.discard(failed)])
            }
            return (authority, old)
        }

        private func expectRetryGate(_ authority: HostAuthority, authorization: ActivationAuthorization) async {
            let before = await authority.snapshot()
            #expect(Bench.refusal(await authority.commit(project: Bench.projectA, authorization: authorization))
                    == .lifecycleRejectsChanges(.recovering))
            #expect(await authority.snapshot() == before)
        }

        private func expectCommitBusy(_ authority: HostAuthority, authorization: ActivationAuthorization) async {
            let before = await authority.snapshot()
            #expect(Bench.refusal(await authority.commit(project: Bench.projectA, authorization: authorization))
                    == .activation(.busy))
            #expect(await authority.snapshot() == before)
        }
    }
}
