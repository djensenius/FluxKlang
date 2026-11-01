import Foundation
import Testing
@testable import FluxKlang

// The same host, graph and plans as the `TransactionBench` defaults.
private let projectA = ProjectID(validated: "prj.a")
private let graphID = GraphID(validated: "graph.main")
private let audio = CapabilityID(validated: "cap.audio")
private let runningPlan = PreparedActivationID(validated: "prep.running")
private let planID = PreparedActivationID(validated: "prep.next")
private let planP = PreparedActivationID(validated: "prep.p")
private let planQ = PreparedActivationID(validated: "prep.q")
private let nodes = [NodeID(validated: "node.fx"), NodeID(validated: "node.eq"), NodeID(validated: "node.out")]

private func report(_ outcome: ActivationCommitOutcome, prepared: PreparedActivationID = planID) -> CommitReportDraft {
    switch outcome {
    case .succeeded: CommitReportDraft(prepared: prepared, outcome: outcome, applied: Set(nodes), unapplied: [])
    case .failed: CommitReportDraft(prepared: prepared, outcome: outcome, applied: [], unapplied: Set(nodes))
    case .partial: CommitReportDraft(prepared: prepared, outcome: outcome, applied: [nodes[0]],
                                     unapplied: [nodes[1], nodes[2]])
    }
}

/// A decoded graph carrying unknown fields at the root and on a node, plus extensions.
private func extendedGraph() throws -> GraphDocument {
    var graph = GraphDocument(
        id: graphID, capabilities: [CapabilityDefinition(id: audio, label: "Audio")],
        nodes: [GraphNode(id: nodes[0], kind: .plugin, label: "FX", requiredCapabilities: [audio]),
                GraphNode(id: nodes[1], kind: .plugin, label: "EQ")],
        extensions: ["vendor": .object(["k": .bool(true)])]
    )
    graph.unknownFields = ["future": .object(["x": .array([.int(1), .double(2.5)])])]
    graph.nodes[1].unknownFields = ["x-node": .string("kept")]
    return try GraphDocument.decode(from: graph.encoded())
}

/// `count` discard effects with distinct plan IDs, in order.
private func discards(_ count: Int, from start: Int = 0) throws -> [ActivationEffect] {
    try (start..<(start + count)).map { .discard(try PreparedActivationID("prep.d\($0)")) }
}

private func drain(_ queue: inout EngineCommandQueue) -> [EngineCommand] {
    var commands: [EngineCommand] = []
    while let next = queue.dequeue() { commands.append(next) }
    return commands
}

private func refusal(_ result: Result<Void, EngineCommandQueueRefusal>) -> EngineCommandQueueRefusal? {
    if case .failure(let refusal) = result { return refusal }
    return nil
}

/// Every `RecoveryDecision` case; a new case fails to compile here.
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

/// Every `EngineCommand` case; a new case fails to compile here.
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

/// A hand-built step. The queue ignores `cause` (diagnostics only); this is
/// the one place that builds a step with a `cause`.
private func step(_ decisions: [RecoveryDecision], _ effects: [ActivationEffect] = []) -> ActivationRecoveryStep {
    ActivationRecoveryStep(cause: .leaseLost, decisions: decisions, effects: effects)
}

/// `ProjectGraphLimits.nodes` distinct node IDs, built deterministically.
private func maximumNodes() throws -> Set<NodeID> {
    Set(try (0..<ProjectGraphLimits.nodes).map { try NodeID("node.p\($0)") })
}

private func hasEmptyPlaceholders(_ commands: [EngineCommand]) -> Bool {
    commands.contains { $0 == .placeholders([]) }
}

/// Every `ActivationEffect` case; a new case fails to compile here.
private enum EffectKind: CaseIterable {
    case prepare, commit, discard

    init(_ effect: ActivationEffect) {
        switch effect {
        case .prepare: self = .prepare
        case .commit: self = .commit
        case .discard: self = .discard
        }
    }
}

extension TransactionBench {
    /// Commits the default plan, has the engine report `outcome` and resolves it
    /// under the held lease, returning the recovery step.
    fileprivate mutating func resolved(_ outcome: ActivationCommitOutcome) throws -> ActivationRecoveryStep {
        let attempt = try committedAttempt()
        _ = try transaction.acknowledged(report(outcome)).get()
        return try transaction.resolveRecovery(attempt, lease: registry.snapshot).get()
    }

