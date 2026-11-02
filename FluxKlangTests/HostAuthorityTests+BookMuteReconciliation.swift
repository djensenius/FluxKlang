import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench
private typealias Book = QualifiedRecoveryBook

/// The stored-stopped rows cannot bootstrap an actor resident through raw open.
/// Keep all eight HIGH regression rows on one canonical standalone book instead;
/// running/degraded rows remain real actor sequences. This is not stopped/reattach acceptance.
private struct StoredRetryBench {
    var book: HostAuthorityBook
    let old: RestoreRecord
    let failed: PlanBinding
    let installed: PlanBinding

    init(stage: RestoreLeaseStage) throws {
        var book = try Book.make(baseline: .storedStopped)
        installed = try #require(book.projects[Bench.projectA]?.installed)
        failed = try Book.commit(&book, name: .init(validated: "prep.failed"))
        try Book.report(&book, binding: failed, outcome: .failed)
        _ = try book.resolveRecovery(project: Bench.projectA).get()
        old = try #require(book.restoring)
        #expect(book.projects[Bench.projectA]?.lifecycle == .stopped && !book.outputsMuted)
        if stage != .queued { #expect(book.nextEngineCommand() == Bench.restoreCommand(old)) }
        if stage == .discardDelivered {
            #expect(try Book.drain(&book) == [.discard(failed)])
        }
        self.book = book
    }
}

func storedLeaseRetry(stage: RestoreLeaseStage, pressure: Bool) throws {
    var fixture = try StoredRetryBench(stage: stage)
    let old = fixture.old
    let failed = fixture.failed
    let beforeRelease = fixture.book.snapshot()
    try fixture.book.release(project: Bench.projectA).get()
    let released = fixture.book.snapshot()
    #expect(released.restoring == nil && !released.outputsMuted && released.pendingOutput == nil)
    #expect(released.projects[Bench.projectA]?.lifecycle == .recovering)
    #expect(released.projects[Bench.projectA]?.recoveryBase == .absent)
    #expect(released.projects[Bench.projectB] == beforeRelease.projects[Bench.projectB])
    let owed: [PlanBinding] = stage == .discardDelivered ? [] : [failed]
    #expect(released.deferredRestoreDiscards == (owed.isEmpty ? [:] : [Bench.projectA: owed]))
    if pressure {
        for _ in fixture.book.queue.count..<EngineCommandQueue.capacity {
            try Book.begin(&fixture.book, project: Bench.projectB)
            try fixture.book.abandonPrepare(project: Bench.projectB).get()
        }
    }
    let lease = try fixture.book.acquire(project: Bench.projectA, window: Bench.windowA).get()
    if pressure {
        let full = fixture.book.snapshot()
        #expect(full.restoring == nil && full.queue.count == EngineCommandQueue.capacity)
        #expect(Bench.refusal(fixture.book.resolveRecovery(project: Bench.projectA)) == .queueFull)
        #expect(Bench.refusal(Book.acknowledge(&fixture.book, old)) == .staleRestore)
        #expect(fixture.book.snapshot() == full)
        #expect(try Book.drain(&fixture.book) == full.queue.pending.filter {
            if case .restore = $0 { false } else { true }
        })
    }
    let fresh = try Book.reviewQueued(&fixture.book, name: failed.prepared)
    #expect(fresh != failed && fresh.prepared == failed.prepared)
    let authorization = try fixture.book.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
    try assertStoredGate(&fixture.book, authorization)
    if pressure { _ = try fixture.book.resolveRecovery(project: Bench.projectA).get() }
    let current = try #require(fixture.book.restoring)
    #expect(current.attempt != old.attempt && current.token == lease.token && current.token != old.token)
    #expect(current.target == old.target && current.revision == old.revision && !current.delivered)
    #expect(current.discardAfterRestore == owed && fixture.book.deferredRestoreDiscards.isEmpty)
    let queued = fixture.book.snapshot()
    #expect(Bench.refusal(Book.acknowledge(&fixture.book, old)) == .staleRestore)
    #expect(Bench.refusal(Book.acknowledge(&fixture.book, current)) == .staleRestore)
    if !owed.isEmpty { #expect(Bench.refusal(fixture.book.retired(failed)) == .retirementQueued) }
    #expect(fixture.book.snapshot() == queued)
    let commands = try Book.drain(&fixture.book)
    #expect(commands == queued.queue.pending.filter { $0 != Bench.restoreCommand(old) })
    #expect(commands.contains(Bench.restoreCommand(current)))
    #expect(commands.filter { $0 == .discard(failed) }.count == owed.count)
    #expect(fixture.book.phase(of: failed) == nil)
    #expect(fixture.book.restoring?.discardAfterRestore.isEmpty == true)
    try assertStoredGate(&fixture.book, authorization)
    let delivered = fixture.book.snapshot()
    #expect(Bench.refusal(Book.acknowledge(&fixture.book, old)) == .staleRestore)
    #expect(fixture.book.snapshot() == delivered)
    #expect(Book.acknowledge(&fixture.book, current)
            == .success(.preparing(try current.revision.next(), over: .absent)))
    let acknowledged = fixture.book.snapshot()
    #expect(acknowledged.ledger == queued.ledger && acknowledged.authorizedWindows == queued.authorizedWindows)
    #expect(!acknowledged.outputsMuted && acknowledged.pendingOutput == nil && acknowledged.restoring == nil)
    #expect(acknowledged.projects[Bench.projectA]?.recoveryBase == nil && fixture.book.plans.count == 2)
    try fixture.book.commit(project: Bench.projectA, authorization: authorization).get()
    let attempt = try #require(fixture.book.projects[Bench.projectA]?.transaction.lastAttempt)
    #expect(fixture.book.nextEngineCommand() == .commit(fresh, attempt, lease.token))
    try Book.report(&fixture.book, binding: fresh, outcome: .succeeded)
    #expect(try Book.drain(&fixture.book) == [.discard(fixture.installed)])
    #expect(fixture.book.plans.count == 1 && fixture.book.phase(of: fixture.installed) == nil)
    try fixture.book.release(project: Bench.projectA).get()
    _ = try fixture.book.acquire(project: Bench.projectA, window: Bench.windowA).get()
    #expect(fixture.book.restoring == nil && fixture.book.deferredRestoreDiscards.isEmpty)
    #expect(fixture.book.projects[Bench.projectA]?.lifecycle == .running)
    #expect(try Book.drain(&fixture.book).isEmpty)
}

