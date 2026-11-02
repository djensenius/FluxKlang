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
    }
}
