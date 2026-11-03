import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench
private typealias Book = QualifiedRecoveryBook

/// Stored-stopped standalone-book counterpart; no actor lifecycle injection.
func repeatedStoredMutesReplaceRestoreAuthority(abandon: Bool) throws {
    var book = try Book.make(baseline: .storedStopped, installB: true)
    _ = try Book.commit(&book, name: .init(validated: "prep.a"), deliver: false)
    let attemptA = try #require(book.projects[Bench.projectA]?.transaction.lastAttempt)
    let windowC = WindowID(validated: "win.c")
    try book.open(project: Bench.projectC, running: RunningGraph(revision: .initial, prepared: nil)).get()
    _ = try book.transfer(to: Bench.projectC, window: windowC).get()
    _ = try Book.reviewQueued(&book, project: Bench.projectC, name: .init(validated: "prep.c"))
    let authorization = try book.authorize(project: Bench.projectC, gesture: Bench.gesture(windowC)).get()
    try book.commit(project: Bench.projectC, authorization: authorization).get()
    let attemptC = try #require(book.projects[Bench.projectC]?.transaction.lastAttempt)
    _ = try book.transfer(to: Bench.projectB, window: Bench.windowB).get()
    let before = book.snapshot()
    if abandon {
        try book.abandonCommit(attemptA, reason: .outcomeUnknown).get()
    } else {
        #expect(book.nextEngineCommand() == .setOutputsMuted(true))
    }
    let first = try #require(book.restoring)
    #expect(book.projects[Bench.projectB]?.recoveryBase == .absent)
    if abandon {
        try book.abandonCommit(attemptC, reason: .outcomeUnknown).get()
    } else {
        let prepare = book.nextEngineCommand()
        #expect(prepare.map { if case .prepare = $0 { true } else { false } } == true)
        #expect(book.nextEngineCommand() == .setOutputsMuted(true))
    }
    let second = try #require(book.restoring)
    #expect(first.attempt != second.attempt && first.token == second.token && first.target == second.target)
    let queued = book.snapshot()
    #expect(queued.ledger == before.ledger && queued.projects[Bench.projectB]?.recoveryBase == .absent)
    #expect(Bench.refusal(Book.acknowledge(&book, first)) == .staleRestore)
    #expect(book.snapshot() == queued)
    let taken = try Book.drain(&book)
    #expect(!taken.contains(Bench.restoreCommand(first)))
    #expect(Array(taken.suffix(abandon ? 3 : 1)) ==
            (abandon ? [.setOutputsMuted(true), .setOutputsMuted(true)] : []) + [Bench.restoreCommand(second)])
    let delivered = book.snapshot()
    #expect(Bench.refusal(Book.acknowledge(&book, first)) == .staleRestore)
    #expect(book.snapshot() == delivered)
    #expect(Book.acknowledge(&book, second) == .success(.stopped))
    #expect(book.projects[Bench.projectB]?.recoveryBase == nil)
    #expect(try Book.drain(&book) == [.setOutputsMuted(false)])
}

