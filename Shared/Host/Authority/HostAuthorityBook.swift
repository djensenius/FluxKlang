//
//  HostAuthorityBook.swift
//  FluxKlang
//
//  Everything `HostAuthority` owns (#62 H5): the lease registry, generation
//  counters, one canonical plan ledger, live state, each project's transaction,
//  the engine command queue and the commit bookkeeping, with their transitions.
//  The actor stores it as `private var book` in `HostAuthority.swift`, so neither
//  an `await` nor a function taking `isolated HostAuthority` can reach it: the
//  members here are internal only so the book's own extensions
//  (`HostAuthorityBook+Prepare.swift`, `+Commit.swift`, `+LeaseLoss.swift`,
//  `+Restore.swift`) can share them. A book a
//  module caller builds itself is a separate value and never touches an actor's.
//  Every refusal leaves the whole book unchanged, except `redeemDirect`, which
//  always consumes its ticket.
//

/// Deliberately NOT `Sendable` (see the extension below), like `HostProjectState`.
/// Never stage by copying this book: copies would alias the canonical plan ledger.
struct HostAuthorityBook {
    var registry = EngineLeaseRegistry()
    var ledger: GenerationLedger
    var live: HostLiveState
    var projects: [ProjectID: HostProjectState] = [:]
    /// Keyed by project: at most one outstanding attempt per open project.
    var outstanding: [ProjectID: HostPrepare] = [:]
    /// Only the private actor's book owns this reference. Snapshots expose data only.
    let plans: EnginePlanLedger
    var retirementOutbox: [PlanBinding] = []
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
    /// H5d-2: the one restore queued or delivered under the current lease.
    var restoring: RestoreRecord?
    /// Discards from an invalidated restore step; requeued only after its next restore.
    var deferredRestoreDiscards: [ProjectID: [PlanBinding]] = [:]
    /// AU1: admitted, unredeemed direct-write tickets. Not in the snapshot.
    var directWrites: Set<DirectWriteTicket> = []
    /// The last minted ticket serial; never reused.
    var lastDirectWrite: UInt64 = 0

    /// Declares `EngineLeaseRegistry.contextKey` in `ledger` unless it already is.
    init(host ledger: GenerationLedger, live: HostLiveState,
         planCapacity: Int = HostAuthority.planCapacity) throws(HostAuthorityRefusal) {
        var declared = ledger
        if declared.generation(EngineLeaseRegistry.contextKey) == nil {
            do { try declared.declare(EngineLeaseRegistry.contextKey) } catch { throw .ledger(error) }
        }
        do { plans = try EnginePlanLedger(capacity: planCapacity) } catch { throw .plans(error) }
        self.ledger = declared
        self.live = live
    }

    func snapshot() -> HostAuthoritySnapshot {
        HostAuthoritySnapshot(lease: registry.snapshot, lastIssuedLease: registry.lastIssued, ledger: ledger.current,
                              live: live, projects: projects.mapValues(HostProjectSnapshot.init),
                              outstanding: outstanding, plans: plans.snapshot(),
                              retirementOutbox: retirementOutbox, queue: queue,
                              inFlight: inFlight, authorizedWindows: authorizedWindows,
                              pendingOutput: pendingOutput, outputsMuted: outputsMuted, restoring: restoring,
                              deferredRestoreDiscards: deferredRestoreDiscards)
    }

    /// Opens `project` over an empty, unqualified running graph; prepared residents
    /// must be installed through this book's canonical plan ledger. `lifecycle`
    /// defaults to `.stopped`; pass a settled state only when consistent with that graph.
    /// Refused as `lifecycleNotResumable`: `.preparing` (no prepare is outstanding
    /// yet), `.heldByOther` (derived from the lease by `lifecycle(of:window:)`), and
    /// a rendering `.running`/`.degraded` with no book-owned resident. `.stopped` is
    /// accepted over an empty graph. `.recovering` is
    /// accepted either way: unresolved recovery outlives the running set.
    /// Pass `recoveryBase` when resuming a known recovery snapshot; rendering/degraded
    /// bases require an installed resident, which raw `open` cannot import. Without
    /// saved provenance, recovery opens over `.absent` and settles stopped rather
    /// than inferring a running lifecycle from a stored plan. Bootstrap through real
    /// prepare/commit operations so this canonical ledger owns every installed binding.
    mutating func open(project: ProjectID, running: RunningGraph,
                       lifecycle: EngineLifecycle? = nil,
                       recoveryBase: RunningSetState? = nil) -> Result<Void, HostAuthorityRefusal> {
        guard projects[project] == nil else { return .failure(.projectAlreadyOpen(project)) }
        guard projects.count < HostAuthority.projectLimit else { return .failure(.projectLimit) }
        let opening: (lifecycle: EngineLifecycle, recoveryBase: RunningSetState?)
        switch openingLifecycle(running: running, lifecycle: lifecycle, recoveryBase: recoveryBase) {
        case .success(let validated): opening = validated
        case .failure(let refusal): return .failure(refusal)
        }
        projects[project] = HostProjectState(transaction: ActivationTransaction(project: project, running: running),
                                             lifecycle: opening.lifecycle,
                                             recoveryBase: opening.recoveryBase)
        return .success(())
    }

