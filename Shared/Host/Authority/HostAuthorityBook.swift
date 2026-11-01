//
//  HostAuthorityBook.swift
//  FluxKlang
//
//  Everything `HostAuthority` owns, as one value (#62 H5): the lease registry, the
//  ledger, the live state, every project's transaction, the prepare bookkeeping,
//  the engine command queue and the commit bookkeeping, with their transitions.
//  The actor stores it as `private var book` in `HostAuthority.swift`, so neither
//  an `await` nor a function taking `isolated HostAuthority` can reach it: the
//  members here are internal only so the book's own extensions
//  (`HostAuthorityBook+Prepare.swift`, `+Commit.swift`, `+LeaseLoss.swift`) can share them. A book a
//  module caller builds itself is a separate value and never touches an actor's.
//  Every refusal leaves the whole book unchanged.
//

/// Deliberately NOT `Sendable` (see the extension below), like `HostProjectState`.
struct HostAuthorityBook {
    var registry = EngineLeaseRegistry()
    var ledger: GenerationLedger
    var live: HostLiveState
    var projects: [ProjectID: HostProjectState] = [:]
    /// Keyed by project: at most one outstanding attempt per open project.
    var outstanding: [ProjectID: PrepareAttemptID] = [:]
    var abandoned: [AbandonedPrepare] = []
    var queue = EngineCommandQueue()
    /// Commits delivered to the engine and not yet reported; `commitReported` and
    /// `abandonCommit` clear them.
    var inFlight: [ProjectID: CommitAttemptID] = [:]
    /// The window recorded by `authorize`, re-checked by `commit`; cleared when the
    /// authorization is consumed by `commit` or withdrawn by `cancel`.
    var authorizedWindows: [ProjectID: WindowID] = [:]
    /// The fail-closed output lane, delivered by `nextEngineCommand()` before the FIFO:
    /// `true` while a mute is owed. It takes no queue slot, so `leaseLost` is never `.queueFull`.
    var pendingOutput: Bool?
    /// Engine-global (one engine per host): set by every mute, in the lane or the FIFO.
    var outputsMuted = false

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
                              outstanding: outstanding, abandoned: abandoned, queue: queue,
                              inFlight: inFlight, authorizedWindows: authorizedWindows,
                              pendingOutput: pendingOutput, outputsMuted: outputsMuted)
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
    mutating func open(project: ProjectID, running: RunningGraph,
                       lifecycle: EngineLifecycle? = nil) -> Result<Void, HostAuthorityRefusal> {
        guard projects[project] == nil else { return .failure(.projectAlreadyOpen(project)) }
        guard projects.count < HostAuthority.projectLimit else { return .failure(.projectLimit) }
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

    /// Grants `project`'s `window` a new lease (one context bump), staged by
    /// `grantLease` like `transfer`.
    mutating func acquire(project: ProjectID, window: WindowID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        guard projects[project] != nil else { return .failure(.unknownProject(project)) }
        return grantLease { registry throws(EngineLeaseError) in
            try registry.acquire(project: project, window: window)
        }
    }

    /// Releases `project`'s lease, staged by `removeLease` (one context bump).
    /// Checks, in order: project open; no delivered commit is unreported
    /// (`.activation(.busy)`); the lease is held by `project`. A commit that is only
    /// queued does not block: the delivery guard withholds it lazily when it reaches
    /// the head of the queue.
    mutating func release(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        guard projects[project] != nil else { return .failure(.unknownProject(project)) }
        guard inFlight.isEmpty else { return .failure(.activation(.busy)) }
        guard let held = registry.snapshot else { return .failure(.lease(.notHeld)) }
        guard held.project == project else { return .failure(.lease(.heldByOtherProject(held.project))) }
        return removeLease(expected: held.token)
    }

    /// Hands the lease to `project`'s `window` under a new token, staged by
    /// `grantLease` (one context bump). Checks, in order: project open; no delivered
    /// commit is unreported (`.activation(.busy)`); a lease is held; the registry's
    /// own checks (`alreadyHeld` for the holder itself). Queued commits are
    /// withheld lazily, as for `release`.
    mutating func transfer(to project: ProjectID,
                           window: WindowID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        guard projects[project] != nil else { return .failure(.unknownProject(project)) }
        guard inFlight.isEmpty else { return .failure(.activation(.busy)) }
        guard let token = registry.snapshot?.token else { return .failure(.lease(.notHeld)) }
        return grantLease { registry throws(EngineLeaseError) in
            try registry.transfer(to: project, window: window, expected: token)
        }
    }

    /// Adds a window of the holding project, under the current token.
    mutating func attach(_ window: WindowID, project: ProjectID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        guard let token = registry.snapshot?.token else { return .failure(.lease(.notHeld)) }
        var staged = registry
        let held: EngineLeaseSnapshot
        do { held = try staged.attach(window, project: project, expected: token) } catch {
            return .failure(.lease(error))
        }
        registry = staged
        return .success(held)
    }

    mutating func detach(_ window: WindowID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        guard let token = registry.snapshot?.token else { return .failure(.lease(.notHeld)) }
        var staged = registry
        let held: EngineLeaseSnapshot
        do { held = try staged.detach(window, expected: token) } catch { return .failure(.lease(error)) }
        registry = staged
        return .success(held)
    }

    /// What `window` of `project` observes.
    func lifecycle(of project: ProjectID, window: WindowID) -> EngineLifecycle? {
        projects[project].map {
            EngineLifecycle.observed(by: window, of: project, in: registry, engine: $0.lifecycle)
        }
    }

    /// The one place a lease is granted (`acquire`, `transfer`): staged on registry
    /// and ledger copies, so both change or neither does, and the grant's context
    /// change is applied exactly once. Later lease hooks belong here.
    private mutating func grantLease(
        _ grant: (inout EngineLeaseRegistry) throws(EngineLeaseError) -> EngineLeaseGrant
    ) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        var stagedRegistry = registry
        var stagedLedger = ledger
        let granted: EngineLeaseGrant
        do { granted = try grant(&stagedRegistry) } catch { return .failure(.lease(error)) }
        do { try granted.context.apply(to: &stagedLedger) } catch { return .failure(.ledger(error)) }
        registry = stagedRegistry
        ledger = stagedLedger
        return .success(granted.snapshot)
    }

    /// The one place a lease is removed (`release`, `leaseLost`), staged like `grantLease`.
    mutating func removeLease(expected token: EngineLeaseToken) -> Result<Void, HostAuthorityRefusal> {
        var stagedRegistry = registry
        var stagedLedger = ledger
        let change: ContextChange
        do { change = try stagedRegistry.release(expected: token) } catch { return .failure(.lease(error)) }
        do { try change.apply(to: &stagedLedger) } catch { return .failure(.ledger(error)) }
        registry = stagedRegistry
        ledger = stagedLedger
        return .success(())
    }

    func liveContext(over running: RunningGraph) -> ActivationLiveContext? {
        guard let engine = ledger.generation(EngineLeaseRegistry.contextKey) else { return nil }
        let activation = ActivationContext(hostEpoch: live.hostEpoch, activeRevision: running.revision,
                                           permission: live.permission, capabilities: live.capabilities)
        return ActivationLiveContext(activation: activation, engine: engine)
    }

    /// Every plan the engine must keep: running, reviewed or committing, and held by a phase.
    func livePlans() -> Set<PreparedActivationID> {
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

@available(*, unavailable, message: "the book never leaves HostAuthority")
extension HostAuthorityBook: Sendable {}
