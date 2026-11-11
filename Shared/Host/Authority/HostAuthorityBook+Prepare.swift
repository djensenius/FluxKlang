//
//  HostAuthorityBook+Prepare.swift
//  FluxKlang
//
//  Stage transaction and queue checks before the canonical ledger's one mutation.
//

extension HostAuthorityBook {
    mutating func begin(_ request: ActivationRequest, candidate: GraphDocument,
                        projectDocument: ProjectDocument, project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
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
        guard effects.count == 1, case .prepare(let validated, let attempt) = effects[0] else {
            return .failure(.unboundPlan)
        }
        do {
            try Self.validateProject(projectDocument, selectedGraph: validated.graph, project: project)
        } catch { return .failure(error) }
        let instance = plans.currentInstance
        var stagedQueue = queue
        let command = EngineCommand.prepare(validated.graph, projectDocument, instance, attempt)
        guard case .success = stagedQueue.enqueue([command]) else {
            return .failure(.queueFull)
        }
        do { try plans.dispatch(instance: instance, attempt: attempt) } catch { return .failure(.plans(error)) }
        state.lifecycle = state.lifecycle.startingPreparation(of: target)
        queue = stagedQueue
        outstanding[project] = HostPrepare(instance: instance, attempt: attempt)
        projects[project] = state
        return .success(())
    }

    private static func validateProject(
        _ document: ProjectDocument, selectedGraph: GraphDocument, project: ProjectID
    ) throws(HostAuthorityRefusal) {
        guard document.id == project else {
            throw .projectDocumentMismatch(expected: project, found: document.id)
        }
        do {
            try document.validatePreparationContext(selectedGraph: selectedGraph)
        } catch { throw .preparationProject(error) }
    }

    /// Answers carry the actual engine instance even when the attempt is known.
    /// Lost answers stay pending and consume capacity; late answers need no queue room.
    mutating func prepareAnswered(
        _ result: Result<PreparedActivationID, PrepareFailure>, instance: EngineInstanceID, attempt: PrepareAttemptID
    ) -> Result<PrepareAnswerOutcome, HostAuthorityRefusal> {
        let preparation = HostPrepare(instance: instance, attempt: attempt)
        if let project = outstanding.first(where: { $0.value == preparation })?.key {
            return route(result, preparation: preparation, project: project)
        }
        guard plans.pendingReclaim(instance: instance, attempt: attempt) == true else {
            return .failure(.activation(.stalePrepareResponse))
        }
        let completion: EnginePlanCompletion
        do { completion = try plans.complete(instance: instance, attempt: attempt, result: result) } catch {
            return .failure(.plans(error))
        }
        switch completion {
        case .retiring(let binding):
            scheduleRetirement(binding)
            return .success(.reclaimed(binding))
        case .failed: return .success(.dropped)
        case .held: return .success(.routed) // Unreachable: the checked entry is pending-reclaim.
        }
    }

    mutating func abandonPrepare(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        guard var state = projects[project] else { return .failure(.unknownProject(project)) }
        guard let preparation = outstanding[project],
              state.transaction.lastPrepareAttempt == preparation.attempt else {
            return .failure(.activation(.unexpectedPhase(state.transaction.phase)))
        }
        if case .failure(let refusal) = state.transaction.abandonPrepare(preparation.attempt) {
            return .failure(.activation(refusal))
        }
        do { try plans.reclaim(instance: preparation.instance, attempt: preparation.attempt) } catch {
            return .failure(.plans(error))
        }
        state.lifecycle = state.lifecycle.endingPreparation
        projects[project] = state
        outstanding[project] = nil
        return .success(())
    }

    /// Queue-room preflight remains deliberate: a full-queue cancel refuses unchanged.
    mutating func cancel(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        guard var state = projects[project] else { return .failure(.unknownProject(project)) }
        guard queue.canAccept(1) else { return .failure(.queueFull) }
        let effects: [ActivationEffect]
        switch state.transaction.cancel() {
        case .failure(let refusal): return .failure(.activation(refusal))
        case .success(let emitted): effects = emitted
        }
        guard let binding = state.reviewed, effects == [.discard(binding.prepared)],
              phase(of: binding) == .held else { return .failure(.unboundPlan) }
        do { try plans.release(binding) } catch { return .failure(.plans(error)) }
        state.lifecycle = state.lifecycle.endingPreparation
        state.reviewed = nil
        projects[project] = state
        authorizedWindows[project] = nil
        scheduleRetirement(binding)
        return .success(())
    }

    private mutating func route(
        _ result: Result<PreparedActivationID, PrepareFailure>, preparation: HostPrepare, project: ProjectID
    ) -> Result<PrepareAnswerOutcome, HostAuthorityRefusal> {
        guard var state = projects[project] else { return .failure(.activation(.stalePrepareResponse)) }
        // Defensive: abandonPrepare removes outstanding before a reclaiming answer can route here.
        // Refuse inconsistent ownership before advancing the transaction or mutating the ledger.
        guard plans.pendingReclaim(instance: preparation.instance, attempt: preparation.attempt) == false else {
            return .failure(.unboundPlan)
        }
        if case .failure(let refusal) = state.transaction.prepared(result, attempt: preparation.attempt) {
            guard case .success(let prepared) = result else { return .failure(.activation(refusal)) }
            if case .failure(let abandoned) = state.transaction.abandonPrepare(preparation.attempt) {
                return .failure(.activation(abandoned))
            }
            let binding: PlanBinding
            do {
                binding = try plans.completeRetiring(
                    instance: preparation.instance, attempt: preparation.attempt, prepared: prepared
                )
            } catch { return .failure(.plans(error)) }
            state.lifecycle = state.lifecycle.endingPreparation
            projects[project] = state
            outstanding[project] = nil
            scheduleRetirement(binding)
            return .success(.refusedReclaimed(binding, refusal: refusal))
        }
        let completion: EnginePlanCompletion
        do {
            completion = try plans.complete(
                instance: preparation.instance, attempt: preparation.attempt, result: result
            )
        } catch { return .failure(.plans(error)) }
        switch completion {
        case .held(let binding): state.reviewed = binding
        case .failed: state.lifecycle = state.lifecycle.endingPreparation
        case .retiring(let binding): scheduleRetirement(binding)
        }
        projects[project] = state
        outstanding[project] = nil
        return .success(.routed)
    }
}
