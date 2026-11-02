import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

enum RestoreCommitPhase: CaseIterable, Sendable {
    case commitFailed, partial

    var outcome: ActivationCommitOutcome {
        switch self {
        case .commitFailed: .failed
        case .partial: .partial
        }
    }

    var withAux: Bool { self == .partial }
}

func authorityWithDeferredRestoreDiscard(
    _ engine: inout ScriptedActivationEngine
) async throws -> (HostAuthority, PlanBinding) {
    let authority = try await Bench.makeAuthority(&engine)
    _ = try await Bench.commitDelivered(authority, &engine)
    let failedBinding = try #require(try await Bench.state(authority).reviewed)
    _ = try #require(await engine.report(authority, .failed)).verdict.get()
    let firstToken = try await Bench.leaseToken(authority)
    _ = try await authority.leaseLost(firstToken).get()
    #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
    let secondToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
    #expect(await authority.snapshot().restoring?.discardAfterRestore == [failedBinding])
    _ = try await authority.leaseLost(secondToken).get()
    #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
    #expect(await authority.snapshot().deferredRestoreDiscards == [Bench.projectA: [failedBinding]])
    return (authority, failedBinding)
}

extension HostAuthorityTests {
    /// Recovery restore admission, exact engine acknowledgement and fail-closed unmuting (H5d-2a).
    struct ActorRestore {
        @Test func restoreWaitsForHeldLease() async throws {
            let unheld = try await Bench.makeAuthority(holding: nil, lifecycleA: .recovering,
                                                       recoveryBaseA: .running)
            let beforeUnheld = await unheld.snapshot()
            let unheldResult = await unheld.resolveRecovery(project: Bench.projectA)
            #expect(Bench.refusal(unheldResult) == .activation(.leaseNotHeld))
            #expect(await unheld.snapshot() == beforeUnheld)
            #expect(await unheld.snapshot().restoring == nil)

            let otherHolder = try await Bench.makeAuthority(holding: nil, lifecycleA: .recovering,
                                                            recoveryBaseA: .running)
            _ = try await otherHolder.acquire(project: Bench.projectB, window: Bench.windowB).get()
            let beforeOtherHolder = await otherHolder.snapshot()
            let heldByOther = await otherHolder.resolveRecovery(project: Bench.projectA)
            #expect(Bench.refusal(heldByOther) == .activation(.leaseHeldByOtherProject(Bench.projectB)))
            #expect(await otherHolder.snapshot() == beforeOtherHolder)
            #expect(await otherHolder.snapshot().restoring == nil)
        }

