/// Why a reprepare budget or a ledger step was refused.
enum ReprepareFault: Error, Hashable, Sendable {
    case invalidBudget(Int)
    case notPreparing(ReprepareStatus)
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
struct ReprepareLedger: Hashable, Sendable {
    let budget: ReprepareBudget
    let status: ReprepareStatus
    let attempts: Int

    init(budget: ReprepareBudget) {
        self.init(budget: budget, status: .rendering, attempts: 0)
    }

    private init(budget: ReprepareBudget, status: ReprepareStatus, attempts: Int) {
        self.budget = budget
        self.status = status
        self.attempts = attempts
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

    /// Records the result of an off-render prepare; throws `.notPreparing(status)` unless `status == .preparing`.
    func recordingPreparation(succeeded: Bool) throws(ReprepareFault) -> ReprepareTransition {
        guard status == .preparing else { throw .notPreparing(status) }
        guard succeeded else { return escalated() }
        return ReprepareTransition(
            ledger: ReprepareLedger(budget: budget, status: .rendering, attempts: 0), decision: .resume)
    }

    private func escalated() -> ReprepareTransition {
        let maximum = budget.maximumAttempts
        guard attempts < maximum else {
            return ReprepareTransition(
                ledger: ReprepareLedger(budget: budget, status: .silenced, attempts: attempts),
                decision: .silence(.budgetExhausted(attempts: attempts, maximum: maximum)))
        }
        return ReprepareTransition(
            ledger: ReprepareLedger(budget: budget, status: .preparing, attempts: attempts + 1),
            decision: .reprepare(attempt: attempts + 1))
    }
}
