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
    private var preparationLifetime: OwnedPreparationLifetime = .vacant

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
        guard preparationLimits != nil else {
            return book.begin(request, candidate: candidate, projectDocument: projectDocument, project: project)
        }
        if let refusal = preparationLifetime.admissionRefusal { return .failure(refusal) }
        // Reserve before canonical admission can touch a transaction, attempt,
        // ledger or queue. A canonical refusal releases only this provisional charge.
        preparationLifetime = .provisional
        switch book.begin(request, candidate: candidate, projectDocument: projectDocument, project: project) {
        case .failure(let refusal):
            preparationLifetime = .vacant
            return .failure(refusal)
        case .success:
            guard let identity = book.outstanding[project],
                  book.plans.snapshot().records.first(where: { $0.instance == identity.instance })?
                    .entries.contains(where: {
                        $0.attempt == identity.attempt && $0.state == .pending(reclaim: false)
                    }) == true,
                  book.queue.pending.contains(where: {
                      if case .prepare(_, let document, let instance, let attempt) = $0 {
                          return document.id == project && instance == identity.instance &&
                              attempt == identity.attempt
                      }
                      return false
                  }) else {
                preparationLifetime = .faulted(.unassociatedAdmission)
                return .failure(.preparationAdmissionFault)
            }
            preparationLifetime = .queued(identity)
            return .success(())
        }
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

    /// One nonsuspending turn consumes its own reserved FIFO head. A queued
    /// reservation is not physical occupancy; callers cannot supply commands.
    func constructNextPreparation() -> OwnedPreparationStep {
        guard let limits = preparationLimits else { return .refused(.legacyMode) }
        guard preparationLifetime.fault == nil else { return .refused(.faulted) }
        guard book.pendingOutput == nil else { return .refused(.blocked) }
        guard preparation?.identity == nil else { return .refused(.occupied) }
        guard let head = book.queue.pending.first else { return .empty }
        return constructAdmittedPreparation(head, limits: limits)
    }

    private func constructAdmittedPreparation(_ head: EngineCommand, limits: AudioRoutingLimits)
    -> OwnedPreparationStep {
        guard case .prepare(_, _, let instance, let attempt) = head else { return .refused(.blocked) }
        guard case .queued(let identity) = preparationLifetime else {
            return latchConstructionFault(.unassociatedAdmission)
        }
        guard identity.instance == instance, identity.attempt == attempt else {
            return latchConstructionFault(.unexpectedDelivery(identity))
        }
        guard let entry = book.plans.snapshot().records.first(where: { $0.instance == instance })?
            .entries.first(where: { $0.attempt == attempt }),
              case .pending(let reclaim) = entry.state else {
            return latchConstructionFault(.missingAdmission(identity))
        }
        // The admitted lifetime remains charged throughout this nonsuspending turn.
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
            preparationLifetime = .held(identity)
            return .retained(identity, layout)
        } catch {
            // The throwing initializer has fully unwound before the failure ACK.
            return terminatePreparation(identity, reason: .engineRefused)
        }
    }

    /// Reclaim only privately retained custody with exact canonical abandonment
    /// evidence. One nonsuspending turn; queued work and other interest are untouched.
    func reclaimAbandonedPreparation() -> OwnedPreparationStep {
        guard preparationLimits != nil else { return .refused(.legacyMode) }
        guard preparationLifetime.fault == nil else { return .refused(.faulted) }
        guard let identity = preparation?.identity else { return .empty }
        guard let entry = book.plans.snapshot().records.first(where: { $0.instance == identity.instance })?
            .entries.first(where: { $0.attempt == identity.attempt }),
              case .pending(let reclaim) = entry.state else {
            return latchConstructionFault(.missingAdmission(identity))
        }
        let wanted = book.outstanding.values.contains(identity)
        if !reclaim && wanted { return .refused(.occupied) }
        guard reclaim && !wanted else { return .refused(.blocked) }
        switch disposePreparation(identity) {
        case .disposed(let outcome): return .terminated(identity, .cancelled, outcome)
        case .refused(let reason): return .refused(reason)
        case .faultAfterCleanup(let fault): return .faulted(fault)
        }
    }

    /// State, identity and full fixed-stride geometry are checked before staging,
    /// clearing persistent output or allocating independent result copies.
    /// All borrows are synchronous, local and disjoint; no pointer escapes.
    func evaluatePreparation(
        _ expected: HostPrepare, frames: Int, input: [Float]
    ) -> Result<OwnedPreparationBlock, OwnedPreparationRefusal> {
        guard preparationLimits != nil else { return .failure(.legacyMode) }
        guard preparationLifetime.fault == nil else { return .failure(.faulted) }
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
        guard preparationLifetime.fault == nil else { return .refused(.faulted) }
        guard let identity = preparation?.identity else { return .refused(.missing) }
        guard identity == expected else { return .refused(.identityMismatch) }
        Self.destroyPreparation(preparation.take())
        // Only inert identity survives the consuming cleanup scope above.
        preparationLifetime = .cleaned(identity)
        return accountPreparationFailure(.cancelled)
    }

    private static func destroyPreparation(_ resource: consuming PendingPreparation?) {
        _ = consume resource
    }

    private func latchConstructionFault(_ fault: OwnedPreparationFault) -> OwnedPreparationStep {
        preparationLifetime = .faulted(fault)
        return .faulted(fault)
    }

    private func terminatePreparation(_ identity: HostPrepare, reason: PrepareFailure) -> OwnedPreparationStep {
        preparationLifetime = .cleaned(identity)
        switch accountPreparationFailure(reason) {
        case .disposed(let outcome): return .terminated(identity, reason, outcome)
        case .refused(let refusal): return .refused(refusal)
        case .faultAfterCleanup(let fault): return .faulted(fault)
        }
    }

    private func accountPreparationFailure(_ reason: PrepareFailure) -> OwnedPreparationDisposal {
        guard let identity = preparationLifetime.terminalIdentity else { return .refused(.faulted) }
        let result = book.prepareAnswered(.failure(reason), instance: identity.instance, attempt: identity.attempt)
        return preparationLifetime.finishTerminal(result)
    }
}

