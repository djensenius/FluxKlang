/// An event the lease can be asked to apply. Each case has exactly one `kind`.
enum WingLeaseEvent: Equatable, Sendable {
    case beginDiscovery
    case grant(WingLeaseGrant)
    case admitWrite(origin: WingLeaseOrigin, settingCount: Int)
    case beginRestore(plannedCount: Int)
    case admitRestoreWrite(settingCount: Int)
    case finishRestore(expectedCount: Int, confirmedCount: Int)
    case release

    var kind: WingLeaseEventKind {
        switch self {
        case .beginDiscovery: .beginDiscovery
        case .grant: .grant
        case .admitWrite: .admitWrite
        case .beginRestore: .beginRestore
        case .admitRestoreWrite: .admitRestoreWrite
        case .finishRestore: .finishRestore
        case .release: .release
        }
    }
}

/// The compatibility lease: whether any WING mixer write may happen at all.
///
/// An immutable value. `applying(_:at:)` is the only transition: it never changes `self`, returns the successor or
/// throws exactly one `WingLeaseRefusal` (a refusal returns nothing, so state is unchanged by construction).
/// Phases: `unleased` (no traffic), `readOnlyDiscovery` (reads only), `authorizedWrite` (a human grant with an
/// expiry tick and a setting budget) and `restoring` (only restore writes within a declared plan). Restoration is NOT
/// atomic: it is applied setting by setting and ends in `verified`, `partial` or `unverified` by counts.
/// Expiry stops further writes but never drops the restore obligation. Returning to `unleased` clears the grant and
/// the counters, keeps `lastTick` (time never runs backwards across leases) and `lastGrantIssuedAt` (a grant is
/// spendable once; a later grant needs a strictly newer `issuedAt`) and sets or clears `lastOutcome`.
/// The lease holds counts only, never setting addresses or values, and never reads a clock.
struct WingCompatibilityLease: Equatable, Sendable {
    private(set) var phase: WingLeasePhase = .unleased
    private(set) var grant: WingLeaseGrant?
    private(set) var writtenSettingCount = 0
    private(set) var plannedRestoreCount = 0
    private(set) var restoreSentCount = 0
    private(set) var lastTick: WingLeaseTick?
    /// The `issuedAt` of the newest grant ever applied. Kept across every reset, so a grant that was applied once
    /// (same or older `issuedAt`) can never be spent again: a new write after a cycle needs a newer human grant.
    private(set) var lastGrantIssuedAt: WingLeaseTick?
    private(set) var lastOutcome: WingLeaseOutcome?

    init() {}

    static let unleased = WingCompatibilityLease()

    /// Checks, first failure wins: legality of the event in the phase (`notPermitted`), tick monotonicity
    /// (`tickRegressed`; an equal tick is accepted), then the event-specific checks in the documented order.
    func applying(_ event: WingLeaseEvent, at tick: WingLeaseTick) throws(WingLeaseRefusal) -> WingCompatibilityLease {
        guard Self.isLegal(event.kind, in: phase) else {
            throw .notPermitted(phase: phase, event: event.kind)
        }
        if let last = lastTick, tick < last {
            throw .tickRegressed(last: last.rawValue, now: tick.rawValue)
        }
        var next = try transition(event, at: tick)
        next.lastTick = tick
        return next
    }

    private func transition(
        _ event: WingLeaseEvent,
        at tick: WingLeaseTick
    ) throws(WingLeaseRefusal) -> WingCompatibilityLease {
        switch event {
        case .beginDiscovery:
            var next = self
            next.phase = .readOnlyDiscovery
            next.lastOutcome = nil
            return next
        case let .grant(newGrant):
            return try applyGrant(newGrant, at: tick)
        case let .admitWrite(origin, settingCount):
            return try applyAdmitWrite(origin: origin, settingCount: settingCount, at: tick)
        case let .beginRestore(plannedCount):
            return try applyBeginRestore(plannedCount: plannedCount)
        case let .admitRestoreWrite(settingCount):
            return try applyAdmitRestoreWrite(settingCount: settingCount)
        case let .finishRestore(expectedCount, confirmedCount):
            return try applyFinishRestore(expectedCount: expectedCount, confirmedCount: confirmedCount)
        case .release:
            return try applyRelease()
        }
    }

    // MARK: Legality table (4 phases x 7 kinds)

    private static func isLegal(_ kind: WingLeaseEventKind, in phase: WingLeasePhase) -> Bool {
        switch phase {
        case .unleased: legalFromUnleased(kind)
        case .readOnlyDiscovery: legalFromDiscovery(kind)
        case .authorizedWrite: legalFromAuthorizedWrite(kind)
        case .restoring: legalFromRestoring(kind)
        }
    }

    private static func legalFromUnleased(_ kind: WingLeaseEventKind) -> Bool {
        switch kind {
        case .beginDiscovery: true
        case .grant, .admitWrite, .beginRestore, .admitRestoreWrite, .finishRestore, .release: false
        }
    }

    private static func legalFromDiscovery(_ kind: WingLeaseEventKind) -> Bool {
        switch kind {
        case .grant, .release: true
        case .beginDiscovery, .admitWrite, .beginRestore, .admitRestoreWrite, .finishRestore: false
        }
    }

    private static func legalFromAuthorizedWrite(_ kind: WingLeaseEventKind) -> Bool {
        switch kind {
        case .admitWrite, .beginRestore, .release: true
        case .beginDiscovery, .grant, .admitRestoreWrite, .finishRestore: false
        }
    }

