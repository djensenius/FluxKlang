//
//  EngineCommandQueue.swift
//  FluxKlang
//
//  The engine-facing form of transaction effects and recovery decisions, and
//  the bounded FIFO the owner (the H5 actor) performs them through. Pure: it
//  orders and bounds commands, and performs nothing itself.
//

/// One instruction for the activation engine. The eventual executor MUST check
/// the addressed instance at delivery (H5d/M6/G2); these values perform no engine
/// operation and do not certify quiescence, freshness or safe destruction.
enum EngineCommand: Hashable, Sendable {
    /// Prepare exactly the validated graph, unknown fields and extensions included.
    case prepare(GraphDocument, EngineInstanceID, PrepareAttemptID)
    /// Commit the prepared plan; the owner delivers it only under this lease token.
    case commit(PlanBinding, CommitAttemptID, EngineLeaseToken)
    /// Release a prepared plan the engine holds.
    case discard(PlanBinding)
    /// Return to this exact engine-instance target at this revision under the lease.
    case restore(RestoreAttemptID, ContractRevision, RestoreTarget, EngineLeaseToken)
    /// Keep the partly applied plan active as the running graph.
    case keepActivePartial(CommittedResident)
    /// Keep these nodes silent placeholders (not bypassed) and raise diagnostics.
    /// One command per run of consecutive `missingPlaceholder` decisions, in
    /// decision order; never empty.
    case placeholders([NodeID])
    case setOutputsMuted(Bool)
}

/// Why a batch was refused. Every refusal leaves the queue unchanged.
enum EngineCommandQueueRefusal: Error, Hashable, Sendable {
    /// The batch needs `requested` slots and only `available` are free; nothing was queued.
    case full(requested: Int, available: Int)
    /// A `restorePrevious` decision without the lease token it must be performed under.
    case leaseRequired
    /// The decision does not match `running`: a restore of another revision, a
    /// kept partial plan with no running plan to name, or a kept/restored plan that
    /// the same step discards (`running` was the pre-step graph).
    case runningMismatch
    /// A restore decision must carry the book-issued identity of its admitted attempt.
    case restoreAttemptRequired
}

private struct QueueRestoreIdentity {
    let target: RestoreTarget?
    let attempt: RestoreAttemptID?
}

/// A bounded FIFO of engine commands. A batch (one transition's effects, or one
/// recovery step) is queued whole or not at all, in emission order; a recovery
/// step's decisions come before its effects (`ActivationRecoveryStep`).
///
/// The transaction transition that produced a batch has already happened when it
/// is enqueued; a refusal (`.full` included) never rolls the transaction back.
/// Callers call `canAccept(n)` before the transition, with these budgets:
/// prepare 1, commit 1, cancel/ack ≤1, restore step 2, keep step ≤3
/// (`maxRecoveryStepSlots`), mute 1. Otherwise they must treat `.full` as
/// fail-closed: mute outputs and recover.
struct EngineCommandQueue: Hashable, Sendable {
    /// The most commands queued at once.
    static let capacity = 256
    /// The most slots a step produced by `ActivationRecovery` needs: keep,
    /// placeholders, discard.
    static let maxRecoveryStepSlots = 3

    /// Queued commands, oldest first.
    private(set) var pending: [EngineCommand] = []

    /// An empty queue. Declared explicitly so the synthesized `init(pending:)`
    /// does not exist: commands enter only through the checked `enqueue` methods.
    init() {}

    var capacity: Int { Self.capacity }
    var count: Int { pending.count }
    var isEmpty: Bool { pending.isEmpty }

    /// Whether `count` more commands fit. A negative count never fits.
    /// Call this before the transition that produces the batch (budgets on the
    /// type); the transition is not undone if the later enqueue is refused.
    func canAccept(_ count: Int) -> Bool {
        count >= 0 && count <= capacity - pending.count
    }

    /// Queues already-qualified commands, whole or not at all. The host selects
    /// their exact role bindings and stages this queue before publishing a transition.
    mutating func enqueue(_ commands: [EngineCommand]) -> Result<Void, EngineCommandQueueRefusal> {
        append(commands)
    }

