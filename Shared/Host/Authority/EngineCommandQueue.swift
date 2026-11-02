//
//  EngineCommandQueue.swift
//  FluxKlang
//
//  The engine-facing form of transaction effects and recovery decisions, and
//  the bounded FIFO the owner (the H5 actor) performs them through. Pure: it
//  orders and bounds commands, and performs nothing itself.
//

/// One instruction for the activation engine.
enum EngineCommand: Hashable, Sendable {
    /// Prepare exactly the validated graph, unknown fields and extensions included.
    case prepare(GraphDocument, PrepareAttemptID)
    /// Commit the prepared plan; the owner delivers it only under this lease token.
    case commit(PreparedActivationID, CommitAttemptID, EngineLeaseToken)
    /// Release a prepared plan the engine holds.
    case discard(PreparedActivationID)
    /// Return to the running graph's prepared plan at this revision, under this lease token.
    case restore(ContractRevision, PreparedActivationID?, EngineLeaseToken)
    /// Keep the partly applied plan active as the running graph.
    case keepActivePartial(PreparedActivationID)
    /// Keep these nodes silent placeholders (not bypassed) and raise diagnostics.
    /// One command per run of consecutive `missingPlaceholder` decisions, in
    /// decision order; never empty.
    case placeholders([NodeID])
    case setOutputsMuted(Bool)

    /// `.prepare` carries `validated.graph` itself, never a graph rebuilt from the request.
    init(_ effect: ActivationEffect) {
        switch effect {
        case .prepare(let validated, let attempt): self = .prepare(validated.graph, attempt)
        case .commit(let prepared, let attempt, let token): self = .commit(prepared, attempt, token)
        case .discard(let prepared): self = .discard(prepared)
        }
    }
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

    /// Queues one transition's effects in the order they were emitted, whole or
    /// not at all. The transition already happened: `.full` does not undo it, so
    /// call `canAccept(effects.count)` first, or treat `.full` as fail-closed.
    mutating func enqueue(effects: [ActivationEffect]) -> Result<Void, EngineCommandQueueRefusal> {
        append(effects.map(EngineCommand.init))
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
    /// Check order, per decision in order, before anything is queued: revision
    /// (and the named plan against `running` and the step's discards), then lease;
    /// then capacity for the whole step. Any refusal leaves the queue unchanged.
    /// The step's transition already happened and is not undone: call
    /// `canAccept(maxRecoveryStepSlots)` before it, or treat `.full` as fail-closed.
    mutating func enqueue(
        _ step: ActivationRecoveryStep, running: RunningGraph, lease: EngineLeaseToken?
    ) -> Result<Void, EngineCommandQueueRefusal> {
        var commands: [EngineCommand] = []
        var run: [NodeID] = []
        for decision in step.decisions {
            if case .missingPlaceholder(let node) = decision {
                run.append(node)
                continue
            }
            Self.flush(&run, into: &commands)
            switch Self.command(for: decision, running: running, lease: lease, discarding: step.effects) {
            case .success(let command): commands.append(command)
            case .failure(let refusal): return .failure(refusal)
            }
        }
        Self.flush(&run, into: &commands)
        return append(commands + step.effects.map(EngineCommand.init))
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

    private mutating func append(_ commands: [EngineCommand]) -> Result<Void, EngineCommandQueueRefusal> {
        guard canAccept(commands.count) else {
            return .failure(.full(requested: commands.count, available: capacity - pending.count))
        }
        pending.append(contentsOf: commands)
        return .success(())
    }

    /// Checks run in order: revision and named plan (not discarded by `effects`), then lease.
    private static func command(
        for decision: RecoveryDecision, running: RunningGraph, lease: EngineLeaseToken?,
        discarding effects: [ActivationEffect]
    ) -> Result<EngineCommand, EngineCommandQueueRefusal> {
        switch decision {
        case .restorePrevious(let revision):
            guard revision == running.revision else { return .failure(.runningMismatch) }
            if let prepared = running.prepared, effects.contains(.discard(prepared)) {
                return .failure(.runningMismatch)
            }
            guard let lease else { return .failure(.leaseRequired) }
            return .success(.restore(revision, running.prepared, lease))
        case .keepActivePartial:
            guard let prepared = running.prepared, !effects.contains(.discard(prepared)) else {
                return .failure(.runningMismatch)
            }
            return .success(.keepActivePartial(prepared))
        case .missingPlaceholder(let node):
            // `enqueue(_:running:lease:)` folds runs before reaching here; a lone node is a run of one.
            return .success(.placeholders([node]))
        case .recover(let muteOutputs):
            return .success(.setOutputsMuted(muteOutputs))
        }
    }
}
