import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

extension HostAuthorityTests {
    /// Grant-time fail-closed recovery and the remaining recovery entry paths (H5d-2b).
    struct ActorUnmute {
        @Test(arguments: [true, false])
        func grantOnMutedEngineRestoresOnlyGrantee(transfer: Bool) async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            try await authority.open(project: Bench.projectC,
                                     running: RunningGraph(revision: .initial, prepared: nil),
                                     lifecycle: .recovering).get()
            _ = try await Bench.review(authority, &engine, project: Bench.projectB)
            _ = try await Bench.commitQueued(authority, &engine)
            try await authority.abandonCommit(try await Bench.attempt(authority), reason: .outcomeUnknown).get()
            if !transfer { try await authority.release(project: Bench.projectA).get() }
            let beforeGrant = await authority.snapshot()
            let lease: EngineLeaseSnapshot
            if transfer {
                lease = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
            } else {
                lease = try await authority.acquire(project: Bench.projectB, window: Bench.windowB).get()
            }
            let granted = await authority.snapshot()
            #expect(granted.projects[Bench.projectA] == beforeGrant.projects[Bench.projectA])
            #expect(granted.projects[Bench.projectC] == beforeGrant.projects[Bench.projectC])
            #expect(granted.projects[Bench.projectB]?.lifecycle == .recovering)
            #expect(granted.projects[Bench.projectB]?.recoveryBase == .absent)
            #expect(granted.restoring?.project == Bench.projectB)
            #expect(granted.restoring?.token == lease.token && granted.restoring?.delivered == false)
            #expect(granted.outputsMuted && granted.pendingOutput == nil)
            #expect(Bench.context(granted) == (try #require(Bench.context(beforeGrant)).next()))

