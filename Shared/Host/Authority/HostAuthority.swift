//
//  HostAuthority.swift
//  FluxKlang
//
//  The one owner of a host's engine lease, its context counter, the live host
//  state and every project's activation transaction (#62 H5). Methods never
//  await: the engine pulls commands through `nextEngineCommand()` and answers
//  through actor methods. Every refusal leaves the whole actor state unchanged
//  (`snapshot()`). Each method is one actor turn running one `HostAuthorityBook`
//  transition, where its checks are documented.
//

actor HostAuthority {
    static let projectLimit = 16
    /// Abandoned attempts remembered for discarding their late success. When the
    /// FIFO is full, abandoning evicts the oldest: a success arriving later for an
    /// evicted attempt is `stalePrepareResponse` and is NOT discarded, so the engine
    /// may keep that plan (a bounded engine-side leak; H5d may add an engine reset
    /// that clears it). Abandons alone never make `begin` refuse.
    static let abandonedPrepareLimit = 64

    // Access audit (B1, #176 review). Isolation only forbids *synchronous* access
    // from outside the actor: module code may `await` a read of any internal
    // Sendable member or call any internal method, and a function taking
    // `isolated HostAuthority` may read and write internal stored properties
    // synchronously. Hence the only stored property is `book`, private to this
    // file: no lease, ledger, transaction, queue or bookkeeping is reachable from
    // another file, by `await` or isolation. `HostAuthorityBook` and
    // `HostProjectState` are not `Sendable` either. The methods below are the
    // whole API; module code reads state only through the inert `snapshot()` and
    // `lifecycle(of:window:)`.
    private var book: HostAuthorityBook

    /// Declares `EngineLeaseRegistry.contextKey` in `ledger` unless it already is.
    init(host ledger: GenerationLedger, live: HostLiveState) throws(GenerationLedgerError) {
        book = try HostAuthorityBook(host: ledger, live: live)
    }

    func snapshot() -> HostAuthoritySnapshot {
        book.snapshot()
    }

    /// What `window` of `project` observes.
    func lifecycle(of project: ProjectID, window: WindowID) -> EngineLifecycle? {
        book.lifecycle(of: project, window: window)
    }

    /// `HostAuthorityBook.open(project:running:lifecycle:)`.
    func open(project: ProjectID, running: RunningGraph,
              lifecycle: EngineLifecycle? = nil) -> Result<Void, HostAuthorityRefusal> {
        book.open(project: project, running: running, lifecycle: lifecycle)
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

    /// `HostAuthorityBook.begin(_:candidate:project:)`.
    func begin(_ request: ActivationRequest, candidate: GraphDocument,
               project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        book.begin(request, candidate: candidate, project: project)
    }

    /// `HostAuthorityBook.prepareAnswered(_:attempt:)`.
    func prepareAnswered(_ result: Result<PreparedActivationID, PrepareFailure>,
                         attempt: PrepareAttemptID) -> Result<PrepareAnswerOutcome, HostAuthorityRefusal> {
        book.prepareAnswered(result, attempt: attempt)
    }

    /// `HostAuthorityBook.abandonPrepare(project:)`.
    func abandonPrepare(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        book.abandonPrepare(project: project)
    }

    /// `HostAuthorityBook.cancel(project:)`.
    func cancel(project: ProjectID) -> Result<Void, HostAuthorityRefusal> {
        book.cancel(project: project)
    }

    /// `HostAuthorityBook.authorize(project:gesture:)`.
    func authorize(project: ProjectID,
                   gesture: ActivationGesture) -> Result<ActivationAuthorization, HostAuthorityRefusal> {
        book.authorize(project: project, gesture: gesture)
    }

    /// `HostAuthorityBook.commit(project:authorization:)`.
    func commit(project: ProjectID, authorization: ActivationAuthorization) -> Result<Void, HostAuthorityRefusal> {
        book.commit(project: project, authorization: authorization)
    }

    /// `HostAuthorityBook.abandonCommit(_:reason:)`.
    func abandonCommit(_ attempt: CommitAttemptID, reason: CommitAbandonment) -> Result<Void, HostAuthorityRefusal> {
        book.abandonCommit(attempt, reason: reason)
    }

    /// The delivery guard (`HostAuthorityBook.nextEngineCommand()`).
    func nextEngineCommand() -> EngineCommand? {
        book.nextEngineCommand()
    }
}
