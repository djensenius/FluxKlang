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

extension HostAuthorityTests {
    /// Recovery restore admission, exact engine acknowledgement and fail-closed unmuting (H5d-2a).
    struct ActorRestore {
        @Test func restoreWaitsForHeldLease() async throws {
            let unheld = try await Bench.makeAuthority(holding: nil, lifecycleA: .recovering)
            let beforeUnheld = await unheld.snapshot()
            let unheldResult = await unheld.resolveRecovery(project: Bench.projectA)
            #expect(Bench.refusal(unheldResult) == .activation(.leaseNotHeld))
            #expect(await unheld.snapshot() == beforeUnheld)
            #expect(await unheld.nextEngineCommand() == nil)

            let otherHolder = try await Bench.makeAuthority(holding: nil, lifecycleA: .recovering)
            _ = try await otherHolder.acquire(project: Bench.projectB, window: Bench.windowB).get()
            let beforeOtherHolder = await otherHolder.snapshot()
            let heldByOther = await otherHolder.resolveRecovery(project: Bench.projectA)
            #expect(Bench.refusal(heldByOther) == .activation(.leaseHeldByOtherProject(Bench.projectB)))
            #expect(await otherHolder.snapshot() == beforeOtherHolder)
            #expect(await otherHolder.nextEngineCommand() == nil)
        }

