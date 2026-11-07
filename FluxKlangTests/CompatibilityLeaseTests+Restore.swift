import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CompatibilityLeaseTests {
    private static func finish(_ lease: WingCompatibilityLease, expected: Int, confirmed: Int) throws
        -> WingCompatibilityLease {
        try step(lease, .finishRestore(expectedCount: expected, confirmedCount: confirmed), at: 100)
    }

    // MARK: beginRestore

    @Test func leaseBeginRestoreRefusesAPlanBelowOne() throws {
        let lease = try Self.authorized(written: 3)
        try Self.expectRefusal(lease, .beginRestore(plannedCount: 0), at: 100, .invalidCount(0))
        try Self.expectRefusal(lease, .beginRestore(plannedCount: -1), at: 100, .invalidCount(-1))
        try Self.expectRefusal(Self.authorized(), .beginRestore(plannedCount: 0), at: 100, .invalidCount(0))
    }

    @Test func leaseBeginRestorePlanMayEqualButNotExceedWhatWasWritten() throws {
        let lease = try Self.authorized(written: 3)
        #expect(try Self.step(lease, .beginRestore(plannedCount: 1), at: 100).plannedRestoreCount == 1)
        let full = try Self.step(lease, .beginRestore(plannedCount: 3), at: 100)
        #expect(full.plannedRestoreCount == 3 && full.restoreSentCount == 0 && full.writtenSettingCount == 3)
        try Self.expectRefusal(
            lease, .beginRestore(plannedCount: 4), at: 100,
            .restoreExceedsWritten(plannedCount: 4, writtenSettingCount: 3)
        )
    }

    @Test func leaseBeginRestoreWithNothingWrittenIsRefusedBecauseThereIsNothingToRestore() throws {
        try Self.expectRefusal(
            Self.authorized(), .beginRestore(plannedCount: 1), at: 100,
            .restoreExceedsWritten(plannedCount: 1, writtenSettingCount: 0)
        )
    }

    // MARK: admitRestoreWrite

    @Test func leaseAdmitRestoreWriteCountBoundaries() throws {
        let lease = try Self.restoring(written: 300, planned: 300)
        try Self.expectRefusal(lease, .admitRestoreWrite(settingCount: 0), at: 100, .invalidCount(0))
        try Self.expectRefusal(lease, .admitRestoreWrite(settingCount: -1), at: 100, .invalidCount(-1))
        #expect(try Self.step(lease, .admitRestoreWrite(settingCount: 1), at: 100).restoreSentCount == 1)
        #expect(try Self.step(lease, .admitRestoreWrite(settingCount: 256), at: 100).restoreSentCount == 256)
        try Self.expectRefusal(
            lease, .admitRestoreWrite(settingCount: 257), at: 100, .tooManySettings(count: 257, limit: 256)
        )
        try Self.expectRefusal(
            lease, .admitRestoreWrite(settingCount: Int.max), at: 100, .tooManySettings(count: Int.max, limit: 256)
        )
    }

    @Test func leaseAdmitRestoreWriteSentMayReachButNotPassThePlan() throws {
        let lease = try Self.restoring(written: 5, planned: 5, sent: 3)
        let full = try Self.step(lease, .admitRestoreWrite(settingCount: 2), at: 100)
        #expect(full.restoreSentCount == 5 && full.plannedRestoreCount == 5)
        let narrow = try Self.restoring(written: 5, planned: 2)
        try Self.expectRefusal(
            narrow, .admitRestoreWrite(settingCount: 3), at: 100, .restoreBudgetExceeded(requested: 3, remaining: 2)
        )
        try Self.expectRefusal(
            lease, .admitRestoreWrite(settingCount: 3), at: 100, .restoreBudgetExceeded(requested: 3, remaining: 2)
        )
        try Self.expectRefusal(
            full, .admitRestoreWrite(settingCount: 1), at: 100, .restoreBudgetExceeded(requested: 1, remaining: 0)
        )
    }

    @Test func leaseAdmitRestoreWriteReportsTheFirstFailureOfAdjacentPairs() throws {
        let spent = try Self.restoring(written: 5, planned: 5, sent: 5)
        try Self.expectRefusal(spent, .admitRestoreWrite(settingCount: 0), at: 100, .invalidCount(0))
        let small = try Self.restoring(written: 5, planned: 5)
        try Self.expectRefusal(
            small, .admitRestoreWrite(settingCount: 257), at: 100, .tooManySettings(count: 257, limit: 256)
        )
        try Self.expectRefusal(
            small, .admitRestoreWrite(settingCount: 0), at: 99, .tickRegressed(last: 100, now: 99)
        )
    }

    @Test func leaseRestoreWritesNeedNoGrantOriginAndOutliveTheExpiry() throws {
        let lease = try Self.restoring(written: 2, planned: 2)
        let later = try Self.step(lease, .admitRestoreWrite(settingCount: 2), at: 999_999)
        #expect(later.restoreSentCount == 2 && later.lastTick?.rawValue == 999_999)
        #expect(later.grant == lease.grant)
    }

    // MARK: finishRestore

    @Test func leaseFinishRestoreRefusesAMismatchedExpectedCount() throws {
        let lease = try Self.restoring(written: 3, planned: 3, sent: 3)
        try Self.expectRefusal(
            lease, .finishRestore(expectedCount: 2, confirmedCount: 2), at: 100,
            .restoreCountMismatch(expectedCount: 2, plannedCount: 3)
        )
        try Self.expectRefusal(
            lease, .finishRestore(expectedCount: 4, confirmedCount: 3), at: 100,
            .restoreCountMismatch(expectedCount: 4, plannedCount: 3)
        )
    }

    @Test func leaseFinishRestoreRefusesAConfirmedCountOutsideZeroToExpected() throws {
        let lease = try Self.restoring(written: 3, planned: 3, sent: 3)
        try Self.expectRefusal(
            lease, .finishRestore(expectedCount: 3, confirmedCount: -1), at: 100,
            .invalidConfirmedCount(confirmedCount: -1, expectedCount: 3)
        )
        try Self.expectRefusal(
            lease, .finishRestore(expectedCount: 3, confirmedCount: 4), at: 100,
            .invalidConfirmedCount(confirmedCount: 4, expectedCount: 3)
        )
        #expect(try Self.finish(lease, expected: 3, confirmed: 0).phase == .unleased)
        #expect(try Self.finish(lease, expected: 3, confirmed: 3).phase == .unleased)
    }

    @Test func leaseFinishRestoreCannotConfirmMoreThanWasSent() throws {
        let lease = try Self.restoring(written: 3, planned: 3, sent: 1)
        try Self.expectRefusal(
            lease, .finishRestore(expectedCount: 3, confirmedCount: 2), at: 100,
            .confirmedExceedsSent(confirmedCount: 2, restoreSentCount: 1)
        )
        #expect(try Self.finish(lease, expected: 3, confirmed: 1).lastOutcome
            == .partial(confirmedCount: 1, plannedCount: 3))
    }

    @Test func leaseFinishRestoreReportsTheFirstFailureOfAdjacentPairs() throws {
        let lease = try Self.restoring(written: 3, planned: 3, sent: 1)
        try Self.expectRefusal(
            lease, .finishRestore(expectedCount: 2, confirmedCount: -1), at: 100,
            .restoreCountMismatch(expectedCount: 2, plannedCount: 3)
        )
        try Self.expectRefusal(
            lease, .finishRestore(expectedCount: 3, confirmedCount: 4), at: 100,
            .invalidConfirmedCount(confirmedCount: 4, expectedCount: 3)
        )
    }

    // MARK: Outcomes

    @Test func leaseOutcomeIsVerifiedOnlyWhenEveryPlannedSettingIsConfirmed() throws {
        let lease = try Self.restoring(written: 3, planned: 3, sent: 3)
        #expect(try Self.finish(lease, expected: 3, confirmed: 3).lastOutcome == .verified(plannedCount: 3))
        let one = try Self.restoring(written: 1, planned: 1, sent: 1)
        #expect(try Self.finish(one, expected: 1, confirmed: 1).lastOutcome == .verified(plannedCount: 1))
    }

    @Test func leaseOutcomeIsPartialForOneUpToPlannedMinusOne() throws {
        let lease = try Self.restoring(written: 3, planned: 3, sent: 3)
        let one = try #require(try Self.finish(lease, expected: 3, confirmed: 1).lastOutcome)
        let two = try #require(try Self.finish(lease, expected: 3, confirmed: 2).lastOutcome)
        #expect(one == .partial(confirmedCount: 1, plannedCount: 3) && one.unconfirmedCount == 2)
        #expect(two == .partial(confirmedCount: 2, plannedCount: 3) && two.unconfirmedCount == 1)
    }

    @Test func leaseOutcomeIsUnverifiedWhenNothingIsConfirmed() throws {
        let lease = try Self.restoring(written: 3, planned: 3, sent: 3)
        let outcome = try #require(try Self.finish(lease, expected: 3, confirmed: 0).lastOutcome)
        #expect(outcome == .unverified(confirmedCount: 0, plannedCount: 3) && outcome.unconfirmedCount == 3)
        let unsent = try Self.restoring(written: 1, planned: 1)
        #expect(try Self.finish(unsent, expected: 1, confirmed: 0).lastOutcome
            == .unverified(confirmedCount: 0, plannedCount: 1))
    }

    @Test func leaseARestoreWithUnsentSettingsIsNeverVerified() throws {
        let halfway = try Self.restoring(written: 3, planned: 3, sent: 2)
        #expect(try Self.finish(halfway, expected: 3, confirmed: 2).lastOutcome
            == .partial(confirmedCount: 2, plannedCount: 3))
        try Self.expectRefusal(
            halfway, .finishRestore(expectedCount: 3, confirmedCount: 3), at: 100,
            .confirmedExceedsSent(confirmedCount: 3, restoreSentCount: 2)
        )
    }

    @Test func leaseOnlyThreeOutcomeKindsExistAndEveryFinishYieldsOne() throws {
        #expect(WingLeaseOutcomeKind.allCases.count == 3)
        let lease = try Self.restoring(written: 4, planned: 4, sent: 4)
        var kinds: [WingLeaseOutcomeKind] = []
        for confirmed in 0 ... 4 {
            let outcome = try #require(try Self.finish(lease, expected: 4, confirmed: confirmed).lastOutcome)
            kinds.append(outcome.kind)
        }
        #expect(kinds == [.unverified, .partial, .partial, .partial, .verified])
    }
}
