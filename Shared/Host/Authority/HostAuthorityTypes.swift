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
    /// A recovery base was supplied for a nonrecovering project or without its running plan.
    case invalidRecoveryBase
    case lease(EngineLeaseError)
    case ledger(GenerationLedgerError)
    case plans(EnginePlanLedgerRefusal)
    case unqualifiedResident
    case unboundPlan
    case retirementQueued
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
    /// `restoreCompleted` did not match the identified delivered restore under the current lease.
    case staleRestore
}

/// What became of an engine's answer to a `.prepare`.
enum PrepareAnswerOutcome: Hashable, Sendable {
    /// The issuing project's transaction accepted it.
    case routed
    /// An abandoned success consumed once, with qualified disposal scheduled.
    case reclaimed(PlanBinding)
    /// The transaction refused this success, but the answer was consumed and its
    /// resource retired. This is intentionally NOT a state-preserving refusal.
    case refusedReclaimed(PlanBinding, refusal: ActivationRefusal)
    /// An abandoned attempt's terminal, cleaned-up failure consumed once.
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
    /// What rendered before recovery started, if this lifecycle carries that state.
    var recoveryRunningSet: RunningSetState? {
        switch self {
        case .stopped: .absent
        case .preparing(_, over: let runningSet): runningSet
        case .running: .running
        case .degraded(let lost): .degraded(lost)
        case .recovering, .heldByOther: nil
        }
    }

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

extension RunningSetState {
    var settledLifecycle: EngineLifecycle {
        switch self {
        case .absent: .stopped
        case .running: .running
        case .degraded(let lost): .degraded(lost)
        }
    }
}

/// The exact engine preparation, never a raw plan-name ownership lookup.
struct HostPrepare: Hashable, Sendable {
    let instance: EngineInstanceID
    let attempt: PrepareAttemptID
}

/// One open project: its only transaction copy and its engine lifecycle.
/// Deliberately NOT `Sendable`: the actor's `projects` dictionary then cannot
/// leave the actor, so even `await authority.projects[p]?.transaction` fails to
/// compile and no module caller can obtain a transition-capable transaction.
struct HostProjectState: Hashable {
    var transaction: ActivationTransaction
    /// What this project's windows on the lease observe (`EngineLifecycle.observed`).
    var lifecycle: EngineLifecycle
    /// The rendering/degradation base saved on first entry to recovery; `nil` outside recovery.
    var recoveryBase: RunningSetState?

    /// Preserve the first pre-recovery rendering state across repeated recovery entries.
    mutating func enterRecovery() {
        if lifecycle != .recovering {
            recoveryBase = lifecycle.recoveryRunningSet
        }
        lifecycle = .recovering
    }
    /// Retained through failed/partial reports until H5d resolves ownership.
    var reviewed: PlanBinding?
    var installed: PlanBinding?
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
    /// Saved rendering/degradation state during recovery; `.absent` for an unknown imported baseline.
    let recoveryBase: RunningSetState?
    let reviewed: PlanBinding?
    let installed: PlanBinding?
    let record: TransactionRecord

    /// Internal so the actor can build its snapshot; `TransactionRecord.init`
    /// stays `fileprivate` to this file, so this is the only way to make a record.
    init(_ state: HostProjectState) {
        phase = state.transaction.phase
        running = state.transaction.running
        lastPrepareAttempt = state.transaction.lastPrepareAttempt
        lastCommitAttempt = state.transaction.lastAttempt
        lifecycle = state.lifecycle
        recoveryBase = state.recoveryBase
        reviewed = state.reviewed
        installed = state.installed
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
    let outstanding: [ProjectID: HostPrepare]
    let plans: EnginePlanLedgerSnapshot
    let retirementOutbox: [PlanBinding]
    let queue: EngineCommandQueue
    /// Commits delivered to the engine and not yet reported, by project.
    let inFlight: [ProjectID: CommitAttemptID]
    /// The window whose gesture authorized each project's outstanding authorization.
    let authorizedWindows: [ProjectID: WindowID]
    /// The fail-closed output lane: `true` while a mute is owed, delivered before the FIFO.
    let pendingOutput: Bool?
    /// Whether the engine's outputs are muted (engine-global: one engine per host).
    let outputsMuted: Bool
    /// The one uniquely identified restore queued or delivered under the current lease.
    let restoring: RestoreRecord?
    /// Discards held until their project's next current-token restore is queued.
    let deferredRestoreDiscards: [ProjectID: [PlanBinding]]
}

/// Exact target for a restore in the current engine instance. Empty is qualified too.
enum RestoreTarget: Hashable, Sendable {
    case empty(EngineInstanceID)
    case resident(CommittedResident)

    var instance: EngineInstanceID {
        switch self {
        case .empty(let instance): instance
        case .resident(let resident): resident.binding.instance
        }
    }

    var prepared: PreparedActivationID? {
        switch self {
        case .empty: nil
        case .resident(let resident): resident.binding.prepared
        }
    }
}

/// One attempt to restore the running graph. Its retained object identity cannot
/// be reset or reused while an engine can still hold an acknowledgement.
struct RestoreAttemptID: Hashable, Sendable {
    private final class Identity: Sendable {}
    private let identity = Identity()

    init() {}

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity === rhs.identity }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(identity))
    }
}

/// One restore queued or delivered for the current lease. No API accepts a record.
struct RestoreRecord: Hashable, Sendable {
    let attempt: RestoreAttemptID
    let project: ProjectID
    let revision: ContractRevision
    let target: RestoreTarget
    let token: EngineLeaseToken
    var delivered: Bool
    /// Discards emitted after this restore, held back if its lease is invalidated.
    var discardAfterRestore: [PlanBinding]
}

/// What recovery resolution scheduled.
enum RecoveryResolution: Hashable, Sendable {
    case restoring(ContractRevision)
    case keptPartial(ContractRevision)
}
