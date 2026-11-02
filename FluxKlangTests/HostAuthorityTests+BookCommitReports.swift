import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

/// This fixture NEVER copies a book: copies would alias its canonical ledger.
/// Every identity comes from a real command; no binding/resident construction.
private func deliver(
    _ book: inout HostAuthorityBook, name: PreparedActivationID, outcome: ActivationCommitOutcome
) throws -> (PlanBinding, ActivationCommitReport) {
    let revision = try #require(book.snapshot().projects[Bench.projectA]).running.revision
    try book.begin(Bench.request(base: revision), candidate: Bench.candidate(revision: revision),
                   project: Bench.projectA).get()
    let preparedCommand = book.nextEngineCommand()
    guard case .prepare(let graph, let instance, let prepare) = try #require(preparedCommand) else {
        throw BookReportError.command
    }
    #expect(try book.prepareAnswered(.success(name), instance: instance, attempt: prepare).get() == .routed)
    let authorization = try book.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
    try book.commit(project: Bench.projectA, authorization: authorization).get()
    let committedCommand = book.nextEngineCommand()
    guard case .commit(let binding, let attempt, _) = try #require(committedCommand) else {
        throw BookReportError.command
    }
    #expect(binding.instance == instance && binding.attempt == prepare && binding.prepared == name)
    let nodes = Set(graph.nodes.map(\.id))
    let applied = outcome == .succeeded ? nodes : []
    return (binding, ActivationCommitReport(prepared: name, attempt: attempt, outcome: outcome,
                                           applied: applied, unapplied: nodes.subtracting(applied)))
}

private func beginPreparation(_ book: inout HostAuthorityBook) throws -> HostPrepare {
    let revision = try #require(book.snapshot().projects[Bench.projectA]).running.revision
    try book.begin(Bench.request(base: revision), candidate: Bench.candidate(revision: revision),
                   project: Bench.projectA).get()
    let command = book.nextEngineCommand()
    guard case .prepare(_, let instance, let attempt) = try #require(command) else {
        throw BookReportError.command
    }
    return HostPrepare(instance: instance, attempt: attempt)
}

private enum BookReportError: Error { case command }