    /// Validates explicit lifecycle and saved recovery provenance before `open` mutates the book.
    private func openingLifecycle(
        running: RunningGraph,
        lifecycle: EngineLifecycle?,
        recoveryBase: RunningSetState?
    ) -> Result<(lifecycle: EngineLifecycle, recoveryBase: RunningSetState?), HostAuthorityRefusal> {
        if let lifecycle {
            switch lifecycle {
            case .stopped, .recovering: break
            case .running, .degraded:
                guard running.prepared != nil else { return .failure(.lifecycleNotResumable(lifecycle)) }
            case .preparing, .heldByOther: return .failure(.lifecycleNotResumable(lifecycle))
            }
        }
        guard running.prepared == nil else { return .failure(.unqualifiedResident) }
        let initial = lifecycle ?? (running.prepared == nil ? .stopped : .running)
        if let recoveryBase {
            guard initial == .recovering else { return .failure(.invalidRecoveryBase) }
            if recoveryBase != .absent, running.prepared == nil {
                return .failure(.invalidRecoveryBase)
            }
        }
        let savedBase = initial == .recovering ? recoveryBase ?? .absent : nil
        return .success((initial, savedBase))
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

    /// Removes a window from the lease, under the current token, and drops its
    /// outstanding direct-write tickets (they then redeem as `notOutstanding`).
    mutating func detach(_ window: WindowID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        guard let token = registry.snapshot?.token else { return .failure(.lease(.notHeld)) }
        var staged = registry
        let held: EngineLeaseSnapshot
        do { held = try staged.detach(window, expected: token) } catch { return .failure(.lease(error)) }
        registry = staged
        // Fail closed: a re-attached window never redeems a ticket from before its detach.
        directWrites = directWrites.filter { $0.window != window }
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
    /// change is applied exactly once. Lease lifecycle hooks run after both staged values commit.
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
        leaseChanged()
        leaseGranted(to: granted.snapshot.project)
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
        leaseChanged()
        return .success(())
    }

    func liveContext(over running: RunningGraph) -> ActivationLiveContext? {
        guard let engine = ledger.generation(EngineLeaseRegistry.contextKey) else { return nil }
        let activation = ActivationContext(hostEpoch: live.hostEpoch, activeRevision: running.revision,
                                           permission: live.permission, capabilities: live.capabilities)
        return ActivationLiveContext(activation: activation, engine: engine)
    }

}

/// A single-use permit for one direct write that changes the running set (#62 AU1),
/// fenced by the live host epoch and permission, the lease, the engine context
/// generation and the project's running graph revision at admission. Only
/// `HostAuthorityBook.admitDirect` mints one; `redeemDirect` consumes it.
struct DirectWriteTicket: Hashable, Sendable {
    /// Unique per book: minted from a counter that never repeats.
    let serial: UInt64
    let project: ProjectID
    let window: WindowID
    let scope: CommandScope
    /// `HostLiveState.hostEpoch` at admission, which the admission context and so the intent matched.
    let hostEpoch: HostEpoch
    /// `HostLiveState.permission` at admission, likewise matched by the context and the intent.
    let permission: PermissionFingerprint?
    let lease: EngineLeaseToken
    /// `EngineLeaseRegistry.contextKey`'s generation at admission.
    let context: Generation
    /// The project's `transaction.running.revision` at admission.
    let running: ContractRevision