            let authorization = try await authority.authorize(
                project: Bench.projectB, gesture: Bench.gesture(Bench.windowB)
            ).get()
            await expectRecoveringCommitRefusal(authority, project: Bench.projectB, authorization: authorization)
            let beforeDelivery = await authority.snapshot()
            let restore = try await Bench.restore(authority)
            let early = await Bench.acknowledge(restore, on: authority)
            #expect(Bench.refusal(early) == .staleRestore)
            #expect(await authority.snapshot() == beforeDelivery)
            #expect(await engine.drain(authority) == [
                .setOutputsMuted(true), Bench.restoreCommand(restore)
            ])
            #expect(engine.pendingCommits.isEmpty && engine.discarded.isEmpty)
            #expect(await authority.snapshot().outputsMuted)
            await expectRecoveringCommitRefusal(authority, project: Bench.projectB, authorization: authorization)

            let beforeAck = await authority.snapshot()
            let preparing = EngineLifecycle.preparing(try ContractRevision.initial.next(), over: .absent)
            #expect(await engine.completeRestore(authority) == .success(preparing))
            let acknowledged = await authority.snapshot()
            #expect(!acknowledged.outputsMuted && acknowledged.pendingOutput == false)
            #expect(Bench.context(acknowledged) == Bench.context(beforeAck))
            #expect(acknowledged.projects[Bench.projectA] == beforeGrant.projects[Bench.projectA])
            #expect(acknowledged.projects[Bench.projectC] == beforeGrant.projects[Bench.projectC])
            #expect(await engine.drain(authority) == [.setOutputsMuted(false)])
            let beforeCommit = await authority.snapshot()
            let stalePlan = await authority.commit(project: Bench.projectB, authorization: authorization)
            #expect(Bench.refusal(stalePlan) == .activation(.staleContext))
            #expect(await authority.snapshot() == beforeCommit)
        }

        @Test func mutedGrantWithFullQueueStaysRecovering() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            try await authority.open(project: Bench.projectC,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            _ = try await Bench.review(authority, &engine, project: Bench.projectB)
            _ = try await authority.leaseLost(try await Bench.leaseToken(authority)).get()
            try await Bench.fillQueue(authority, with: Bench.projectC)
            let beforeGrant = await authority.snapshot()
            let token = try await authority.acquire(project: Bench.projectB, window: Bench.windowB).get().token
            let granted = await authority.snapshot()
            #expect(granted.queue == beforeGrant.queue && granted.restoring == nil)
            #expect(granted.outputsMuted && granted.pendingOutput == true)
            #expect(granted.projects[Bench.projectB]?.lifecycle == .recovering)
            #expect(granted.projects[Bench.projectB]?.recoveryBase == .absent)
            #expect(granted.projects[Bench.projectA] == beforeGrant.projects[Bench.projectA])
            #expect(granted.projects[Bench.projectC] == beforeGrant.projects[Bench.projectC])
            #expect(Bench.refusal(await authority.resolveRecovery(project: Bench.projectB)) == .queueFull)
            #expect(await authority.snapshot() == granted)
            let authorization = try await authority.authorize(
                project: Bench.projectB, gesture: Bench.gesture(Bench.windowB)
            ).get()
            await expectRecoveringCommitRefusal(authority, project: Bench.projectB, authorization: authorization)
            let taken = await engine.drain(authority)
            #expect(taken.first == .setOutputsMuted(true))
            #expect(Array(taken.dropFirst()) == beforeGrant.queue.pending)
            #expect(engine.pendingRestores.isEmpty)
            #expect(await authority.snapshot().outputsMuted)
            await expectRecoveringCommitRefusal(authority, project: Bench.projectB, authorization: authorization)

            #expect(await authority.resolveRecovery(project: Bench.projectB) == .success(.restoring(.initial)))
            let restore = try await Bench.restore(authority)
            #expect(restore.token == token && restore.prepared == nil && restore.revision == .initial)
            #expect(await engine.drain(authority) == [Bench.restoreCommand(restore)])
            await expectRecoveringCommitRefusal(authority, project: Bench.projectB, authorization: authorization)
            let preparing = EngineLifecycle.preparing(try ContractRevision.initial.next(), over: .absent)
            #expect(await engine.completeRestore(authority) == .success(preparing))
            #expect(await engine.drain(authority) == [.setOutputsMuted(false)])
        }

        @Test func withheldCommitAfterReacquireRestoresUnderNewToken() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let failedPlan = try await Bench.commitQueued(authority, &engine)
            let attempt = try await Bench.attempt(authority)
            let oldToken = try await Bench.leaseToken(authority)
            try await authority.release(project: Bench.projectA).get()
            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            #expect(token != oldToken)
            let reacquired = await authority.snapshot()
            #expect(!reacquired.outputsMuted && reacquired.restoring == nil)
            #expect(reacquired.queue.pending == [.commit(failedPlan, attempt, oldToken)])

            #expect(await authority.nextEngineCommand() == .setOutputsMuted(true))
            let withheld = await authority.snapshot()
            #expect(withheld.outputsMuted && withheld.pendingOutput == nil)
            #expect(withheld.projects[Bench.projectA]?.lifecycle == .recovering)
            #expect(withheld.projects[Bench.projectA]?.phase == .idle)
            #expect(withheld.projects[Bench.projectB] == reacquired.projects[Bench.projectB])
            #expect(withheld.inFlight.isEmpty)
            #expect(Bench.context(withheld) == Bench.context(reacquired))
            #expect(withheld.restoring?.token == token && withheld.restoring?.delivered == false)
            #expect(withheld.restoring?.discardAfterRestore == [failedPlan])
            let restore = try await Bench.restore(authority)
            #expect(restore.prepared == Bench.runningPlan && restore.revision == .initial)
            #expect(withheld.queue.pending == [Bench.restoreCommand(restore), .discard(failedPlan)])
            let early = await Bench.acknowledge(restore, on: authority)
            #expect(Bench.refusal(early) == .staleRestore)
            #expect(await authority.snapshot() == withheld)
            let reuse = await authority.open(project: Bench.projectC,
                                            running: RunningGraph(revision: .initial, prepared: failedPlan))
            #expect(Bench.refusal(reuse) == .activation(.preparedIDInUse))
            #expect(await authority.snapshot() == withheld)

            #expect(await engine.drain(authority) == [
                Bench.restoreCommand(restore), .discard(failedPlan)
            ])
            #expect(engine.pendingCommits.isEmpty)
            #expect(await authority.snapshot().restoring?.discardAfterRestore.isEmpty == true)
            #expect(await authority.snapshot().outputsMuted)
            let delivered = await authority.snapshot()
            let stale = await authority.restoreCompleted(attempt: restore.attempt,
                                                          revision: .initial, prepared: Bench.runningPlan,
                                                          token: oldToken)
            #expect(Bench.refusal(stale) == .staleRestore)
            #expect(await authority.snapshot() == delivered)
            #expect(await engine.completeRestore(authority) == .success(.running))
            #expect(Bench.context(await authority.snapshot()) == Bench.context(reacquired))
            #expect(await engine.drain(authority) == [.setOutputsMuted(false)])
        }

        @Test func commitFailedResolvesWithoutUnmuteOrLifecycleChange() async throws {
            let degraded = EngineLifecycle.degraded([Bench.audio])
            let authority = try await Bench.makeAuthority(lifecycleA: degraded)
            var engine = try ScriptedActivationEngine()
            let failedPlan = try await Bench.commitDelivered(authority, &engine)
            #expect(try #require(await engine.report(authority, .failed)).verdict == .success(.failed))
            let failed = await authority.snapshot()
            #expect(failed.projects[Bench.projectA]?.phase == .commitFailed(failedPlan))
            #expect(failed.projects[Bench.projectA]?.lifecycle == degraded)
            #expect(!failed.outputsMuted && failed.pendingOutput == nil && failed.queue.isEmpty)

            try await Bench.fillQueue(authority)
            let full = await authority.snapshot()
            #expect(Bench.refusal(await authority.resolveRecovery(project: Bench.projectA)) == .queueFull)
            #expect(await authority.snapshot() == full)
            #expect(await engine.drain(authority) == full.queue.pending)
            #expect(await authority.resolveRecovery(project: Bench.projectA) == .success(.restoring(.initial)))
            let queued = await authority.snapshot()
            let token = try #require(queued.lease?.token)
            #expect(queued.projects[Bench.projectA]?.phase == .idle)
            #expect(queued.projects[Bench.projectA]?.running == failed.projects[Bench.projectA]?.running)
            #expect(queued.projects[Bench.projectA]?.lifecycle == degraded)
            #expect(!queued.outputsMuted && queued.pendingOutput == nil)
            #expect(queued.restoring?.discardAfterRestore == [failedPlan])
            let restore = try await Bench.restore(authority)
            #expect(restore.token == token && restore.prepared == Bench.runningPlan && restore.revision == .initial)
            #expect(queued.queue.pending == [Bench.restoreCommand(restore), .discard(failedPlan)])
            #expect(Bench.context(queued) == Bench.context(failed))
            let early = await Bench.acknowledge(restore, on: authority)
            #expect(Bench.refusal(early) == .staleRestore)
            #expect(await authority.snapshot() == queued)
            #expect(Bench.refusal(await authority.resolveRecovery(project: Bench.projectA)) == .activation(.busy))
            #expect(await authority.snapshot() == queued)

            #expect(await engine.drain(authority) == queued.queue.pending)
            let delivered = await authority.snapshot()
            #expect(delivered.restoring?.delivered == true)
            #expect(delivered.restoring?.discardAfterRestore.isEmpty == true)
            #expect(await engine.completeRestore(authority) == .success(degraded))
            let acknowledged = await authority.snapshot()
            #expect(acknowledged.restoring == nil && acknowledged.queue.isEmpty)
            #expect(!acknowledged.outputsMuted && acknowledged.pendingOutput == nil)
            #expect(acknowledged.projects == delivered.projects)
            #expect(acknowledged.ledger == failed.ledger)
            #expect(await engine.drain(authority).isEmpty)
            let duplicate = await Bench.acknowledge(restore, on: authority)
            #expect(Bench.refusal(duplicate) == .staleRestore)
            #expect(await authority.snapshot() == acknowledged)
            #expect(!engine.commands.contains(.setOutputsMuted(true)))
            #expect(!engine.commands.contains(.setOutputsMuted(false)))
        }

        private func expectRecoveringCommitRefusal(_ authority: HostAuthority, project: ProjectID,
                                                   authorization: ActivationAuthorization) async {
            let before = await authority.snapshot()
            #expect(Bench.refusal(await authority.commit(project: project, authorization: authorization))
                    == .lifecycleRejectsChanges(.recovering))
            #expect(await authority.snapshot() == before)
        }
    }
}
