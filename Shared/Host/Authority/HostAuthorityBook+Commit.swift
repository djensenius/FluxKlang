//
//  HostAuthorityBook+Commit.swift
//  FluxKlang
//
//  The commit path of `HostAuthorityBook` (#62 H5c-1): authorizing from a
//  rendering window's gesture, committing against the live context and lease
//  built at commit, abandoning a commit whose outcome is unknown, recording the
//  engine's report on a delivered commit (H5c-2), and the delivery
//  guard with its private `withholdCommit`. `release` and `transfer` (sharing
//  `acquire`'s private lease staging) live in `HostAuthorityBook.swift`. Every
//  refusal leaves the whole book unchanged.
//

extension HostAuthorityBook {
    /// Issues a single-use authorization for `project`'s reviewed plan. Checks, in
    /// order: project open; the gesture's window renders `project`
    /// (`windowCannotAuthorize(role)`: no lease, a window off the lease, or another
    /// holder); then the transaction's checks on `gesture.origin` (never the
    /// request's origin) and the live permission. Success records `gesture.window`
    /// for the commit-time re-check, replacing any earlier record together with the
    /// earlier authorization.
    mutating func authorize(project: ProjectID,
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
    mutating func commit(project: ProjectID,
                         authorization: ActivationAuthorization) -> Result<Void, HostAuthorityRefusal> {
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
    /// Queues the step's mute (marking `outputsMuted`), enters `.recovering` and ends the attempt's
    /// `inFlight` record. A still-queued `.commit` of the attempt is then dropped
    /// by the delivery guard.
    mutating func abandonCommit(_ attempt: CommitAttemptID,
                                reason: CommitAbandonment) -> Result<Void, HostAuthorityRefusal> {
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
        state.enterRecovery()
        queue = stagedQueue
        projects[project] = state
        inFlight[project] = nil
        return .success(())
    }

    /// Records the engine's report on a delivered commit. Checks, in order, all
    /// before anything moves:
    /// 1. routing by attempt: the project whose last commit attempt is
    ///    `report.attempt` (else `.activation(.staleReport)`; a project is never
    ///    found from the plan);
    /// 2. the attempt was delivered and is still unreported (`inFlight`), else
    ///    `.activation(.staleReport)`: a queued, withheld, abandoned or already
    ///    reported commit has no report;
    /// 3. queue room for the replaced plan's `.discard` (`.queueFull`, before the transition);
    /// 4. the transaction's checks (plan, node sets) on a copy;
    /// 5. only for `.succeeded`, one `ctx.engine` bump on a staged ledger
    ///    (`.ledger(error)` with nothing changed: the commit stays in flight and
    ///    may be abandoned as `.outcomeUnknown`).
    /// Then state, ledger and queue change together: the commit leaves `inFlight`,
    /// the reviewed plan is cleared and the lifecycle moves
    /// (`acknowledgingActivation`; `endingPreparation` on `.failed`/`.partial`,
    /// which H5d resolves).
    mutating func commitReported(
        _ report: ActivationCommitReport
    ) -> Result<CommitReportOutcome, HostAuthorityRefusal> {
        guard let project = projects.first(where: { $0.value.transaction.lastAttempt == report.attempt })?.key,
              var state = projects[project], inFlight[project] == report.attempt else {
            return .failure(.activation(.staleReport))
        }
        guard queue.canAccept(1) else { return .failure(.queueFull) }
        let effects: [ActivationEffect]
        switch state.transaction.acknowledged(report) {
        case .failure(let refusal): return .failure(.activation(refusal))
        case .success(let emitted): effects = emitted
        }
        var stagedLedger = ledger
        let outcome: CommitReportOutcome
        switch report.outcome {
        case .succeeded:
            do { _ = try stagedLedger.bump(EngineLeaseRegistry.contextKey, reason: .contextChange) } catch {
                return .failure(.ledger(error))
            }
            state.lifecycle = state.lifecycle.acknowledgingActivation
            outcome = .acknowledged(state.transaction.running.revision)
        case .failed:
            state.lifecycle = state.lifecycle.endingPreparation
            outcome = .failed
        case .partial:
            state.lifecycle = state.lifecycle.endingPreparation
            outcome = .partial(unapplied: report.unapplied)
        }
        var stagedQueue = queue
        guard case .success = stagedQueue.enqueue(effects: effects) else { return .failure(.queueFull) }
        state.reviewed = nil
        ledger = stagedLedger
        queue = stagedQueue
        projects[project] = state
        inFlight[project] = nil
        return .success(outcome)
    }

    /// The one place an H5c recovery step's mute is requested: `abandonCommit`
    /// queues it, `withholdCommit` converts it in the withheld commit's place.
    /// On success it records the mute without moving it out of the FIFO.
    mutating func requestMute(_ step: ActivationRecoveryStep, running: RunningGraph,
                              into staged: inout EngineCommandQueue) -> Bool {
        guard case .success = staged.enqueue(step, running: running, lease: registry.snapshot?.token) else {
            return false
        }
        markFIFOMute()
        return true
    }

    /// A queued mute supersedes an unconsumed restore acknowledgement's unmute;
    /// keep the mute in the FIFO rather than moving it to the fail-closed lane.
    mutating func markFIFOMute() {
        if pendingOutput == false { pendingOutput = nil }
        outputsMuted = true
    }

    /// The delivery guard, in one actor turn. The fail-closed lane (`takeOutput()`,
    /// `+LeaseLoss.swift`) goes first, ahead of every queued command. A `.commit` is
    /// delivered only while its attempt is still some project's committing attempt
    /// (else dropped, and the next command is taken) and only under the current lease token. A commit whose
    /// token was replaced (released, transferred or reacquired) is withheld: the
    /// actor abandons it as `.leaseLost` and returns `.setOutputsMuted(true)` in its
    /// place, keeping its FIFO position (and marking `outputsMuted`). A delivered commit is `inFlight`.
    mutating func nextEngineCommand() -> EngineCommand? {
        if let output = takeOutput() { return output }
        while let command = queue.dequeue() {
            if case .restore = command {
                guard admitRestore(command) else { continue }
                return command
            }
            if case .discard(let prepared) = command {
                retireRestoreDiscard(prepared)
                return command
            }
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
    private mutating func withholdCommit(_ attempt: CommitAttemptID, of project: ProjectID) -> EngineCommand {
        let mute = EngineCommand.setOutputsMuted(true)
        guard var state = projects[project],
              case .success(let step) = state.transaction.abandonCommit(attempt, reason: .leaseLost) else {
            markFIFOMute()
            return mute
        }
        var converted = EngineCommandQueue()
        let queuedMute = requestMute(step, running: state.transaction.running, into: &converted)
        state.enterRecovery()
        projects[project] = state
        if !queuedMute { markFIFOMute() }
        let replacement = converted.pending.count == 1 ? converted.dequeue() ?? mute : mute
        // Continuation point: the withheld commit's state is settled here, before the
        // replacement is delivered; a post-step on `project` belongs here.
        return replacement
    }
}