        @Test func explicitResolveQueuesOneRestore() async throws {
            var engine = try ScriptedActivationEngine(trackedLimit: EngineCommandQueue.capacity + 8)
            let authority = try await Bench.makeAuthority(&engine, holding: nil, lifecycleA: .recovering,
                                                          recoveryBaseA: .running)
            try await Bench.fillQueue(authority)
            _ = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            #expect(await authority.snapshot().restoring == nil)
            #expect((await engine.drain(authority)).count == EngineCommandQueue.capacity + 1)

            let resolution = await authority.resolveRecovery(project: Bench.projectA)
            let queued = try #require(await authority.snapshot().restoring)
            #expect(resolution == .success(.restoring(queued.revision)))
            let token = try await Bench.leaseToken(authority)
            #expect(!queued.delivered && queued.token == token)
            #expect(await engine.drain(authority) == [
                .restore(queued.attempt, queued.revision, queued.target, queued.token)
            ])
            #expect(await authority.snapshot().restoring?.delivered == true)
        }

        @Test func reacquireResumesRestoreUnderNewToken() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            _ = try await Bench.commitDelivered(authority, &engine)
            let failedBinding = try #require(try await Bench.state(authority).reviewed)
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])

            let newLease = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let newToken = newLease.token
            #expect(newToken != oldToken)
            let queuedRestore = try #require(await authority.snapshot().restoring)
            let commands = await engine.drain(authority)
            #expect(commands == [
                .restore(queuedRestore.attempt, queuedRestore.revision, queuedRestore.target, newToken),
                .discard(failedBinding)
            ])
            #expect(engine.pendingRestores == [ScriptedRestore(attempt: queuedRestore.attempt,
                                                               revision: queuedRestore.revision,
                                                               target: queuedRestore.target, token: newToken)])
            let restoring = try #require(await authority.snapshot().restoring)
            #expect(restoring.project == Bench.projectA && restoring.token == newToken && restoring.delivered)
        }

        @Test func queuedRestoreIsStaleAfterLeaseLoss() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let originalToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(originalToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let firstNewToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let firstRestore = try #require(await authority.snapshot().restoring)
            #expect(await authority.snapshot().queue.pending == [
                .restore(firstRestore.attempt, firstRestore.revision, firstRestore.target, firstNewToken)
            ])

            _ = try await authority.leaseLost(firstNewToken).get()
            let lost = await authority.snapshot()
            #expect(lost.restoring == nil && lost.pendingOutput == true && lost.outputsMuted)
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            #expect(await authority.snapshot().queue.isEmpty)

            let latestToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            #expect(latestToken != firstNewToken)
            let latestRestore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [
                .restore(latestRestore.attempt, latestRestore.revision, latestRestore.target, latestToken)
            ])
            #expect(await authority.snapshot().restoring?.token == latestToken)
        }

        @Test func restoreAcknowledgementMustMatchDeliveredRecordAndCurrentLease() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let queued = try #require(await authority.snapshot().restoring)

            let undelivered = await authority.restoreCompleted(attempt: queued.attempt, revision: queued.revision,
                                                               target: queued.target, token: token)
            #expect(Bench.refusal(undelivered) == .staleRestore)
            #expect(await authority.snapshot().restoring?.delivered == false)
            #expect(await engine.drain(authority) == [
                .restore(queued.attempt, queued.revision, queued.target, token)
            ])
            let delivered = await authority.snapshot()
            let wrongTarget = RestoreTarget.empty(queued.target.instance)
            for (revision, target, suppliedToken) in [
                (try queued.revision.next(), queued.target, token),
                (queued.revision, wrongTarget, token),
                (queued.revision, queued.target, oldToken)
            ] {
                let refused = await authority.restoreCompleted(attempt: queued.attempt, revision: revision,
                                                               target: target, token: suppliedToken)
                #expect(Bench.refusal(refused) == .staleRestore)
                #expect(await authority.snapshot() == delivered)
            }

            try await authority.release(project: Bench.projectA).get()
            let released = await authority.snapshot()
            #expect(released.restoring == nil)
            let afterRelease = await authority.restoreCompleted(attempt: queued.attempt, revision: queued.revision,
                                                                target: queued.target, token: token)
            #expect(Bench.refusal(afterRelease) == .staleRestore)
            #expect(await authority.snapshot() == released)
        }

        @Test func unmuteOnlyAfterMatchingRestoreAcknowledgement() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let granted = await authority.snapshot()
            let restore = try #require(granted.restoring)
            #expect(granted.outputsMuted && granted.pendingOutput == nil)
            #expect(await engine.drain(authority) == [
                .restore(restore.attempt, restore.revision, restore.target, token)
            ])
            #expect(await authority.nextEngineCommand() == nil)
            #expect(await authority.snapshot().outputsMuted)

            let beforeAck = await authority.snapshot()
            #expect(await engine.completeRestore(authority) == .success(.running))
            let acknowledged = await authority.snapshot()
            #expect(acknowledged.outputsMuted == false && acknowledged.pendingOutput == false)
            #expect(Bench.context(acknowledged) == Bench.context(beforeAck))
            let duplicate = await authority.restoreCompleted(attempt: restore.attempt, revision: restore.revision,
                                                             target: restore.target, token: token)
            #expect(Bench.refusal(duplicate) == .staleRestore)
            #expect(await authority.snapshot() == acknowledged)
            #expect(await authority.nextEngineCommand() == .setOutputsMuted(false))
            #expect(await authority.snapshot().projects[Bench.projectA]?.lifecycle == .running)
        }

        @Test func leaseLossAfterRestoreAcknowledgementRemutes() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let restore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [
                .restore(restore.attempt, restore.revision, restore.target, token)
            ])
            #expect(await engine.completeRestore(authority) == .success(.running))
            #expect(await authority.snapshot().pendingOutput == false)

            _ = try await authority.leaseLost(token).get()
            let remuted = await authority.snapshot()
            #expect(remuted.outputsMuted && remuted.pendingOutput == true)
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let afterMute = await authority.snapshot()
            #expect(afterMute.outputsMuted && afterMute.pendingOutput == nil)
        }

        @Test func fifoMuteCancelsAcknowledgementUnmuteBeforeDrain() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])

            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let restore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [
                .restore(restore.attempt, restore.revision, restore.target, token)
            ])
            _ = try await Bench.review(authority, &engine)
            let running = try await Bench.state(authority).running
            let preparing = EngineLifecycle.preparing(try running.revision.next(), over: .running)
            #expect(await engine.completeRestore(authority) == .success(preparing))
            let acknowledged = await authority.snapshot()
            #expect(!acknowledged.outputsMuted && acknowledged.pendingOutput == false)

            let authorization = try await authority.authorize(
                project: Bench.projectA, gesture: Bench.gesture()
            ).get()
            try await authority.commit(project: Bench.projectA, authorization: authorization).get()
            try await authority.abandonCommit(try await Bench.attempt(authority),
                                              reason: .outcomeUnknown).get()
            let abandoned = await authority.snapshot()
            #expect(abandoned.outputsMuted && abandoned.pendingOutput == nil)
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
        }

        @Test func resolvingWhileRestoreIsPendingIsBusy() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            let token = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(token).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            _ = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let pending = await authority.snapshot()
            #expect(pending.restoring != nil)
            let refused = await authority.resolveRecovery(project: Bench.projectA)
            #expect(Bench.refusal(refused) == .activation(.busy))
            #expect(await authority.snapshot() == pending)
        }

        @Test(arguments: RestoreCommitPhase.allCases)
        func leaseLossConvertsFailedAndPartialReportsToRestore(_ phase: RestoreCommitPhase) async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            _ = try await Bench.commitDelivered(authority, &engine, withAux: phase.withAux)
            let failedBinding = try #require(try await Bench.state(authority).reviewed)
            _ = try #require(await engine.report(authority, phase.outcome)).verdict.get()
            let token = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(token).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])

            let nextToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let restore = try #require(await authority.snapshot().restoring)
            let commands = await engine.drain(authority)
            #expect(commands == [.restore(restore.attempt, restore.revision, restore.target, nextToken),
                                 .discard(failedBinding)])
            #expect(!commands.contains { if case .keepActivePartial = $0 { true } else { false } })
            #expect(!commands.contains { if case .placeholders = $0 { true } else { false } })
            #expect(await engine.completeRestore(authority) == .success(.running))
        }

        @Test func changedLeaseOnPartialFailsClosedInsteadOfKeepingPartial() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            _ = try await Bench.commitDelivered(authority, &engine, withAux: true)
            let partialBinding = try #require(try await Bench.state(authority).reviewed)
            _ = try #require(await engine.report(authority, .partial)).verdict.get()
            let oldToken = try await Bench.leaseToken(authority)
            try await authority.release(project: Bench.projectA).get()
            let newToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            #expect(newToken != oldToken)

            let resolution = await authority.resolveRecovery(project: Bench.projectA)
            let queued = await authority.snapshot()
            let restore = try #require(queued.restoring)
            #expect(resolution == .success(.restoring(restore.revision)))
            #expect(queued.outputsMuted && queued.pendingOutput == true)
            let commands = await engine.drain(authority)
            #expect(commands == [.setOutputsMuted(true), .restore(restore.attempt, restore.revision,
                                                                  restore.target, newToken),
                                 .discard(partialBinding)])
            #expect(!commands.contains { if case .keepActivePartial = $0 { true } else { false } })
            #expect(!commands.contains { if case .placeholders = $0 { true } else { false } })
        }

        @Test func fullQueueRefusesRecoveryWithoutChangingSnapshot() async throws {
            let authority = try await Bench.makeAuthority()
            let token = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(token).get()
            try await Bench.fillQueue(authority)
            _ = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let full = await authority.snapshot()
            #expect(!full.queue.canAccept(EngineCommandQueue.maxRecoveryStepSlots))
            let refused = await authority.resolveRecovery(project: Bench.projectA)
            #expect(Bench.refusal(refused) == .queueFull)
            #expect(await authority.snapshot() == full)
        }

    }
}