        @Test func explicitResolveQueuesOneRestore() async throws {
            let authority = try await Bench.makeAuthority(holding: nil, lifecycleA: .recovering)
            try await Bench.fillQueue(authority)
            _ = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            #expect(await authority.snapshot().restoring == nil)
            var engine = try ScriptedActivationEngine()
            #expect((await engine.drain(authority)).count == EngineCommandQueue.capacity)

            let resolution = await authority.resolveRecovery(project: Bench.projectA)
            #expect(resolution == .success(.restoring(.initial)))
            let queued = try #require(await authority.snapshot().restoring)
            let token = try await Bench.leaseToken(authority)
            #expect(!queued.delivered && queued.token == token)
            #expect(await engine.drain(authority) == [
                .restore(queued.attempt, .initial, Bench.runningPlan, queued.token)
            ])
            #expect(await authority.snapshot().restoring?.delivered == true)
        }

        @Test func reacquireResumesRestoreUnderNewToken() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let failedPlan = try await Bench.commitDelivered(authority, &engine)
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])

            let newLease = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let newToken = newLease.token
            #expect(newToken != oldToken)
            let queuedRestore = try #require(await authority.snapshot().restoring)
            let commands = await engine.drain(authority)
            #expect(commands == [.restore(queuedRestore.attempt, .initial, Bench.runningPlan, newToken),
                                 .discard(failedPlan)])
            #expect(engine.pendingRestores == [ScriptedRestore(attempt: queuedRestore.attempt, revision: .initial,
                                                               prepared: Bench.runningPlan, token: newToken)])
            let restoring = try #require(await authority.snapshot().restoring)
            #expect(restoring.project == Bench.projectA && restoring.token == newToken && restoring.delivered)
        }

        @Test func queuedRestoreIsStaleAfterLeaseLoss() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let originalToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(originalToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let firstNewToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let firstRestore = try #require(await authority.snapshot().restoring)
            #expect(await authority.snapshot().queue.pending == [
                .restore(firstRestore.attempt, .initial, Bench.runningPlan, firstNewToken)
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
                .restore(latestRestore.attempt, .initial, Bench.runningPlan, latestToken)
            ])
            #expect(await authority.snapshot().restoring?.token == latestToken)
        }

        @Test func restoreAcknowledgementMustMatchDeliveredRecordAndCurrentLease() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let queued = try #require(await authority.snapshot().restoring)

            let undelivered = await authority.restoreCompleted(attempt: queued.attempt, revision: queued.revision,
                                                               prepared: queued.prepared, token: token)
            #expect(Bench.refusal(undelivered) == .staleRestore)
            #expect(await authority.snapshot().restoring?.delivered == false)
            #expect(await engine.drain(authority) == [
                .restore(queued.attempt, queued.revision, queued.prepared, token)
            ])
            let delivered = await authority.snapshot()
            let otherPlan = PreparedActivationID(validated: "prep.other")
            for (revision, prepared, suppliedToken) in [
                (try queued.revision.next(), queued.prepared, token),
                (queued.revision, otherPlan, token),
                (queued.revision, queued.prepared, oldToken)
            ] {
                let refused = await authority.restoreCompleted(attempt: queued.attempt, revision: revision,
                                                               prepared: prepared, token: suppliedToken)
                #expect(Bench.refusal(refused) == .staleRestore)
                #expect(await authority.snapshot() == delivered)
            }

            try await authority.release(project: Bench.projectA).get()
            let released = await authority.snapshot()
            #expect(released.restoring == nil)
            let afterRelease = await authority.restoreCompleted(attempt: queued.attempt, revision: queued.revision,
                                                                prepared: queued.prepared, token: token)
            #expect(Bench.refusal(afterRelease) == .staleRestore)
            #expect(await authority.snapshot() == released)
        }

        @Test func unmuteOnlyAfterMatchingRestoreAcknowledgement() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let granted = await authority.snapshot()
            let restore = try #require(granted.restoring)
            #expect(granted.outputsMuted && granted.pendingOutput == nil)
            #expect(await engine.drain(authority) == [
                .restore(restore.attempt, .initial, Bench.runningPlan, token)
            ])
            #expect(await authority.nextEngineCommand() == nil)
            #expect(await authority.snapshot().outputsMuted)

            let beforeAck = await authority.snapshot()
            #expect(await engine.completeRestore(authority) == .success(.running))
            let acknowledged = await authority.snapshot()
            #expect(acknowledged.outputsMuted == false && acknowledged.pendingOutput == false)
            #expect(Bench.context(acknowledged) == Bench.context(beforeAck))
            let duplicate = await authority.restoreCompleted(attempt: restore.attempt, revision: .initial,
                                                             prepared: Bench.runningPlan, token: token)
            #expect(Bench.refusal(duplicate) == .staleRestore)
            #expect(await authority.snapshot() == acknowledged)
            #expect(await authority.nextEngineCommand() == .setOutputsMuted(false))
            #expect(await authority.snapshot().projects[Bench.projectA]?.lifecycle == .running)
        }

        @Test func leaseLossAfterRestoreAcknowledgementRemutes() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let restore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [.restore(restore.attempt, .initial, Bench.runningPlan, token)])
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
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let oldToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(oldToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])

            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let restore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [.restore(restore.attempt, .initial, Bench.runningPlan, token)])
            _ = try await Bench.review(authority, &engine)
            #expect(await engine.completeRestore(authority) == .success(.running))
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

        @Test(arguments: [true, false])
        func restoreDiscardDependencySurvivesLeaseLoss(reacquire: Bool) async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let failedPlan = try await Bench.commitDelivered(authority, &engine)
            _ = try #require(await engine.report(authority, .failed)).verdict.get()

            let firstToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(firstToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let secondToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let secondRestore = try #require(await authority.snapshot().restoring)
            #expect(secondRestore.token == secondToken)
            #expect(secondRestore.discardAfterRestore == [failedPlan])
            #expect(await authority.snapshot().queue.pending == [
                .restore(secondRestore.attempt, .initial, Bench.runningPlan, secondToken), .discard(failedPlan)
            ])

            _ = try await authority.leaseLost(secondToken).get()
            let lost = await authority.snapshot()
            #expect(lost.restoring == nil)
            #expect(lost.deferredRestoreDiscards == [Bench.projectA: [failedPlan]])
            #expect(lost.queue.pending == [
                .restore(secondRestore.attempt, .initial, Bench.runningPlan, secondToken)
            ])
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            #expect(!engine.commands.contains(.discard(failedPlan)))

            guard reacquire else {
                #expect(await engine.drain(authority).isEmpty)
                return
            }
            let thirdToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let thirdRestore = try #require(await authority.snapshot().restoring)
            #expect(thirdToken != secondToken)
            #expect(await authority.snapshot().deferredRestoreDiscards.isEmpty)
            #expect(await engine.drain(authority) == [
                .restore(thirdRestore.attempt, .initial, Bench.runningPlan, thirdToken), .discard(failedPlan)
            ])
            #expect(engine.commands.suffix(2) == [
                .restore(thirdRestore.attempt, .initial, Bench.runningPlan, thirdToken), .discard(failedPlan)
            ])
            #expect(engine.commands.suffix(3) == [
                .setOutputsMuted(true), .restore(thirdRestore.attempt, .initial, Bench.runningPlan, thirdToken),
                .discard(failedPlan)
            ])
        }

        @Test func deferredRestorePlanCannotBeOpened() async throws {
            var engine = try ScriptedActivationEngine()
            let (authority, failedPlan) = try await authorityWithDeferredRestoreDiscard(&engine)
            let before = await authority.snapshot()
            let result = await authority.open(
                project: Bench.projectC, running: RunningGraph(revision: .initial, prepared: failedPlan)
            )
            #expect(Bench.refusal(result) == .activation(.preparedIDInUse))
            #expect(await authority.snapshot() == before)
        }

        @Test func deferredRestorePlanCannotBeAdoptedByPrepareAnswer() async throws {
            var engine = try ScriptedActivationEngine()
            let (authority, failedPlan) = try await authorityWithDeferredRestoreDiscard(&engine)
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectB).get()
            let attempt = try #require(await authority.snapshot().projects[Bench.projectB]?.lastPrepareAttempt)
            let before = await authority.snapshot()

            let result = await authority.prepareAnswered(.success(failedPlan), attempt: attempt)
            #expect(Bench.refusal(result) == .activation(.preparedIDInUse))
            #expect(await authority.snapshot() == before)
        }

        @Test func abandonedLateSuccessCannotDiscardDeferredRestorePlan() async throws {
            var engine = try ScriptedActivationEngine()
            let (authority, failedPlan) = try await authorityWithDeferredRestoreDiscard(&engine)
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectB).get()
            let attempt = try #require(await authority.snapshot().projects[Bench.projectB]?.lastPrepareAttempt)
            #expect(await engine.drain(authority).count == 1)
            let withheldAttempt = engine.withholdNext()
            #expect(withheldAttempt == attempt)
            try await authority.abandonPrepare(project: Bench.projectB).get()

            let result = await authority.prepareAnswered(.success(failedPlan), attempt: attempt)
            #expect(result == .success(.dropped))
            #expect(await authority.snapshot().queue.pending.isEmpty)
            #expect(await authority.snapshot().deferredRestoreDiscards == [Bench.projectA: [failedPlan]])

            let token = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let restore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [
                .restore(restore.attempt, .initial, Bench.runningPlan, token), .discard(failedPlan)
            ])
            #expect(engine.discarded == [failedPlan])
        }

        @Test func deliveredRestoreDiscardRetiresBeforePlanIDReuse() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let failedPlan = try await Bench.commitDelivered(authority, &engine)
            _ = try #require(await engine.report(authority, .failed)).verdict.get()
            let firstToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(firstToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])

            let secondToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let secondRestore = try #require(await authority.snapshot().restoring)
            #expect(await engine.drain(authority) == [
                .restore(secondRestore.attempt, .initial, Bench.runningPlan, secondToken), .discard(failedPlan)
            ])
            #expect(await authority.snapshot().restoring?.discardAfterRestore.isEmpty == true)

            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectB).get()
            let attempt = try #require(await authority.snapshot().projects[Bench.projectB]?.lastPrepareAttempt)
            #expect(await engine.drain(authority).count == 1)
            let withheldAttempt = engine.withholdNext()
            #expect(withheldAttempt == attempt)
            #expect(await authority.prepareAnswered(.success(failedPlan), attempt: attempt) == .success(.routed))
            try await authority.cancel(project: Bench.projectB).get()
            #expect(await authority.snapshot().queue.pending == [.discard(failedPlan)])

            _ = try await authority.leaseLost(secondToken).get()
            let lost = await authority.snapshot()
            #expect(lost.restoring == nil && lost.deferredRestoreDiscards.isEmpty)
            #expect(lost.queue.pending == [.discard(failedPlan)])
            #expect(await engine.drain(authority) == [.setOutputsMuted(true), .discard(failedPlan)])

            let thirdToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let thirdRestore = try #require(await authority.snapshot().restoring)
            #expect(thirdRestore.discardAfterRestore.isEmpty)
            #expect(await engine.drain(authority) == [
                .restore(thirdRestore.attempt, .initial, Bench.runningPlan, thirdToken)
            ])
            #expect(engine.discarded == [failedPlan, failedPlan])
        }

        @Test func sameLeasePartialRecoveryKeepsAdvancedRunningGraph() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let partialPlan = try await Bench.commitDelivered(authority, &engine, withAux: true)
            _ = try #require(await engine.report(authority, .partial)).verdict.get()

            let resolution = await authority.resolveRecovery(project: Bench.projectA)
            let revision = try ContractRevision.initial.next()
            #expect(resolution == .success(.keptPartial(revision)))
            #expect(await authority.snapshot().queue.pending == [
                .keepActivePartial(partialPlan), .placeholders([Bench.nodeOut]), .discard(Bench.runningPlan)
            ])
            let snapshot = await authority.snapshot()
            #expect(snapshot.projects[Bench.projectA]?.running == RunningGraph(revision: revision,
                                                                                prepared: partialPlan))
            #expect(snapshot.outputsMuted == false && snapshot.pendingOutput == nil)
            #expect(snapshot.restoring == nil)
            #expect(await engine.drain(authority) == [
                .keepActivePartial(partialPlan), .placeholders([Bench.nodeOut]), .discard(Bench.runningPlan)
            ])
        }

        @Test func resolvingWhileRestoreIsPendingIsBusy() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
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
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let failedPlan = try await Bench.commitDelivered(authority, &engine, withAux: phase.withAux)
            _ = try #require(await engine.report(authority, phase.outcome)).verdict.get()
            let token = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(token).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])

            let nextToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            let restore = try #require(await authority.snapshot().restoring)
            let commands = await engine.drain(authority)
            #expect(commands == [.restore(restore.attempt, .initial, Bench.runningPlan, nextToken),
                                 .discard(failedPlan)])
            #expect(!commands.contains { if case .keepActivePartial = $0 { true } else { false } })
            #expect(!commands.contains { if case .placeholders = $0 { true } else { false } })
            #expect(await engine.completeRestore(authority) == .success(.running))
        }

        @Test func changedLeaseOnPartialFailsClosedInsteadOfKeepingPartial() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            let partialPlan = try await Bench.commitDelivered(authority, &engine, withAux: true)
            _ = try #require(await engine.report(authority, .partial)).verdict.get()
            let oldToken = try await Bench.leaseToken(authority)
            try await authority.release(project: Bench.projectA).get()
            let newToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            #expect(newToken != oldToken)

            let resolution = await authority.resolveRecovery(project: Bench.projectA)
            #expect(resolution == .success(.restoring(.initial)))
            let queued = await authority.snapshot()
            #expect(queued.outputsMuted && queued.pendingOutput == true)
            let commands = await engine.drain(authority)
            let restore = try #require(queued.restoring)
            #expect(commands == [.setOutputsMuted(true), .restore(restore.attempt, .initial,
                                                                  Bench.runningPlan, newToken),
                                 .discard(partialPlan)])
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

        private func authorityWithDeferredRestoreDiscard(
            _ engine: inout ScriptedActivationEngine
        ) async throws -> (HostAuthority, PreparedActivationID) {
            let authority = try await Bench.makeAuthority()
            let failedPlan = try await Bench.commitDelivered(authority, &engine)
            _ = try #require(await engine.report(authority, .failed)).verdict.get()
            let firstToken = try await Bench.leaseToken(authority)
            _ = try await authority.leaseLost(firstToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            let secondToken = try await authority.acquire(project: Bench.projectA, window: Bench.windowA).get().token
            #expect(await authority.snapshot().restoring?.discardAfterRestore == [failedPlan])
            _ = try await authority.leaseLost(secondToken).get()
            #expect(await engine.drain(authority) == [.setOutputsMuted(true)])
            #expect(await authority.snapshot().deferredRestoreDiscards == [Bench.projectA: [failedPlan]])
            return (authority, failedPlan)
        }
    }
}
