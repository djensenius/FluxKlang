import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

enum RecoveryEntryBaseline: CaseIterable, Sendable {
    case storedStopped, running, degraded

    var lifecycle: EngineLifecycle {
        switch self {
        case .storedStopped: .stopped
        case .running: .running
        case .degraded: .degraded([Bench.audio])
        }
    }

    var base: RunningSetState {
        switch self {
        case .storedStopped: .absent
        case .running: .running
        case .degraded: .degraded([Bench.audio])
        }
    }
}

enum RecoveryEntryPhase: CaseIterable, Sendable {
    case idle, preparing, awaitingReview, pressured
}

extension HostAuthorityTests {
    /// Parent recovery provenance composed with the child's grant/mute entry hooks.
    struct RecoveryProvenance {
        @Test(arguments: RecoveryEntryBaseline.allCases, RecoveryEntryPhase.allCases)
        func grantPreservesFirstBaseAcrossReentry(
            baseline: RecoveryEntryBaseline, phase: RecoveryEntryPhase
        ) async throws {
            let plan = PreparedActivationID(validated: "prep.b-stored")
            let authority = try await Bench.makeAuthority(runningB: plan, lifecycleB: baseline.lifecycle)
            var engine = try ScriptedActivationEngine()
            if phase == .preparing || phase == .awaitingReview {
                try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectB).get()
                _ = await engine.drain(authority)
                if phase == .awaitingReview {
                    #expect(try await engine.answerNext(authority)?.verdict.get() == .routed)
                }
            }
            if phase == .pressured {
                try await authority.open(project: Bench.projectC,
                                         running: RunningGraph(revision: .initial, prepared: nil)).get()
                try await Bench.fillQueue(authority, with: Bench.projectC)
            }
            _ = try await authority.leaseLost(try await Bench.leaseToken(authority)).get()
            let beforeGrant = await authority.snapshot()
            _ = try await authority.acquire(project: Bench.projectB, window: Bench.windowB).get()
            let granted = await authority.snapshot()
            #expect(granted.projects[Bench.projectB]?.lifecycle == .recovering)
            #expect(granted.projects[Bench.projectB]?.recoveryBase == baseline.base)
            #expect(granted.projects[Bench.projectA] == beforeGrant.projects[Bench.projectA])
            #expect(granted.projects[Bench.projectC] == beforeGrant.projects[Bench.projectC])
            #expect(granted.outputsMuted && granted.pendingOutput == true)
            #expect(Bench.context(granted) == (try #require(Bench.context(beforeGrant)).next()))
            if phase == .pressured {
                #expect(granted.restoring == nil)
                #expect(Bench.refusal(await authority.resolveRecovery(project: Bench.projectB)) == .queueFull)
                #expect(await authority.snapshot() == granted)
                #expect(await engine.drain(authority) == [.setOutputsMuted(true)] + beforeGrant.queue.pending)
                _ = try await authority.resolveRecovery(project: Bench.projectB).get()
            }
            let old = try await Bench.restore(authority)
            // A second grant while already recovering must not replace the first base.
            try await authority.release(project: Bench.projectB).get()
            let token = try await authority.acquire(project: Bench.projectB, window: Bench.windowB).get().token
            let fresh = try await Bench.restore(authority)
            #expect(fresh.attempt != old.attempt && fresh.token == token && fresh.prepared == plan)
            let queued = await authority.snapshot()
            #expect(queued.projects[Bench.projectB]?.recoveryBase == baseline.base)
            #expect(Bench.refusal(await Bench.acknowledge(old, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == queued)
            #expect(await engine.drain(authority) ==
                    (phase == .pressured ? [] : [.setOutputsMuted(true)]) + [Bench.restoreCommand(fresh)])
            let beforeAck = await authority.snapshot()
            let expected: EngineLifecycle = phase == .preparing || phase == .awaitingReview
                ? .preparing(try ContractRevision.initial.next(), over: baseline.base) : baseline.lifecycle
            #expect(await engine.completeRestore(authority) == .success(expected))
            let acknowledged = await authority.snapshot()
            #expect(acknowledged.projects[Bench.projectB]?.lifecycle == expected)
            #expect(acknowledged.projects[Bench.projectB]?.recoveryBase == nil)
            #expect(acknowledged.projects[Bench.projectB]?.running == granted.projects[Bench.projectB]?.running)
            #expect(acknowledged.ledger == beforeAck.ledger)
            #expect(await engine.drain(authority) == [.setOutputsMuted(false)])
        }

        @Test(arguments: RecoveryEntryBaseline.allCases, [false, true])
        func lateMutePreservesPreparingBase(baseline: RecoveryEntryBaseline, abandon: Bool) async throws {
            let plan = PreparedActivationID(validated: "prep.b-stored")
            let authority = try await Bench.makeAuthority(runningB: plan, lifecycleB: baseline.lifecycle)
            var engine = try ScriptedActivationEngine()
            let retained = try await Bench.commitQueued(authority, &engine)
            let attemptA = try await Bench.attempt(authority)
            _ = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
            try await authority.begin(Bench.request(), candidate: Bench.candidate(), project: Bench.projectB).get()
            let beforeMute = await authority.snapshot()
            let prepare = try #require(beforeMute.outstanding[Bench.projectB])
            if abandon {
                try await authority.abandonCommit(attemptA, reason: .outcomeUnknown).get()
            } else {
                #expect(await authority.nextEngineCommand() == .setOutputsMuted(true))
            }
            let muted = await authority.snapshot()
            #expect(muted.outputsMuted && muted.projects[Bench.projectB]?.lifecycle == .recovering)
            #expect(muted.projects[Bench.projectB]?.recoveryBase == baseline.base)
            #expect(muted.projects[Bench.projectB]?.phase == .preparing)
            #expect(muted.projects[Bench.projectA]?.phase ==
                    .recovering(retained, cause: abandon ? .commitOutcomeUnknown : .leaseLost))
            #expect(muted.ledger == beforeMute.ledger)
            let restore = try await Bench.restore(authority)
            #expect(await engine.drain(authority) ==
                    [.prepare(Bench.candidate(), prepare)] + (abandon ? [.setOutputsMuted(true)] : [])
                    + [Bench.restoreCommand(restore)])
            let delivered = await authority.snapshot()
            #expect(delivered.outputsMuted && delivered.projects[Bench.projectB]?.recoveryBase == baseline.base)
            #expect(try await engine.answerNext(authority)?.verdict.get() == .routed)
            let authorization = try await authority.authorize(
                project: Bench.projectB, gesture: Bench.gesture(Bench.windowB)
            ).get()
            let beforeCommit = await authority.snapshot()
            #expect(Bench.refusal(await authority.commit(project: Bench.projectB, authorization: authorization))
                    == .lifecycleRejectsChanges(.recovering))
            #expect(await authority.snapshot() == beforeCommit)
            let expected = EngineLifecycle.preparing(try ContractRevision.initial.next(), over: baseline.base)
            #expect(await engine.completeRestore(authority) == .success(expected))
            let acknowledged = await authority.snapshot()
            #expect(acknowledged.projects[Bench.projectB]?.recoveryBase == nil)
            #expect(acknowledged.projects[Bench.projectB]?.lifecycle == expected)
            #expect(acknowledged.ledger == beforeMute.ledger)
            #expect(await engine.drain(authority) == [.setOutputsMuted(false)])
            try await authority.commit(project: Bench.projectB, authorization: authorization).get()
            _ = await engine.drain(authority)
            _ = try #require(await engine.report(authority, .succeeded)).verdict.get()
            let afterCommit: EngineLifecycle = baseline == .degraded ? baseline.lifecycle : .running
            #expect(await authority.snapshot().projects[Bench.projectB]?.lifecycle == afterCommit)
            #expect(!engine.discarded.contains(retained))
        }

        @Test(arguments: RecoveryEntryBaseline.allCases, [false, true])
        func snapshotReopenRequiresExplicitProvenance(baseline: RecoveryEntryBaseline, known: Bool) async throws {
            let original = try await Bench.makeAuthority(lifecycleA: baseline.lifecycle)
            _ = try await original.leaseLost(try await Bench.leaseToken(original)).get()
            let saved = try await Bench.state(original)
            #expect(saved.recoveryBase == baseline.base && saved.lifecycle == .recovering)
            let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.reopened"),
                                              musicalClock: nil, nominalRate: 48_000)
            let reopened = try HostAuthority(host: ledger, live: Bench.liveState())
            // Omission deliberately models UNKNOWN provenance, not a known snapshot import.
            try await reopened.open(project: Bench.projectA, running: saved.running,
                                     lifecycle: saved.lifecycle, recoveryBase: known ? saved.recoveryBase : nil).get()
            _ = try await reopened.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let recovering = try await Bench.state(reopened)
            #expect(recovering.recoveryBase == (known ? baseline.base : .absent))
            var engine = try ScriptedActivationEngine()
            let restore = try await Bench.restore(reopened)
            #expect(await engine.drain(reopened) == [Bench.restoreCommand(restore)])
            #expect(await engine.completeRestore(reopened) == .success(known ? baseline.lifecycle : .stopped))
            #expect(await reopened.snapshot().projects[Bench.projectA]?.recoveryBase == nil)
            #expect(await engine.drain(reopened).isEmpty)
        }
    }
}
