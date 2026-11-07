/// Why a reprepare budget or a ledger step was refused.
enum ReprepareFault: Error, Hashable, Sendable {
    case invalidBudget(Int)
    case notPreparing(ReprepareStatus)
    /// The completion names `presented`, but the outstanding preparation is `current`: a late result of a superseded
    /// (or already completed) attempt. The ledger is left exactly as it was.
    case superseded(presented: ReprepareToken, current: ReprepareToken)
}

/// Names one off-render preparation attempt. Opaque: only a `.reprepare` decision of a `ReprepareLedger` issues it;
/// its serial grows with every issue and is never reused or rewound by a success, a live change or a silence.
/// Equality is the only operation: no ordering and no public init.
struct ReprepareToken: Hashable, Sendable {
    fileprivate let serial: Int
}

/// The most off-render prepare attempts one disturbance may consume, in `1...reprepareAttemptsCeiling`.
struct ReprepareBudget: Hashable, Sendable {
    let maximumAttempts: Int

    /// `RenderNegotiationLimits.reprepareAttemptsStandard` attempts.
    static let standard = ReprepareBudget(validated: RenderNegotiationLimits.reprepareAttemptsStandard)

    /// Throws `.invalidBudget` unless `maximumAttempts` is in `1...RenderNegotiationLimits.reprepareAttemptsCeiling`.
    init(maximumAttempts: Int) throws(ReprepareFault) {
        guard (1...RenderNegotiationLimits.reprepareAttemptsCeiling).contains(maximumAttempts) else {
            throw .invalidBudget(maximumAttempts)
        }
        self.maximumAttempts = maximumAttempts
    }

    private init(validated maximumAttempts: Int) {
        self.maximumAttempts = maximumAttempts
    }
}

/// The bounded reprepare-or-silence policy for unsupported live changes: count-bounded, terminal silence, no time.
///
/// Pure value: no clock, no sleeping (an adapter may add time backoff later). A frames, bus layout, format or sample
/// rate change moves a rendering ledger to `.preparing` and consumes an attempt; a change observed while already
/// preparing supersedes the pending prepare and consumes another, so a plugin that changes format on every callback
/// cannot loop forever. When the budget is spent the ledger is `.silenced`. `.silenced` is TERMINAL for a ledger
/// value: there is no recovery API here; an owner creates a new ledger after an explicit user action. A latency change
/// never forces a reprepare or silence. `attempts` never exceeds `budget.maximumAttempts`.
///
/// Every `.reprepare` decision issues a `ReprepareToken` (`pendingToken`) from `issued`, a count of tokens ever issued
/// by this ledger value's lineage that no success, supersession or silence ever rewinds. A completion is accepted only
/// for the exact outstanding token; anything else throws `.superseded` and changes nothing. A fresh
/// `ReprepareLedger.init(budget:)` is for an owner's FIRST ledger only: it starts a lineage at zero. A replacement
/// (for example after an explicit user action on a silenced ledger) MUST use `restarted()`, which keeps `issued`, so
/// tokens never repeat across a replacement and a late completion from the replaced ledger is always refused.
struct ReprepareLedger: Hashable, Sendable {
    let budget: ReprepareBudget
    let status: ReprepareStatus
    let attempts: Int
    let issued: Int
    /// The token of the one outstanding preparation; `nil` unless `status == .preparing`.
    let pendingToken: ReprepareToken?

    init(budget: ReprepareBudget) {
        self.init(budget: budget, status: .rendering, attempts: 0, issued: 0, pendingToken: nil)
    }

    private init(
        budget: ReprepareBudget, status: ReprepareStatus, attempts: Int, issued: Int, pendingToken: ReprepareToken?
    ) {
        self.budget = budget
        self.status = status
        self.attempts = attempts
        self.issued = issued
        self.pendingToken = pendingToken
    }

    /// Pure and total, legal from any status: a `.rendering` successor with zero attempts, the same budget, no
    /// outstanding token and the SAME `issued`, so no token is ever issued twice across a replacement. A completion
    /// carried over from the replaced ledger meets `.notPreparing` while the successor renders or is silenced, and
    /// `.superseded` once it has issued its own token.
    func restarted() -> ReprepareLedger {
        ReprepareLedger(budget: budget, status: .rendering, attempts: 0, issued: issued, pendingToken: nil)
    }

    /// Total and pure: the ledger after observing `change` and the decision for the owner.
    func observing(_ change: RenderLiveChange) -> ReprepareTransition {
        switch change {
        case .latency:
            return ReprepareTransition(ledger: self, decision: .invalidateDelayPlans)
        case .maximumFrames, .busLayout, .format, .sampleRate:
            if status == .silenced { return ReprepareTransition(ledger: self, decision: .remainSilent) }
            return escalated()
        }
    }

    /// Records the result of the off-render prepare issued as `token`.
    ///
    /// Throws `.notPreparing(status)` unless `status == .preparing`, then `.superseded` unless `token` is exactly
    /// `pendingToken`; a refused completion neither resumes, resets nor consumes the budget.
    func recordingPreparation(_ token: ReprepareToken, succeeded: Bool) throws(ReprepareFault) -> ReprepareTransition {
        guard status == .preparing, let current = pendingToken else { throw .notPreparing(status) }
        guard token == current else { throw .superseded(presented: token, current: current) }
        guard succeeded else { return escalated() }
        return ReprepareTransition(
            ledger: ReprepareLedger(
                budget: budget, status: .rendering, attempts: 0, issued: issued, pendingToken: nil),
            decision: .resume)
    }

    private func escalated() -> ReprepareTransition {
        let maximum = budget.maximumAttempts
        let next = issued.addingReportingOverflow(1)
        // The overflow arm is unreachable in practice (2^63 issues); kept for totality, it silences with the
        // same `.budgetExhausted` reason rather than reusing a serial.
        guard attempts < maximum, !next.overflow else {
            return ReprepareTransition(
                ledger: ReprepareLedger(
                    budget: budget, status: .silenced, attempts: attempts, issued: issued, pendingToken: nil),
                decision: .silence(.budgetExhausted(attempts: attempts, maximum: maximum)))
        }
        return ReprepareTransition(
            ledger: ReprepareLedger(
                budget: budget, status: .preparing, attempts: attempts + 1, issued: next.partialValue,
                pendingToken: ReprepareToken(serial: next.partialValue)),
            decision: .reprepare(attempt: attempts + 1))
    }
}
