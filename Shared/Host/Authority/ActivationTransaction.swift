//
//  ActivationTransaction.swift
//  FluxKlang
//
//  The prepare/review/authorize/commit/acknowledge state machine for one
//  project's activations. It performs nothing: each transition returns the
//  effects its owner must perform, so a refused step emits no `.prepare` or
//  `.commit` effect, that is, no write. Every refusal leaves the transaction unchanged.
//

enum PreparedActivationTag: ContractIDTag {}
/// The engine's name for a prepared, not yet committed plan.
typealias PreparedActivationID = ContractID<PreparedActivationTag>

/// Why the engine could not prepare a validated activation.
enum PrepareFailure: Error, Hashable, Sendable {
    case engineRefused
    case capabilityLost(CapabilityID)
    case cancelled
}

/// One `.commit` effect. Only `ActivationTransaction` creates one: do not add
/// initializers in other files. It pairs the issuing transaction's identity with
/// a bounded, monotonic counter, so a report from an earlier attempt (even of a
/// reused prepared ID, or from another transaction) never matches the current one.
struct CommitAttemptID: Hashable, Sendable {
    fileprivate final class Identity: Hashable, Sendable {
        static func == (lhs: Identity, rhs: Identity) -> Bool { lhs === rhs }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }

    fileprivate let issuer: Identity
    /// Compared for equality only, together with the issuer.
    let generation: Generation
    // The memberwise initializer is fileprivate because `issuer` is.

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.issuer === rhs.issuer && lhs.generation == rhs.generation
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(issuer))
        hasher.combine(generation)
    }
}

/// One `.prepare` effect, built like `CommitAttemptID`: only
/// `ActivationTransaction` creates one, from its own identity and a separate
/// bounded counter, so a delayed, duplicate or other transaction's prepare
/// response never matches the current one.
struct PrepareAttemptID: Hashable, Sendable {
    fileprivate let issuer: CommitAttemptID.Identity
    /// Compared for equality only, together with the issuer.
    let generation: Generation
    // The memberwise initializer is fileprivate because `issuer` is.

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.issuer === rhs.issuer && lhs.generation == rhs.generation
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(issuer))
        hasher.combine(generation)
    }
}

/// The engine's plan-level verdict on a commit. `resolveRecovery` acts on
/// `.failed` and `.partial`; a missing report is `abandonCommit(_:reason:)`.
enum ActivationCommitOutcome: Hashable, Sendable {
    /// Every planned node is applied; the plan is now running.
    case succeeded
    /// The plan did not take effect, including failing to replace the running
    /// graph with an empty plan.
    case failed
    /// Some planned nodes are applied and some are not.
    case partial
}

/// What the engine reports after performing a `.commit` effect.
struct ActivationCommitReport: Hashable, Sendable {
    let prepared: PreparedActivationID
    /// The attempt named by the `.commit` effect being reported.
    let attempt: CommitAttemptID
    let outcome: ActivationCommitOutcome
    let applied: Set<NodeID>
    /// Empty when the whole plan was applied.
    let unapplied: Set<NodeID>

    /// Whether the node sets split exactly `planned` and agree with `outcome`:
    /// `.succeeded` leaves nothing unapplied, `.failed` applies nothing and
    /// `.partial` has both applied and unapplied nodes. Anything else fails closed.
    func isConsistent(with planned: Set<NodeID>) -> Bool {
        guard applied.isDisjoint(with: unapplied), applied.union(unapplied) == planned else { return false }
        switch outcome {
        case .succeeded: return unapplied.isEmpty
        case .failed: return applied.isEmpty
        case .partial: return !applied.isEmpty && !unapplied.isEmpty
        }
    }
}

enum ActivationEffect: Hashable, Sendable {
    case prepare(ValidatedActivation, PrepareAttemptID)
    case commit(PreparedActivationID, CommitAttemptID, EngineLeaseToken)
    case discard(PreparedActivationID)
}

