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

/// Standalone-book boundary only. Bootstrap every binding through the canonical
/// book; model persisted stopped lifecycle without importing a resident into an actor.
enum QualifiedRecoveryBook {
    static func make(baseline: RecoveryEntryBaseline = .running, installB: Bool = false) throws -> HostAuthorityBook {
        let ledger = try GenerationLedger(primaryClock: .init(validated: "smp.qualified.recovery"),
                                          musicalClock: nil, nominalRate: 48_000)
        var book = try HostAuthorityBook(host: ledger, live: Bench.liveState(), planCapacity: 512)
        for project in [Bench.projectA, Bench.projectB] {
            try book.open(project: project, running: RunningGraph(revision: .initial, prepared: nil)).get()
        }
        _ = try book.acquire(project: Bench.projectA, window: Bench.windowA).get()
        let installed = try commit(&book, name: Bench.runningPlan)
        try report(&book, binding: installed, outcome: .succeeded)
        book.projects[Bench.projectA]?.lifecycle = baseline.lifecycle
        if installB {
            _ = try book.transfer(to: Bench.projectB, window: Bench.windowB).get()
            let installedB = try commit(&book, project: Bench.projectB, window: Bench.windowB,
                                        name: .init(validated: "prep.b-running"))
            try report(&book, binding: installedB, project: Bench.projectB, outcome: .succeeded)
            book.projects[Bench.projectB]?.lifecycle = baseline.lifecycle
            _ = try book.transfer(to: Bench.projectA, window: Bench.windowA).get()
        }
        return book
    }

    static func begin(_ book: inout HostAuthorityBook, project: ProjectID = Bench.projectA) throws {
        let revision = try #require(book.projects[project]).transaction.running.revision
        let graph = Bench.candidate(revision: revision)
        try book.begin(Bench.request(base: revision), candidate: graph,
                       projectDocument: Bench.projectDocument(project: project, candidate: graph),
                       project: project).get()
    }

    static func review(_ book: inout HostAuthorityBook, project: ProjectID = Bench.projectA,
                       name: PreparedActivationID) throws -> PlanBinding {
        try begin(&book, project: project)
        let prepare = try #require(book.outstanding[project])
        let command = book.nextEngineCommand()
        guard case .prepare(_, _, prepare.instance, prepare.attempt) = command else {
            throw QualifiedRecoveryError.command
        }
        #expect(try book.prepareAnswered(.success(name), instance: prepare.instance,
                                         attempt: prepare.attempt).get() == .routed)
        return try #require(book.projects[project]?.reviewed)
    }

    static func reviewQueued(_ book: inout HostAuthorityBook, project: ProjectID = Bench.projectA,
                             name: PreparedActivationID) throws -> PlanBinding {
        try begin(&book, project: project)
        let preparation = try #require(book.outstanding[project])
        #expect(book.queue.pending.contains {
            if case .prepare(_, _, preparation.instance, preparation.attempt) = $0 { true } else { false }
        })
        #expect(try book.prepareAnswered(.success(name), instance: preparation.instance,
                                         attempt: preparation.attempt).get() == .routed)
        return try #require(book.projects[project]?.reviewed)
    }

    /// Simulated execution at the standalone-book boundary, including terminal
    /// cleanup of abandoned prepares and truthful acknowledgement after discard delivery.
    static func drain(_ book: inout HostAuthorityBook) throws -> [EngineCommand] {
        var commands: [EngineCommand] = []
        for _ in 0..<(book.plans.capacity + EngineCommandQueue.capacity + 4) {
            guard let command = book.nextEngineCommand() else { return commands }
            commands.append(command)
            if case .discard(let binding) = command { try book.retired(binding).get() }
            if case .prepare(_, _, let instance, let attempt) = command,
               book.plans.snapshot().records.flatMap(\.entries).contains(where: {
                   $0.attempt == attempt && $0.state == .pending(reclaim: true)
               }) {
                #expect(try book.prepareAnswered(.failure(.engineRefused), instance: instance,
                                                 attempt: attempt).get() == .dropped)
            }
        }
        throw QualifiedRecoveryError.command
    }

    static func commit(_ book: inout HostAuthorityBook, project: ProjectID = Bench.projectA,
                       window: WindowID = Bench.windowA, name: PreparedActivationID,
                       deliver: Bool = true) throws -> PlanBinding {
        let binding = try review(&book, project: project, name: name)
        let authorization = try book.authorize(project: project, gesture: Bench.gesture(window)).get()
        try book.commit(project: project, authorization: authorization).get()
        if deliver {
            let attempt = try #require(book.projects[project]?.transaction.lastAttempt)
            let token = try #require(book.registry.snapshot?.token)
            #expect(book.nextEngineCommand() == .commit(binding, attempt, token))
        }
        return binding
    }

    static func report(_ book: inout HostAuthorityBook, binding: PlanBinding,
                       project: ProjectID = Bench.projectA, outcome: ActivationCommitOutcome) throws {
        let attempt = try #require(book.projects[project]?.transaction.lastAttempt)
        _ = try book.commitReported(.init(prepared: binding.prepared, attempt: attempt, outcome: outcome,
                                          applied: outcome == .succeeded ? [Bench.nodeOut] : [],
                                          unapplied: outcome == .failed ? [Bench.nodeOut] : [])).get()
    }

    static func acknowledge(_ book: inout HostAuthorityBook, _ record: RestoreRecord)
    -> Result<EngineLifecycle, HostAuthorityRefusal> {
        book.restoreCompleted(attempt: record.attempt, revision: record.revision,
                              target: record.target, token: record.token)
    }
}