func storedGrantProvenance(phase: RecoveryEntryPhase) throws {
    var book = try Book.make(baseline: .storedStopped, installB: true)
    let installed = try #require(book.projects[Bench.projectB]?.installed)
    if phase == .preparing || phase == .awaitingReview {
        if phase == .awaitingReview {
            _ = try Book.review(&book, project: Bench.projectB, name: .init(validated: "prep.review"))
        } else {
            try Book.begin(&book, project: Bench.projectB)
            #expect(try Book.drain(&book).count == 1)
        }
    }
    if phase == .pressured {
        try book.open(project: Bench.projectC, running: RunningGraph(revision: .initial, prepared: nil)).get()
        for _ in 0..<EngineCommandQueue.capacity {
            try Book.begin(&book, project: Bench.projectC)
            try book.abandonPrepare(project: Bench.projectC).get()
        }
    }
    _ = try book.leaseLost(try #require(book.registry.snapshot?.token)).get()
    let before = book.snapshot()
    _ = try book.acquire(project: Bench.projectB, window: Bench.windowB).get()
    let granted = book.snapshot()
    #expect(granted.projects[Bench.projectB]?.lifecycle == .recovering)
    #expect(granted.projects[Bench.projectB]?.recoveryBase == .absent)
    #expect(granted.projects[Bench.projectA] == before.projects[Bench.projectA])
    #expect(granted.projects[Bench.projectC] == before.projects[Bench.projectC])
    #expect(granted.outputsMuted && granted.pendingOutput == true)
    #expect(Bench.context(granted) == (try #require(Bench.context(before)).next()))
    if phase == .pressured {
        #expect(book.restoring == nil)
        #expect(Bench.refusal(book.resolveRecovery(project: Bench.projectB)) == .queueFull)
        #expect(book.snapshot() == granted)
        #expect(try Book.drain(&book) == [.setOutputsMuted(true)] + before.queue.pending)
        _ = try book.resolveRecovery(project: Bench.projectB).get()
    }
    let old = try #require(book.restoring)
    try book.release(project: Bench.projectB).get()
    let token = try book.acquire(project: Bench.projectB, window: Bench.windowB).get().token
    let fresh = try #require(book.restoring)
    #expect(fresh.attempt != old.attempt && fresh.token == token)
    guard case .resident(let resident) = fresh.target else {
        Issue.record("Expected a qualified stored resident")
        return
    }
    #expect(resident.binding == installed && book.projects[Bench.projectB]?.recoveryBase == .absent)
    let queued = book.snapshot()
    #expect(Bench.refusal(Book.acknowledge(&book, old)) == .staleRestore)
    #expect(book.snapshot() == queued)
    #expect(try Book.drain(&book) ==
            (phase == .pressured ? [] : [.setOutputsMuted(true)]) + [Bench.restoreCommand(fresh)])
    let expected: EngineLifecycle = phase == .preparing || phase == .awaitingReview
        ? .preparing(try fresh.revision.next(), over: .absent) : .stopped
    #expect(Book.acknowledge(&book, fresh) == .success(expected))
    #expect(book.projects[Bench.projectB]?.recoveryBase == nil && book.ledger.current == queued.ledger)
    #expect(book.projects[Bench.projectB]?.transaction.running == granted.projects[Bench.projectB]?.running)
    #expect(try Book.drain(&book) == [.setOutputsMuted(false)])
}

func storedLateMuteProvenance(abandon: Bool) throws {
    var book = try Book.make(baseline: .storedStopped, installB: true)
    let retained = try Book.commit(&book, name: .init(validated: "prep.a"), deliver: false)
    let attemptA = try #require(book.projects[Bench.projectA]?.transaction.lastAttempt)
    _ = try book.transfer(to: Bench.projectB, window: Bench.windowB).get()
    try Book.begin(&book, project: Bench.projectB)
    let before = book.snapshot()
    let prepareCommand = try #require(before.queue.pending.last)
    let prepare = try #require(before.outstanding[Bench.projectB])
    if abandon {
        try book.abandonCommit(attemptA, reason: .outcomeUnknown).get()
    } else {
        #expect(book.nextEngineCommand() == .setOutputsMuted(true))
    }
    let muted = book.snapshot()
    #expect(muted.outputsMuted && muted.projects[Bench.projectB]?.lifecycle == .recovering)
    #expect(muted.projects[Bench.projectB]?.recoveryBase == .absent)
    #expect(muted.projects[Bench.projectB]?.phase == .preparing && muted.ledger == before.ledger)
    #expect(muted.projects[Bench.projectA]?.phase ==
            .recovering(retained.prepared, cause: abandon ? .commitOutcomeUnknown : .leaseLost))
    let restore = try #require(book.restoring)
    #expect(try Book.drain(&book) ==
            [prepareCommand] + (abandon ? [.setOutputsMuted(true)] : []) + [Bench.restoreCommand(restore)])
    #expect(try book.prepareAnswered(.success(.init(validated: "prep.b-next")), instance: prepare.instance,
                                     attempt: prepare.attempt).get() == .routed)
    let fresh = try #require(book.projects[Bench.projectB]?.reviewed)
    let authorization = try book.authorize(project: Bench.projectB, gesture: Bench.gesture(Bench.windowB)).get()
    let gated = book.snapshot()
    #expect(Bench.refusal(book.commit(project: Bench.projectB, authorization: authorization))
            == .lifecycleRejectsChanges(.recovering))
    #expect(book.snapshot() == gated)
    #expect(Book.acknowledge(&book, restore) == .success(.preparing(try restore.revision.next(), over: .absent)))
    #expect(book.projects[Bench.projectB]?.recoveryBase == nil && book.ledger.current == before.ledger)
    #expect(try Book.drain(&book) == [.setOutputsMuted(false)])
    try book.commit(project: Bench.projectB, authorization: authorization).get()
    _ = try Book.drain(&book)
    try Book.report(&book, binding: fresh, project: Bench.projectB, outcome: .succeeded)
    #expect(book.projects[Bench.projectB]?.lifecycle == .running && book.phase(of: retained) == .held)
}

