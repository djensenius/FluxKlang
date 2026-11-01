import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

/// Separate-book scheduler boundary, not an injectable actor fixture. A's commit
/// is legitimately admitted first, then held outside this book's FIFO without
/// delivery bookkeeping. B subsequently fails and restores under its own lease.
/// This deliberately adversarial scheduling lets A's retained stale work cause
/// a later mute; no new commit is admitted during B's restore. The actor's normal
/// FIFO cannot construct this ordering, because it would withhold A first.
private struct MuteSchedulingBench {
    var book: HostAuthorityBook
    let staleAttempt: CommitAttemptID
    let old: RestoreRecord
    let retained = PreparedActivationID(validated: "prep.a-retained")
    let failed = PreparedActivationID(validated: "prep.b-failed")
    let runningB = PreparedActivationID(validated: "prep.b-running")

    init(delivered: Bool = false) throws {
        let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.mute-scheduling"),
                                          musicalClock: nil, nominalRate: 48_000)
        var book = try HostAuthorityBook(host: ledger, live: Bench.liveState())
        try book.open(project: Bench.projectA,
                      running: RunningGraph(revision: .initial, prepared: Bench.runningPlan)).get()
        try book.open(project: Bench.projectB,
                      running: RunningGraph(revision: .initial, prepared: runningB)).get()
        let leaseA = try book.acquire(project: Bench.projectA, window: Bench.windowA).get()
        staleAttempt = try Self.queueCommit(&book, project: Bench.projectA,
                                            window: Bench.windowA, prepared: retained)
        let held = book.queue.dequeue()
        #expect(held == .commit(retained, staleAttempt, leaseA.token))
        _ = try book.transfer(to: Bench.projectB, window: Bench.windowB).get()
        let attemptB = try Self.queueCommit(&book, project: Bench.projectB, window: Bench.windowB, prepared: failed)
        let commit = book.nextEngineCommand()
        #expect(commit == .commit(failed, attemptB, try #require(book.registry.snapshot?.token)))
        _ = try book.commitReported(ActivationCommitReport(
            prepared: failed, attempt: attemptB, outcome: .failed, applied: [], unapplied: [Bench.nodeOut]
        )).get()
        _ = try book.resolveRecovery(project: Bench.projectB).get()
        old = try #require(book.restoring)
        if delivered {
            let command = book.nextEngineCommand()
            #expect(command == Bench.restoreCommand(old))
        }
        self.book = book
    }

    private static func queueCommit(_ book: inout HostAuthorityBook, project: ProjectID,
                                    window: WindowID, prepared: PreparedActivationID) throws -> CommitAttemptID {
        try book.begin(Bench.request(), candidate: Bench.candidate(), project: project).get()
        let prepare = try #require(book.snapshot().projects[project]?.lastPrepareAttempt)
        let command = book.nextEngineCommand()
        #expect(command == .prepare(Bench.candidate(), prepare))
        _ = try book.prepareAnswered(.success(prepared), attempt: prepare).get()
        let authorization = try book.authorize(project: project, gesture: Bench.gesture(window)).get()
        try book.commit(project: project, authorization: authorization).get()
        return try #require(book.snapshot().projects[project]?.lastCommitAttempt)
    }

    mutating func fill(to count: Int) throws {
        for _ in book.queue.count..<count {
            try book.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectB).get()
            try book.abandonPrepare(project: Bench.projectB).get()
        }
    }

    mutating func acknowledge(_ record: RestoreRecord) -> Result<EngineLifecycle, HostAuthorityRefusal> {
        book.restoreCompleted(attempt: record.attempt, revision: record.revision,
                              prepared: record.prepared, token: record.token)
    }

    mutating func drain() -> [EngineCommand] {
        var commands: [EngineCommand] = []
        for _ in 0...EngineCommandQueue.capacity {
            guard let command = book.nextEngineCommand() else { return commands }
            commands.append(command)
        }
        Issue.record("Bounded drain exceeded the queue capacity")
        return commands
    }
}

extension HostAuthorityTests {
    struct BookMuteReconciliation {
        @Test func refusedMutePreservesRestoreAuthority() throws {
            var bench = try MuteSchedulingBench()
            let before = bench.book.snapshot()
            let reserved = bench.book.abandonCommit(bench.staleAttempt, reason: .leaseLost)
            #expect(Bench.refusal(reserved) == .abandonmentReserved(.leaseLost))
            #expect(bench.book.snapshot() == before)
            try bench.fill(to: EngineCommandQueue.capacity)
            let full = bench.book.snapshot()
            #expect(full.restoring == before.restoring && !full.outputsMuted)
            let crowded = bench.book.abandonCommit(bench.staleAttempt, reason: .outcomeUnknown)
            #expect(Bench.refusal(crowded) == .queueFull)
            #expect(bench.book.snapshot() == full)
        }

