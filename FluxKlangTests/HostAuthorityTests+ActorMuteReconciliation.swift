import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

extension HostAuthorityTests {
    /// Rule M: a later FIFO mute gates the current holder, regardless of its cause.
    struct ActorMuteReconciliation {
        @Test(arguments: [false, true], [false, true])
        func lateMuteGatesCurrentHolder(abandon: Bool, runningB: Bool) async throws {
            let planB = runningB ? PreparedActivationID(validated: "prep.b-running") : nil
            let authority = try await Bench.makeAuthority(runningB: planB)
            var engine = try ScriptedActivationEngine()
            try await authority.open(project: Bench.projectC,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            let planA = try await Bench.commitQueued(authority, &engine)
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
            #expect(restore.revision == .initial && restore.prepared == planB && !restore.delivered)
            #expect(Bench.refusal(await Bench.acknowledge(restore, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == muted)
            #expect(await engine.drain(authority) ==
                    (abandon ? [.setOutputsMuted(true)] : []) + [Bench.restoreCommand(restore)])
            // Fresh context/authorization, not a stale plan that would refuse anyway.
            let freshB = try await Bench.review(authority, &engine, project: Bench.projectB)
            let authorization = try await authority.authorize(
                project: Bench.projectB, gesture: Bench.gesture(Bench.windowB)
            ).get()
            let beforeCommit = await authority.snapshot()
            #expect(Bench.refusal(await authority.commit(project: Bench.projectB, authorization: authorization))
                    == .lifecycleRejectsChanges(.recovering))
            #expect(await authority.snapshot() == beforeCommit)
            let preparing = EngineLifecycle.preparing(
                try ContractRevision.initial.next(), over: runningB ? .running : .absent
            )
            #expect(await engine.completeRestore(authority) == .success(preparing))
            #expect(await engine.drain(authority) == [.setOutputsMuted(false)])
            #expect(await authority.snapshot().ledger == granted.ledger)
            try await authority.commit(project: Bench.projectB, authorization: authorization).get()
            let attemptB = try await Bench.attempt(authority, Bench.projectB)
            #expect(await engine.drain(authority) == [.commit(freshB, attemptB, token)])
            #expect(!engine.discarded.contains(planA))
        }

        @Test(arguments: [false, true])
        func pressureKeepsGateUntilExplicitRetry(abandon: Bool) async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.commitQueued(authority, &engine)
            let attempt = try await Bench.attempt(authority)
            _ = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
            try await authority.open(project: Bench.projectC,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            let limit = abandon ? EngineCommandQueue.capacity - 3 : EngineCommandQueue.capacity
            for _ in 1..<limit {
                try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectC).get()
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
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.commitQueued(authority, &engine)
            let attemptA = try await Bench.attempt(authority)
            _ = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
            let planB = PreparedActivationID(validated: "prep.b")
            try await Bench.commitWithoutDrain(authority, project: Bench.projectB, window: Bench.windowB,
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
            #expect(restore.prepared == (outcome == .failed ? nil : planB))
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
            try book.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectB).get()
            guard case .prepare(_, let prepare) = book.nextEngineCommand() else {
                Issue.record("Expected B's prepare")
                return
            }
            let plan = PreparedActivationID(validated: "prep.b")
            _ = try book.prepareAnswered(.success(plan), attempt: prepare).get()
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
                                                   prepared: restore.prepared, token: restore.token)
            #expect(completed == .success(.stopped))
            #expect(book.projects[Bench.projectB]?.recoveryBase == nil)
            let unmute = book.nextEngineCommand()
            #expect(unmute == .setOutputsMuted(false))
        }

        @Test(arguments: [false, true], RecoveryEntryBaseline.allCases)
        func repeatedMutesReplaceRestoreAuthority(abandon: Bool, baseline: RecoveryEntryBaseline) async throws {
            let authority = try await Bench.makeAuthority(
                runningB: PreparedActivationID(validated: "prep.b-stored"), lifecycleB: baseline.lifecycle
            )
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.commitQueued(authority, &engine)
            let attemptA = try await Bench.attempt(authority)
            let windowC = WindowID(validated: "win.c")
            try await authority.open(project: Bench.projectC,
                                     running: RunningGraph(revision: .initial, prepared: nil)).get()
            _ = try await authority.transfer(to: Bench.projectC, window: windowC).get()
            try await Bench.commitWithoutDrain(authority, project: Bench.projectC, window: windowC,
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