enum ActivationPhase: Hashable, Sendable {
    case idle
    case preparing
    case awaitingReview
    case committing
    case acknowledged(ContractRevision)
    /// The commit of the named plan was partly applied. The running graph is
    /// unchanged until `resolveRecovery`.
    case partial(PreparedActivationID, applied: Set<NodeID>, unapplied: Set<NodeID>)
    /// The commit of the named plan failed. The running graph and revision are
    /// unchanged until `resolveRecovery`.
    case commitFailed(PreparedActivationID)
    case prepareFailed(PrepareFailure)
    /// The named plan's commit was abandoned (outcome unknown, revision overflow
    /// or lease lost) and outputs are muted; `resolveRecovery` restores the running graph.
    case recovering(PreparedActivationID)
}

/// What the engine is running. Changes only when a commit is fully acknowledged
/// or a partial commit is kept by `resolveRecovery`.
struct RunningGraph: Hashable, Sendable {
    let revision: ContractRevision
    let prepared: PreparedActivationID?
}

/// The live state a prepared plan is checked against at commit.
struct ActivationLiveContext: Hashable, Sendable {
    let activation: ActivationContext
    /// The caller's ledger generation for `EngineLeaseRegistry.contextKey`.
    /// Every lease grant, transfer or release bumps it.
    let engine: Generation
}

/// Why a transition was refused. Validation failures keep their H1 reason.
enum ActivationRefusal: Error, Hashable, Sendable {
    case rejected(ActivationRejection)
    /// `begin` while a transaction is preparing, awaiting review or committing.
    case busy
    case unexpectedPhase(ActivationPhase)
    /// The live context is not byte-identical to the one the plan was validated
    /// in (see `commit`), or its active revision is not the running revision.
    case staleContext
    case authorizationInvalid(AuthorizationDefect)
    case leaseNotHeld
    case leaseHeldByOtherProject(ProjectID)
    /// The report names another attempt than the current commit's.
    case staleReport
    /// The prepare response names another attempt than the current `.prepare`'s.
    case stalePrepareResponse
    /// The report names another plan, or its node sets do not split exactly
    /// the plan's nodes consistently with its outcome.
    case reportMismatch
    /// The engine named a prepared plan with the running graph's plan ID.
    case preparedIDInUse
    /// The authorization nonce, the commit attempt or the running revision cannot advance.
    case overflow
}

/// One project's activation transaction. Sendable does not provide
/// synchronization; the owner (the H5 actor) serializes access and owns the
/// only copy, so a discarded copy's effects must never be performed. Value
/// copies share the commit-attempt identity and `lastAttempt`, so exactly one
/// copy (the H5 owner) may issue commits: diverged copies would issue matching
/// attempt IDs.
struct ActivationTransaction: Hashable, Sendable {
    private struct Plan: Hashable, Sendable {
        let validated: ValidatedActivation
        let engine: Generation
        let prepareAttempt: PrepareAttemptID
        var prepared: PreparedActivationID?
        var attempt: CommitAttemptID?
    }

    let project: ProjectID
    private(set) var running: RunningGraph
    private(set) var phase: ActivationPhase = .idle
    private(set) var authorizer: ActivationAuthorizer
    /// The last issued commit attempt; attempts never repeat within the one
    /// copy that issues commits. Value copies share it with the identity below.
    private(set) var lastAttempt: CommitAttemptID?
    /// The lease `lastAttempt` was issued under; a partial plan is kept only under it.
    private var commitLease: EngineLeaseToken?
    /// Issues this transaction's commit attempts. Value copies share it, so
    /// only the H5 owner's copy may commit; a diverged copy would issue an
    /// attempt ID equal to the owner's.
    private let attempts = CommitAttemptID.Identity()
    /// The last issued prepare attempt, under the same identity and copy rule.
    private(set) var lastPrepareAttempt: PrepareAttemptID?
    private var plan: Plan?