        @Test(arguments: [false, true])
        func newMuteInvalidatesRestoreAndPreservesDependencies(delivered: Bool) throws {
            var bench = try MuteSchedulingBench(delivered: delivered)
            let beforeMute = bench.book.snapshot()
            try bench.book.abandonCommit(bench.staleAttempt, reason: .outcomeUnknown).get()
            let replacement = try #require(bench.book.restoring)
            #expect(replacement.attempt != bench.old.attempt && replacement.token == bench.old.token)
            #expect(replacement.revision == bench.old.revision && replacement.prepared == bench.old.prepared)
            #expect(replacement.discardAfterRestore == [bench.failed])
            let muted = bench.book.snapshot()
            #expect(muted.ledger == beforeMute.ledger && muted.outputsMuted)
            #expect(muted.projects[Bench.projectB]?.lifecycle == .recovering)
            #expect(muted.projects[Bench.projectA]?.phase == .recovering(bench.retained, cause: .commitOutcomeUnknown))
            let oldAck = bench.acknowledge(bench.old)
            #expect(Bench.refusal(oldAck) == .staleRestore)
            #expect(bench.book.snapshot() == muted)
            let early = bench.acknowledge(replacement)
            #expect(Bench.refusal(early) == .staleRestore)
            #expect(bench.book.snapshot() == muted)
            let reuse = bench.book.open(project: Bench.projectC,
                                        running: RunningGraph(revision: .initial, prepared: bench.retained))
            #expect(Bench.refusal(reuse) == .activation(.preparedIDInUse))
            #expect(bench.book.snapshot() == muted)
            let taken = bench.drain()
            #expect(taken == [.setOutputsMuted(true), Bench.restoreCommand(replacement), .discard(bench.failed)])
            #expect(!taken.contains(Bench.restoreCommand(bench.old)))
            #expect(!taken.contains(.discard(bench.retained)))
            let afterDelivery = bench.book.snapshot()
            #expect(afterDelivery.restoring?.discardAfterRestore.isEmpty == true)
            let replay = bench.acknowledge(bench.old)
            #expect(Bench.refusal(replay) == .staleRestore)
            #expect(bench.book.snapshot() == afterDelivery)
            let completed = bench.acknowledge(replacement)
            #expect(completed == .success(.running))
            #expect(bench.drain() == [.setOutputsMuted(false)])
        }

        @Test func pressureDefersInvalidatedRestoreDependencies() throws {
            var bench = try MuteSchedulingBench(delivered: true)
            try bench.fill(to: EngineCommandQueue.capacity - 3)
            try bench.book.abandonCommit(bench.staleAttempt, reason: .outcomeUnknown).get()
            let deferred = bench.book.snapshot()
            #expect(deferred.outputsMuted && deferred.restoring == nil)
            #expect(deferred.projects[Bench.projectB]?.lifecycle == .recovering)
            #expect(deferred.deferredRestoreDiscards == [Bench.projectB: [bench.failed]])
            #expect(!deferred.queue.pending.contains(.discard(bench.failed)))
            let refused = bench.book.resolveRecovery(project: Bench.projectB)
            #expect(Bench.refusal(refused) == .queueFull)
            #expect(bench.book.snapshot() == deferred)
            let oldAck = bench.acknowledge(bench.old)
            #expect(Bench.refusal(oldAck) == .staleRestore)
            #expect(bench.book.snapshot() == deferred)
            for plan in [bench.failed, bench.retained] {
                let reuse = bench.book.open(project: Bench.projectC,
                                            running: RunningGraph(revision: .initial, prepared: plan))
                #expect(Bench.refusal(reuse) == .activation(.preparedIDInUse))
                #expect(bench.book.snapshot() == deferred)
            }
            let drained = bench.drain()
            #expect(drained.last == .setOutputsMuted(true))
            #expect(!drained.contains(.discard(bench.failed)) && !drained.contains(.discard(bench.retained)))
            _ = try bench.book.resolveRecovery(project: Bench.projectB).get()
            let fresh = try #require(bench.book.restoring)
            #expect(fresh.attempt != bench.old.attempt && fresh.token == bench.old.token)
            #expect(bench.book.deferredRestoreDiscards.isEmpty)
            #expect(bench.drain() == [Bench.restoreCommand(fresh), .discard(bench.failed)])
            #expect(bench.book.restoring?.discardAfterRestore.isEmpty == true)
            let afterDelivery = bench.book.snapshot()
            let replay = bench.acknowledge(bench.old)
            #expect(Bench.refusal(replay) == .staleRestore)
            #expect(bench.book.snapshot() == afterDelivery)
            let completed = bench.acknowledge(fresh)
            #expect(completed == .success(.running))
            #expect(bench.drain() == [.setOutputsMuted(false)])
        }
    }
}
