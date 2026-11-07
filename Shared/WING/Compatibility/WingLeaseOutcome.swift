/// The three possible verdicts of a restoration, decided by counts alone.
enum WingLeaseOutcomeKind: String, CaseIterable, Sendable {
    case verified
    case partial
    case unverified
}

/// The verdict of a restoration.
///
/// WING restoration is applied setting by setting and is NOT atomic: `verified` means every planned setting was
/// confirmed back, never that the console changed all at once. A restore that stops halfway is `partial` or
/// `unverified`, never silently complete, and abandoning a restore is `unverified`.
///
/// The wiring must turn a `WingApplyVerification` into `confirmedCount` like this: `.verified` is
/// `settings.count`; `.partiallyVerified` is `verification.confirmedCount`; `.failed` (the transport rejected a send)
/// is 0, conservatively, even if the echo of some address matched.
enum WingLeaseOutcome: Equatable, Sendable {
    case verified(plannedCount: Int)
    case partial(confirmedCount: Int, plannedCount: Int)
    case unverified(confirmedCount: Int, plannedCount: Int)

    var kind: WingLeaseOutcomeKind {
        switch self {
        case .verified: .verified
        case .partial: .partial
        case .unverified: .unverified
        }
    }

    /// Planned minus confirmed; 0 for `verified`.
    var unconfirmedCount: Int {
        switch self {
        case .verified: 0
        case let .partial(confirmed, planned), let .unverified(confirmed, planned): planned - confirmed
        }
    }

    /// Decided only by these counts, in this order: all confirmed is `verified`, at least one is `partial`, none is
    /// `unverified`.
    static func decide(confirmedCount: Int, plannedCount: Int) -> WingLeaseOutcome {
        if confirmedCount == plannedCount { return .verified(plannedCount: plannedCount) }
        if confirmedCount >= WingLeaseLimits.minimumCount {
            return .partial(confirmedCount: confirmedCount, plannedCount: plannedCount)
        }
        return .unverified(confirmedCount: confirmedCount, plannedCount: plannedCount)
    }
}