    /// The `resuming` arguments are for diagnostics and test continuity only.
    /// `lastAttempt` is a generation: this transaction's attempts carry its own
    /// identity, so they never equal another instance's.
    init(project: ProjectID, running: RunningGraph, resumingAfterNonce lastNonce: Generation? = nil,
         resumingAfterAttempt lastAttempt: Generation? = nil,
         resumingAfterPrepareAttempt lastPrepare: Generation? = nil) {
        self.project = project
        self.running = running
        authorizer = ActivationAuthorizer(resumingAfter: lastNonce)
        if let lastAttempt { self.lastAttempt = CommitAttemptID(issuer: attempts, generation: lastAttempt) }
        if let lastPrepare { lastPrepareAttempt = PrepareAttemptID(issuer: attempts, generation: lastPrepare) }
    }

    /// The plan being prepared, reviewed or committed.
    var validated: ValidatedActivation? { plan?.validated }

    /// Validates `request` against the live context and, if it passes, asks
    /// the owner to prepare it under a new prepare attempt. Checks: busy, context
    /// revision, H1 validation, then the attempt counter (`overflow`).
    /// A `.partial`, `.commitFailed` or `.recovering` commit must be resolved first.
    mutating func begin(
        _ request: ActivationRequest, candidate: GraphDocument, in live: ActivationLiveContext
    ) -> Result<[ActivationEffect], ActivationRefusal> {
        switch phase {
        case .preparing, .awaitingReview, .committing: return .failure(.busy)
        case .partial, .commitFailed, .recovering: return .failure(.unexpectedPhase(phase))
        case .idle, .acknowledged, .prepareFailed: break
        }
        guard live.activation.activeRevision == running.revision else { return .failure(.staleContext) }
        switch ActivationValidator.validate(request, candidate: candidate, in: live.activation) {
        case .failure(let reason):
            return .failure(.rejected(reason))
        case .success(let validated):
            let next: Generation
            do { next = try lastPrepareAttempt?.generation.next() ?? .initial } catch { return .failure(.overflow) }
            let attempt = PrepareAttemptID(issuer: attempts, generation: next)
            lastPrepareAttempt = attempt
            plan = Plan(validated: validated, engine: live.engine, prepareAttempt: attempt)
            phase = .preparing
            return .success([.prepare(validated, attempt)])
        }
    }

    /// Records the engine's answer to the `.prepare` of `attempt`. Checks: phase,
    /// attempt (`stalePrepareResponse`), then content. A failure keeps the running graph.
    /// An ID equal to the running graph's plan is refused, so acknowledging can
    /// never discard the plan it installs.
    mutating func prepared(
        _ result: Result<PreparedActivationID, PrepareFailure>, attempt: PrepareAttemptID
    ) -> Result<[ActivationEffect], ActivationRefusal> {
        guard phase == .preparing, var current = plan else { return .failure(.unexpectedPhase(phase)) }
        guard attempt == current.prepareAttempt else { return .failure(.stalePrepareResponse) }
        switch result {
        case .success(let id):
            guard id != running.prepared else { return .failure(.preparedIDInUse) }
            current.prepared = id
            plan = current
            phase = .awaitingReview
        case .failure(let reason):
            plan = nil
            phase = .prepareFailed(reason)
        }
        return .success([])
    }

    /// Issues a single-use authorization for the reviewed plan. `origin` and
    /// `permission` come from the trusted gesture path and the live permission.
    mutating func authorize(
        origin: CommandOrigin, permission: PermissionFingerprint?
    ) -> Result<ActivationAuthorization, ActivationRefusal> {
        guard phase == .awaitingReview, let plan else { return .failure(.unexpectedPhase(phase)) }
        return authorizer.issue(for: plan.validated, origin: origin, permission: permission)
    }