extension HostAuthorityTests {
    /// Rule M: a later FIFO mute gates the current holder, regardless of its cause.
    struct ActorMuteReconciliation {
        @Test(arguments: [false, true], [false, true])
        func lateMuteGatesCurrentHolder(abandon: Bool, runningB: Bool) async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            if runningB { try await Bench.installB(authority, &engine) }
            let installedB = try await Bench.state(authority, Bench.projectB).installed
            try await authority.open(project: Bench.projectC,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            let planA = try await Bench.commitQueued(authority, &engine)
            let retainedA = try #require(try await Bench.state(authority).reviewed)
            let attemptA = try await Bench.attempt(authority)
            let token = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get().token
            let granted = await authority.snapshot()
            #expect(!granted.outputsMuted && granted.restoring == nil)
            if abandon {
                try await authority.abandonCommit(attemptA, reason: .outcomeUnknown).get()
            } else {
                #expect(await authority.nextEngineCommand() == .setOutputsMuted(true))
            }
            let muted = await authority.snapshot()
            #expect(muted.outputsMuted && muted.pendingOutput == nil)
            #expect(muted.projects[Bench.projectB]?.lifecycle == .recovering)
            #expect(muted.projects[Bench.projectB]?.recoveryBase == (runningB ? .running : .absent))
            #expect(muted.projects[Bench.projectC] == granted.projects[Bench.projectC])
            #expect(muted.projects[Bench.projectA]?.lifecycle == .recovering)
            #expect(muted.projects[Bench.projectA]?.phase ==
                    .recovering(planA, cause: abandon ? .commitOutcomeUnknown : .leaseLost))
            #expect(muted.ledger == granted.ledger)
            let restore = try await Bench.restore(authority)
            #expect(restore.project == Bench.projectB && restore.token == token)
            #expect(restore.revision == granted.projects[Bench.projectB]?.running.revision && !restore.delivered)
            #expect(restore.target.instance == granted.plans.currentInstance)
            if case .resident(let resident) = restore.target {
                #expect(resident.binding == installedB)
            } else {
                #expect(installedB == nil)
            }
            #expect(Bench.refusal(await Bench.acknowledge(restore, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == muted)
            #expect(await engine.drain(authority) ==
                    (abandon ? [.setOutputsMuted(true)] : []) + [Bench.restoreCommand(restore)])
            // Fresh context/authorization, not a stale plan that would refuse anyway.
            _ = try await Bench.review(authority, &engine, project: Bench.projectB)
            let freshB = try #require(try await Bench.state(authority, Bench.projectB).reviewed)
            let authorization = try await authority.authorize(
                project: Bench.projectB, gesture: Bench.gesture(Bench.windowB)
            ).get()
            let beforeCommit = await authority.snapshot()
            #expect(Bench.refusal(await authority.commit(project: Bench.projectB, authorization: authorization))
                    == .lifecycleRejectsChanges(.recovering))
            #expect(await authority.snapshot() == beforeCommit)
            let preparing = EngineLifecycle.preparing(
                try #require(granted.projects[Bench.projectB]).running.revision.next(),
                over: runningB ? .running : .absent
            )
            #expect(await engine.completeRestore(authority) == .success(preparing))
            #expect(await engine.drain(authority) == [.setOutputsMuted(false)])
            #expect(await authority.snapshot().ledger == granted.ledger)
            try await authority.commit(project: Bench.projectB, authorization: authorization).get()
            let attemptB = try await Bench.attempt(authority, Bench.projectB)
            #expect(await engine.drain(authority) == [.commit(freshB, attemptB, token)])
            #expect(!engine.discarded.contains(retainedA))
        }

        @Test(arguments: [false, true])
        func pressureKeepsGateUntilExplicitRetry(abandon: Bool) async throws {
            var engine = try ScriptedActivationEngine(trackedLimit: 512)
            let authority = try await Bench.makeAuthority(&engine)
            _ = try await Bench.commitQueued(authority, &engine)
            let attempt = try await Bench.attempt(authority)
            _ = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
            try await authority.open(project: Bench.projectC,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            let limit = abandon ? EngineCommandQueue.capacity - 3 : EngineCommandQueue.capacity
            for _ in 1..<limit {
                try await authority.begin(
                    Bench.request(), candidate: Bench.candidate(),
                    projectDocument: Bench.projectDocument(project: Bench.projectC, candidate: Bench.candidate()),
                    project: Bench.projectC
                ).get()
                try await authority.abandonPrepare(project: Bench.projectC).get()
            }
            let full = await authority.snapshot()
            if abandon {
                // The mute fits; the subsequent best-effort restore does not.
                try await authority.abandonCommit(attempt, reason: .outcomeUnknown).get()
            } else {
                #expect(await authority.nextEngineCommand() == .setOutputsMuted(true))
            }
            let muted = await authority.snapshot()
            #expect(muted.outputsMuted && muted.restoring == nil)
            #expect(muted.projects[Bench.projectB]?.lifecycle == .recovering)
            #expect(muted.ledger == full.ledger)
            #expect(Bench.refusal(await authority.resolveRecovery(project: Bench.projectB)) == .queueFull)
            #expect(await authority.snapshot() == muted)
            #expect(await engine.drain(authority) == Array(full.queue.pending.dropFirst())
                    + (abandon ? [.setOutputsMuted(true)] : []))
            #expect(await authority.resolveRecovery(project: Bench.projectB) == .success(.restoring(.initial)))
            let restore = try await Bench.restore(authority)
            #expect(await engine.drain(authority) == [Bench.restoreCommand(restore)])
            #expect(await engine.completeRestore(authority) == .success(.stopped))
            #expect(await engine.drain(authority) == [.setOutputsMuted(false)])
        }

        @Test(arguments: [false, true], [ActivationCommitOutcome.succeeded, .failed, .partial])
        func admittedCommitSettlesBehindRecoveryGate(delivered: Bool, outcome: ActivationCommitOutcome) async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            _ = try await Bench.commitQueued(authority, &engine)
            let attemptA = try await Bench.attempt(authority)
            _ = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
            let planB = PreparedActivationID(validated: "prep.b")
            try await Bench.commitWithoutDrain(authority, &engine, project: Bench.projectB, window: Bench.windowB,
                                               prepared: planB, withAux: true)
            let attemptB = try await Bench.attempt(authority, Bench.projectB)
            if delivered {
                // Withholding A gates B while its already-admitted commit still delivers.
                _ = await engine.drain(authority)
            } else {
                try await authority.abandonCommit(attemptA, reason: .outcomeUnknown).get()
            }
            let gated = await authority.snapshot()
            #expect(gated.projects[Bench.projectB]?.lifecycle == .recovering)
            #expect(gated.projects[Bench.projectB]?.recoveryBase == .absent)
            #expect(gated.projects[Bench.projectB]?.phase == .committing)
            #expect(gated.outputsMuted && gated.restoring == nil)
            #expect(Bench.refusal(await authority.resolveRecovery(project: Bench.projectB)) == .activation(.busy))
            #expect(await authority.snapshot() == gated)
            if !delivered { _ = await engine.drain(authority) }
            #expect(await authority.snapshot().inFlight == [Bench.projectB: attemptB])
            let beforeReport = await authority.snapshot()
            let nodes: Set<NodeID> = [Bench.nodeOut, Bench.nodeAux]
            let applied: Set<NodeID> = outcome == .succeeded ? nodes : outcome == .partial ? [Bench.nodeAux] : []
            let report = ActivationCommitReport(prepared: planB, attempt: attemptB, outcome: outcome,
                                                applied: applied, unapplied: nodes.subtracting(applied))
            _ = try await authority.commitReported(report).get()
            let settled = await authority.snapshot()
            #expect(settled.projects[Bench.projectB]?.lifecycle == .recovering)
            #expect(settled.projects[Bench.projectB]?.recoveryBase == .absent)
            #expect(settled.outputsMuted && settled.restoring == nil && settled.inFlight.isEmpty)
            if outcome != .succeeded { #expect(settled.ledger == beforeReport.ledger) }
            let resolution = try await authority.resolveRecovery(project: Bench.projectB).get()
            if outcome == .partial {
                #expect(resolution == .keptPartial(try ContractRevision.initial.next()))
                _ = await engine.drain(authority)
                #expect(await authority.snapshot().outputsMuted)
                #expect(await authority.snapshot().projects[Bench.projectB]?.lifecycle == .recovering)
                _ = try await authority.resolveRecovery(project: Bench.projectB).get()
            }
            let restore = try await Bench.restore(authority)
            #expect(restore.target.prepared == (outcome == .failed ? nil : planB))
            _ = await engine.drain(authority)
            // Settling admitted work does not replace the first, absent recovery base
            // with a rendering state merely because a plan is now stored.
            #expect(await engine.completeRestore(authority) == .success(.stopped))
            #expect(await authority.snapshot().projects[Bench.projectB]?.recoveryBase == nil)
            #expect(await engine.drain(authority) == [.setOutputsMuted(false)])
        }

        @Test(arguments: [ActivationCommitOutcome.succeeded, .failed])
        func mutePublishedWhileHolderAlreadyInFlight(outcome: ActivationCommitOutcome) throws {
            let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.inflight"),
                                              musicalClock: nil, nominalRate: 48_000)
            // Separate-book unit boundary: publish a FIFO mute while B is ALREADY
            // in flight, without adding an actor bookkeeping/command-injection API.
            var book = try HostAuthorityBook(host: ledger, live: Bench.liveState())
            try book.open(project: Bench.projectB, running: RunningGraph(revision: .initial, prepared: nil)).get()
            _ = try book.acquire(project: Bench.projectB, window: Bench.windowB).get()
            try book.begin(
                Bench.request(), candidate: Bench.candidate(),
                projectDocument: Bench.projectDocument(project: Bench.projectB, candidate: Bench.candidate()),
                project: Bench.projectB
            ).get()
            guard case .prepare(_, _, let instance, let prepare) = book.nextEngineCommand() else {
                Issue.record("Expected B's prepare")
                return
            }
            let plan = PreparedActivationID(validated: "prep.b")
            _ = try book.prepareAnswered(.success(plan), instance: instance, attempt: prepare).get()
            let authorization = try book.authorize(project: Bench.projectB, gesture: Bench.gesture(Bench.windowB)).get()
            try book.commit(project: Bench.projectB, authorization: authorization).get()
            guard case .commit(_, let attempt, _) = book.nextEngineCommand() else {
                Issue.record("Expected B's delivered commit")
                return
            }
            let before = book.snapshot()
            let running = try #require(before.projects[Bench.projectB]?.running)
            let step = ActivationRecovery.enterRecovery(.commitOutcomeUnknown, running: running)
            var staged = book.queue
            let queued = book.requestMute(step, running: running, into: &staged)
            #expect(queued)
            book.queue = staged
            book.reconcileFIFOMute()
            let gated = book.snapshot()
            #expect(gated.inFlight == [Bench.projectB: attempt] && gated.restoring == nil)
            #expect(gated.projects[Bench.projectB]?.phase == .committing)
            #expect(gated.projects[Bench.projectB]?.lifecycle == .recovering && gated.outputsMuted)
            #expect(gated.projects[Bench.projectB]?.recoveryBase == .absent)
            #expect(gated.ledger == before.ledger)
            let refused = book.resolveRecovery(project: Bench.projectB)
            #expect(Bench.refusal(refused) == .activation(.busy))
            #expect(book.snapshot() == gated)
            let report = ActivationCommitReport(prepared: plan, attempt: attempt, outcome: outcome,
                                                applied: outcome == .succeeded ? [Bench.nodeOut] : [],
                                                unapplied: outcome == .failed ? [Bench.nodeOut] : [])
            _ = try book.commitReported(report).get()
            #expect(book.projects[Bench.projectB]?.lifecycle == .recovering)
            #expect(book.projects[Bench.projectB]?.recoveryBase == .absent)
            #expect(book.inFlight.isEmpty && book.restoring == nil && book.outputsMuted)
            _ = try book.resolveRecovery(project: Bench.projectB).get()
            let restore = try #require(book.restoring)
            let mute = book.nextEngineCommand()
            #expect(mute == .setOutputsMuted(true))
            let command = book.nextEngineCommand()
            #expect(command == Bench.restoreCommand(restore))
            let completed = book.restoreCompleted(attempt: restore.attempt, revision: restore.revision,
                                                   target: restore.target, token: restore.token)
            #expect(completed == .success(.stopped))
            #expect(book.projects[Bench.projectB]?.recoveryBase == nil)
            let unmute = book.nextEngineCommand()
            #expect(unmute == .setOutputsMuted(false))
        }

        @Test(arguments: [false, true], RecoveryEntryBaseline.allCases)
        func repeatedMutesReplaceRestoreAuthority(abandon: Bool, baseline: RecoveryEntryBaseline) async throws {
            if baseline == .storedStopped {
                try repeatedStoredMutesReplaceRestoreAuthority(abandon: abandon)
                return
            }
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            try await Bench.installB(authority, &engine, lifecycle: baseline.lifecycle)
            _ = try await Bench.commitQueued(authority, &engine)
            let attemptA = try await Bench.attempt(authority)
            let windowC = WindowID(validated: "win.c")
            try await authority.open(project: Bench.projectC,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            _ = try await authority.transfer(to: Bench.projectC, window: windowC).get()
            try await Bench.commitWithoutDrain(authority, &engine, project: Bench.projectC, window: windowC,
                                               prepared: PreparedActivationID(validated: "prep.c"))
            let attemptC = try await Bench.attempt(authority, Bench.projectC)
            _ = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
            if abandon {
                try await authority.abandonCommit(attemptA, reason: .outcomeUnknown).get()
            } else {
                #expect(await authority.nextEngineCommand() == .setOutputsMuted(true))
            }
            let first = try await Bench.restore(authority)
            #expect(await authority.snapshot().projects[Bench.projectB]?.recoveryBase == baseline.base)
            if abandon {
                try await authority.abandonCommit(attemptC, reason: .outcomeUnknown).get()
            } else {
                guard case .prepare = await authority.nextEngineCommand() else {
                    Issue.record("Expected C's prepare before its withheld commit")
                    return
                }
                #expect(await authority.nextEngineCommand() == .setOutputsMuted(true))
            }
            let second = try await Bench.restore(authority)
            #expect(first.attempt != second.attempt && first.token == second.token)
            let before = await authority.snapshot()
            #expect(before.projects[Bench.projectB]?.recoveryBase == baseline.base)
            #expect(Bench.refusal(await Bench.acknowledge(first, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == before)
            let taken = await engine.drain(authority)
            if abandon {
                #expect(Array(taken.suffix(3)) ==
                        [.setOutputsMuted(true), .setOutputsMuted(true), Bench.restoreCommand(second)])
            } else {
                #expect(taken == [Bench.restoreCommand(second)])
            }
            #expect(!taken.contains(Bench.restoreCommand(first)))
            let delivered = await authority.snapshot()
            #expect(Bench.refusal(await Bench.acknowledge(first, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == delivered)
            #expect(await engine.completeRestore(authority) == .success(baseline.lifecycle))
            #expect(await authority.snapshot().projects[Bench.projectB]?.recoveryBase == nil)
            #expect(await engine.drain(authority) == [.setOutputsMuted(false)])
        }
    }
}