    fileprivate init(serial: UInt64, project: ProjectID, window: WindowID, scope: CommandScope,
                     live: HostLiveState, lease: EngineLeaseToken, context: Generation, running: ContractRevision) {
        self.serial = serial
        self.project = project
        self.window = window
        self.scope = scope
        hostEpoch = live.hostEpoch
        permission = live.permission
        self.lease = lease
        self.context = context
        self.running = running
    }
}

extension HostAuthorityBook {
    /// Admits a direct write from `window` of `project`. Checks, in order: project
    /// open (`unknownProject`); `HostCommandGate.admitDirect` with this window's
    /// current lifecycle and role and the book's live state (gate first, then
    /// `staleLive` and `.renders` for running-set changes); capacity. Safety and
    /// draft scopes succeed with no ticket. Every refusal leaves the snapshot and
    /// the outstanding count unchanged; only at capacity are tickets that cannot
    /// redeem now dropped first, including `commitInFlight` ones that could redeem
    /// again if the commit fails (fails closed: the write is re-admitted).
    /// Admission is not refused while a commit is in flight or partial (the gate
    /// sees the unchanged lifecycle); such a ticket records the pre-settlement
    /// running revision, so it is refused `commitInFlight` until the commit settles
    /// and `staleContext` once a success or kept partial moves the running graph.
    mutating func admitDirect(_ intent: CommandIntent, admission: AdmissionContext,
                              project: ProjectID, window: WindowID) -> Result<DirectWriteTicket?, DirectWriteRefusal> {
        guard let lifecycle = lifecycle(of: project, window: window),
              let running = projects[project]?.transaction.running.revision else { return .failure(.unknownProject) }
        let lease: EngineLeaseToken
        switch HostCommandGate.admitDirect(intent, admission: admission, lifecycle: lifecycle,
                                           role: registry.role(of: window, project: project), live: live) {
        case .failure(let refusal): return .failure(refusal)
        case .success(nil): return .success(nil)
        case .success(let required?): lease = required
        }
        // Unreachable today (`init` declares the counter); fails closed.
        guard let context = ledger.generation(EngineLeaseRegistry.contextKey) else { return .failure(.staleContext) }
        if directWrites.count >= HostAuthority.directWriteCapacity {
            directWrites = directWrites.filter { directWriteRefusal($0) == nil }
        }
        // The serial bound is unreachable in practice; it fails closed as capacity.
        guard directWrites.count < HostAuthority.directWriteCapacity, lastDirectWrite < .max else {
            return .failure(.tooManyOutstanding)
        }
        lastDirectWrite += 1
        let ticket = DirectWriteTicket(serial: lastDirectWrite, project: project, window: window,
                                       scope: intent.operation.scope, live: live, lease: lease, context: context,
                                       running: running)
        directWrites.insert(ticket)
        return .success(ticket)
    }

    /// Redeems `ticket` once, synchronously, immediately before its write.
    /// Any attempt consumes it, refused or not, so it can never be retried
    /// (`notOutstanding`); then `HostCommandGate.redeemRefusal`'s checks, in its
    /// order. Never changes the snapshot.
    ///
    /// The fence holds only while nothing else runs: the write must happen inside
    /// the same serialization as lease, live, context and running-graph changes (redeem under the
    /// send lock, as `WingMixerWriteAuthorization` does). Redeeming on the actor and
    /// writing after an `await` leaves a race that the wiring slice must close.
    mutating func redeemDirect(_ ticket: DirectWriteTicket) -> Result<Void, DirectWriteRefusal> {
        guard directWrites.remove(ticket) != nil else { return .failure(.notOutstanding) }
        if let refusal = directWriteRefusal(ticket) { return .failure(refusal) }
        return .success(())
    }

    /// Admitted, unredeemed tickets; diagnostics and tests only.
    var outstandingDirectWriteCount: Int { directWrites.count }

    /// Delivered and unreported, reported `.partial` and not yet resolved, or a
    /// restore of the running graph queued or delivered and not yet completed
    /// (`restoring` holds both until `restoreCompleted`; a lease change clears it
    /// and leaves the project `.recovering`).
    private func commitInFlight(_ project: ProjectID) -> Bool {
        if inFlight[project] != nil || restoring?.project == project { return true }
        if case .partial? = projects[project]?.transaction.phase { return true }
        return false
    }

    private func directWriteRefusal(_ ticket: DirectWriteTicket) -> DirectWriteRefusal? {
        let now = DirectWriteFence(lifecycle: lifecycle(of: ticket.project, window: ticket.window), live: live,
                                   held: registry.snapshot?.token,
                                   role: registry.role(of: ticket.window, project: ticket.project),
                                   commitInFlight: commitInFlight(ticket.project),
                                   context: ledger.generation(EngineLeaseRegistry.contextKey),
                                   running: projects[ticket.project]?.transaction.running.revision)
        return HostCommandGate.redeemRefusal(ticket, now: now)
    }
}

@available(*, unavailable, message: "the book never leaves HostAuthority")
extension HostAuthorityBook: Sendable {}