    fileprivate var token: EngineLeaseToken {
        get throws { try #require(registry.snapshot).token }
    }
}

extension HostAuthorityTests {
    struct EngineCommands {
        @Test func effectsDequeueInEmissionOrder() throws {
            var host = try TransactionBench()
            try host.acquire(projectA)
            var emitted = [try host.begin()]
            _ = try host.transaction.prepared(.success(planP)).get()
            emitted.append(try host.transaction.cancel().get())
            emitted.append(try host.begin())
            _ = try host.transaction.prepared(.success(planQ)).get()
            emitted.append(try host.commit(try host.authorize()).get())
            emitted.append(try host.transaction.acknowledged(report(.succeeded, prepared: planQ)).get())
            guard case .prepare(let first, let firstAttempt) = try #require(emitted[0].first),
                  case .prepare(let second, let secondAttempt) = try #require(emitted[2].first) else {
                Issue.record("Expected prepares, got \(emitted)")
                return
            }
            #expect(firstAttempt != secondAttempt)
            let expected: [EngineCommand] = [
                .prepare(first.graph, firstAttempt), .discard(planP), .prepare(second.graph, secondAttempt),
                .commit(planQ, try #require(host.transaction.lastAttempt), try host.token), .discard(runningPlan)
            ]
            // One batch per transition, with a dequeue in between: FIFO across batches.
            let later = try discards(1)
            var perTransition = EngineCommandQueue()
            for effects in emitted { try perTransition.enqueue(effects: effects).get() }
            #expect(perTransition.count == expected.count)
            let oldest = perTransition.dequeue()
            #expect(oldest == expected[0])
            try perTransition.enqueue(effects: later).get()
            let rest = drain(&perTransition)
            #expect(rest == Array(expected.dropFirst()) + later.map(EngineCommand.init))
            // The whole sequence as one multi-effect batch keeps its emission order too.
            var oneBatch = EngineCommandQueue()
            try oneBatch.enqueue(effects: emitted.flatMap { $0 }).get()
            #expect(oneBatch.pending == expected)
            let drained = drain(&oneBatch)
            let afterLast = oneBatch.dequeue()
            #expect(drained == expected && oneBatch.isEmpty && afterLast == nil)
        }