extension HostAuthorityTests {
    /// Temporarily relocated from the actor: degraded is not actor-reachable yet.
    /// H5d MUST reinstate actor success/failure rows through a real capability-loss
    /// transition before full #62 acceptance. This is not a waiver or production seam.
    struct BookCommitReports {
        @Test(arguments: [ActivationCommitOutcome.succeeded, .failed])
        func degradedReportPreservesOwnershipAndLostCapabilities(_ outcome: ActivationCommitOutcome) throws {
            let generations = try GenerationLedger(primaryClock: .init(validated: "smp.book"), musicalClock: nil,
                                                   nominalRate: 48_000)
            var book = try HostAuthorityBook(host: generations, live: Bench.liveState())
            try book.open(project: Bench.projectA, running: RunningGraph(revision: .initial, prepared: nil)).get()
            _ = try book.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let (installed, bootstrap) = try deliver(&book, name: Bench.runningPlan, outcome: .succeeded)
            let firstRevision = try ContractRevision.initial.next()
            #expect(try book.commitReported(bootstrap).get() == .acknowledged(firstRevision))
            #expect(book.snapshot().queue.isEmpty && book.snapshot().retirementOutbox.isEmpty)
            #expect(book.snapshot().projects[Bench.projectA]?.installed == installed)
            #expect(book.phase(of: installed) == .committed)
            // Arrange only the lifecycle on this standalone value, never actor.book.
            let lost = [Bench.audio]
            book.projects[Bench.projectA]?.lifecycle = .degraded(lost)
            let (reviewed, report) = try deliver(&book, name: .init(validated: "prep.next"), outcome: outcome)
            let before = book.snapshot()
            #expect(before.projects[Bench.projectA]?.lifecycle == .preparing(try firstRevision.next(),
                                                                            over: .degraded(lost)))
            let wrong = ActivationCommitReport(prepared: installed.prepared, attempt: report.attempt,
                                                outcome: report.outcome, applied: report.applied,
                                                unapplied: report.unapplied)
            #expect(Bench.refusal(book.commitReported(wrong)) == .activation(.reportMismatch))
            #expect(book.snapshot() == before)
            let result = try book.commitReported(report).get()
            let after = book.snapshot()
            let state = try #require(after.projects[Bench.projectA])
            #expect(state.lifecycle == .degraded(lost) && after.inFlight.isEmpty && after.retirementOutbox.isEmpty)
            let context = try #require(Bench.context(before))
            if outcome == .succeeded {
                #expect(result == .acknowledged(try firstRevision.next()))
                #expect(state.installed == reviewed && state.reviewed == nil)
                #expect(book.phase(of: installed) == .retiring && book.phase(of: reviewed) == .committed)
                #expect(Bench.context(after) == (try context.next()))
                #expect(after.queue.pending == [.discard(installed)])
                #expect(Bench.refusal(book.retired(installed)) == .retirementQueued)
                #expect(book.snapshot() == after)
                #expect(book.nextEngineCommand() == .discard(installed))
                #expect(book.nextEngineCommand() == nil)
                try book.retired(installed).get()
                #expect(book.phase(of: installed) == nil && book.phase(of: reviewed) == .committed)
            } else {
                #expect(result == .failed && state.phase == .commitFailed(reviewed.prepared))
                #expect(state.installed == installed && state.reviewed == reviewed)
                #expect(book.phase(of: installed) == .committed && book.phase(of: reviewed) == .held)
                #expect(Bench.context(after) == context && after.queue.isEmpty)
                #expect(book.nextEngineCommand() == nil)
            }
            let settled = book.snapshot()
            #expect(Bench.refusal(book.commitReported(report)) == .activation(.staleReport))
            #expect(book.snapshot() == settled)
        }

        @Test func stoppedStoredResidentRecoveryRestoresStoppedOverAbsent() throws {
            let generations = try GenerationLedger(primaryClock: .init(validated: "smp.book.stopped"),
                                                   musicalClock: nil, nominalRate: 48_000)
            var book = try HostAuthorityBook(host: generations, live: Bench.liveState())
            try book.open(project: Bench.projectA, running: RunningGraph(revision: .initial, prepared: nil)).get()
            let oldToken = try book.acquire(project: Bench.projectA, window: Bench.windowA).get().token

            let (installed, bootstrap) = try deliver(&book, name: Bench.runningPlan, outcome: .succeeded)
            let installedRevision = try ContractRevision.initial.next()
            #expect(try book.commitReported(bootstrap).get() == .acknowledged(installedRevision))
            let resident = try #require(book.plans.attestCommitted(installed))
            #expect(book.phase(of: installed) == .committed)
            #expect(book.snapshot().projects[Bench.projectA]?.installed == installed)

            // A standalone book models the stopped persisted state; ownership remains genuinely installed.
            book.projects[Bench.projectA]?.lifecycle = .stopped
            let (reviewed, _) = try deliver(
                &book, name: .init(validated: "prep.book.stopped.recovery"), outcome: .failed
            )
            let preparing = try #require(book.snapshot().projects[Bench.projectA])
            #expect(preparing.running == RunningGraph(revision: installedRevision, prepared: installed.prepared))
            #expect(preparing.lifecycle == .preparing(try installedRevision.next(), over: .absent))
            #expect(book.phase(of: installed) == .committed && book.phase(of: reviewed) == .held)

            _ = try book.leaseLost(oldToken).get()
            #expect(book.snapshot().projects[Bench.projectA]?.lifecycle == .recovering)
            #expect(book.snapshot().projects[Bench.projectA]?.recoveryBase == .absent)
            #expect(book.snapshot().projects[Bench.projectA]?.running.prepared == installed.prepared)
            #expect(book.snapshot().inFlight.isEmpty)
            #expect(book.nextEngineCommand() == .setOutputsMuted(true))

            let lease = try book.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let restore = try #require(book.restoring)
            let expectedTarget = RestoreTarget.resident(resident)
            #expect(restore.project == Bench.projectA && restore.revision == installedRevision)
            #expect(restore.target == expectedTarget && restore.token == lease.token)
            #expect(restore.discardAfterRestore == [reviewed])
            #expect(book.phase(of: installed) == .committed && book.phase(of: reviewed) == .retiring)
            #expect(book.nextEngineCommand() == .restore(
                restore.attempt, installedRevision, expectedTarget, lease.token
            ))
            #expect(book.nextEngineCommand() == .discard(reviewed))
            #expect(book.restoring?.discardAfterRestore.isEmpty == true)
            #expect(book.nextEngineCommand() == nil)

            #expect(book.restoreCompleted(
                attempt: restore.attempt, revision: installedRevision, target: expectedTarget, token: lease.token
            ) == .success(.stopped))
            let settled = try #require(book.snapshot().projects[Bench.projectA])
            #expect(settled.lifecycle == .stopped && settled.recoveryBase == nil)
            #expect(settled.running == preparing.running && settled.installed == installed && settled.reviewed == nil)
            #expect(book.lifecycle(of: Bench.projectA, window: Bench.windowA) == .stopped)
            #expect(book.snapshot().restoring == nil && book.snapshot().inFlight.isEmpty)
            #expect(book.snapshot().queue.isEmpty && book.snapshot().retirementOutbox.isEmpty)
            #expect(book.phase(of: installed) == .committed)
            try book.retired(reviewed).get()
            #expect(book.phase(of: reviewed) == nil && book.phase(of: installed) == .committed)
        }

        @Test(arguments: [false, true])
        func stoppedStoredResidentRecoveryPreservesPreparationAcrossRestoreACK(
            awaitingReview: Bool
        ) throws {
            let generations = try GenerationLedger(primaryClock: .init(validated: "smp.book.pending.restore"),
                                                   musicalClock: nil, nominalRate: 48_000)
            var book = try HostAuthorityBook(host: generations, live: Bench.liveState())
            try book.open(project: Bench.projectA, running: RunningGraph(revision: .initial, prepared: nil)).get()
            let oldToken = try book.acquire(project: Bench.projectA, window: Bench.windowA).get().token

            let (installed, bootstrap) = try deliver(&book, name: Bench.runningPlan, outcome: .succeeded)
            let installedRevision = try ContractRevision.initial.next()
            #expect(try book.commitReported(bootstrap).get() == .acknowledged(installedRevision))
            let resident = try #require(book.plans.attestCommitted(installed))
            book.projects[Bench.projectA]?.lifecycle = .stopped

            let preparation = try beginPreparation(&book)
            let reviewed: PlanBinding?
            if awaitingReview {
                #expect(try book.prepareAnswered(
                    .success(.init(validated: "prep.book.pending.reviewed")),
                    instance: preparation.instance,
                    attempt: preparation.attempt
                ).get() == .routed)
                reviewed = try #require(book.snapshot().projects[Bench.projectA]?.reviewed)
                #expect(reviewed?.instance == preparation.instance && reviewed?.attempt == preparation.attempt)
            } else {
                reviewed = nil
            }

            let phase: ActivationPhase = awaitingReview ? .awaitingReview : .preparing
            let saved = book.snapshot()
            let savedProject = try #require(saved.projects[Bench.projectA])
            #expect(savedProject.phase == phase)
            #expect(savedProject.lifecycle == .preparing(try installedRevision.next(), over: .absent))
            #expect(savedProject.lastPrepareAttempt == preparation.attempt)
            #expect(savedProject.installed == installed && savedProject.reviewed == reviewed)
            #expect(saved.outstanding[Bench.projectA] == (awaitingReview ? nil : preparation))
            #expect(book.phase(of: installed) == .committed)
            #expect(book.plans.attestCommitted(installed) == resident)
            if let reviewed { #expect(book.phase(of: reviewed) == .held) }

            _ = try book.leaseLost(oldToken).get()
            let recovering = book.snapshot()
            let recoveringProject = try #require(recovering.projects[Bench.projectA])
            #expect(recoveringProject.phase == phase && recoveringProject.lifecycle == .recovering)
            #expect(recoveringProject.recoveryBase == .absent)
            #expect(recoveringProject.installed == installed && recoveringProject.reviewed == reviewed)
            #expect(recovering.outstanding[Bench.projectA] == saved.outstanding[Bench.projectA])
            #expect(recovering.plans == saved.plans && recovering.inFlight.isEmpty)
            #expect(book.nextEngineCommand() == .setOutputsMuted(true))

            let lease = try book.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let restore = try #require(book.restoring)
            let target = RestoreTarget.resident(resident)
            #expect(restore.revision == installedRevision && restore.target == target)
            #expect(restore.token == lease.token && restore.discardAfterRestore.isEmpty)
            #expect(book.nextEngineCommand() == .restore(
                restore.attempt, installedRevision, target, lease.token
            ))
            #expect(book.nextEngineCommand() == nil)

            let beforeAck = book.snapshot()
            let beforeAckProject = try #require(beforeAck.projects[Bench.projectA])
            #expect(beforeAckProject.phase == phase && beforeAckProject.lifecycle == .recovering)
            #expect(beforeAckProject.installed == installed && beforeAckProject.reviewed == reviewed)
            #expect(beforeAck.outstanding[Bench.projectA] == saved.outstanding[Bench.projectA])
            #expect(beforeAck.plans == saved.plans && book.plans.attestCommitted(installed) == resident)
            if let reviewed { #expect(book.phase(of: reviewed) == .held) }

            let expectedLifecycle = EngineLifecycle.preparing(try installedRevision.next(), over: .absent)
            #expect(book.restoreCompleted(
                attempt: restore.attempt, revision: installedRevision, target: target, token: lease.token
            ) == .success(expectedLifecycle))
            let afterAck = book.snapshot()
            let afterProject = try #require(afterAck.projects[Bench.projectA])
            #expect(afterProject.phase == phase)
            #expect(afterProject.lifecycle == expectedLifecycle && afterProject.recoveryBase == nil)
            #expect(afterProject.running == savedProject.running)
            #expect(afterProject.lastPrepareAttempt == savedProject.lastPrepareAttempt)
            #expect(afterProject.installed == installed && afterProject.reviewed == reviewed)
            #expect(afterAck.plans == saved.plans && afterAck.outstanding == saved.outstanding)
            #expect(afterAck.inFlight.isEmpty && afterAck.queue.isEmpty && afterAck.retirementOutbox.isEmpty)
            #expect(afterAck.restoring == nil && afterAck.pendingOutput == false && !afterAck.outputsMuted)
            #expect(book.phase(of: installed) == .committed && book.plans.attestCommitted(installed) == resident)
            if let reviewed { #expect(book.phase(of: reviewed) == .held) }
            #expect(book.lifecycle(of: Bench.projectA, window: Bench.windowA) == expectedLifecycle)
        }
    }
}