    /// `lease` is the registry's current snapshot (nil when nothing holds it).
    /// Checks: phase, authorization, lease, then plan staleness: the live host
    /// epoch, active revision and engine generation must equal those validated,
    /// the live permission must be well formed and byte-identical to the
    /// request's, and the live capability document must have a byte-identical
    /// encoding (within its byte limit). Synthesized `==` is not enough: its
    /// strings compare by Unicode canonical equivalence. Last, the next commit
    /// attempt is issued (`overflow` if it cannot advance).
    mutating func commit(
        _ authorization: ActivationAuthorization, lease: EngineLeaseSnapshot?, context live: ActivationLiveContext
    ) -> Result<[ActivationEffect], ActivationRefusal> {
        guard phase == .awaitingReview, var plan, let prepared = plan.prepared else {
            return .failure(.unexpectedPhase(phase))
        }
        if let defect = authorizer.defect(of: authorization, for: plan.validated.request) {
            return .failure(.authorizationInvalid(defect))
        }
        guard let lease else { return .failure(.leaseNotHeld) }
        guard lease.project == project else { return .failure(.leaseHeldByOtherProject(lease.project)) }
        let reviewed = plan.validated.context
        guard live.activation.hostEpoch == reviewed.hostEpoch,
              live.activation.activeRevision == reviewed.activeRevision, live.engine == plan.engine,
              let permission = live.activation.permission, permission.isWellFormedForActivation,
              permission.matchesExactly(plan.validated.request.permission),
              let liveBytes = try? live.activation.capabilities.encoded(),
              let reviewedBytes = try? reviewed.capabilities.encoded(), liveBytes == reviewedBytes else {
            return .failure(.staleContext)
        }
        let next: Generation
        do { next = try lastAttempt?.generation.next() ?? .initial } catch { return .failure(.overflow) }
        let attempt = CommitAttemptID(issuer: attempts, generation: next)
        authorizer.revoke()
        lastAttempt = attempt
        commitLease = lease.token
        plan.attempt = attempt
        self.plan = plan
        phase = .committing
        return .success([.commit(prepared, attempt, lease.token)])
    }

    /// Withdraws a plan awaiting review and asks the owner to discard it.
    mutating func cancel() -> Result<[ActivationEffect], ActivationRefusal> {
        guard phase == .awaitingReview, let prepared = plan?.prepared else {
            return .failure(.unexpectedPhase(phase))
        }
        authorizer.revoke()
        plan = nil
        phase = .idle
        return .success([.discard(prepared)])
    }

    /// Records the engine's report on the current commit attempt (any other
    /// attempt is `staleReport`). It must name the plan and be consistent with
    /// the plan's nodes (`ActivationCommitReport.isConsistent(with:)`). Only
    /// `.succeeded` makes the plan the running graph, advancing the revision by
    /// one and discarding the plan it replaces; `.failed` and `.partial` leave
    /// the running graph and revision to `resolveRecovery`, without effects.
    /// If the revision cannot advance (`overflow`), the transaction stays
    /// `.committing` although the engine applied the plan; the exit is
    /// `abandonCommit(_:reason: .revisionOverflow)`.
    mutating func acknowledged(_ report: ActivationCommitReport) -> Result<[ActivationEffect], ActivationRefusal> {
        guard phase == .committing, let plan, let prepared = plan.prepared, let attempt = plan.attempt else {
            return .failure(.unexpectedPhase(phase))
        }
        guard report.attempt == attempt else { return .failure(.staleReport) }
        guard report.prepared == prepared,
              report.isConsistent(with: Set(plan.validated.graph.nodes.map(\.id))) else {
            return .failure(.reportMismatch)
        }
        switch report.outcome {
        case .succeeded: break
        case .failed:
            self.plan = nil
            phase = .commitFailed(prepared)
            return .success([])
        case .partial:
            self.plan = nil
            phase = .partial(prepared, applied: report.applied, unapplied: report.unapplied)
            return .success([])
        }
        let revision: ContractRevision
        do { revision = try running.revision.next() } catch { return .failure(.overflow) }
        let replaced = running.prepared
        running = RunningGraph(revision: revision, prepared: prepared)
        self.plan = nil
        phase = .acknowledged(revision)
        return .success(replaced.map { [.discard($0)] } ?? [])
    }

