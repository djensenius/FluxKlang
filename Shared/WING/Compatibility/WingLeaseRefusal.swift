/// The single typed reason a lease transition or a gate query was refused. A refusal never changes any state.
/// Payloads are counts, tick integers and closed enums only: never a setting address, value, host or text.
/// `readNotPermitted` is produced by `WingLeaseGate` only, never by `WingCompatibilityLease.applying`.
enum WingLeaseRefusal: Error, Equatable, Sendable {
    case notPermitted(phase: WingLeasePhase, event: WingLeaseEventKind)
    case readNotPermitted(phase: WingLeasePhase)
    case tickRegressed(last: Int, now: Int)
    case invalidCount(Int)
    case tooManySettings(count: Int, limit: Int)
    case originMismatch(expected: WingLeaseOrigin, got: WingLeaseOrigin)
    case grantNotCurrent(issuedAt: Int, expiry: Int, now: Int)
    case grantAlreadyApplied(issuedAt: Int, lastAppliedIssuedAt: Int)
    case grantExpired(expiry: Int, now: Int)
    case budgetExceeded(requested: Int, remaining: Int)
    case restoreRequired(writtenSettingCount: Int)
    case restoreExceedsWritten(plannedCount: Int, writtenSettingCount: Int)
    case restoreBudgetExceeded(requested: Int, remaining: Int)
    case restoreCountMismatch(expectedCount: Int, plannedCount: Int)
    case invalidConfirmedCount(confirmedCount: Int, expectedCount: Int)
    case confirmedExceedsSent(confirmedCount: Int, restoreSentCount: Int)
}