extension HostAuthorityTests.ActorMuteReconciliation {
    @Test func capabilityLossBeforeRestoreAdmissionPreservesDegradedResident() async throws {
        var engine = try ScriptedActivationEngine(trackedLimit: 512)
        let authority = try await Bench.makeAuthority(&engine, lifecycleA: .degraded([Bench.audio]))
        _ = try await Bench.commitDelivered(authority, &engine)
        let before = await authority.snapshot()
        let installed = try #require(before.projects[Bench.projectA]?.installed)
        let dependent = try #require(before.projects[Bench.projectA]?.reviewed)
        let token = try await Bench.leaseToken(authority)
        // The mute fits; fewer than maxRecoveryStepSlots remain for automatic admission.
        for _ in 0..<(EngineCommandQueue.capacity - EngineCommandQueue.maxRecoveryStepSlots) {
            try await Bench.begin(authority, project: Bench.projectB)
            try await authority.abandonPrepare(project: Bench.projectB).get()
        }
        try await authority.abandonCommit(try await Bench.attempt(authority), reason: .outcomeUnknown).get()
        let blocked = await authority.snapshot()
        #expect(blocked.restoring == nil && blocked.outputsMuted && blocked.inFlight.isEmpty)
        #expect(blocked.projects[Bench.projectA]?.lifecycle == .recovering)
        #expect(blocked.projects[Bench.projectA]?.recoveryBase == .degraded([Bench.audio]))
        #expect(blocked.lease == before.lease && !blocked.queue.canAccept(EngineCommandQueue.maxRecoveryStepSlots))
        #expect(Bench.refusal(await authority.resolveRecovery(project: Bench.projectA)) == .queueFull)
        #expect(await authority.snapshot() == blocked)
        let loss = CapabilityID(validated: "cap.adat") // Sorts before the existing audio loss.
        let retained = [Bench.audio, loss].sorted()
        try await authority.capabilityLost(loss, project: Bench.projectA, token: token).get()
        let updated = await authority.snapshot()
        #expect(updated.restoring == nil && updated.projects[Bench.projectA]?.lifecycle == .recovering)
        #expect(updated.projects[Bench.projectA]?.recoveryBase == .degraded(retained))
        #expect(updated.projects[Bench.projectA]?.record == blocked.projects[Bench.projectA]?.record)
        #expect(updated.lease == blocked.lease && updated.ledger == blocked.ledger && updated.plans == blocked.plans)
        #expect(updated.queue == blocked.queue && updated.outstanding == blocked.outstanding)
        #expect(await engine.drain(authority) == blocked.queue.pending)
        try await engine.finishAbandoned(authority)
        let drained = await authority.snapshot()
        #expect(drained.restoring == nil && drained.outputsMuted && drained.queue.isEmpty)
        #expect(drained.lease == before.lease && engine.pending.isEmpty && engine.pendingRestores.isEmpty)
        #expect(drained.plans.records.flatMap(\.entries).count == 2)
        let revision = try #require(before.projects[Bench.projectA]).running.revision
        #expect(await authority.resolveRecovery(project: Bench.projectA) == .success(.restoring(revision)))
        let queued = await authority.snapshot()
        let restore = try #require(queued.restoring)
        guard case .resident(let resident) = restore.target else {
            Issue.record("Expected the genuinely installed qualified resident")
            return
        }
        #expect(resident.binding == installed && restore.target.instance == before.plans.currentInstance)
        #expect(restore.token == token && restore.revision == revision && !restore.delivered)
        #expect(restore.discardAfterRestore == [dependent])
        #expect(queued.projects[Bench.projectA]?.recoveryBase == .degraded(retained))
        #expect(queued.queue.pending == [Bench.restoreCommand(restore), .discard(dependent)])
        #expect(Bench.refusal(await Bench.acknowledge(restore, on: authority)) == .staleRestore)
        #expect(await authority.snapshot() == queued)
        #expect(await engine.drain(authority) == [Bench.restoreCommand(restore), .discard(dependent)])
        #expect(await engine.completeRestore(authority) == .success(.degraded(retained)))
        let acknowledged = await authority.snapshot()
        #expect(acknowledged.projects[Bench.projectA]?.lifecycle == .degraded(retained))
        #expect(acknowledged.projects[Bench.projectA]?.recoveryBase == nil && acknowledged.restoring == nil)
        #expect(acknowledged.projects[Bench.projectA]?.running == before.projects[Bench.projectA]?.running)
        #expect(acknowledged.projects[Bench.projectA]?.installed == installed && acknowledged.ledger == before.ledger)
        #expect(!acknowledged.outputsMuted && acknowledged.pendingOutput == false && acknowledged.lease == before.lease)
        #expect(acknowledged.plans.records.flatMap(\.entries).count == 1)
        #expect(engine.discarded == [dependent] && engine.anomalies.isEmpty)
        #expect(await engine.drain(authority) == [.setOutputsMuted(false)])
    }
}