/// Concrete, noncopyable custody confined to the actor's defining file. There
/// is no supplied backend, processor, closure, replacement or resource accessor.
private struct PendingPreparation: ~Copyable {
    /// Added sample payload only, separate from the original arena's 16 MiB ceiling.
    private static let maximumSampleStorageBytes = 16 * 1_024 * 1_024
    let identity: HostPrepare
    private var processor: OfflineAudioRoutingProcessor
    private let storage: UnsafeMutablePointer<Float>?
    private let sampleCount: Int
    private let outputRange: Range<Int>
    private let peakRange: Range<Int>

    var layout: AudioRoutingLayout { processor.layout }

    init(identity: HostPrepare, project: ProjectDocument, graph: GraphDocument, limits: AudioRoutingLimits) throws {
        let prepared = try OfflineAudioRoutingProcessor(project: project, selectedGraph: graph, limits: limits)
        // The compiler checks fixed-stride products. Check all added slab endpoints
        // and bytes before allocation, without another graph/coverage collection.
        let layout = prepared.layout
        let peakStart = try AudioRoutingAdmission.add(layout.inputSampleCount, layout.outputSampleCount)
        let end = try AudioRoutingAdmission.add(peakStart, layout.peakCount)
        let bytes = try AudioRoutingAdmission.multiply(end, MemoryLayout<Float>.stride)
        guard bytes <= Self.maximumSampleStorageBytes else { throw AudioRoutingPreparationError.resourceLimit }
        self.identity = identity
        processor = consume prepared
        outputRange = layout.inputSampleCount..<peakStart
        peakRange = peakStart..<end
        sampleCount = end
        // Control allocator exhaustion remains nonrecoverable, not a thrown error.
        // No fallible unowned step follows allocation. Empty payload needs no slab,
        // but keeps the same original arena/processor, including mute-only work.
        storage = end == 0 ? nil : UnsafeMutablePointer<Float>.allocate(capacity: end)
        storage?.initialize(repeating: 0, count: end)
    }

    deinit {
        // Existing consuming cleanup destroys this slab and the original processor
        // before terminal accounting. Fatal allocation failure promises neither.
        storage?.deinitialize(count: sampleCount)
        storage?.deallocate()
    }

    mutating func evaluate(frames: Int, input: [Float]) -> OwnedPreparationBlock {
        input.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, !source.isEmpty {
                storage?.update(from: base, count: source.count)
            }
        }
        let source = UnsafeBufferPointer(start: storage.map { UnsafePointer($0) }, count: outputRange.lowerBound)
        let output = UnsafeMutableBufferPointer(
            start: storage?.advanced(by: outputRange.lowerBound), count: outputRange.count
        )
        let peaks = UnsafeMutableBufferPointer(
            start: storage?.advanced(by: peakRange.lowerBound), count: peakRange.count
        )
        // Clear ALL padding, including zero-frame calls, just as fresh arrays did.
        // Staging, clearing and snapshot copies are outside maxSampleWork.
        output.baseAddress?.update(repeating: 0, count: output.count)
        let result = processor.process(frames: frames, input: source, output: output, peaks: peaks)
        return OwnedPreparationBlock(
            layout: processor.layout, result: result, output: Array(output), peaks: Array(peaks)
        )
    }
}