        @Test func recoveryDecisionsPrecedeEffects() throws {
            var failed = try TransactionBench()
            let restore = try failed.resolved(.failed)
            var partial = try TransactionBench()
            let keep = try partial.resolved(.partial)
            #expect(keep.decisions.count == 3 && keep.effects.count == 1)
            let earlier = try discards(1)
            let failedToken = try failed.token
            let restoreAttempt = RestoreAttemptID()
            var queue = EngineCommandQueue()
            try queue.enqueue(effects: earlier).get()
            try queue.enqueue(restore, running: failed.transaction.running, lease: failedToken,
                              restoreAttempt: restoreAttempt).get()
            try queue.enqueue(keep, running: partial.transaction.running, lease: try partial.token).get()
            // restorePrevious → discard; keepActivePartial → placeholders (sorted) → discard of the replaced plan.
            let recovered = drain(&queue)
            #expect(recovered == earlier.map(EngineCommand.init) + [
                .restore(restoreAttempt, .initial, runningPlan, failedToken), .discard(planID),
                .keepActivePartial(planID), .placeholders([nodes[1], nodes[2]]), .discard(runningPlan)
            ])
            // A fail-closed exit is a decision only: mute, nothing discarded.
            var unknown = try TransactionBench()
            let attempt = try unknown.committedAttempt()
            let muted = try unknown.transaction.abandonCommit(attempt, reason: .outcomeUnknown).get()
            try queue.enqueue(muted, running: unknown.transaction.running, lease: nil).get()
            #expect(queue.pending == [.setOutputsMuted(true)])
            // Within a step, decisions and effects each keep their own order.
            let ordered = step([.missingPlaceholder(nodes[2]), .recover(muteOutputs: true)],
                               [.discard(planQ), .discard(planP)])
            var fresh = EngineCommandQueue()
            try fresh.enqueue(ordered, running: unknown.transaction.running, lease: nil).get()
            #expect(fresh.pending == [.placeholders([nodes[2]]), .setOutputsMuted(true), .discard(planQ),
                                      .discard(planP)])
        }

        @Test func queueRefusesWholeBatchBeyondCapacity() throws {
            #expect(EngineCommandQueue.capacity == 256 && EngineCommandQueue().capacity == 256)
            let all = try discards(260)
            var empty = EngineCommandQueue()
            let tooMany = empty.enqueue(effects: Array(all.prefix(257)))
            #expect(refusal(tooMany) == .full(requested: 257, available: 256))
            #expect(empty == EngineCommandQueue())
            #expect(!empty.canAccept(-1) && empty.canAccept(0) && empty.canAccept(256) && !empty.canAccept(257))
            // Exactly at capacity is accepted, in order; then nothing more fits.
            var full = EngineCommandQueue()
            try full.enqueue(effects: Array(all.prefix(256))).get()
            #expect(full.count == 256 && full.canAccept(0) && !full.canAccept(1))
            let before = full
            let oneMore = full.enqueue(effects: [all[256]])
            #expect(refusal(oneMore) == .full(requested: 1, available: 0))
            #expect(full == before)
            let drained = drain(&full)
            #expect(drained == all.prefix(256).map(EngineCommand.init))
            // One slot short: a three-effect batch and a three-command keep step are refused whole.
            var host = try TransactionBench()
            let keep = try host.resolved(.partial)
            let (running, token) = (host.transaction.running, try host.token)
            var nearlyFull = EngineCommandQueue()
            try nearlyFull.enqueue(effects: Array(all.prefix(254))).get()
            let snapshot = nearlyFull
            let batch = nearlyFull.enqueue(effects: Array(all.suffix(3)))
            #expect(refusal(batch) == .full(requested: 3, available: 2))
            #expect(nearlyFull == snapshot)
            let refusedStep = nearlyFull.enqueue(keep, running: running, lease: token)
            #expect(refusal(refusedStep) == .full(requested: 3, available: 2))
            #expect(nearlyFull == snapshot)
            // A dequeue frees a slot, and the step then fills the queue exactly, after the older commands.
            let oldest = nearlyFull.dequeue()
            #expect(oldest == EngineCommand(all[0]))
            try nearlyFull.enqueue(keep, running: running, lease: token).get()
            #expect(nearlyFull.count == 256 && !nearlyFull.canAccept(1))
            #expect(Array(nearlyFull.pending.suffix(4)) == [
                EngineCommand(all[253]), .keepActivePartial(planID), .placeholders([nodes[1], nodes[2]]),
                .discard(runningPlan)
            ])
        }

        @Test func restoreAndKeepNeedTheirLeaseAndRunningPlan() throws {
            var host = try TransactionBench()
            let beforeRestore = host.transaction.running
            let restore = try host.resolved(.failed)
            let (running, token) = (host.transaction.running, try host.token)
            // A rollback leaves the running graph as it was, so a real restore step cannot name a discarded plan.
            #expect(beforeRestore == running)
            var queue = EngineCommandQueue()
            try queue.enqueue(effects: try discards(1)).get()
            let before = queue
            let missingAttempt = queue.enqueue(restore, running: running, lease: token)
            #expect(refusal(missingAttempt) == .restoreAttemptRequired)
            #expect(queue == before)
            let unleased = queue.enqueue(restore, running: running, lease: nil)
            #expect(refusal(unleased) == .leaseRequired)
            let moved = RunningGraph(revision: try running.revision.next(), prepared: running.prepared)
            let otherRevision = queue.enqueue(restore, running: moved, lease: token)
            #expect(refusal(otherRevision) == .runningMismatch)
            let keep = step([.keepActivePartial])
            let bare = RunningGraph(revision: .initial, prepared: nil)
            let planless = queue.enqueue(keep, running: bare, lease: token)
            #expect(refusal(planless) == .runningMismatch)
            // The pre-step running graph names the plan the real keep step discards: refused.
            var partial = try TransactionBench()
            let preStep = partial.transaction.running
            let realKeep = try partial.resolved(.partial)
            #expect(realKeep.effects == [.discard(try #require(preStep.prepared))])
            let stale = queue.enqueue(realKeep, running: preStep, lease: try partial.token)
            #expect(refusal(stale) == .runningMismatch)
            // The same for a (hand-built) restore that would discard the plan it restores.
            let selfDiscard = step([.restorePrevious(.initial)], [.discard(runningPlan)])
            let restoreStale = queue.enqueue(selfDiscard, running: preStep, lease: token)
            #expect(refusal(restoreStale) == .runningMismatch)
            #expect(queue == before)
            // A running graph without a plan is restored as such.
            let restoreAttempt = RestoreAttemptID()
            try queue.enqueue(restore, running: bare, lease: token, restoreAttempt: restoreAttempt).get()
            #expect(Array(queue.pending.dropFirst()) == [
                .restore(restoreAttempt, .initial, nil, token), .discard(planID)
            ])
        }

        @Test func maximumPartialKeepNeedsThreeSlots() throws {
            let unapplied = try maximumNodes()
            #expect(unapplied.count == ProjectGraphLimits.nodes && EngineCommandQueue.maxRecoveryStepSlots == 3)
            let previous = RunningGraph(revision: .initial, prepared: runningPlan)
            let keep = ActivationRecovery.keepPartial(unapplied: unapplied, replacing: previous)
            let running = RunningGraph(revision: try ContractRevision.initial.next(), prepared: planID)
            var host = try TransactionBench()
            try host.acquire(projectA)
            let (token, fillers) = (try host.token, try discards(254))
            // Full minus two: refused whole.
            var minusTwo = EngineCommandQueue()
            try minusTwo.enqueue(effects: fillers).get()
            let before = minusTwo
            let refused = minusTwo.enqueue(keep, running: running, lease: token)
            #expect(refusal(refused) == .full(requested: 3, available: 2))
            #expect(minusTwo == before)
            // Full minus three: exactly keep, one placeholders command (sorted by the policy), discard.
            var minusThree = EngineCommandQueue()
            try minusThree.enqueue(effects: Array(fillers.prefix(253))).get()
            #expect(minusThree.canAccept(EngineCommandQueue.maxRecoveryStepSlots))
            try minusThree.enqueue(keep, running: running, lease: token).get()
            #expect(minusThree.count == EngineCommandQueue.capacity)
            // The largest step the policy produces uses exactly the documented per-step budget.
            var empty = EngineCommandQueue()
            try empty.enqueue(keep, running: running, lease: token).get()
            #expect(empty.count == EngineCommandQueue.maxRecoveryStepSlots)
            #expect(Array(minusThree.pending.suffix(3)) == [
                .keepActivePartial(planID), .placeholders(unapplied.sorted()), .discard(runningPlan)
            ])
        }

        @Test func refusalPartWayThroughStepLeavesQueueUnchanged() throws {
            var host = try TransactionBench()
            try host.acquire(projectA)
            let token = try host.token
            let running = RunningGraph(revision: .initial, prepared: runningPlan)
            let wrong = try ContractRevision.initial.next()
            var queue = EngineCommandQueue()
            try queue.enqueue(effects: try discards(1)).get()
            let before = queue
            // Earlier decisions map fine; the last one is refused, and nothing of the step is queued.
            let late = step([.missingPlaceholder(nodes[0]), .recover(muteOutputs: true), .restorePrevious(wrong)],
                            [.discard(planP)])
            let mismatch = queue.enqueue(late, running: running, lease: token)
            #expect(refusal(mismatch) == .runningMismatch)
            let unleased = queue.enqueue(step([.recover(muteOutputs: true), .restorePrevious(.initial)]),
                                         running: running, lease: nil)
            #expect(refusal(unleased) == .leaseRequired)
            #expect(queue == before)
            // Check order: revision, then lease, then capacity.
            let bothWrong = queue.enqueue(step([.restorePrevious(wrong)]), running: running, lease: nil)
            #expect(refusal(bothWrong) == .runningMismatch)
            var full = EngineCommandQueue()
            try full.enqueue(effects: try discards(EngineCommandQueue.capacity)).get()
            let unleasedFull = full.enqueue(step([.restorePrevious(.initial)]), running: running, lease: nil)
            #expect(refusal(unleasedFull) == .leaseRequired)
            #expect(queue == before)
        }

        @Test func placeholderRunsFoldWithoutCrossingDecisions() throws {
            let running = RunningGraph(revision: .initial, prepared: runningPlan)
            // The policy's own crash decision: one node, one command.
            let crash = step(ActivationRecovery.decisions(for: .processorCrashed(nodes[1]), running: running))
            var queue = EngineCommandQueue()
            try queue.enqueue(crash, running: running, lease: nil).get()
            #expect(queue.pending == [.placeholders([nodes[1]])])
            // Two runs split by a decision stay two commands; each keeps decision order and duplicates.
            let split = step([.missingPlaceholder(nodes[2]), .missingPlaceholder(nodes[0]), .recover(muteOutputs: true),
                              .missingPlaceholder(nodes[1]), .missingPlaceholder(nodes[1])], [.discard(planP)])
            var twoRuns = EngineCommandQueue()
            try twoRuns.enqueue(split, running: running, lease: nil).get()
            #expect(twoRuns.pending == [
                .placeholders([nodes[2], nodes[0]]), .setOutputsMuted(true), .placeholders([nodes[1], nodes[1]]),
                .discard(planP)
            ])
            // Runs never merge across steps, and no step emits an empty run.
            try queue.enqueue(step([.missingPlaceholder(nodes[2])]), running: running, lease: nil).get()
            try queue.enqueue(step([.recover(muteOutputs: true)], [.discard(planQ)]), running: running,
                              lease: nil).get()
            try queue.enqueue(step([]), running: running, lease: nil).get()
            #expect(queue.pending == [
                .placeholders([nodes[1]]), .placeholders([nodes[2]]), .setOutputsMuted(true), .discard(planQ)
            ])
            #expect(!hasEmptyPlaceholders(queue.pending) && !hasEmptyPlaceholders(twoRuns.pending))
        }

        @Test func prepareCarriesValidatedGraphBytes() throws {
            let graph = try extendedGraph()
            #expect(!graph.unknownFields.isEmpty && !graph.nodes[1].unknownFields.isEmpty && graph.extensions != nil)
            var host = try TransactionBench()
            try host.acquire(projectA)
            let effects = try host.begin(candidate: graph)
            let validated = try #require(host.transaction.validated)
            var queue = EngineCommandQueue()
            try queue.enqueue(effects: effects).get()
            let first = queue.dequeue()
            guard case .prepare(let sent, let attempt) = try #require(first) else {
                Issue.record("Expected a prepare, got \(effects)")
                return
            }
            #expect(attempt == host.transaction.lastPrepareAttempt)
            #expect(try sent.encoded() == validated.graph.encoded())
            #expect(try sent.encoded() == graph.encoded())
            #expect(sent.unknownFields == graph.unknownFields && sent.extensions == graph.extensions)
            #expect(sent.node(nodes[1])?.unknownFields == ["x-node": .string("kept")])
        }

        @Test func everyDecisionAndEffectMapsToExactlyOneCommand() throws {
            var host = try TransactionBench()
            let attempt = try host.committedAttempt()
            let token = try host.token
            let running = RunningGraph(revision: .initial, prepared: runningPlan)
            let restoreAttempt = RestoreAttemptID()
            let decisions: [(RecoveryDecision, EngineCommand)] = [
                (.restorePrevious(.initial), .restore(restoreAttempt, .initial, runningPlan, token)),
                (.keepActivePartial, .keepActivePartial(runningPlan)),
                (.missingPlaceholder(nodes[2]), .placeholders([nodes[2]])),
                (.recover(muteOutputs: true), .setOutputsMuted(true)),
                (.recover(muteOutputs: false), .setOutputsMuted(false))
            ]
            #expect(Set(decisions.map { DecisionKind($0.0) }) == Set(DecisionKind.allCases))
            // Each decision kind maps to one command kind; only placeholder runs fold.
            let kinds: [DecisionKind: CommandKind] = [
                .restorePrevious: .restore, .keepActivePartial: .keepActivePartial,
                .missingPlaceholder: .placeholders, .recover: .setOutputsMuted
            ]
            for (decision, command) in decisions {
                var queue = EngineCommandQueue()
                let admissionID: RestoreAttemptID?
                if case .restorePrevious = decision {
                    admissionID = restoreAttempt
                } else {
                    admissionID = nil
                }
                try queue.enqueue(step([decision]), running: running, lease: token,
                                  restoreAttempt: admissionID).get()
                #expect(queue.pending == [command])
                #expect(kinds[DecisionKind(decision)] == CommandKind(command))
            }
            var preparing = try TransactionBench()
            try preparing.acquire(projectA)
            let began = try preparing.begin()
            let prepare = try #require(began.first)
            let validated = try #require(preparing.transaction.validated)
            let prepareAttempt = try #require(preparing.transaction.lastPrepareAttempt)
            let effects: [(ActivationEffect, EngineCommand)] = [
                (prepare, .prepare(validated.graph, prepareAttempt)),
                (.commit(planID, attempt, token), .commit(planID, attempt, token)),
                (.discard(planP), .discard(planP))
            ]
            #expect(Set(effects.map { EffectKind($0.0) }) == Set(EffectKind.allCases))
            for (effect, command) in effects {
                var queue = EngineCommandQueue()
                try queue.enqueue(effects: [effect]).get()
                #expect(queue.pending == [command])
            }
        }
    }
}
