//
//  HostAuthorityTypes.swift
//  FluxKlang
//
//  The values `HostAuthority` exchanges with its callers and exposes in its
//  snapshot (#62 H5). The snapshot is inert: it never contains a transaction.
//

/// The live host state every activation context is built from. Only the actor
/// combines it with a project's running revision; callers never supply a context.
struct HostLiveState: Hashable, Sendable {
    let hostEpoch: HostEpoch
    /// `nil` when no permission is currently granted.
    let permission: PermissionFingerprint?
    let capabilities: DeviceCapabilityDocument
}

/// The trusted gesture path's claim: who confirmed the commit, and in which
/// window. Forgeable until the UI wiring exists; never derived from the request.
struct ActivationGesture: Hashable, Sendable {
    let origin: CommandOrigin
    let window: WindowID
}

/// Why the actor refused. Every refusal leaves the actor state unchanged.
enum HostAuthorityRefusal: Error, Equatable, Sendable {
    /// The transaction's own refusal, unchanged.
    case activation(ActivationRefusal)
    case unknownProject(ProjectID)
    case projectAlreadyOpen(ProjectID)
    case projectLimit
    /// `open` resumes only a settled lifecycle consistent with the running graph.
    case lifecycleNotResumable(EngineLifecycle)
    case lease(EngineLeaseError)
    case ledger(GenerationLedgerError)
    /// The engine command queue cannot take the transition's commands; nothing moved.
    case queueFull
    /// Only a window that renders the project (`WindowRenderRole.renders`) may
    /// authorize, and it must still render it at commit.
    case windowCannotAuthorize(WindowRenderRole)
    /// The project's engine lifecycle refuses an activation change (`.recovering`).
    case lifecycleRejectsChanges(EngineLifecycle)
    /// Callers may only abandon a commit as `.outcomeUnknown`; the actor alone
    /// abandons for a lost lease, and revision overflow is refused at `begin`.
    case abandonmentReserved(CommitAbandonment)
}

/// What became of an engine's answer to a `.prepare`.
enum PrepareAnswerOutcome: Hashable, Sendable {
    /// The issuing project's transaction accepted it.
    case routed
    /// A success for an abandoned attempt, refused by the transaction with `refusal`:
    /// the engine's plan was queued for discard, exactly once.
    case discarded(PreparedActivationID, refusal: ActivationRefusal)
    /// An abandoned attempt's failure, or a success naming a live plan, or a plan
    /// whose discard is already queued: nothing to discard.
    case dropped
}

/// What an accepted engine commit report did (`HostAuthority.commitReported`).
enum CommitReportOutcome: Hashable, Sendable {
    /// The plan is now running at this revision; the plan it replaced is queued for discard.
    case acknowledged(ContractRevision)
    /// The plan did not take effect (`commitFailed`); H5d resolves it.
    case failed
    /// Only some nodes were applied (`partial`); H5d resolves it.
    case partial(unapplied: Set<NodeID>)
}

extension EngineLifecycle {
    /// The lifecycle once the engine acknowledged an activation: a preparation over
    /// nothing or a running graph renders `.running`; over a degraded graph it stays
    /// `.degraded` with the same lost capabilities; `.recovering` stays (fail closed:
    /// unmuting is H5d's). Any other state is not preparing and is kept.
    var acknowledgingActivation: EngineLifecycle {
        switch self {
        case .preparing(_, over: .absent), .preparing(_, over: .running): .running
        case .preparing(_, over: .degraded(let lost)): .degraded(lost)
        case .recovering, .stopped, .running, .degraded, .heldByOther: self
        }
    }
}

/// A prepare attempt `abandonPrepare` gave up on; its late success is discarded.
struct AbandonedPrepare: Hashable, Sendable {
    let attempt: PrepareAttemptID
    let project: ProjectID
}

/// One open project: its only transaction copy and its engine lifecycle.
/// Deliberately NOT `Sendable`: the actor's `projects` dictionary then cannot
/// leave the actor, so even `await authority.projects[p]?.transaction` fails to
/// compile and no module caller can obtain a transition-capable transaction.
struct HostProjectState: Hashable {
    var transaction: ActivationTransaction
    /// What this project's windows on the lease observe (`EngineLifecycle.observed`).
    var lifecycle: EngineLifecycle
    /// The plan the engine prepared for the current review; meaningful only
    /// while the transaction is awaiting review or committing.
    var reviewed: PreparedActivationID?
}

@available(*, unavailable, message: "a project's transaction never leaves HostAuthority")
extension HostProjectState: Sendable {}

/// A transaction kept inert for the snapshot: equality and hashing still cover
/// the whole transaction, so any change is detected, but nothing reads it back.
/// Only the actor's own copy may transition (the single-owner rule): a copy
/// handed out could issue commits with the same authorization and attempt IDs
/// outside the actor's queue.
struct TransactionRecord: Hashable, Sendable {
    private let transaction: ActivationTransaction

    fileprivate init(_ transaction: ActivationTransaction) {
        self.transaction = transaction
    }
}

/// One open project as the snapshot shows it: read-only diagnostics and an inert
/// record of its transaction, never the transaction itself.
struct HostProjectSnapshot: Hashable, Sendable {
    let phase: ActivationPhase
    let running: RunningGraph
    let lastPrepareAttempt: PrepareAttemptID?
    /// The last issued commit attempt, for routing `abandonCommit` and diagnostics.
    let lastCommitAttempt: CommitAttemptID?
    let lifecycle: EngineLifecycle
    let reviewed: PreparedActivationID?
    let record: TransactionRecord

    /// Internal so the actor can build its snapshot; `TransactionRecord.init`
    /// stays `fileprivate` to this file, so this is the only way to make a record.
    init(_ state: HostProjectState) {
        phase = state.transaction.phase
        running = state.transaction.running
        lastPrepareAttempt = state.transaction.lastPrepareAttempt
        lastCommitAttempt = state.transaction.lastAttempt
        lifecycle = state.lifecycle
        reviewed = state.reviewed
        record = TransactionRecord(state.transaction)
    }
}

/// The whole actor state, for refusal checks and diagnostics. It holds no
/// transaction (`HostProjectSnapshot`).
struct HostAuthoritySnapshot: Hashable, Sendable {
    let lease: EngineLeaseSnapshot?
    let lastIssuedLease: Generation?
    let ledger: [GenerationKey: Generation]
    let live: HostLiveState
    let projects: [ProjectID: HostProjectSnapshot]
    /// The one unanswered, not abandoned prepare of each preparing project.
    let outstanding: [ProjectID: PrepareAttemptID]
    /// Abandoned and unanswered, oldest first; at most `abandonedPrepareLimit`.
    let abandoned: [AbandonedPrepare]
    let queue: EngineCommandQueue
    /// Commits delivered to the engine and not yet reported, by project.
    let inFlight: [ProjectID: CommitAttemptID]
    /// The window whose gesture authorized each project's outstanding authorization.
    let authorizedWindows: [ProjectID: WindowID]
    /// The fail-closed output lane: `true` while a mute is owed, delivered before the FIFO.
    let pendingOutput: Bool?
    /// Whether the engine's outputs are muted (engine-global: one engine per host).
    let outputsMuted: Bool
}