    /// Abandons the current commit attempt without a usable report: its outcome
    /// is unknown (timeout, lost report), its applied plan has no next revision,
    /// or the lease was lost. Never assumed successful. Allowed from `.committing`,
    /// and from `.commitFailed` or `.partial` for `.leaseLost` only. Checks: phase,
    /// then the attempt (`staleReport`); a `.revisionOverflow` claim is verified, and
    /// refused as `unexpectedPhase` while the revision can advance. Enters `.recovering` with muted outputs,
    /// without effects: the engine may still hold the plan, so `resolveRecovery`
    /// discards it. Later reports are refused.
    mutating func abandonCommit(
        _ attempt: CommitAttemptID, reason: CommitAbandonment
    ) -> Result<ActivationRecoveryStep, ActivationRefusal> {
        let prepared: PreparedActivationID
        switch phase {
        case .committing:
            guard let id = plan?.prepared else { return .failure(.unexpectedPhase(phase)) }
            prepared = id
        case .commitFailed(let id) where reason == .leaseLost, .partial(let id, _, _) where reason == .leaseLost:
            prepared = id
        default: return .failure(.unexpectedPhase(phase))
        }
        guard attempt == lastAttempt else { return .failure(.staleReport) }
        if reason == .revisionOverflow, (try? running.revision.next()) != nil {
            return .failure(.unexpectedPhase(phase))
        }
        plan = nil
        phase = .recovering(prepared)
        return .success(ActivationRecovery.enterRecovery(reason.event, running: running))
    }

    /// The sanctioned exit from `.commitFailed`, `.partial` and `.recovering`.
    /// Checks: phase, then the failing attempt (`lastAttempt`, else `staleReport`).
    /// A failed or abandoned plan is discarded and the running graph restored
    /// (`.idle`) only under this project's lease (any token, so reacquiring
    /// unblocks it), else `leaseNotHeld` / `leaseHeldByOtherProject`. A partial plan is
    /// kept as the next revision with its unapplied nodes as placeholders
    /// (`.acknowledged`) only while `lease` is still the commit's lease, and the
    /// revision can advance; otherwise it fails closed into muted `.recovering`,
    /// installing nothing and discarding nothing.
    mutating func resolveRecovery(
        _ attempt: CommitAttemptID, lease: EngineLeaseSnapshot?
    ) -> Result<ActivationRecoveryStep, ActivationRefusal> {
        let prepared: PreparedActivationID
        var unapplied: Set<NodeID>?
        switch phase {
        case .commitFailed(let id), .recovering(let id): prepared = id
        case .partial(let id, _, let missing): (prepared, unapplied) = (id, missing)
        default: return .failure(.unexpectedPhase(phase))
        }
        guard attempt == lastAttempt else { return .failure(.staleReport) }
        guard let unapplied else {
            guard let lease else { return .failure(.leaseNotHeld) }
            guard lease.project == project else { return .failure(.leaseHeldByOtherProject(lease.project)) }
            phase = .idle
            return .success(ActivationRecovery.restore(running, discarding: prepared))
        }
        guard let lease, lease.project == project, lease.token == commitLease else {
            phase = .recovering(prepared)
            return .success(ActivationRecovery.enterRecovery(.leaseLost, running: running))
        }
        guard let revision = try? running.revision.next() else {
            phase = .recovering(prepared)
            return .success(ActivationRecovery.enterRecovery(.revisionOverflow, running: running))
        }
        let step = ActivationRecovery.keepPartial(unapplied: unapplied, replacing: running)
        running = RunningGraph(revision: revision, prepared: prepared)
        phase = .acknowledged(revision)
        return .success(step)
    }

    /// Abandons the outstanding `.prepare` whose answer was lost. Checks: phase
    /// `.preparing`, then the attempt (`stalePrepareResponse`). Returns to `.idle`
    /// with no effects and no discard: the prepared ID is unknown to the transaction;
    /// H5 must discard any `.success` ID delivered with a refused or abandoned attempt.
    /// The late answer is refused (`unexpectedPhase`, then `stalePrepareResponse`
    /// once a new prepare is out).
    mutating func abandonPrepare(_ attempt: PrepareAttemptID) -> Result<[ActivationEffect], ActivationRefusal> {
        guard phase == .preparing, let current = plan?.prepareAttempt else { return .failure(.unexpectedPhase(phase)) }
        guard attempt == current else { return .failure(.stalePrepareResponse) }
        plan = nil
        phase = .idle
        return .success([])
    }
}