    /// Queues `step`: its decisions in order, then its effects in order
    /// (restorePrevious → discard; keepActivePartial → placeholders → discard).
    /// Each maximal run of consecutive `missingPlaceholder` decisions becomes one
    /// `.placeholders` command in decision order, so a step produced by
    /// `ActivationRecovery` needs at most `maxRecoveryStepSlots` (3) slots whatever
    /// its node count; runs never merge across another decision or step.
    /// `running` is the transaction's running graph after the step; `lease` is the
    /// token a restore is performed under.
    ///
    /// Check order: discard-only effects (at most one), retiring presence/name,
    /// distinct resident/retiring bindings, then refusal of an unused resident.
    /// Next, per decision in order: restore revision, resident presence/name
    /// consistency with `running`, and finally the restore lease (`leaseRequired`).
    /// All role/revision/plan failures are `runningMismatch`; whole-step capacity
    /// is checked last. Role authority belongs to the host: equal raw names cannot
    /// reveal wrongly supplied roles. Any refusal leaves the queue unchanged.
    /// The step's transition already happened and is not undone: call
    /// `canAccept(maxRecoveryStepSlots)` before it, or treat `.full` as fail-closed.
    mutating func enqueue(
        _ step: ActivationRecoveryStep, running: RunningGraph, resident: CommittedResident?,
        retiring: PlanBinding?, lease: EngineLeaseToken?,
        restoreAttempt: RestoreAttemptID? = nil, restoreTarget: RestoreTarget? = nil
    ) -> Result<Void, EngineCommandQueueRefusal> {
        // Roles come from the private host, NOT a raw-name lookup. Equal names
        // cannot distinguish incorrectly supplied roles; these are consistency checks.
        let discards = step.effects.compactMap { effect -> PreparedActivationID? in
            if case .discard(let prepared) = effect { return prepared }
            return nil
        }
        guard discards.count == step.effects.count, discards.count <= 1,
              discards.first == retiring?.prepared else { return .failure(.runningMismatch) }
        let target = restoreTarget ?? resident.map(RestoreTarget.resident)
        guard Self.validRestoreTarget(resident: resident, target: target, explicitTarget: restoreTarget,
                                      retiring: retiring) else {
            return .failure(.runningMismatch)
        }
        let usesTarget = step.decisions.contains(where: Self.usesTarget)
        guard usesTarget || target == nil else { return .failure(.runningMismatch) }
        var commands: [EngineCommand] = []
        var run: [NodeID] = []
        for decision in step.decisions {
            if case .missingPlaceholder(let node) = decision {
                run.append(node)
                continue
            }
            Self.flush(&run, into: &commands)
            switch Self.command(for: decision, running: running, resident: resident, lease: lease,
                                identity: QueueRestoreIdentity(target: target, attempt: restoreAttempt)) {
            case .success(let command): commands.append(command)
            case .failure(let refusal): return .failure(refusal)
            }
        }
        Self.flush(&run, into: &commands)
        if let retiring { commands.append(.discard(retiring)) }
        return append(commands)
    }

    private static func usesTarget(_ decision: RecoveryDecision) -> Bool {
        switch decision {
        case .restorePrevious, .keepActivePartial: true
        case .missingPlaceholder, .recover: false
        }
    }

    private static func validRestoreTarget(
        resident: CommittedResident?, target: RestoreTarget?, explicitTarget: RestoreTarget?,
        retiring: PlanBinding?
    ) -> Bool {
        if let resident, resident.binding == retiring { return false }
        if let retiring, let target {
            if case .resident(let targetResident) = target, targetResident.binding == retiring { return false }
        }
        if let explicitTarget, let resident, explicitTarget != .resident(resident) { return false }
        return true
    }

    /// Ends a run of consecutive `missingPlaceholder` decisions as one command, if any.
    private static func flush(_ run: inout [NodeID], into commands: inout [EngineCommand]) {
        guard !run.isEmpty else { return }
        commands.append(.placeholders(run))
        run.removeAll()
    }

    /// Removes and returns the oldest command.
    mutating func dequeue() -> EngineCommand? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Extracts exact selected discards while preserving every other command's FIFO order.
    mutating func extractDiscards(_ bindings: Set<PlanBinding>) -> [PlanBinding] {
        var extracted: [PlanBinding] = []
        pending.removeAll { command in
            guard case .discard(let binding) = command, bindings.contains(binding) else { return false }
            extracted.append(binding)
            return true
        }
        return extracted
    }

    private mutating func append(_ commands: [EngineCommand]) -> Result<Void, EngineCommandQueueRefusal> {
        guard canAccept(commands.count) else {
            return .failure(.full(requested: commands.count, available: capacity - pending.count))
        }
        pending.append(contentsOf: commands)
        return .success(())
    }

    /// After enqueue's batch-role checks: revision and target/name consistency,
    /// then the current lease and unique attempt. Keep requires a resident.
    private static func command(
        for decision: RecoveryDecision, running: RunningGraph, resident: CommittedResident?,
        lease: EngineLeaseToken?, identity: QueueRestoreIdentity
    ) -> Result<EngineCommand, EngineCommandQueueRefusal> {
        switch decision {
        case .restorePrevious(let revision):
            guard revision == running.revision else { return .failure(.runningMismatch) }
            guard let target = identity.target, target.prepared == running.prepared else {
                return .failure(.runningMismatch)
            }
            guard let lease else { return .failure(.leaseRequired) }
            guard let attempt = identity.attempt else { return .failure(.restoreAttemptRequired) }
            return .success(.restore(attempt, revision, target, lease))
        case .keepActivePartial:
            guard let resident, resident.binding.prepared == running.prepared else {
                return .failure(.runningMismatch)
            }
            return .success(.keepActivePartial(resident))
        case .missingPlaceholder(let node):
            // The recovery enqueue folds runs before reaching here; a lone node is a run of one.
            return .success(.placeholders([node]))
        case .recover(let muteOutputs):
            return .success(.setOutputsMuted(muteOutputs))
        }
    }
}
