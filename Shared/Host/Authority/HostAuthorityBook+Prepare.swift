//
//  HostAuthorityBook+Prepare.swift
//  FluxKlang
//
//  The prepare path of `HostAuthorityBook` (#62 H5b): beginning an activation,
//  routing the engine's answers, abandoning a prepare and cancelling a review.
//  Every refusal leaves the whole book unchanged.
//

extension HostAuthorityBook {
    /// Validates and begins `request` against the live context the actor builds
    /// itself. Checks, in order: project, queue room for the `.prepare` (before the
    /// transition; `.queueFull` moves nothing), the running revision can advance
    /// (`.activation(.overflow)`, so the lifecycle never shows a revision that cannot
    /// be prepared), then the transaction's own checks (`.busy` while preparing).
    mutating func begin(_ request: ActivationRequest, candidate: GraphDocument,
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
    /// - An abandoned attempt's first answer is consumed exactly once, and never
    ///   reaches a transaction or the queue (so it is never `.queueFull`): a success
    ///   is `.unreclaimed`, unless it names a live plan or a plan whose `.discard` is
    ///   already queued; that, or a failure, is `.dropped`. No `.discard` is ever
    ///   queued from its bare ID, which the engine may have reused (#191).
    /// - An unknown, foreign, evicted or already answered attempt is
    ///   `stalePrepareResponse` and changes nothing.
    mutating func prepareAnswered(_ result: Result<PreparedActivationID, PrepareFailure>,
                                  attempt: PrepareAttemptID) -> Result<PrepareAnswerOutcome, HostAuthorityRefusal> {
        if let project = outstanding.first(where: { $0.value == attempt })?.key {
            return route(result, attempt: attempt, project: project)
        }
        if let index = abandoned.firstIndex(where: { $0.attempt == attempt }) {
            return .success(consumeLate(result, abandonedAt: index))
        }
        return .failure(.activation(.stalePrepareResponse))
    }

    /// Gives up on `project`'s outstanding prepare. Its first late answer is
    /// recognised once, unless `abandonedPrepareLimit` later abandons evict it first;
    /// its plan is never reclaimed here (#191).
    mutating func abandonPrepare(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
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
        if abandoned.count >= HostAuthority.abandonedPrepareLimit { abandoned.removeFirst() }
        abandoned.append(AbandonedPrepare(attempt: attempt, project: project))
        return .success(())
    }

    /// Withdraws the plan awaiting review and queues its discard (room checked first).
    mutating func cancel(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
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

    private mutating func route(_ result: Result<PreparedActivationID, PrepareFailure>, attempt: PrepareAttemptID,
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

    /// Consumes an abandoned attempt's first answer. Nothing is queued and no
    /// transaction sees it; `refusal` is only read from the issuing project's phase.
    private mutating func consumeLate(_ result: Result<PreparedActivationID, PrepareFailure>,
                                      abandonedAt index: Int) -> PrepareAnswerOutcome {
        let entry = abandoned.remove(at: index)
        guard case .success(let id) = result, !livePlans().contains(id),
              !queue.pending.contains(.discard(id)) else { return .dropped }
        let refusal: ActivationRefusal
        switch projects[entry.project]?.transaction.phase {
        case .preparing?, nil: refusal = .stalePrepareResponse
        case let phase?: refusal = .unexpectedPhase(phase)
        }
        return .unreclaimed(id, refusal: refusal)
    }
}
