//
//  HostAuthorityBook+Restore.swift
//  FluxKlang
//
//  Recovery under a held lease (#62 H5d-2): queue one qualified restore, admit
//  it only for the current lease and ledger instance, and unmute on exact ACK.
//

private struct HostRecoveryPlan {
    let state: HostProjectState
    let step: ActivationRecoveryStep
    let resolution: RecoveryResolution
    let failClosed: Bool
    let resident: CommittedResident?
    let target: RestoreTarget?
    let retiring: PlanBinding?
}

private struct RestoreAdmission {
    let record: RestoreRecord
}

extension HostAuthorityBook {
    /// Resolves `project`'s recovery under its held lease.
    /// Checks, in order: project open; lease held by this project; no restore or
    /// delivered commit already pending; room for the largest recovery step.
    /// Every refusal leaves the book and its canonical plan ledger unchanged.
    mutating func resolveRecovery(project: ProjectID) -> Result<RecoveryResolution, HostAuthorityRefusal> {
        guard let state = projects[project] else { return .failure(.unknownProject(project)) }
        guard let lease = registry.snapshot else { return .failure(.activation(.leaseNotHeld)) }
        guard lease.project == project else {
            return .failure(.activation(.leaseHeldByOtherProject(lease.project)))
        }
        guard restoring == nil, inFlight[project] == nil else { return .failure(.activation(.busy)) }
        guard queue.canAccept(EngineCommandQueue.maxRecoveryStepSlots) else { return .failure(.queueFull) }
        switch recoveryPlan(for: state, lease: lease) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let plan): return applyRecoveryPlan(plan, project: project, lease: lease)
        }
    }

    private mutating func applyRecoveryPlan(
        _ plan: HostRecoveryPlan, project: ProjectID, lease: EngineLeaseSnapshot
    ) -> Result<RecoveryResolution, HostAuthorityRefusal> {
        let deferred = deferredRestoreDiscards[project] ?? []
        if case .restoring = plan.resolution, plan.target == nil {
            return .failure(.unboundPlan)
        }
        guard let admission = makeRestoreAdmission(for: plan, project: project, lease: lease,
                                                   deferredDiscards: deferred) else {
            if !deferred.isEmpty { return .failure(.activation(.unexpectedPhase(plan.state.transaction.phase))) }
            return applyWithoutRestore(plan, project: project)
        }
        guard let stagedQueue = stagedRecoveryQueue(for: plan, lease: lease, admission: admission,
                                                    deferredDiscards: deferred) else {
            return .failure(.queueFull)
        }
        if let retiring = plan.retiring {
            do { try plans.release(retiring) } catch { return .failure(.plans(error)) }
        }
        queue = stagedQueue
        projects[project] = plan.state
        if plan.failClosed { failClosedMute() }
        restoring = admission.record
        deferredRestoreDiscards[project] = nil
        return .success(plan.resolution)
    }

    private mutating func applyWithoutRestore(
        _ plan: HostRecoveryPlan, project: ProjectID
    ) -> Result<RecoveryResolution, HostAuthorityRefusal> {
        guard retirementOutbox.isEmpty else { return .failure(.queueFull) }
        var stagedQueue = queue
        guard case .success = stagedQueue.enqueue(
            plan.step, running: plan.state.transaction.running, resident: plan.resident,
            retiring: plan.retiring, lease: registry.snapshot?.token
        ) else { return .failure(.queueFull) }
        if let retiring = plan.retiring {
            do { try plans.release(retiring) } catch { return .failure(.plans(error)) }
        }
        queue = stagedQueue
        projects[project] = plan.state
        if plan.failClosed { failClosedMute() }
        return .success(plan.resolution)
    }

    private func makeRestoreAdmission(
        for plan: HostRecoveryPlan, project: ProjectID, lease: EngineLeaseSnapshot,
        deferredDiscards: [PlanBinding]
    ) -> RestoreAdmission? {
        guard case .restoring(let revision) = plan.resolution, let target = plan.target else { return nil }
        var dependencies = plan.retiring.map { [$0] } ?? []
        var seen = Set(dependencies)
        let additional = deferredDiscards.filter { seen.insert($0).inserted }
        dependencies.append(contentsOf: additional)
        let record = RestoreRecord(attempt: RestoreAttemptID(), project: project, revision: revision,
                                   target: target, token: lease.token, delivered: false,
                                   discardAfterRestore: dependencies)
        return RestoreAdmission(record: record)
    }

    private func stagedRecoveryQueue(
        for plan: HostRecoveryPlan, lease: EngineLeaseSnapshot, admission: RestoreAdmission,
        deferredDiscards: [PlanBinding]
    ) -> EngineCommandQueue? {
        guard retirementOutbox.isEmpty else { return nil }
        var seenDiscards = Set<PlanBinding>()
        if let retiring = plan.retiring { seenDiscards.insert(retiring) }
        let additionalDiscards = deferredDiscards.filter { seenDiscards.insert($0).inserted }
        let needed = EngineCommandQueue.maxRecoveryStepSlots + additionalDiscards.count
        guard queue.canAccept(needed) else { return nil }
        var staged = queue
        guard case .success = staged.enqueue(
            plan.step, running: plan.state.transaction.running, resident: plan.resident,
            retiring: plan.retiring, lease: lease.token, restoreAttempt: admission.record.attempt,
            restoreTarget: admission.record.target
        ) else { return nil }
        let dependentCommands = additionalDiscards.map(EngineCommand.discard)
        guard case .success = staged.enqueue(dependentCommands) else { return nil }
        return staged
    }

    /// Completes only the exact restore admitted to the engine under the current lease.
    /// Success clears the record, updates a recovering lifecycle, and owes an unmute
    /// only if the engine was muted; it never bumps the host context.
    mutating func restoreCompleted(
        attempt: RestoreAttemptID, revision: ContractRevision, target: RestoreTarget,
        token: EngineLeaseToken
    ) -> Result<EngineLifecycle, HostAuthorityRefusal> {
        guard let record = restoring, record.delivered,
              record.attempt == attempt, record.revision == revision,
              record.target == target, record.token == token,
              target.instance == plans.currentInstance, targetIsCurrent(target),
              let held = registry.snapshot, held.project == record.project, held.token == token,
              var state = projects[record.project] else {
            return .failure(.staleRestore)
        }
        restoring = nil
        if state.lifecycle == .recovering {
            state.lifecycle = lifecycleAfterRestore(for: state)
            state.recoveryBase = nil
        }
        projects[record.project] = state
        if outputsMuted {
            pendingOutput = false
            outputsMuted = false
        }
        return .success(state.lifecycle)
    }

    private func lifecycleAfterRestore(for state: HostProjectState) -> EngineLifecycle {
        let base = state.recoveryBase ?? .absent
        switch state.transaction.phase {
        case .preparing, .awaitingReview:
            guard let revision = try? state.transaction.running.revision.next() else { return base.settledLifecycle }
            return .preparing(revision, over: base)
        default: return base.settledLifecycle
        }
    }

    private func targetIsCurrent(_ target: RestoreTarget) -> Bool {
        switch target {
        case .empty(let instance):
            return instance == plans.currentInstance
        case .resident(let resident):
            return resident.binding.instance == plans.currentInstance &&
                plans.attestCommitted(resident.binding) == resident
        }
    }

    /// D-auto: try a recovery transition, discarding nothing on any refusal.
    mutating func resumeRecovery(of project: ProjectID) {
        guard projects[project]?.lifecycle == .recovering else { return }
        _ = resolveRecovery(project: project)
    }

    /// A lease grant or removal invalidates the restore; dependent discards from
    /// both FIFO and retirement outbox wait until a restore under the next token.
    mutating func leaseChanged() {
        if let record = restoring {
            let selected = Set(record.discardAfterRestore)
            let queued = queue.extractDiscards(selected)
            let pending = extractRetirements(selected)
            let consumed = Set(queued + pending)
            let stillOwed = record.discardAfterRestore.filter(consumed.contains)
            if !stillOwed.isEmpty {
                var deferred = deferredRestoreDiscards[record.project] ?? []
                let additional = stillOwed.filter { !deferred.contains($0) }
                deferred.append(contentsOf: additional)
                deferredRestoreDiscards[record.project] = deferred
            }
        }
        restoring = nil
        refillRetirements()
    }

    private mutating func extractRetirements(_ bindings: Set<PlanBinding>) -> [PlanBinding] {
        var extracted: [PlanBinding] = []
        retirementOutbox.removeAll { binding in
            guard bindings.contains(binding) else { return false }
            extracted.append(binding)
            return true
        }
        return extracted
    }

    /// Retires a discard dependency when that exact command leaves the FIFO.
    mutating func retireRestoreDiscard(_ binding: PlanBinding) {
        guard var record = restoring,
              let index = record.discardAfterRestore.firstIndex(of: binding) else { return }
        record.discardAfterRestore.remove(at: index)
        restoring = record
    }

    /// D-auto is project-scoped; Rule G is intentionally deferred to H5d-2b.
    mutating func leaseGranted(to project: ProjectID) {
        resumeRecovery(of: project)
    }

    /// Marks only an exact, undelivered restore under the current lease and ledger instance.
    mutating func admitRestore(_ command: EngineCommand) -> Bool {
        guard case .restore(let attempt, let revision, let target, let token) = command,
              var record = restoring, !record.delivered,
              record.attempt == attempt, record.revision == revision,
              record.target == target, record.token == token,
              target.instance == plans.currentInstance, targetIsCurrent(target),
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

    private func recoveryPlan(
        for current: HostProjectState, lease: EngineLeaseSnapshot
    ) -> Result<HostRecoveryPlan, HostAuthorityRefusal> {
        switch current.transaction.phase {
        case .commitFailed where !outputsMuted:
            // The direct, unmuted commit-failure recovery path is deferred to H5d-2b.
            return .failure(.activation(.unexpectedPhase(current.transaction.phase)))
        case .commitFailed, .recovering, .partial:
            return transactionRecoveryPlan(current, lease: lease)
        default:
            guard current.lifecycle == .recovering else {
                return .failure(.activation(.unexpectedPhase(current.transaction.phase)))
            }
            let step = ActivationRecoveryStep(
                cause: .leaseLost,
                decisions: [.restorePrevious(current.transaction.running.revision)],
                effects: []
            )
            switch restoreRoles(for: current) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let roles):
                let result = RecoveryResolution.restoring(current.transaction.running.revision)
                return .success(HostRecoveryPlan(state: current, step: step, resolution: result,
                                                 failClosed: false, resident: roles.resident,
                                                 target: roles.target, retiring: nil))
            }
        }
    }

    private func transactionRecoveryPlan(
        _ current: HostProjectState, lease: EngineLeaseSnapshot
    ) -> Result<HostRecoveryPlan, HostAuthorityRefusal> {
        var state = current
        let resolution: (step: ActivationRecoveryStep, failClosed: Bool)
        switch recoveryStep(in: &state, lease: lease) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let resolved): resolution = resolved
        }
        if resolution.step.decisions.contains(.keepActivePartial) {
            return partialRecoveryPlan(state, original: current, step: resolution.step)
        }
        return restoringRecoveryPlan(state, step: resolution.step, failClosed: resolution.failClosed)
    }

    private func recoveryStep(
        in state: inout HostProjectState, lease: EngineLeaseSnapshot
    ) -> Result<(step: ActivationRecoveryStep, failClosed: Bool), HostAuthorityRefusal> {
        if case .commitFailed = state.transaction.phase, outputsMuted {
            state.enterRecovery()
        }
        guard let attempt = state.transaction.lastAttempt else { return .failure(.activation(.staleReport)) }
        let firstStep: ActivationRecoveryStep
        switch state.transaction.resolveRecovery(attempt, lease: lease) {
        case .failure(let refusal): return .failure(.activation(refusal))
        case .success(let resolved): firstStep = resolved
        }
        let failClosed = firstStep.decisions.contains(where: Self.requestsMute)
        let step: ActivationRecoveryStep
        if failClosed {
            state.enterRecovery()
            switch state.transaction.resolveRecovery(attempt, lease: lease) {
            case .failure(let refusal): return .failure(.activation(refusal))
            case .success(let restored): step = restored
            }
        } else {
            step = firstStep
        }
        return .success((step, failClosed))
    }

    private func partialRecoveryPlan(
        _ source: HostProjectState, original: HostProjectState, step: ActivationRecoveryStep
    ) -> Result<HostRecoveryPlan, HostAuthorityRefusal> {
        var state = source
        guard let binding = state.reviewed,
              binding.prepared == state.transaction.running.prepared else {
            return .failure(.unboundPlan)
        }
        guard let resident = plans.attestCommitted(binding),
              binding.instance == plans.currentInstance else { return .failure(.unboundPlan) }
        state.installed = binding
        state.reviewed = nil
        if state.lifecycle == .stopped { state.lifecycle = .running }
        let retiring: PlanBinding?
        switch discardRole(in: step, candidate: original.installed) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let binding): retiring = binding
        }
        let result = RecoveryResolution.keptPartial(state.transaction.running.revision)
        return .success(HostRecoveryPlan(state: state, step: step, resolution: result,
                                         failClosed: false, resident: resident, target: nil,
                                         retiring: retiring))
    }

    private func restoringRecoveryPlan(
        _ source: HostProjectState, step: ActivationRecoveryStep, failClosed: Bool
    ) -> Result<HostRecoveryPlan, HostAuthorityRefusal> {
        var state = source
        switch restoreRoles(for: state) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let roles):
            let retiring: PlanBinding?
            switch discardRole(in: step, candidate: state.reviewed) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let binding): retiring = binding
            }
            if retiring != nil { state.reviewed = nil }
            let result = RecoveryResolution.restoring(state.transaction.running.revision)
            return .success(HostRecoveryPlan(state: state, step: step, resolution: result,
                                             failClosed: failClosed, resident: roles.resident,
                                             target: roles.target, retiring: retiring))
        }
    }

    private func restoreRoles(
        for state: HostProjectState
    ) -> Result<(resident: CommittedResident?, target: RestoreTarget), HostAuthorityRefusal> {
        let running = state.transaction.running
        guard running.prepared == state.installed?.prepared else { return .failure(.unboundPlan) }
        guard let binding = state.installed else {
            guard running.prepared == nil else { return .failure(.unboundPlan) }
            let target = RestoreTarget.empty(plans.currentInstance)
            return .success((nil, target))
        }
        guard binding.instance == plans.currentInstance,
              let resident = plans.attestCommitted(binding) else { return .failure(.unboundPlan) }
        return .success((resident, .resident(resident)))
    }

    private func discardRole(
        in step: ActivationRecoveryStep, candidate: PlanBinding?
    ) -> Result<PlanBinding?, HostAuthorityRefusal> {
        let discards = step.effects.compactMap { effect -> PreparedActivationID? in
            if case .discard(let prepared) = effect { return prepared }
            return nil
        }
        guard discards.count == step.effects.count, discards.count <= 1 else {
            return .failure(.unboundPlan)
        }
        guard let discarded = discards.first else { return .success(nil) }
        guard let candidate, candidate.prepared == discarded else { return .failure(.unboundPlan) }
        return .success(candidate)
    }
}
