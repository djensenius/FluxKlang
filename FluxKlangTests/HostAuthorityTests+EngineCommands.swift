import Testing
@testable import FluxKlang

private let nodes = [NodeID(validated: "node.fx"), NodeID(validated: "node.eq"), NodeID(validated: "node.out")]

/// Real ledger operations mint every binding/resident. Never an ownership lookup by raw ID.
private struct QueuePlans {
    let ledger: EnginePlanLedger
    let previous: PlanBinding
    let reviewed: PlanBinding
    let resident: CommittedResident
    let token: EngineLeaseToken

    init(alias: Bool = false) throws {
        ledger = try EnginePlanLedger(capacity: 4)
        let attempts = try ledgerAttempts(2)
        previous = try ledgerBinding(ledger, attempt: attempts[0], prepared: .init(validated: "prep.previous"))
        reviewed = try ledgerBinding(ledger, attempt: attempts[1],
                                     prepared: .init(validated: alias ? "prep.previous" : "prep.reviewed"))
        try ledger.committed(previous, outcome: .succeeded)
        resident = try #require(ledger.attestCommitted(previous))
        var registry = EngineLeaseRegistry()
        token = try registry.acquire(project: .init(validated: "prj.queue"),
                                     window: .init(validated: "win.queue")).snapshot.token
    }

    var running: RunningGraph { RunningGraph(revision: .initial, prepared: previous.prepared) }
}

private func step(_ decisions: [RecoveryDecision], _ effects: [ActivationEffect] = []) -> ActivationRecoveryStep {
    ActivationRecoveryStep(cause: .leaseLost, decisions: decisions, effects: effects)
}

private func refusal(_ result: Result<Void, EngineCommandQueueRefusal>) -> EngineCommandQueueRefusal? {
    if case .failure(let refusal) = result { return refusal }
    return nil
}

private func drain(_ queue: inout EngineCommandQueue) -> [EngineCommand] {
    var commands: [EngineCommand] = []
    while let command = queue.dequeue() { commands.append(command) }
    return commands
}

private func fillers(_ count: Int) -> [EngineCommand] {
    (0..<count).map { .setOutputsMuted($0.isMultiple(of: 2)) }
}

private enum DecisionKind: CaseIterable {
    case restorePrevious, keepActivePartial, missingPlaceholder, recover

    init(_ decision: RecoveryDecision) {
        switch decision {
        case .restorePrevious: self = .restorePrevious
        case .keepActivePartial: self = .keepActivePartial
        case .missingPlaceholder: self = .missingPlaceholder
        case .recover: self = .recover
        }
    }
}

private enum CommandKind: CaseIterable {
    case prepare, commit, discard, restore, keepActivePartial, placeholders, setOutputsMuted

    init(_ command: EngineCommand) {
        switch command {
        case .prepare: self = .prepare
        case .commit: self = .commit
        case .discard: self = .discard
        case .restore: self = .restore
        case .keepActivePartial: self = .keepActivePartial
        case .placeholders: self = .placeholders
        case .setOutputsMuted: self = .setOutputsMuted
        }
    }
}

extension HostAuthorityTests {
    struct EngineCommands {
        @Test func qualifiedCommandsDequeueInEmissionOrder() throws {
            let plans = try QueuePlans()
            var host = try TransactionBench()
            let attempt = try host.committedAttempt()
            let graph = AuthorityBench.candidate()
            let document = AuthorityBench.projectDocument(project: AuthorityBench.projectA, candidate: graph)
            let commands: [EngineCommand] = [
                .prepare(graph, document, plans.reviewed.instance, plans.reviewed.attempt), .discard(plans.reviewed),
                .commit(plans.previous, attempt, plans.token)
            ]
            var queue = EngineCommandQueue()
            for command in commands { try queue.enqueue([command]).get() }
            #expect(queue.dequeue() == commands[0])
            try queue.enqueue([.setOutputsMuted(true)]).get()
            #expect(drain(&queue) == Array(commands.dropFirst()) + [.setOutputsMuted(true)])
            var batch = EngineCommandQueue()
            try batch.enqueue(commands).get()
            #expect(drain(&batch) == commands && batch.isEmpty && batch.dequeue() == nil)
        }

