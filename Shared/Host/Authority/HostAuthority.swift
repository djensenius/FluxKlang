//
//  HostAuthority.swift
//  FluxKlang
//
//  The one owner of a host's engine lease, its context counter, the live host
//  state and every project's activation transaction (#62 H5). Methods never
//  await. Legacy authorities expose engine commands/reports; prepare-only
//  authorities instead retain one real pending offline preparation privately.
//  Refusals preserve state; irreversible faults are explicitly separate results.
//

actor HostAuthority {
    static let projectLimit = 16
    /// A control-contract bound, not a runtime sizing conclusion. Lost answers
    /// retain capacity indefinitely; no abandoned FIFO evicts ownership.
    static let planCapacity = 64

    // Access audit (B1, #176 review). Isolation only forbids *synchronous* access
    // from outside the actor: module code may `await` a read of any internal
    // Sendable member or call any internal method, and a function taking
    // `isolated HostAuthority` may read and write internal stored properties
    // synchronously. Hence all ownership storage is private to this
    // file: no processor, lease, ledger, transaction or queue is reachable from
    // another file, by `await` or isolation. `HostAuthorityBook` and
    // `HostProjectState` are not `Sendable` either. The methods below are the
    // whole API; module code reads state only through the inert `snapshot()` and
    // `lifecycle(of:window:)`.
    private var book: HostAuthorityBook
    private let preparationLimits: AudioRoutingLimits?
    private var preparation: PendingPreparation?
    private var preparationFault: OwnedPreparationFault?

    /// Declares `EngineLeaseRegistry.contextKey` in `ledger` unless it already is.
    init(host ledger: GenerationLedger, live: HostLiveState,
         planCapacity: Int = HostAuthority.planCapacity) throws(HostAuthorityRefusal) {
        book = try HostAuthorityBook(host: ledger, live: live, planCapacity: planCapacity)
        preparationLimits = nil
    }

    /// Construction-only custody. Never produces successful prepare answers or
    /// bound plans. Unsupported recovery work may remain blocked indefinitely.
    init(host ledger: GenerationLedger, live: HostLiveState, prepareOnly: AudioRoutingLimits,
         planCapacity: Int = HostAuthority.planCapacity) throws(HostAuthorityRefusal) {
        book = try HostAuthorityBook(host: ledger, live: live, planCapacity: planCapacity)
        preparationLimits = prepareOnly
    }

    func snapshot() -> HostAuthoritySnapshot {
        book.snapshot()
    }

    /// What `window` of `project` observes.
    func lifecycle(of project: ProjectID, window: WindowID) -> EngineLifecycle? {
        book.lifecycle(of: project, window: window)
    }

    /// `HostAuthorityBook.open(project:running:lifecycle:recoveryBase:)`.
    func open(project: ProjectID, running: RunningGraph,
              lifecycle: EngineLifecycle? = nil,
              recoveryBase: RunningSetState? = nil) -> Result<Void, HostAuthorityRefusal> {
        book.open(project: project, running: running, lifecycle: lifecycle, recoveryBase: recoveryBase)
    }

    /// `HostAuthorityBook.acquire(project:window:)`.
    func acquire(project: ProjectID, window: WindowID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        book.acquire(project: project, window: window)
    }

    /// `HostAuthorityBook.release(project:)`.
    func release(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        book.release(project: project)
    }

    /// `HostAuthorityBook.transfer(to:window:)`.
    func transfer(to project: ProjectID, window: WindowID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        book.transfer(to: project, window: window)
    }

    /// `HostAuthorityBook.attach(_:project:)`.
    func attach(_ window: WindowID, project: ProjectID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        book.attach(window, project: project)
    }

    /// `HostAuthorityBook.detach(_:)`.
    func detach(_ window: WindowID) -> Result<EngineLeaseSnapshot, HostAuthorityRefusal> {
        book.detach(window)
    }

    func updateLive(_ state: HostLiveState) {
        book.live = state
    }

    /// `HostAuthorityBook.begin(_:candidate:projectDocument:project:)`.
    func begin(_ request: ActivationRequest, candidate: GraphDocument,
               projectDocument: ProjectDocument, project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        guard preparationFault == nil else { return .failure(.preparationOwnerFaulted) }
        return book.begin(request, candidate: candidate, projectDocument: projectDocument, project: project)
    }

    /// `HostAuthorityBook.prepareAnswered(_:instance:attempt:)`.
    func prepareAnswered(_ result: Result<PreparedActivationID, PrepareFailure>,
                         instance: EngineInstanceID,
                         attempt: PrepareAttemptID) -> Result<PrepareAnswerOutcome, HostAuthorityRefusal> {
        guard preparationLimits == nil else { return .failure(.preparationOnly) }
        return book.prepareAnswered(result, instance: instance, attempt: attempt)
    }

    /// Truthful executor acknowledgement remains a G2 caller premise.
    func retired(_ binding: PlanBinding) -> Result<Void, HostAuthorityRefusal> {
        guard preparationLimits == nil else { return .failure(.preparationOnly) }
        return book.retired(binding)
    }

    /// `HostAuthorityBook.abandonPrepare(project:)`.
    func abandonPrepare(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        book.abandonPrepare(project: project)
    }

    /// `HostAuthorityBook.cancel(project:)`.
    func cancel(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        guard preparationLimits == nil else { return .failure(.preparationOnly) }
        return book.cancel(project: project)
    }

    /// `HostAuthorityBook.authorize(project:gesture:)`.
    func authorize(project: ProjectID,
                   gesture: ActivationGesture) -> Result<ActivationAuthorization, HostAuthorityRefusal> {
        guard preparationLimits == nil else { return .failure(.preparationOnly) }
        return book.authorize(project: project, gesture: gesture)
    }

    /// `HostAuthorityBook.commit(project:authorization:)`.
    func commit(project: ProjectID, authorization: ActivationAuthorization) -> Result<Void, HostAuthorityRefusal> {
        guard preparationLimits == nil else { return .failure(.preparationOnly) }
        return book.commit(project: project, authorization: authorization)
    }

    /// `HostAuthorityBook.abandonCommit(_:reason:)`.
    func abandonCommit(_ attempt: CommitAttemptID, reason: CommitAbandonment) -> Result<Void, HostAuthorityRefusal> {
        guard preparationLimits == nil else { return .failure(.preparationOnly) }
        return book.abandonCommit(attempt, reason: reason)
    }

    /// `HostAuthorityBook.leaseLost(_:)`.
    func leaseLost(_ token: EngineLeaseToken) -> Result<ProjectID, HostAuthorityRefusal> {
        book.leaseLost(token)
    }

    /// `HostAuthorityBook.capabilityLost(_:project:token:)`.
    func capabilityLost(
        _ capability: CapabilityID, project: ProjectID, token: EngineLeaseToken
    ) -> Result<Void, HostAuthorityRefusal> {
        book.capabilityLost(capability, project: project, token: token)
    }

    /// `HostAuthorityBook.resolveRecovery(project:)`.
    func resolveRecovery(project: ProjectID) -> Result<RecoveryResolution, HostAuthorityRefusal> {
        book.resolveRecovery(project: project)
    }

    /// D-auto recovery after the project acquires or reacquires the lease.
    func resumeRecovery(of project: ProjectID) {
        book.resumeRecovery(of: project)
    }

    /// `HostAuthorityBook.restoreCompleted(attempt:revision:target:token:)`.
    func restoreCompleted(
        attempt: RestoreAttemptID, revision: ContractRevision, target: RestoreTarget,
        token: EngineLeaseToken
    ) -> Result<EngineLifecycle, HostAuthorityRefusal> {
        guard preparationLimits == nil else { return .failure(.preparationOnly) }
        return book.restoreCompleted(attempt: attempt, revision: revision, target: target, token: token)
    }

    /// `HostAuthorityBook.commitReported(_:)`.
    func commitReported(_ report: ActivationCommitReport) -> Result<CommitReportOutcome, HostAuthorityRefusal> {
        guard preparationLimits == nil else { return .failure(.preparationOnly) }
        return book.commitReported(report)
    }

    /// The delivery guard (`HostAuthorityBook.nextEngineCommand()`).
    func nextEngineCommand() -> EngineCommand? {
        // In closed mode nil is NOT an assertion that the queue is empty.
        guard preparationLimits == nil else { return nil }
        return book.nextEngineCommand()
    }

    /// One nonsuspending turn reserves the empty slot before pulling exactly
    /// the admitted FIFO head. No command accepted from a caller can execute.
    func constructNextPreparation() -> OwnedPreparationStep {
        guard let limits = preparationLimits else { return .refused(.legacyMode) }
        guard preparationFault == nil else { return .refused(.faulted) }
        guard book.pendingOutput == nil else { return .refused(.blocked) }
        guard preparation?.identity == nil else { return .refused(.occupied) }
        guard let head = book.queue.pending.first else { return .empty }
        guard case .prepare(_, _, let instance, let attempt) = head else { return .refused(.blocked) }
        let identity = HostPrepare(instance: instance, attempt: attempt)
        guard let entry = book.plans.snapshot().records.first(where: { $0.instance == instance })?
            .entries.first(where: { $0.attempt == attempt }),
              case .pending(let reclaim) = entry.state else {
            return latchConstructionFault(.missingAdmission(identity))
        }
        // Empty slot + actor isolation reserve real capacity for this entire
        // turn. No suspension/reentrancy exists between this check and storage.
        // No success report can create bound entries: retirement refill is inert.
        guard let delivered = book.nextEngineCommand(), delivered == head,
              case .prepare(let graph, let project, _, _) = delivered else {
            return latchConstructionFault(.unexpectedDelivery(identity))
        }
        if reclaim { return terminatePreparation(identity, reason: .cancelled) }
        do {
            let resource = try PendingPreparation(identity: identity, project: project, graph: graph, limits: limits)
            let layout = resource.layout
            preparation = consume resource
            return .retained(identity, layout)
        } catch {
            // The throwing initializer has fully unwound before the failure ACK.
            return terminatePreparation(identity, reason: .engineRefused)
        }
    }

    /// Full fixed-stride geometry is checked before any output allocation.
    /// All borrows are synchronous, local and disjoint; no pointer escapes.
    func evaluatePreparation(
        _ expected: HostPrepare, frames: Int, input: [Float]
    ) -> Result<OwnedPreparationBlock, OwnedPreparationRefusal> {
        guard preparationLimits != nil else { return .failure(.legacyMode) }
        guard preparationFault == nil else { return .failure(.faulted) }
        guard let identity = preparation?.identity else { return .failure(.missing) }
        guard identity == expected else { return .failure(.identityMismatch) }
        guard book.outstanding.values.contains(identity) else { return .failure(.unwanted) }
        guard book.pendingOutput == nil, !book.outputsMuted, book.restoring == nil,
              book.queue.isEmpty, book.retirementOutbox.isEmpty, book.deferredRestoreDiscards.isEmpty else {
            return .failure(.blocked)
        }
        guard let layout = preparation?.layout else { return .failure(.missing) }
        guard frames >= 0, frames <= layout.maxFrames else { return .failure(.invalidFrames) }
        guard input.count == layout.inputSampleCount else { return .failure(.invalidInputGeometry) }
        guard let block = preparation?.evaluate(frames: frames, input: input) else { return .failure(.missing) }
        return .success(block)
    }

    /// Explicit disposal with a strongly alive authority is the qualified
    /// control-side path. Last-reference ARC destruction is NOT qualified
    /// teardown and sends no answer, callback or quiescence acknowledgement.
    func disposePreparation(_ expected: HostPrepare) -> OwnedPreparationDisposal {
        guard preparationLimits != nil else { return .refused(.legacyMode) }
        guard let identity = preparation?.identity else { return .refused(.missing) }
        guard identity == expected else { return .refused(.identityMismatch) }
        Self.destroyPreparation(preparation.take())
        // Only inert identity survives the consuming cleanup scope above.
        switch book.prepareAnswered(.failure(.cancelled), instance: identity.instance, attempt: identity.attempt) {
        case .success(let outcome): return .disposed(outcome)
        case .failure(let refusal):
            let fault = OwnedPreparationFault.terminalAfterCleanup(identity, refusal)
            preparationFault = fault
            return .faultAfterCleanup(fault)
        }
    }

    private static func destroyPreparation(_ resource: consuming PendingPreparation?) {
        _ = consume resource
    }

    private func latchConstructionFault(_ fault: OwnedPreparationFault) -> OwnedPreparationStep {
        preparationFault = fault
        return .faulted(fault)
    }

    private func terminatePreparation(_ identity: HostPrepare, reason: PrepareFailure) -> OwnedPreparationStep {
        switch book.prepareAnswered(.failure(reason), instance: identity.instance, attempt: identity.attempt) {
        case .success(let outcome): return .terminated(identity, reason, outcome)
        case .failure(let refusal):
            return latchConstructionFault(.terminalAfterCleanup(identity, refusal))
        }
    }
}

/// Concrete, noncopyable custody confined to the actor's defining file. There
/// is no supplied backend, processor, closure, replacement or resource accessor.
private struct PendingPreparation: ~Copyable {
    let identity: HostPrepare
    private var processor: OfflineAudioRoutingProcessor

    var layout: AudioRoutingLayout { processor.layout }

    init(identity: HostPrepare, project: ProjectDocument, graph: GraphDocument, limits: AudioRoutingLimits) throws {
        self.identity = identity
        processor = try OfflineAudioRoutingProcessor(project: project, selectedGraph: graph, limits: limits)
    }

    mutating func evaluate(frames: Int, input: [Float]) -> OwnedPreparationBlock {
        let layout = processor.layout
        var output = [Float](repeating: 0, count: layout.outputSampleCount)
        var peaks = [Float](repeating: 0, count: layout.peakCount)
        let result = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                peaks.withUnsafeMutableBufferPointer { meters in
                    processor.process(frames: frames, input: source, output: destination, peaks: meters)
                }
            }
        }
        return OwnedPreparationBlock(layout: layout, result: result, output: output, peaks: peaks)
    }
}
