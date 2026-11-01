//
//  HostAuthorityBook+Restore.swift
//  FluxKlang
//
//  Recovery under a held lease (#62 H5d-2): queue one restore, admit it only
//  for the current lease, and unmute only after the engine acknowledges it.
//

private struct HostRecoveryPlan {
    let state: HostProjectState
    let step: ActivationRecoveryStep
    let resolution: RecoveryResolution
    let failClosed: Bool
}

private struct RestoreAdmission {
    let attempt: RestoreAttemptID
    let record: RestoreRecord
}

extension HostAuthorityBook {
    /// Resolves `project`'s recovery under its held lease.
    /// Checks, in order: project open; lease held by this project; no restore or
    /// delivered commit already pending; room for the largest recovery step.
    /// Every refusal leaves the book unchanged.
    mutating func resolveRecovery(project: ProjectID) -> Result<RecoveryResolution, HostAuthorityRefusal> {
        guard let state = projects[project] else { return .failure(.unknownProject(project)) }
        guard let lease = registry.snapshot else { return .failure(.activation(.leaseNotHeld)) }
        guard lease.project == project else {
            return .failure(.activation(.leaseHeldByOtherProject(lease.project)))
        }
        guard restoring == nil, inFlight[project] == nil else { return .failure(.activation(.busy)) }
        guard queue.canAccept(EngineCommandQueue.maxRecoveryStepSlots) else { return .failure(.queueFull) }
        switch recoveryPlan(for: state, lease: lease) {
        case .failure(let refusal): return .failure(.activation(refusal))
        case .success(let plan): return applyRecoveryPlan(plan, project: project, lease: lease)
        }
    }

    private mutating func applyRecoveryPlan(_ plan: HostRecoveryPlan, project: ProjectID,
                                            lease: EngineLeaseSnapshot)
    -> Result<RecoveryResolution, HostAuthorityRefusal> {
        let deferredDiscards = deferredRestoreDiscards[project] ?? []
        let admission = makeRestoreAdmission(for: plan, project: project, lease: lease,
                                              deferredDiscards: deferredDiscards)
        guard let stagedQueue = stagedRecoveryQueue(for: plan, lease: lease, admission: admission,
                                                    deferredDiscards: deferredDiscards) else {
            return .failure(.queueFull)
        }
        queue = stagedQueue
        projects[project] = plan.state
        if plan.failClosed { failClosedMute() }
        if let admission {
            restoring = admission.record
            deferredRestoreDiscards[project] = nil
        }
        return .success(plan.resolution)
    }

    private func makeRestoreAdmission(
        for plan: HostRecoveryPlan, project: ProjectID, lease: EngineLeaseSnapshot,
        deferredDiscards: [PreparedActivationID]
    ) -> RestoreAdmission? {
        guard case .restoring(let revision) = plan.resolution else { return nil }
        let attempt = RestoreAttemptID()
        let stepDiscards = plan.step.effects.compactMap { effect -> PreparedActivationID? in
            if case .discard(let prepared) = effect { return prepared }
            return nil
        }
        let record = RestoreRecord(attempt: attempt, project: project, revision: revision,
                                   prepared: plan.state.transaction.running.prepared,
                                   token: lease.token, delivered: false,
                                   discardAfterRestore: stepDiscards + deferredDiscards)
        return RestoreAdmission(attempt: attempt, record: record)
    }

    private func stagedRecoveryQueue(
        for plan: HostRecoveryPlan, lease: EngineLeaseSnapshot, admission: RestoreAdmission?,
        deferredDiscards: [PreparedActivationID]
    ) -> EngineCommandQueue? {
        if admission != nil, !queue.canAccept(EngineCommandQueue.maxRecoveryStepSlots + deferredDiscards.count) {
            return nil
        }
        var stagedQueue = queue
        guard case .success = stagedQueue.enqueue(plan.step, running: plan.state.transaction.running,
                                                   lease: lease.token, restoreAttempt: admission?.attempt) else {
            return nil
        }
        if admission != nil, !deferredDiscards.isEmpty {
            guard case .success = stagedQueue.enqueue(effects: deferredDiscards.map(ActivationEffect.discard)) else {
                return nil
            }
        }
        return stagedQueue
    }

    /// Completes only the exact restore admitted to the engine under the current lease.
    /// Success clears the record, updates a recovering lifecycle, and owes an unmute
    /// only if the engine was muted; it never bumps the host context.
    mutating func restoreCompleted(
        attempt: RestoreAttemptID, revision: ContractRevision, prepared: PreparedActivationID?,
        token: EngineLeaseToken
    ) -> Result<EngineLifecycle, HostAuthorityRefusal> {
        guard let record = restoring, record.delivered,
              record.attempt == attempt,
              record.revision == revision, record.prepared == prepared, record.token == token,
              let held = registry.snapshot, held.project == record.project, held.token == token,
              var state = projects[record.project] else {
            return .failure(.staleRestore)
        }
        restoring = nil
        if state.lifecycle == .recovering {
            state.lifecycle = state.transaction.running.prepared == nil ? .stopped : .running
        }
        projects[record.project] = state
        if outputsMuted {
            pendingOutput = false
            outputsMuted = false
        }
        return .success(state.lifecycle)
    }