        @Test func recoveryDecisionsPrecedeEffects() throws {
            let plans = try QueuePlans()
            let restore = ActivationRecovery.restore(plans.running, discarding: plans.reviewed.prepared,
                                                      cause: .commitFailed)
            var queue = EngineCommandQueue()
            try queue.enqueue([.setOutputsMuted(false)]).get()
            let restoreAttempt = RestoreAttemptID()
            try queue.enqueue(restore, running: plans.running, resident: plans.resident,
                              retiring: plans.reviewed, lease: plans.token, restoreAttempt: restoreAttempt,
                              restoreTarget: .resident(plans.resident)).get()
            try plans.ledger.committed(plans.reviewed, outcome: .partial)
            let kept = try #require(plans.ledger.attestCommitted(plans.reviewed))
            let keep = ActivationRecovery.keepPartial(unapplied: [nodes[1], nodes[2]], replacing: plans.running)
            let running = RunningGraph(revision: try ContractRevision.initial.next(), prepared: plans.reviewed.prepared)
            try queue.enqueue(keep, running: running, resident: kept, retiring: plans.previous, lease: nil).get()
            #expect(drain(&queue) == [
                .setOutputsMuted(false),
                .restore(restoreAttempt, .initial, .resident(plans.resident), plans.token), .discard(plans.reviewed),
                .keepActivePartial(kept), .placeholders([nodes[1], nodes[2]]), .discard(plans.previous)
            ])
            // Mute over a NONEMPTY graph has no resident role to supply.
            let mute = ActivationRecovery.enterRecovery(.commitOutcomeUnknown, running: plans.running)
            try queue.enqueue(mute, running: plans.running, resident: nil, retiring: nil, lease: nil).get()
            #expect(queue.pending == [.setOutputsMuted(true)])
            let before = queue
            let two = step([.recover(muteOutputs: true)], [.discard(plans.reviewed.prepared),
                                                         .discard(plans.previous.prepared)])
            #expect(refusal(queue.enqueue(two, running: plans.running, resident: nil,
                                           retiring: plans.reviewed, lease: nil)) == .runningMismatch)
            #expect(queue == before)
        }

        @Test func queueRefusesWholeBatchBeyondCapacity() throws {
            var queue = EngineCommandQueue()
            #expect(EngineCommandQueue.capacity == 256 && queue.capacity == 256)
            #expect(!queue.canAccept(-1) && queue.canAccept(0) && queue.canAccept(256) && !queue.canAccept(257))
            #expect(refusal(queue.enqueue(fillers(257))) == .full(requested: 257, available: 256))
            #expect(queue.isEmpty)
            try queue.enqueue(fillers(256)).get()
            let before = queue
            #expect(refusal(queue.enqueue(fillers(1))) == .full(requested: 1, available: 0))
            #expect(queue == before && queue.canAccept(0) && !queue.canAccept(1))
            #expect(drain(&queue) == fillers(256))
            try queue.enqueue(fillers(254)).get()
            let nearlyFull = queue
            #expect(refusal(queue.enqueue(fillers(3))) == .full(requested: 3, available: 2))
            #expect(queue == nearlyFull)
        }

        @Test func restoreAndKeepNeedTheirLeaseAndQualifiedRunningPlan() throws {
            let plans = try QueuePlans()
            let restore = step([.restorePrevious(.initial)], [.discard(plans.reviewed.prepared)])
            var queue = EngineCommandQueue()
            try queue.enqueue(fillers(1)).get()
            let before = queue
            let missingAttempt = queue.enqueue(restore, running: plans.running, resident: plans.resident,
                                               retiring: plans.reviewed, lease: plans.token,
                                               restoreTarget: .resident(plans.resident))
            #expect(refusal(missingAttempt) == .restoreAttemptRequired)
            #expect(queue == before)
            let restoreAttempt = RestoreAttemptID()
            let unleased = queue.enqueue(restore, running: plans.running, resident: plans.resident,
                                         retiring: plans.reviewed, lease: nil, restoreAttempt: restoreAttempt,
                                         restoreTarget: .resident(plans.resident))
            #expect(refusal(unleased) == .leaseRequired)
            #expect(refusal(queue.enqueue(restore, running: plans.running, resident: plans.resident,
                                           retiring: plans.reviewed, lease: nil)) == .leaseRequired)
            #expect(refusal(queue.enqueue(restore, running: plans.running, resident: nil,
                                           retiring: plans.reviewed, lease: plans.token)) == .runningMismatch)
            let moved = RunningGraph(revision: try ContractRevision.initial.next(), prepared: plans.previous.prepared)
            #expect(refusal(queue.enqueue(restore, running: moved, resident: plans.resident,
                                           retiring: plans.reviewed, lease: plans.token)) == .runningMismatch)
            let bare = RunningGraph(revision: .initial, prepared: nil)
            #expect(refusal(queue.enqueue(step([.keepActivePartial]), running: bare, resident: nil,
                                           retiring: nil, lease: plans.token)) == .runningMismatch)
            let selfDiscard = step([.restorePrevious(.initial)], [.discard(plans.previous.prepared)])
            #expect(refusal(queue.enqueue(selfDiscard, running: plans.running, resident: plans.resident,
                                           retiring: plans.previous, lease: plans.token)) == .runningMismatch)
            try plans.ledger.committed(plans.reviewed, outcome: .partial)
            let wrongRole = try #require(plans.ledger.attestCommitted(plans.reviewed))
            #expect(refusal(queue.enqueue(restore, running: plans.running, resident: wrongRole,
                                           retiring: plans.previous, lease: plans.token)) == .runningMismatch)
            #expect(queue == before)
            let emptyTarget = RestoreTarget.empty(plans.ledger.currentInstance)
            try queue.enqueue(restore, running: bare, resident: nil, retiring: plans.reviewed, lease: plans.token,
                              restoreAttempt: restoreAttempt, restoreTarget: emptyTarget).get()
            let expected: [EngineCommand] = [
                .restore(restoreAttempt, .initial, emptyTarget, plans.token), .discard(plans.reviewed)
            ]
            #expect(Array(queue.pending.dropFirst()) == expected)
        }

        @Test func explicitRestoreTargetCannotDiscardItsResident() throws {
            let plans = try QueuePlans()
            let restore = step([.restorePrevious(.initial)], [.discard(plans.previous.prepared)])
            let target = RestoreTarget.resident(plans.resident)
            var queue = EngineCommandQueue()
            try queue.enqueue(fillers(1)).get()
            let before = queue

            let refused = queue.enqueue(
                restore, running: plans.running, resident: nil, retiring: plans.previous,
                lease: plans.token, restoreAttempt: RestoreAttemptID(), restoreTarget: target
            )
            #expect(refusal(refused) == .runningMismatch)
            #expect(queue == before)
        }

        @Test func retirementAndResidentAreExactOptionalRoles() throws {
            let plans = try QueuePlans(alias: true)
            let restore = step([.restorePrevious(.initial)], [.discard(plans.reviewed.prepared)])
            var queue = EngineCommandQueue()
            // Same raw name, different qualified preparations: allowed. Role authority belongs to the host.
            let restoreAttempt = RestoreAttemptID()
            let target = RestoreTarget.resident(plans.resident)
            try queue.enqueue(restore, running: plans.running, resident: plans.resident,
                              retiring: plans.reviewed, lease: plans.token, restoreAttempt: restoreAttempt,
                              restoreTarget: target).get()
            #expect(queue.pending == [
                .restore(restoreAttempt, .initial, target, plans.token), .discard(plans.reviewed)
            ])
            let before = queue
            #expect(refusal(queue.enqueue(restore, running: plans.running, resident: plans.resident,
                                           retiring: nil, lease: plans.token)) == .runningMismatch)
            let mute = step([.recover(muteOutputs: true)])
            #expect(refusal(queue.enqueue(mute, running: plans.running, resident: plans.resident,
                                           retiring: nil, lease: nil)) == .runningMismatch)
            #expect(refusal(queue.enqueue(mute, running: plans.running, resident: nil,
                                           retiring: plans.reviewed, lease: nil)) == .runningMismatch)
            #expect(queue == before)
        }

        @Test func maximumPartialKeepNeedsThreeSlots() throws {
            let plans = try QueuePlans()
            try plans.ledger.committed(plans.reviewed, outcome: .partial)
            let resident = try #require(plans.ledger.attestCommitted(plans.reviewed))
            let unapplied = Set(try (0..<ProjectGraphLimits.nodes).map { try NodeID("node.p\($0)") })
            let keep = ActivationRecovery.keepPartial(unapplied: unapplied, replacing: plans.running)
            let running = RunningGraph(revision: try ContractRevision.initial.next(), prepared: plans.reviewed.prepared)
            var queue = EngineCommandQueue()
            try queue.enqueue(fillers(254)).get()
            let before = queue
            #expect(refusal(queue.enqueue(keep, running: running, resident: resident,
                                           retiring: plans.previous, lease: nil)) == .full(requested: 3, available: 2))
            #expect(queue == before)
            #expect(queue.dequeue() == .setOutputsMuted(true))
            try queue.enqueue(keep, running: running, resident: resident, retiring: plans.previous, lease: nil).get()
            #expect(queue.count == EngineCommandQueue.capacity)
            #expect(Array(queue.pending.suffix(3)) == [
                .keepActivePartial(resident), .placeholders(unapplied.sorted()), .discard(plans.previous)
            ])
            var empty = EngineCommandQueue()
            try empty.enqueue(keep, running: running, resident: resident, retiring: plans.previous, lease: nil).get()
            #expect(empty.count == EngineCommandQueue.maxRecoveryStepSlots && empty.count == 3)
        }

        @Test func refusalPartWayThroughStepLeavesQueueUnchanged() throws {
            let plans = try QueuePlans()
            let wrong = try ContractRevision.initial.next()
            var queue = EngineCommandQueue()
            try queue.enqueue(fillers(256)).get()
            let before = queue
            let late = step([.missingPlaceholder(nodes[0]), .recover(muteOutputs: true), .restorePrevious(wrong)],
                            [.discard(plans.reviewed.prepared)])
            #expect(refusal(queue.enqueue(late, running: plans.running, resident: plans.resident,
                                           retiring: plans.reviewed, lease: nil)) == .runningMismatch)
            let restore = step([.recover(muteOutputs: true), .restorePrevious(.initial)])
            // Revision -> plan -> lease -> whole-batch capacity.
            #expect(refusal(queue.enqueue(restore, running: plans.running, resident: nil,
                                           retiring: nil, lease: nil)) == .runningMismatch)
            #expect(refusal(queue.enqueue(restore, running: plans.running, resident: plans.resident,
                                           retiring: nil, lease: nil)) == .leaseRequired)
            #expect(refusal(queue.enqueue(restore, running: plans.running, resident: plans.resident,
                                           retiring: nil, lease: plans.token)) == .restoreAttemptRequired)
            #expect(refusal(queue.enqueue(restore, running: plans.running, resident: plans.resident,
                                           retiring: nil, lease: plans.token,
                                           restoreAttempt: RestoreAttemptID())) == .full(requested: 2, available: 0))
            #expect(queue == before)
        }

        @Test func placeholderRunsFoldWithoutCrossingDecisions() throws {
            let plans = try QueuePlans()
            let crash = step(ActivationRecovery.decisions(for: .processorCrashed(nodes[1]), running: plans.running))
            var queue = EngineCommandQueue()
            try queue.enqueue(crash, running: plans.running, resident: nil, retiring: nil, lease: nil).get()
            let split = step([.missingPlaceholder(nodes[2]), .missingPlaceholder(nodes[0]), .recover(muteOutputs: true),
                              .missingPlaceholder(nodes[1]), .missingPlaceholder(nodes[1])],
                             [.discard(plans.reviewed.prepared)])
            try queue.enqueue(split, running: plans.running, resident: nil, retiring: plans.reviewed, lease: nil).get()
            try queue.enqueue(step([.missingPlaceholder(nodes[2])]), running: plans.running,
                              resident: nil, retiring: nil, lease: nil).get()
            try queue.enqueue(step([]), running: plans.running, resident: nil, retiring: nil, lease: nil).get()
            #expect(queue.pending == [
                .placeholders([nodes[1]]), .placeholders([nodes[2], nodes[0]]), .setOutputsMuted(true),
                .placeholders([nodes[1], nodes[1]]), .discard(plans.reviewed), .placeholders([nodes[2]])
            ])
            #expect(!queue.pending.contains(.placeholders([])))
        }

        @Test func prepareCarriesValidatedGraphBytes() async throws {
            var engine = try ScriptedActivationEngine()
            let authority = try await AuthorityBench.makeAuthority(&engine)
            let revision = try await AuthorityBench.state(authority).running.revision
            var graph = AuthorityBench.candidate(revision: revision)
            graph.unknownFields = ["future": .array([.int(1), .double(2.5)])]
            graph.nodes[0].unknownFields = ["x-node": .string("kept")]
            graph.extensions = ["vendor": .object(["k": .bool(true)])]
            let decoded = try GraphDocument.decode(from: graph.encoded())
            try await authority.begin(AuthorityBench.request(base: revision), candidate: decoded,
                                      projectDocument: AuthorityBench.projectDocument(
                                        project: AuthorityBench.projectA, candidate: decoded),
                                      project: AuthorityBench.projectA).get()
            let first = try #require(await authority.nextEngineCommand())
            guard case .prepare(let sent, _, let instance, let attempt) = first else {
                Issue.record("Expected prepare")
                return
            }
            #expect(try sent.encoded() == decoded.encoded())
            #expect(sent.unknownFields == graph.unknownFields && sent.extensions == graph.extensions)
            #expect(sent.nodes[0].unknownFields == ["x-node": .string("kept")])
            #expect(await authority.snapshot().outstanding[AuthorityBench.projectA]
                    == HostPrepare(instance: instance, attempt: attempt))
        }

        @Test func everyDecisionMapsToItsQualifiedCommand() throws {
            let plans = try QueuePlans()
            let restoreAttempt = RestoreAttemptID()
            let target = RestoreTarget.resident(plans.resident)
            let cases: [(RecoveryDecision, EngineCommand)] = [
                (.restorePrevious(.initial), .restore(restoreAttempt, .initial, target, plans.token)),
                (.keepActivePartial, .keepActivePartial(plans.resident)),
                (.missingPlaceholder(nodes[2]), .placeholders([nodes[2]])),
                (.recover(muteOutputs: true), .setOutputsMuted(true)),
                (.recover(muteOutputs: false), .setOutputsMuted(false))
            ]
            #expect(Set(cases.map { DecisionKind($0.0) }) == Set(DecisionKind.allCases))
            var kinds: Set<CommandKind> = [.prepare, .commit, .discard]
            for (decision, expected) in cases {
                var queue = EngineCommandQueue()
                let resident: CommittedResident?
                switch decision {
                case .restorePrevious, .keepActivePartial: resident = plans.resident
                case .recover, .missingPlaceholder: resident = nil
                }
                try queue.enqueue(step([decision]), running: plans.running, resident: resident,
                                  retiring: nil, lease: plans.token,
                                  restoreAttempt: decision == .restorePrevious(.initial) ? restoreAttempt : nil,
                                  restoreTarget: decision == .restorePrevious(.initial) ? target : nil).get()
                #expect(queue.pending == [expected])
                kinds.insert(CommandKind(expected))
            }
            #expect(kinds == Set(CommandKind.allCases))
        }
    }
}
