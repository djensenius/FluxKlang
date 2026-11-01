//
//  HostAuthority.swift
//  FluxKlang
//
//  The one owner of a host's engine lease, its context counter, the live host
//  state and every project's activation transaction (#62 H5). Methods never
//  await: the engine pulls commands through `nextEngineCommand()` and answers
//  through actor methods. Every refusal leaves the whole actor state unchanged
//  (`snapshot()`).
//

/// The live host state every activation context is built from. Only the actor
/// combines it with a project's running revision; callers never supply a context.
struct HostLiveState: Hashable, Sendable {
    let hostEpoch: HostEpoch
    /// `nil` when no permission is currently granted.
    let permission: PermissionFingerprint?
    let capabilities: DeviceCapabilityDocument
}

/// Why the actor refused. Every refusal leaves the actor state unchanged.
enum HostAuthorityRefusal: Error, Equatable, Sendable {
    /// The transaction's own refusal, unchanged.
    case activation(ActivationRefusal)
    case unknownProject(ProjectID)
    case projectAlreadyOpen(ProjectID)
    case projectLimit
    /// `open` resumes only a settled lifecycle consistent with the running graph.
    case lifecycleNotResumable(EngineLifecycle)
    case lease(EngineLeaseError)
    case ledger(GenerationLedgerError)
    /// The engine command queue cannot take the transition's commands; nothing moved.
    case queueFull
}

/// What became of an engine's answer to a `.prepare`.
enum PrepareAnswerOutcome: Hashable, Sendable {
    /// The issuing project's transaction accepted it.
    case routed
    /// A success for an abandoned attempt, refused by the transaction with `refusal`:
    /// the engine's plan was queued for discard, exactly once.
    case discarded(PreparedActivationID, refusal: ActivationRefusal)
    /// An abandoned attempt's failure, or a success naming a live plan, or a plan
    /// whose discard is already queued: nothing to discard.
    case dropped
}

/// A prepare attempt `abandonPrepare` gave up on; its late success is discarded.
struct AbandonedPrepare: Hashable, Sendable {
    let attempt: PrepareAttemptID
    let project: ProjectID
}

/// One open project: its only transaction copy and its engine lifecycle.
struct HostProjectState: Hashable, Sendable {
    var transaction: ActivationTransaction
    /// What this project's windows on the lease observe (`EngineLifecycle.observed`).
    var lifecycle: EngineLifecycle
    /// The plan the engine prepared for the current review; meaningful only
    /// while the transaction is awaiting review or committing.
    var reviewed: PreparedActivationID?
}

/// A transaction kept inert for the snapshot: equality and hashing still cover
/// the whole transaction, so any change is detected, but nothing reads it back.
/// Only the actor's own copy may transition (the single-owner rule): a copy
/// handed out could issue commits with the same authorization and attempt IDs
/// outside the actor's queue.
struct TransactionRecord: Hashable, Sendable {
    private let transaction: ActivationTransaction

    fileprivate init(_ transaction: ActivationTransaction) {
        self.transaction = transaction
    }
}

/// One open project as the snapshot shows it: read-only diagnostics and an inert
/// record of its transaction, never the transaction itself.
struct HostProjectSnapshot: Hashable, Sendable {
    let phase: ActivationPhase
    let running: RunningGraph
    let lastPrepareAttempt: PrepareAttemptID?
    let lifecycle: EngineLifecycle
    let reviewed: PreparedActivationID?
    let record: TransactionRecord

    fileprivate init(_ state: HostProjectState) {
        phase = state.transaction.phase
        running = state.transaction.running
        lastPrepareAttempt = state.transaction.lastPrepareAttempt
        lifecycle = state.lifecycle
        reviewed = state.reviewed
        record = TransactionRecord(state.transaction)
    }
}

/// The whole actor state, for refusal checks and diagnostics. It holds no
/// transaction (`HostProjectSnapshot`).
struct HostAuthoritySnapshot: Hashable, Sendable {
    let lease: EngineLeaseSnapshot?
    let lastIssuedLease: Generation?
    let ledger: [GenerationKey: Generation]
    let live: HostLiveState
    let projects: [ProjectID: HostProjectSnapshot]
    /// The one unanswered, not abandoned prepare of each preparing project.
    let outstanding: [ProjectID: PrepareAttemptID]
    /// Abandoned and unanswered, oldest first; at most `abandonedPrepareLimit`.
    let abandoned: [AbandonedPrepare]
    let queue: EngineCommandQueue
}