    /// D-auto: try a recovery transition, discarding nothing on any refusal.
    mutating func resumeRecovery(of project: ProjectID) {
        guard projects[project]?.lifecycle == .recovering else { return }
        _ = resolveRecovery(project: project)
    }

    /// A lease grant or removal invalidates the restore; its queued dependent discards
    /// are held until a restore under the next current token is queued.
    mutating func leaseChanged() {
        if let record = restoring, !record.discardAfterRestore.isEmpty {
            let extracted = queue.extractDiscards(Set(record.discardAfterRestore))
            if !extracted.isEmpty {
                deferredRestoreDiscards[record.project, default: []].append(contentsOf: extracted)
            }
        }
        restoring = nil
    }

    /// Retires a discard dependency when that command leaves the FIFO for delivery.
    mutating func retireRestoreDiscard(_ prepared: PreparedActivationID) {
        guard var record = restoring,
              let index = record.discardAfterRestore.firstIndex(of: prepared) else { return }
        record.discardAfterRestore.remove(at: index)
        restoring = record
    }

    /// D-auto is project-scoped; Rule G is intentionally deferred to H5d-2b.
    mutating func leaseGranted(to project: ProjectID) {
        resumeRecovery(of: project)
    }

    /// Marks only an exact, undelivered restore under the current lease as delivered.
    mutating func admitRestore(_ command: EngineCommand) -> Bool {
        guard case .restore(let attempt, let revision, let prepared, let token) = command,
              var record = restoring, !record.delivered,
              record.attempt == attempt,
              record.revision == revision, record.prepared == prepared, record.token == token,
              let held = registry.snapshot, held.project == record.project, held.token == token else {
            return false
        }
        record.delivered = true
        restoring = record
        return true
    }

    private static func requestsMute(_ decision: RecoveryDecision) -> Bool {
        if case .recover(muteOutputs: true) = decision { return true }
        return false
    }

    private static func requestsRestore(_ decision: RecoveryDecision) -> Bool {
        if case .restorePrevious = decision { return true }
        return false
    }

    private func recoveryPlan(for state: HostProjectState,
                              lease: EngineLeaseSnapshot) -> Result<HostRecoveryPlan, ActivationRefusal> {
        switch state.transaction.phase {
        case .commitFailed where !outputsMuted:
            // The direct, unmuted commit-failure recovery path is deferred to H5d-2b.
            return .failure(.unexpectedPhase(state.transaction.phase))
        case .commitFailed, .recovering, .partial:
            return transactionRecoveryPlan(state, lease: lease)
        default:
            guard state.lifecycle == .recovering else {
                return .failure(.unexpectedPhase(state.transaction.phase))
            }
            let step = ActivationRecoveryStep(
                cause: .leaseLost,
                decisions: [.restorePrevious(state.transaction.running.revision)],
                effects: []
            )
            let result = RecoveryResolution.restoring(state.transaction.running.revision)
            return .success(HostRecoveryPlan(state: state, step: step, resolution: result, failClosed: false))
        }
    }

    private func transactionRecoveryPlan(_ current: HostProjectState, lease: EngineLeaseSnapshot)
    -> Result<HostRecoveryPlan, ActivationRefusal> {
        var state = current
        guard let attempt = state.transaction.lastAttempt else { return .failure(.staleReport) }
        let firstStep: ActivationRecoveryStep
        switch state.transaction.resolveRecovery(attempt, lease: lease) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let resolved): firstStep = resolved
        }
        let failClosed = firstStep.decisions.contains(where: Self.requestsMute)
        let step: ActivationRecoveryStep
        if failClosed {
            // A partial plan that cannot be kept (or cannot advance the
            // revision) first fails closed, then resolves the new recovery.
            state.lifecycle = .recovering
            switch state.transaction.resolveRecovery(attempt, lease: lease) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let restored): step = restored
            }
        } else {
            step = firstStep
        }
        if !failClosed, step.decisions.contains(.keepActivePartial), state.lifecycle == .stopped {
            state.lifecycle = .running
        }
        let resolution: RecoveryResolution
        if step.decisions.contains(where: Self.requestsRestore) {
            resolution = .restoring(state.transaction.running.revision)
        } else {
            resolution = .keptPartial(state.transaction.running.revision)
        }
        return .success(HostRecoveryPlan(state: state, step: step, resolution: resolution,
                                         failClosed: failClosed))
    }
}