private func assertStoredGate(_ book: inout HostAuthorityBook, _ authorization: ActivationAuthorization) throws {
    let before = book.snapshot()
    #expect(Bench.refusal(book.commit(project: Bench.projectA, authorization: authorization))
            == .lifecycleRejectsChanges(.recovering))
    #expect(book.snapshot() == before)
}

func storedRetryAfterPreparation(reviewed: Bool) throws {
    var fixture = try StoredRetryBench(stage: .discardDelivered)
    let binding: PlanBinding?
    if reviewed {
        binding = try Book.review(&fixture.book, name: .init(validated: "prep.cancel"))
    } else {
        binding = nil
        try Book.begin(&fixture.book)
        #expect(try Book.drain(&fixture.book).count == 1)
    }
    let preparation = fixture.book.outstanding[Bench.projectA]
    let before = fixture.book.snapshot()
    _ = try fixture.book.transfer(to: Bench.projectB, window: Bench.windowB).get()
    let transferred = fixture.book.snapshot()
    #expect(transferred.projects[Bench.projectB] == before.projects[Bench.projectB])
    #expect(transferred.projects[Bench.projectA]?.recoveryBase == .absent)
    #expect(transferred.projects[Bench.projectA]?.lifecycle == .recovering)
    #expect(transferred.projects[Bench.projectA]?.phase == (reviewed ? .awaitingReview : .preparing))
    #expect(transferred.restoring == nil && !transferred.outputsMuted)
    let installedB = try Book.commit(&fixture.book, project: Bench.projectB, window: Bench.windowB,
                                     name: .init(validated: "prep.b"))
    try Book.report(&fixture.book, binding: installedB, project: Bench.projectB, outcome: .succeeded)
    _ = try fixture.book.transfer(to: Bench.projectA, window: Bench.windowA).get()
    let current = try #require(fixture.book.restoring)
    #expect(current.attempt != fixture.old.attempt && current.token != fixture.old.token)
    if reviewed {
        try fixture.book.cancel(project: Bench.projectA).get()
    } else {
        try fixture.book.abandonPrepare(project: Bench.projectA).get()
        let prepare = try #require(preparation)
        #expect(try fixture.book.prepareAnswered(.failure(.engineRefused), instance: prepare.instance,
                                                 attempt: prepare.attempt).get() == .dropped)
    }
    let cancelled = fixture.book.snapshot()
    #expect(cancelled.projects[Bench.projectA]?.phase == .idle)
    #expect(cancelled.projects[Bench.projectA]?.lifecycle == .recovering)
    #expect(cancelled.projects[Bench.projectA]?.recoveryBase == .absent)
    #expect(Bench.refusal(Book.acknowledge(&fixture.book, fixture.old)) == .staleRestore)
    #expect(fixture.book.snapshot() == cancelled)
    #expect(try Book.drain(&fixture.book) ==
            [Bench.restoreCommand(current)] + (binding.map { [.discard($0)] } ?? []))
    #expect(Book.acknowledge(&fixture.book, current) == .success(.stopped))
    #expect(fixture.book.projects[Bench.projectA]?.recoveryBase == nil)
    #expect(fixture.book.ledger.current == cancelled.ledger && fixture.book.plans.count == 2)
    #expect(try Book.drain(&fixture.book).isEmpty)
}

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
    let retained: PlanBinding
    let failed: PlanBinding

    init(delivered: Bool = false) throws {
        var book = try QualifiedRecoveryBook.make(installB: true)
        let leaseA = try #require(book.registry.snapshot)
        retained = try QualifiedRecoveryBook.commit(&book, name: .init(validated: "prep.a-retained"),
                                                    deliver: false)
        staleAttempt = try #require(book.projects[Bench.projectA]?.transaction.lastAttempt)
        let held = book.queue.dequeue()
        #expect(held == .commit(retained, staleAttempt, leaseA.token))
        _ = try book.transfer(to: Bench.projectB, window: Bench.windowB).get()
        failed = try QualifiedRecoveryBook.commit(&book, project: Bench.projectB, window: Bench.windowB,
                                                  name: .init(validated: "prep.b-failed"), deliver: false)
        let attemptB = try #require(book.projects[Bench.projectB]?.transaction.lastAttempt)
        let commit = book.nextEngineCommand()
        #expect(commit == .commit(failed, attemptB, try #require(book.registry.snapshot?.token)))
        _ = try book.commitReported(ActivationCommitReport(
            prepared: failed.prepared, attempt: attemptB, outcome: .failed, applied: [], unapplied: [Bench.nodeOut]
        )).get()
        _ = try book.resolveRecovery(project: Bench.projectB).get()
        old = try #require(book.restoring)
        if delivered {
            let command = book.nextEngineCommand()
            #expect(command == Bench.restoreCommand(old))
        }
        self.book = book
    }

    mutating func fill(to count: Int) throws {
        for _ in book.queue.count..<count {
            try QualifiedRecoveryBook.begin(&book, project: Bench.projectB)
            try book.abandonPrepare(project: Bench.projectB).get()
        }
    }

    mutating func acknowledge(_ record: RestoreRecord) -> Result<EngineLifecycle, HostAuthorityRefusal> {
        book.restoreCompleted(attempt: record.attempt, revision: record.revision,
                              target: record.target, token: record.token)
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
            #expect(replacement.revision == bench.old.revision && replacement.target == bench.old.target)
            #expect(replacement.discardAfterRestore == [bench.failed])
            let muted = bench.book.snapshot()
            #expect(muted.ledger == beforeMute.ledger && muted.outputsMuted)
            #expect(muted.projects[Bench.projectB]?.lifecycle == .recovering)
            #expect(muted.projects[Bench.projectA]?.phase ==
                    .recovering(bench.retained.prepared, cause: .commitOutcomeUnknown))
            let oldAck = bench.acknowledge(bench.old)
            #expect(Bench.refusal(oldAck) == .staleRestore)
            #expect(bench.book.snapshot() == muted)
            let early = bench.acknowledge(replacement)
            #expect(Bench.refusal(early) == .staleRestore)
            #expect(bench.book.snapshot() == muted)
            let reuse = bench.book.retired(bench.failed)
            #expect(Bench.refusal(reuse) == .retirementQueued)
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
            #expect(Bench.refusal(bench.book.retired(bench.failed)) == .retirementQueued)
            #expect(Bench.refusal(bench.book.retired(bench.retained)) == .plans(.notRetiring))
            #expect(bench.book.snapshot() == deferred)
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