actor HostAuthority {
    static let projectLimit = 16
    /// Abandoned attempts remembered for discarding their late success. When the
    /// FIFO is full, abandoning evicts the oldest: a success arriving later for an
    /// evicted attempt is `stalePrepareResponse` and is NOT discarded, so the engine
    /// may keep that plan (a bounded engine-side leak; H5d may add an engine reset
    /// that clears it). Abandons alone never make `begin` refuse.
    static let abandonedPrepareLimit = 64

    private var registry = EngineLeaseRegistry()
    private var ledger: GenerationLedger
    private var live: HostLiveState
    private var projects: [ProjectID: HostProjectState] = [:]
    /// Keyed by project: at most one outstanding attempt per open project.
    private var outstanding: [ProjectID: PrepareAttemptID] = [:]
    private var abandoned: [AbandonedPrepare] = []
    private var queue = EngineCommandQueue()

    /// Declares `EngineLeaseRegistry.contextKey` in `ledger` unless it already is.
    init(host ledger: GenerationLedger, live: HostLiveState) throws(GenerationLedgerError) {
        var declared = ledger
        if declared.generation(EngineLeaseRegistry.contextKey) == nil {
            try declared.declare(EngineLeaseRegistry.contextKey)
        }
        self.ledger = declared
        self.live = live
    }

    func snapshot() -> HostAuthoritySnapshot {
        HostAuthoritySnapshot(lease: registry.snapshot, lastIssuedLease: registry.lastIssued, ledger: ledger.current,
                              live: live, projects: projects.mapValues(HostProjectSnapshot.init),
                              outstanding: outstanding, abandoned: abandoned, queue: queue)
    }

    /// Opens `project` over its running graph. `lifecycle` defaults to `.running`
    /// over a running plan, else `.stopped`; pass one only to resume a settled state.
    /// Refused as `lifecycleNotResumable`: `.preparing` (no prepare is outstanding
    /// yet), `.heldByOther` (derived from the lease by `lifecycle(of:window:)`), and
    /// a rendering `.running`/`.degraded` with no running plan. `.stopped` over a
    /// running plan is accepted: a stopped engine stores the running set without
    /// rendering (`EngineLifecycle.acceptsRunningSetChanges`), and `endingPreparation`
    /// returns to `.stopped` whatever the running graph holds. `.recovering` is
    /// accepted either way: unresolved recovery outlives the running set.
    /// Last, a running plan that is already in use is refused as
    /// `.activation(.preparedIDInUse)`, like `route`: any project's running,
    /// reviewed or held plan (`livePlans()`), or a plan whose `.discard` is queued.
    /// Adopting it would let another project's cancel, or the queued discard,
    /// destroy this project's running graph.
    func open(project: ProjectID, running: RunningGraph,
              lifecycle: EngineLifecycle? = nil) -> Result<Void, HostAuthorityRefusal> {
        guard projects[project] == nil else { return .failure(.projectAlreadyOpen(project)) }
        guard projects.count < Self.projectLimit else { return .failure(.projectLimit) }
        if let lifecycle {
            switch lifecycle {
            case .stopped, .recovering: break
            case .running, .degraded:
                guard running.prepared != nil else { return .failure(.lifecycleNotResumable(lifecycle)) }
            case .preparing, .heldByOther: return .failure(.lifecycleNotResumable(lifecycle))
            }
        }
        if let plan = running.prepared {
            guard !livePlans().contains(plan) else { return .failure(.activation(.preparedIDInUse)) }
            guard !queue.pending.contains(.discard(plan)) else { return .failure(.activation(.preparedIDInUse)) }
        }
        let initial = lifecycle ?? (running.prepared == nil ? .stopped : .running)
        projects[project] = HostProjectState(transaction: ActivationTransaction(project: project, running: running),
                                             lifecycle: initial)
        return .success(())
    }

    /// Staged on registry and ledger copies; both change or neither does. The one
    /// place a lease is granted, so H5d can refuse it during unresolved recovery.
    func acquire(project: ProjectID, window: WindowID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        guard projects[project] != nil else { return .failure(.unknownProject(project)) }
        var stagedRegistry = registry
        var stagedLedger = ledger
        let grant: EngineLeaseGrant
        do { grant = try stagedRegistry.acquire(project: project, window: window) } catch {
            return .failure(.lease(error))
        }
        do { try grant.context.apply(to: &stagedLedger) } catch { return .failure(.ledger(error)) }
        registry = stagedRegistry
        ledger = stagedLedger
        return .success(grant.snapshot)
    }

    /// Adds a window of the holding project, under the current token.
    func attach(_ window: WindowID, project: ProjectID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        guard let token = registry.snapshot?.token else { return .failure(.lease(.notHeld)) }
        var staged = registry
        let held: EngineLeaseSnapshot
        do { held = try staged.attach(window, project: project, expected: token) } catch {
            return .failure(.lease(error))
        }
        registry = staged
        return .success(held)
    }

    func detach(_ window: WindowID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        guard let token = registry.snapshot?.token else { return .failure(.lease(.notHeld)) }
        var staged = registry
        let held: EngineLeaseSnapshot
        do { held = try staged.detach(window, expected: token) } catch { return .failure(.lease(error)) }
        registry = staged
        return .success(held)
    }

    func updateLive(_ state: HostLiveState) {
        live = state
    }

    /// Validates and begins `request` against the live context the actor builds
    /// itself. Checks, in order: project, queue room for the `.prepare` (before the
    /// transition; `.queueFull` moves nothing), the running revision can advance
    /// (`.activation(.overflow)`, so the lifecycle never shows a revision that cannot
    /// be prepared), then the transaction's own checks (`.busy` while preparing).
    func begin(_ request: ActivationRequest, candidate: GraphDocument,
               project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        guard var state = projects[project] else { return .failure(.unknownProject(project)) }
        guard queue.canAccept(1) else { return .failure(.queueFull) }
        guard let target = try? state.transaction.running.revision.next() else {
            return .failure(.activation(.overflow))
        }
        guard let context = liveContext(over: state.transaction.running) else {
            return .failure(.ledger(.undeclaredCounter(EngineLeaseRegistry.contextKey)))
        }
        let effects: [ActivationEffect]
        switch state.transaction.begin(request, candidate: candidate, in: context) {
        case .failure(let refusal): return .failure(.activation(refusal))
        case .success(let emitted): effects = emitted
        }
        // Unreachable unless the transaction breaks its contract (a successful begin issues an attempt).
        guard let attempt = state.transaction.lastPrepareAttempt else { return .failure(.activation(.busy)) }
        var stagedQueue = queue
        guard case .success = stagedQueue.enqueue(effects: effects) else { return .failure(.queueFull) }
        state.lifecycle = state.lifecycle.startingPreparation(of: target)
        queue = stagedQueue
        outstanding[project] = attempt
        projects[project] = state
        return .success(())
    }

    /// Routes the engine's answer to the project that issued `attempt`.
    /// - An outstanding attempt is routed to its project's transaction. A success
    ///   naming any live plan (any project's running, reviewed or held plan) or a
    ///   plan whose `.discard` is still queued is refused as `preparedIDInUse`
    ///   first, with nothing changed: adopting it would let that discard destroy it.
    /// - An abandoned attempt's success is discarded exactly once, unless it names
    ///   a live plan or a plan whose `.discard` is already queued; its failure, a
    ///   live plan or an already queued discard is `.dropped` (never `.queueFull`).
    /// - An unknown, foreign, evicted or already answered attempt is
    ///   `stalePrepareResponse` and never discards.
    ///
    /// Re-delivery: on `.queueFull` nothing changed, the attempt is still
    /// remembered, and the engine must deliver the same answer again after the
    /// queue drains; otherwise that plan is never discarded.
    func prepareAnswered(_ result: Result<PreparedActivationID, PrepareFailure>,
                         attempt: PrepareAttemptID) -> Result<PrepareAnswerOutcome, HostAuthorityRefusal> {
        if let project = outstanding.first(where: { $0.value == attempt })?.key {
            return route(result, attempt: attempt, project: project)
        }
        if let index = abandoned.firstIndex(where: { $0.attempt == attempt }) {
            return discardLate(result, abandonedAt: index)
        }
        return .failure(.activation(.stalePrepareResponse))
    }

    /// Gives up on `project`'s outstanding prepare. Its late success is discarded,
    /// unless `abandonedPrepareLimit` later abandons evict it first.
    func abandonPrepare(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        guard var state = projects[project] else { return .failure(.unknownProject(project)) }
        guard let attempt = outstanding[project], state.transaction.lastPrepareAttempt == attempt else {
            return .failure(.activation(.unexpectedPhase(state.transaction.phase)))
        }
        if case .failure(let refusal) = state.transaction.abandonPrepare(attempt) {
            return .failure(.activation(refusal))
        }
        state.lifecycle = state.lifecycle.endingPreparation
        projects[project] = state
        outstanding[project] = nil
        if abandoned.count >= Self.abandonedPrepareLimit { abandoned.removeFirst() }
        abandoned.append(AbandonedPrepare(attempt: attempt, project: project))
        return .success(())
    }

    /// Withdraws the plan awaiting review and queues its discard (room checked first).
    func cancel(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        guard var state = projects[project] else { return .failure(.unknownProject(project)) }
        guard queue.canAccept(1) else { return .failure(.queueFull) }
        let effects: [ActivationEffect]
        switch state.transaction.cancel() {
        case .failure(let refusal): return .failure(.activation(refusal))
        case .success(let emitted): effects = emitted
        }
        var stagedQueue = queue
        guard case .success = stagedQueue.enqueue(effects: effects) else { return .failure(.queueFull) }
        state.lifecycle = state.lifecycle.endingPreparation
        state.reviewed = nil
        queue = stagedQueue
        projects[project] = state
        return .success(())
    }

    func nextEngineCommand() -> EngineCommand? {
        queue.dequeue()
    }

    /// What `window` of `project` observes.
    func lifecycle(of project: ProjectID, window: WindowID) -> EngineLifecycle? {
        projects[project].map {
            EngineLifecycle.observed(by: window, of: project, in: registry, engine: $0.lifecycle)
        }
    }

    private func route(_ result: Result<PreparedActivationID, PrepareFailure>, attempt: PrepareAttemptID,
                       project: ProjectID) -> Result<PrepareAnswerOutcome, HostAuthorityRefusal> {
        guard var state = projects[project] else { return .failure(.activation(.stalePrepareResponse)) }
        if case .success(let id) = result, livePlans().contains(id) || queue.pending.contains(.discard(id)) {
            return .failure(.activation(.preparedIDInUse))
        }
        if case .failure(let refusal) = state.transaction.prepared(result, attempt: attempt) {
            return .failure(.activation(refusal))
        }
        switch result {
        case .success(let id): state.reviewed = id
        case .failure: state.lifecycle = state.lifecycle.endingPreparation
        }
        projects[project] = state
        outstanding[project] = nil
        return .success(.routed)
    }

    /// The transaction copy only supplies the refusal reported with the discard.
    private func discardLate(_ result: Result<PreparedActivationID, PrepareFailure>,
                             abandonedAt index: Int) -> Result<PrepareAnswerOutcome, HostAuthorityRefusal> {
        let entry = abandoned[index]
        guard case .success(let id) = result, !livePlans().contains(id) else {
            abandoned.remove(at: index)
            return .success(.dropped)
        }
        // Its discard is already queued: never queue a second one (nor refuse `.queueFull` for it).
        guard !queue.pending.contains(.discard(id)) else {
            abandoned.remove(at: index)
            return .success(.dropped)
        }
        var copy = projects[entry.project]?.transaction
        let refusal: ActivationRefusal
        switch copy?.prepared(result, attempt: entry.attempt) {
        case .failure(let reason): refusal = reason
        case .success, nil: refusal = .stalePrepareResponse
        }
        guard case .success = queue.enqueue(effects: [.discard(id)]) else { return .failure(.queueFull) }
        abandoned.remove(at: index)
        return .success(.discarded(id, refusal: refusal))
    }

    private func liveContext(over running: RunningGraph) -> ActivationLiveContext? {
        guard let engine = ledger.generation(EngineLeaseRegistry.contextKey) else { return nil }
        let activation = ActivationContext(hostEpoch: live.hostEpoch, activeRevision: running.revision,
                                           permission: live.permission, capabilities: live.capabilities)
        return ActivationLiveContext(activation: activation, engine: engine)
    }

    /// Every plan the engine must keep: running, reviewed or committing, and held by a phase.
    private func livePlans() -> Set<PreparedActivationID> {
        var plans: Set<PreparedActivationID> = []
        for state in projects.values {
            if let running = state.transaction.running.prepared { plans.insert(running) }
            switch state.transaction.phase {
            case .awaitingReview, .committing: if let reviewed = state.reviewed { plans.insert(reviewed) }
            case .partial(let id, _, _), .commitFailed(let id), .recovering(let id, _): plans.insert(id)
            case .idle, .preparing, .acknowledged, .prepareFailed: break
            }
        }
        return plans
    }
}
