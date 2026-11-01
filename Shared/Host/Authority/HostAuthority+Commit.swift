//
//  HostAuthority+Commit.swift
//  FluxKlang
//
//  The commit path of `HostAuthority` (#62 H5c-1): authorizing from a rendering
//  window's gesture, committing against the live context and lease built at
//  commit, and abandoning a commit whose outcome is unknown. `release`,
//  `transfer` (sharing `acquire`'s private lease staging) and the delivery
//  guard's private `withholdCommit` live in `HostAuthority.swift`. Every refusal
//  leaves the whole actor state unchanged.
//

extension HostAuthority {
    /// Issues a single-use authorization for `project`'s reviewed plan. Checks, in
    /// order: project open; the gesture's window renders `project`
    /// (`windowCannotAuthorize(role)`: no lease, a window off the lease, or another
    /// holder); then the transaction's checks on `gesture.origin` (never the
    /// request's origin) and the live permission. Success records `gesture.window`
    /// for the commit-time re-check, replacing any earlier record together with the
    /// earlier authorization.
    func authorize(project: ProjectID,
                   gesture: ActivationGesture) -> Result<ActivationAuthorization, HostAuthorityRefusal> {
        guard var state = projects[project] else { return .failure(.unknownProject(project)) }
        let role = registry.role(of: gesture.window, project: project)
        guard case .renders = role else { return .failure(.windowCannotAuthorize(role)) }
        switch state.transaction.authorize(origin: gesture.origin, permission: live.permission) {
        case .failure(let refusal): return .failure(.activation(refusal))
        case .success(let authorization):
            projects[project] = state
            authorizedWindows[project] = gesture.window
            return .success(authorization)
        }
    }

    /// Commits `project`'s reviewed plan. Checks, in order, all before anything
    /// moves:
    /// 1. project open;
    /// 2. the lifecycle is not `.recovering` (`lifecycleRejectsChanges`);
    /// 3. the window recorded by `authorize` still renders `project`
    ///    (`windowCannotAuthorize(role)`; no record is `authorizationInvalid(.noneOutstanding)`).
    ///    A released, transferred or detached lease therefore refuses here, before
    ///    the transaction's own lease checks;
    /// 4. queue room for the `.commit` (`.queueFull`, before the transition);
    /// 5. the transaction's checks against the authorization, the current lease and
    ///    the live context built now from `live`, `ledger` and the running graph.
    /// The queued `.commit` is delivered only if its lease is still current
    /// (`nextEngineCommand()`). Success consumes the window record.
    func commit(project: ProjectID, authorization: ActivationAuthorization) -> Result<Void, HostAuthorityRefusal> {
        guard var state = projects[project] else { return .failure(.unknownProject(project)) }
        if case .recovering = state.lifecycle { return .failure(.lifecycleRejectsChanges(state.lifecycle)) }
        guard let window = authorizedWindows[project] else {
            return .failure(.activation(.authorizationInvalid(.noneOutstanding)))
        }
        let role = registry.role(of: window, project: project)
        guard case .renders = role else { return .failure(.windowCannotAuthorize(role)) }
        guard queue.canAccept(1) else { return .failure(.queueFull) }
        guard let context = liveContext(over: state.transaction.running) else {
            return .failure(.ledger(.undeclaredCounter(EngineLeaseRegistry.contextKey)))
        }
        let effects: [ActivationEffect]
        switch state.transaction.commit(authorization, lease: registry.snapshot, context: context) {
        case .failure(let refusal): return .failure(.activation(refusal))
        case .success(let emitted): effects = emitted
        }
        var stagedQueue = queue
        guard case .success = stagedQueue.enqueue(effects: effects) else { return .failure(.queueFull) }
        queue = stagedQueue
        projects[project] = state
        authorizedWindows[project] = nil
        return .success(())
    }

    /// Abandons a commit that never got a report. Callers may only claim
    /// `.outcomeUnknown` (`abandonmentReserved` otherwise: the actor alone abandons
    /// for a lost lease, and `begin` refuses a revision that cannot advance).
    /// Checks, in order: reason; `attempt` is an open project's last commit attempt
    /// (`.activation(.staleReport)`); queue room for any recovery step
    /// (`maxRecoveryStepSlots`, before the transition); the transaction's checks.
    /// Queues the step's mute, enters `.recovering` and ends the attempt's
    /// `inFlight` record. A still-queued `.commit` of the attempt is then dropped
    /// by the delivery guard.
    func abandonCommit(_ attempt: CommitAttemptID, reason: CommitAbandonment) -> Result<Void, HostAuthorityRefusal> {
        guard reason == .outcomeUnknown else { return .failure(.abandonmentReserved(reason)) }
        guard let project = projects.first(where: { $0.value.transaction.lastAttempt == attempt })?.key,
              var state = projects[project] else { return .failure(.activation(.staleReport)) }
        guard queue.canAccept(EngineCommandQueue.maxRecoveryStepSlots) else { return .failure(.queueFull) }
        let step: ActivationRecoveryStep
        switch state.transaction.abandonCommit(attempt, reason: reason) {
        case .failure(let refusal): return .failure(.activation(refusal))
        case .success(let recovery): step = recovery
        }
        var stagedQueue = queue
        guard requestMute(step, running: state.transaction.running, into: &stagedQueue) else {
            return .failure(.queueFull)
        }
        state.lifecycle = state.lifecycle.after(reason.event)
        queue = stagedQueue
        projects[project] = state
        inFlight[project] = nil
        return .success(())
    }

    /// The one place an H5c recovery step's mute is requested: `abandonCommit`
    /// queues it, `withholdCommit` (in `HostAuthority.swift`) converts it in the
    /// withheld commit's place. It only fills the caller's own `staged` queue;
    /// `false` (nothing queued) if it does not fit.
    func requestMute(_ step: ActivationRecoveryStep, running: RunningGraph,
                     into staged: inout EngineCommandQueue) -> Bool {
        guard case .success = staged.enqueue(step, running: running, lease: registry.snapshot?.token) else {
            return false
        }
        return true
    }
}
