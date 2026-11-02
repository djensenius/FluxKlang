import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

extension HostAuthorityTests {
    struct ActorRestoreDependencies {
        @Test(arguments: [true, false])
        func restoreDiscardDependencySurvivesLeaseLoss(reacquire: Bool) async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            _ = try await Bench.commitDelivered(authority, &engine)
            let failedBinding = try #require(try await Bench.state(authority).reviewed)
            _ = try #require(await engine.report(authority, .failed)).verdict.get()

            let firstToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(firstToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let secondToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let secondRestore = try #require(await authority.snapshot().restoring)
            #expect(secondRestore.token == secondToken)
            #expect(secondRestore.discardAfterRestore == [failedBinding])
            #expect(await authority.snapshot().queue.pending == [
                .restore(secondRestore.attempt, secondRestore.revision, secondRestore.target, secondToken),
                .discard(failedBinding)
            ])

            _ = try await authority.leaseLost(secondToken).get()
            let lost = await authority.snapshot()
            #expect(lost.restoring == nil)
            #expect(lost.deferredRestoreDiscards == [Bench.projectA: [failedBinding]])
            #expect(lost.queue.pending == [
                .restore(secondRestore.attempt, secondRestore.revision, secondRestore.target, secondToken)
            ])
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            #expect(!engine.commands.contains(.discard(failedBinding)))
            #expect(Bench.refusal(await authority.retired(failedBinding)) == .retirementQueued)

            guard reacquire else {
                #expect(await engine.drain(authority).isEmpty)
                return
            }
            let thirdToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let thirdRestore = try #require(await authority.snapshot().restoring)
            #expect(thirdToken != secondToken)
            #expect(await authority.snapshot().deferredRestoreDiscards.isEmpty)
            #expect(await engine.drain(authority) == [
                .restore(thirdRestore.attempt, thirdRestore.revision, thirdRestore.target, thirdToken),
                .discard(failedBinding)
            ])
            #expect(engine.commands.suffix(2) == [
                .restore(thirdRestore.attempt, thirdRestore.revision, thirdRestore.target, thirdToken),
                .discard(failedBinding)
            ])
            #expect(engine.commands.suffix(3) == [
                .setOutputsMuted(true),
                .restore(thirdRestore.attempt, thirdRestore.revision, thirdRestore.target, thirdToken),
                .discard(failedBinding)
            ])
        }

        @Test func deferredRestoreBindingDoesNotAliasSameNamedPreparation() async throws {
            var engine = try ScriptedActivationEngine()
            let (authority, failedBinding) = try await authorityWithDeferredRestoreDiscard(&engine)
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectB).get()
            let preparation = try #require(await authority.snapshot().outstanding[Bench.projectB])
            #expect(await engine.drain(authority).count == 1)
            let result = await authority.prepareAnswered(.success(failedBinding.prepared),
                                                         instance: preparation.instance,
                                                         attempt: preparation.attempt)
            #expect(result == .success(.routed))
            let rebound = try #require(await Bench.state(authority, Bench.projectB).reviewed)
            #expect(rebound.prepared == failedBinding.prepared && rebound != failedBinding)
            #expect(await authority.snapshot().deferredRestoreDiscards == [Bench.projectA: [failedBinding]])
            let rawAdoption = await authority.open(project: Bench.projectC,
                                                   running: RunningGraph(revision: .initial,
                                                                         prepared: failedBinding.prepared))
            #expect(Bench.refusal(rawAdoption) == .unqualifiedResident)
        }

        @Test func abandonedLateSuccessCannotDiscardDeferredRestorePlan() async throws {
            var engine = try ScriptedActivationEngine()
            let (authority, failedBinding) = try await authorityWithDeferredRestoreDiscard(&engine)
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectB).get()
            let preparation = try #require(await authority.snapshot().outstanding[Bench.projectB])
            #expect(await engine.drain(authority).count == 1)
            let withheldAttempt = engine.withholdNext()
            #expect(withheldAttempt == preparation)
            try await authority.abandonPrepare(project: Bench.projectB).get()

            let answer = engine.prepare(preparation, as: failedBinding.prepared)
            let result = await authority.prepareAnswered(answer, instance: preparation.instance,
                                                         attempt: preparation.attempt)
            guard case .success(.reclaimed(let lateBinding)) = result else {
                Issue.record("Expected a separately qualified late retirement")
                return
            }
            #expect(lateBinding != failedBinding && lateBinding.prepared == failedBinding.prepared)
            #expect(await authority.snapshot().queue.pending == [.discard(lateBinding)])
            #expect(await authority.snapshot().deferredRestoreDiscards == [Bench.projectA: [failedBinding]])

            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let restore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [
                .discard(lateBinding), .restore(restore.attempt, restore.revision, restore.target, token),
                .discard(failedBinding)
            ])
            #expect(engine.discarded.suffix(2).elementsEqual([lateBinding, failedBinding]))
        }

        @Test func deliveredRestoreDiscardRetiresBeforePlanIDReuse() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            _ = try await Bench.commitDelivered(authority, &engine)
            let failedBinding = try #require(try await Bench.state(authority).reviewed)
            _ = try #require(await engine.report(authority, .failed)).verdict.get()
            let firstToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(firstToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])

            let secondToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let secondRestore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [
                .restore(secondRestore.attempt, secondRestore.revision, secondRestore.target, secondToken),
                .discard(failedBinding)
            ])
            #expect(await authority.snapshot().restoring?.discardAfterRestore.isEmpty == true)

            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectB).get()
            let preparation = try #require(await authority.snapshot().outstanding[Bench.projectB])
            #expect(await engine.drain(authority).count == 1)
            let withheldAttempt = engine.withholdNext()
            #expect(withheldAttempt == preparation)
            let answer = engine.prepare(preparation, as: failedBinding.prepared)
            #expect(await authority.prepareAnswered(answer, instance: preparation.instance,
                                                     attempt: preparation.attempt) == .success(.routed))
            let reused = try #require(await Bench.state(authority, Bench.projectB).reviewed)
            #expect(reused != failedBinding && reused.prepared == failedBinding.prepared)
            try await authority.cancel(project: Bench.projectB).get()
            #expect(await authority.snapshot().queue.pending == [.discard(reused)])

            _ = try await authority.leaseLost(secondToken).get()
            let lost = await authority.snapshot()
            #expect(lost.restoring == nil && lost.deferredRestoreDiscards.isEmpty)
            #expect(lost.queue.pending == [.discard(reused)])
            #expect(await engine.drain(authority) == [.setOutputsMuted(true), .discard(reused)])

            let thirdToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let thirdRestore = try #require(await authority.snapshot().restoring)
            #expect(thirdRestore.discardAfterRestore.isEmpty)
            #expect(await engine.drain(authority) == [
                .restore(thirdRestore.attempt, thirdRestore.revision, thirdRestore.target, thirdToken)
            ])
            #expect(engine.discarded.suffix(2).elementsEqual([failedBinding, reused]))
        }

        @Test func sameLeasePartialRecoveryKeepsAdvancedRunningGraph() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let previous = try #require(try await Bench.state(authority).installed)
            let partialPlan = try await Bench.commitDelivered(authority, &engine, withAux: true)
            _ = try #require(await engine.report(authority, .partial)).verdict.get()

            let revision = try await Bench.state(authority).running.revision.next()
            let resolution = await authority.resolveRecovery(project: Bench.projectA)
            #expect(resolution == .success(.keptPartial(revision)))
            let queued = await authority.snapshot().queue.pending
            guard case .keepActivePartial(let kept)? = queued.first else {
                Issue.record("Expected a qualified partial resident")
                return
            }
            #expect(kept.binding.prepared == partialPlan)
            #expect(Array(queued.dropFirst()) == [.placeholders([Bench.nodeOut]), .discard(previous)])
            let snapshot = await authority.snapshot()
            #expect(snapshot.projects[Bench.projectA]?.running == RunningGraph(revision: revision,
                                                                                prepared: partialPlan))
            #expect(snapshot.outputsMuted == false && snapshot.pendingOutput == nil)
            #expect(snapshot.restoring == nil)
            let commands = await engine.drain(authority)
            guard case .keepActivePartial(let delivered)? = commands.first else {
                Issue.record("Expected a qualified partial resident delivery")
                return
            }
            #expect(delivered == kept)
            #expect(Array(commands.dropFirst()) == [.placeholders([Bench.nodeOut]), .discard(previous)])
        }

        @Test func firstPartialActivationStartsRenderingOnlyWhenKept() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine, lifecycleA: .stopped)
            #expect(try await Bench.state(authority).installed == nil)
            _ = try await Bench.commitDelivered(authority, &engine, withAux: true)
            _ = try #require(await engine.report(authority, .partial)).verdict.get()

            #expect(try await Bench.state(authority).lifecycle == .stopped)
            #expect(await authority.resolveRecovery(project: Bench.projectA)
                    == .success(.keptPartial(try ContractRevision.initial.next())))
            let state = try await Bench.state(authority)
            #expect(state.running == RunningGraph(revision: try ContractRevision.initial.next(),
                                                   prepared: state.installed?.prepared))
            #expect(state.lifecycle == .running && state.lifecycle.rendersOutput)
            #expect(await authority.snapshot().restoring == nil)
            #expect(await authority.snapshot().outputsMuted == false)
            let commands = await engine.drain(authority)
            guard case .keepActivePartial(let resident)? = commands.first else {
                Issue.record("Expected a qualified first partial resident")
                return
            }
            #expect(resident.binding == state.installed)
            #expect(Array(commands.dropFirst()) == [.placeholders([Bench.nodeOut])])
        }

        @Test func partialKeepPreservesDegradedLifecycle() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine, lifecycleA: .degraded([Bench.audio]))
            _ = try await Bench.commitDelivered(authority, &engine, withAux: true)
            _ = try #require(await engine.report(authority, .partial)).verdict.get()
            let revision = try await Bench.state(authority).running.revision.next()
            #expect(await authority.resolveRecovery(project: Bench.projectA) == .success(.keptPartial(revision)))
            let lifecycle = try await Bench.state(authority).lifecycle
            #expect(lifecycle == .degraded([Bench.audio]) && lifecycle.rendersOutput)
        }
    }
}