    private static func legalFromRestoring(_ kind: WingLeaseEventKind) -> Bool {
        switch kind {
        case .admitRestoreWrite, .finishRestore, .release: true
        case .beginDiscovery, .grant, .admitWrite, .beginRestore: false
        }
    }

    // MARK: Event handlers (each returns the successor; none changes `self`)

    private func applyGrant(
        _ newGrant: WingLeaseGrant,
        at tick: WingLeaseTick
    ) throws(WingLeaseRefusal) -> WingCompatibilityLease {
        guard newGrant.issuedAt <= tick, tick < newGrant.expiry else {
            throw .grantNotCurrent(
                issuedAt: newGrant.issuedAt.rawValue,
                expiry: newGrant.expiry.rawValue,
                now: tick.rawValue
            )
        }
        if let applied = lastGrantIssuedAt, newGrant.issuedAt <= applied {
            throw .grantAlreadyApplied(issuedAt: newGrant.issuedAt.rawValue, lastAppliedIssuedAt: applied.rawValue)
        }
        var next = self
        next.phase = .authorizedWrite
        next.grant = newGrant
        next.writtenSettingCount = 0
        next.lastGrantIssuedAt = newGrant.issuedAt
        return next
    }

    private func applyAdmitWrite(
        origin: WingLeaseOrigin,
        settingCount: Int,
        at tick: WingLeaseTick
    ) throws(WingLeaseRefusal) -> WingCompatibilityLease {
        try Self.checkRequestSize(settingCount)
        // An authorizedWrite lease always holds a grant; this branch is unreachable.
        guard let grant else { throw .notPermitted(phase: phase, event: .admitWrite) }
        guard origin == grant.writeOrigin else {
            throw .originMismatch(expected: grant.writeOrigin, got: origin)
        }
        guard tick < grant.expiry else {
            throw .grantExpired(expiry: grant.expiry.rawValue, now: tick.rawValue)
        }
        let remaining = grant.settingBudget - writtenSettingCount
        let (sum, overflow) = writtenSettingCount.addingReportingOverflow(settingCount)
        guard settingCount <= remaining, !overflow else {
            throw .budgetExceeded(requested: settingCount, remaining: remaining)
        }
        var next = self
        next.writtenSettingCount = sum
        return next
    }

    private func applyBeginRestore(plannedCount: Int) throws(WingLeaseRefusal) -> WingCompatibilityLease {
        guard plannedCount >= WingLeaseLimits.minimumCount else { throw .invalidCount(plannedCount) }
        guard plannedCount <= writtenSettingCount else {
            throw .restoreExceedsWritten(plannedCount: plannedCount, writtenSettingCount: writtenSettingCount)
        }
        var next = self
        next.phase = .restoring
        next.plannedRestoreCount = plannedCount
        next.restoreSentCount = 0
        return next
    }

    private func applyAdmitRestoreWrite(settingCount: Int) throws(WingLeaseRefusal) -> WingCompatibilityLease {
        try Self.checkRequestSize(settingCount)
        let remaining = plannedRestoreCount - restoreSentCount
        let (sum, overflow) = restoreSentCount.addingReportingOverflow(settingCount)
        guard settingCount <= remaining, !overflow else {
            throw .restoreBudgetExceeded(requested: settingCount, remaining: remaining)
        }
        var next = self
        next.restoreSentCount = sum
        return next
    }

    private func applyFinishRestore(
        expectedCount: Int,
        confirmedCount: Int
    ) throws(WingLeaseRefusal) -> WingCompatibilityLease {
        guard expectedCount == plannedRestoreCount else {
            throw .restoreCountMismatch(expectedCount: expectedCount, plannedCount: plannedRestoreCount)
        }
        guard confirmedCount >= 0, confirmedCount <= expectedCount else {
            throw .invalidConfirmedCount(confirmedCount: confirmedCount, expectedCount: expectedCount)
        }
        guard confirmedCount <= restoreSentCount else {
            throw .confirmedExceedsSent(confirmedCount: confirmedCount, restoreSentCount: restoreSentCount)
        }
        return returnedToUnleased(
            outcome: .decide(confirmedCount: confirmedCount, plannedCount: plannedRestoreCount)
        )
    }

    private func applyRelease() throws(WingLeaseRefusal) -> WingCompatibilityLease {
        if phase == .authorizedWrite, writtenSettingCount != 0 {
            throw .restoreRequired(writtenSettingCount: writtenSettingCount)
        }
        // Abandoning a restoration is never claimed as verified.
        let outcome: WingLeaseOutcome? = phase == .restoring
            ? .unverified(confirmedCount: 0, plannedCount: plannedRestoreCount)
            : nil
        return returnedToUnleased(outcome: outcome)
    }

    private func returnedToUnleased(outcome: WingLeaseOutcome?) -> WingCompatibilityLease {
        var next = self
        next.phase = .unleased
        next.grant = nil
        next.writtenSettingCount = 0
        next.plannedRestoreCount = 0
        next.restoreSentCount = 0
        next.lastOutcome = outcome
        return next
    }

    private static func checkRequestSize(_ settingCount: Int) throws(WingLeaseRefusal) {
        guard settingCount >= WingLeaseLimits.minimumCount else { throw .invalidCount(settingCount) }
        guard settingCount <= WingLeaseLimits.maximumSettingsPerRequest else {
            throw .tooManySettings(count: settingCount, limit: WingLeaseLimits.maximumSettingsPerRequest)
        }
    }
}