private enum QualifiedRecoveryError: Error { case command }

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
            if baseline == .storedStopped {
                try storedGrantProvenance(phase: phase)
                return
            }
            var engine = try ScriptedActivationEngine(trackedLimit: 512)
            let authority = try await Bench.makeAuthority(&engine)
            try await Bench.installB(authority, &engine, lifecycle: baseline.lifecycle)
            let plan = try #require(try await Bench.state(authority, Bench.projectB).installed)
            if phase == .preparing || phase == .awaitingReview {
                try await Bench.begin(authority, project: Bench.projectB)
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
            #expect(fresh.attempt != old.attempt && fresh.token == token)
            guard case .resident(let resident) = fresh.target else {
                Issue.record("Expected B's qualified resident")
                return
            }
            #expect(resident.binding == plan)
            let queued = await authority.snapshot()
            #expect(queued.projects[Bench.projectB]?.recoveryBase == baseline.base)
            #expect(Bench.refusal(await Bench.acknowledge(old, on: authority)) == .staleRestore)
            #expect(await authority.snapshot() == queued)
            #expect(await engine.drain(authority) ==
                    (phase == .pressured ? [] : [.setOutputsMuted(true)]) + [Bench.restoreCommand(fresh)])
            let beforeAck = await authority.snapshot()
            let expected: EngineLifecycle = phase == .preparing || phase == .awaitingReview
                ? .preparing(try fresh.revision.next(), over: baseline.base) : baseline.lifecycle
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
            if baseline == .storedStopped {
                try storedLateMuteProvenance(abandon: abandon)
                return
            }
            var engine = try ScriptedActivationEngine()
            let authority = try await Bench.makeAuthority(&engine)
            try await Bench.installB(authority, &engine, lifecycle: baseline.lifecycle)
            let retained = try await Bench.commitQueued(authority, &engine)
            let retainedBinding = try #require(try await Bench.state(authority).reviewed)
            let attemptA = try await Bench.attempt(authority)
            _ = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
            try await Bench.begin(authority, project: Bench.projectB)
            let beforeMute = await authority.snapshot()
            let prepare = try #require(beforeMute.queue.pending.last)
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
                    [prepare] + (abandon ? [.setOutputsMuted(true)] : [])
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
            let expected = EngineLifecycle.preparing(try restore.revision.next(), over: baseline.base)
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
            #expect(!engine.discarded.contains(retainedBinding))
        }

        @Test(arguments: RecoveryEntryBaseline.allCases, [false, true])
        func snapshotReopenRequiresExplicitProvenance(baseline: RecoveryEntryBaseline, known: Bool) async throws {
            var original = try QualifiedRecoveryBook.make(baseline: baseline)
            _ = try original.leaseLost(try #require(original.registry.snapshot?.token)).get()
            let saved = try #require(original.snapshot().projects[Bench.projectA])
            #expect(saved.recoveryBase == baseline.base && saved.lifecycle == .recovering)
            let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.reopened"),
                                              musicalClock: nil, nominalRate: 48_000)
            let reopened = try HostAuthority(host: ledger, live: Bench.liveState())
            // G1 cannot import a raw resident even with correct saved provenance.
            let before = await reopened.snapshot()
            let refused = await reopened.open(project: Bench.projectA, running: saved.running,
                                              lifecycle: saved.lifecycle,
                                              recoveryBase: known ? saved.recoveryBase : nil)
            #expect(Bench.refusal(refused) == .unqualifiedResident)
            #expect(await reopened.snapshot() == before)
            // Model missing provenance only on this standalone canonical owner,
            // never import bindings into an actor or infer running from a stored plan.
            if !known { original.projects[Bench.projectA]?.recoveryBase = nil }
            #expect(original.nextEngineCommand() == .setOutputsMuted(true))
            _ = try original.acquire(project: Bench.projectA, window: Bench.windowA).get()
            let restore = try #require(original.restoring)
            #expect(try QualifiedRecoveryBook.drain(&original) == [Bench.restoreCommand(restore)])
            #expect(QualifiedRecoveryBook.acknowledge(&original, restore)
                    == .success(known ? baseline.lifecycle : .stopped))
            #expect(original.projects[Bench.projectA]?.recoveryBase == nil)
            #expect(try QualifiedRecoveryBook.drain(&original) == [.setOutputsMuted(false)])
        }
    }
}
