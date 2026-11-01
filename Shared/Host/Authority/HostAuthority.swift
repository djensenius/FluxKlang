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

actor HostAuthority {
    static let projectLimit = 16
    /// Abandoned attempts remembered for discarding their late success. When the
    /// FIFO is full, abandoning evicts the oldest: a success arriving later for an
    /// evicted attempt is `stalePrepareResponse` and is NOT discarded, so the engine
    /// may keep that plan (a bounded engine-side leak; H5d may add an engine reset
    /// that clears it). Abandons alone never make `begin` refuse.
    static let abandonedPrepareLimit = 64

    // Access audit (B1). Actor isolation only forbids *synchronous* access from
    // outside: module code may still `await` a read of any internal Sendable
    // property or call any internal method. Hence:
    // - `projects` holds the transactions; `HostProjectState` is not `Sendable`, so
    //   the dictionary cannot leave the actor, even by `await`.
    // - `ledger`, `outstanding`, `abandoned` and the delivery guard's helpers are private.
    // - `registry` and `live` are `private(set)`; `queue`, `inFlight` and
    //   `authorizedWindows` stay internal for `HostAuthority+Commit.swift`. An
    //   outside `await` read yields only a value copy of what `snapshot()` already
    //   shows, and an outside write does not compile.
    // - Internal methods (`liveContext`, `livePlans`, `requestMute`) return values
    //   and change no actor state.
    private(set) var registry = EngineLeaseRegistry()
    private var ledger: GenerationLedger
    private(set) var live: HostLiveState
    var projects: [ProjectID: HostProjectState] = [:]
    /// Keyed by project: at most one outstanding attempt per open project.
    private var outstanding: [ProjectID: PrepareAttemptID] = [:]
    private var abandoned: [AbandonedPrepare] = []
    var queue = EngineCommandQueue()
    /// Commits delivered to the engine and not yet reported (H5c-2 clears them on report).
    var inFlight: [ProjectID: CommitAttemptID] = [:]
    /// The window recorded by `authorize`, re-checked by `commit`; cleared when the
    /// authorization is consumed by `commit` or withdrawn by `cancel`.
    var authorizedWindows: [ProjectID: WindowID] = [:]

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
                              inFlight: inFlight, authorizedWindows: authorizedWindows)
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

    /// Grants `project`'s `window` a new lease (one context bump), staged by
    /// `grantLease` like `transfer`.
    func acquire(project: ProjectID, window: WindowID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
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
    func release(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
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
    func transfer(to project: ProjectID, window: WindowID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        guard projects[project] != nil else { return .failure(.unknownProject(project)) }
        guard inFlight.isEmpty else { return .failure(.activation(.busy)) }
        guard let token = registry.snapshot?.token else { return .failure(.lease(.notHeld)) }
        return grantLease { registry throws(EngineLeaseError) in
            try registry.transfer(to: project, window: window, expected: token)
        }
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
        authorizedWindows[project] = nil
        return .success(())
    }

    /// The delivery guard, in one actor turn. A `.commit` is delivered only while
    /// its attempt is still some project's committing attempt (else dropped, and the
    /// next command is taken) and only under the current lease token. A commit whose
    /// token was replaced (released, transferred or reacquired) is withheld: the
    /// actor abandons it as `.leaseLost` and returns `.setOutputsMuted(true)` in its
    /// place, keeping its FIFO position. A delivered commit is `inFlight`.
    func nextEngineCommand() -> EngineCommand? {
        while let command = queue.dequeue() {
            guard case .commit(_, let attempt, let token) = command else { return command }
            guard let project = committingProject(for: attempt) else { continue }
            guard token == registry.snapshot?.token else { return withholdCommit(attempt, of: project) }
            inFlight[project] = attempt
            return command
        }
        return nil
    }

    /// The project whose transaction is still committing `attempt`, if any.
    private func committingProject(for attempt: CommitAttemptID) -> ProjectID? {
        projects.first { $0.value.transaction.phase == .committing && $0.value.transaction.lastAttempt == attempt }?
            .key
    }

    /// Abandons `project`'s committing `attempt` (from `committingProject`) as
    /// `.leaseLost` and returns the one command that takes the commit's place in
    /// the queue: the recovery step's mute. The lifecycle becomes `.recovering`;
    /// the reviewed plan stays live. Private to the delivery guard, so no caller can
    /// claim `.leaseLost`. State changes only if the abandon succeeds; otherwise
    /// (a contract break) nothing changes and the mute is still returned in place
    /// of the dropped commit, which fails closed.
    private func withholdCommit(_ attempt: CommitAttemptID, of project: ProjectID) -> EngineCommand {
        let mute = EngineCommand.setOutputsMuted(true)
        guard var state = projects[project],
              case .success(let step) = state.transaction.abandonCommit(attempt, reason: .leaseLost) else {
            return mute
        }
        var converted = EngineCommandQueue()
        _ = requestMute(step, running: state.transaction.running, into: &converted)
        state.lifecycle = state.lifecycle.after(CommitAbandonment.leaseLost.event)
        projects[project] = state
        let replacement = converted.pending.count == 1 ? converted.dequeue() ?? mute : mute
        // Continuation point: the withheld commit's state is settled here, before the
        // replacement is delivered; a post-step on `project` belongs here.
        return replacement
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

    /// The one place a lease is granted (`acquire`, `transfer`): staged on registry
    /// and ledger copies, so both change or neither does, and the grant's context
    /// change is applied exactly once. Later lease hooks belong here.
    private func grantLease(
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

    /// The one place a lease is removed (`release`), staged like `grantLease`.
    private func removeLease(expected token: EngineLeaseToken) -> Result<Void, HostAuthorityRefusal> {
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
