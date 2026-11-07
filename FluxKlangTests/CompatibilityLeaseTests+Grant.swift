import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CompatibilityLeaseTests {
    private static func fault(
        grantor: WingLeaseOrigin = .human,
        origin: WingLeaseOrigin = .human,
        issuedAt: Int = 100,
        duration: Int = 1_000,
        budget: Int = 10
    ) throws -> WingLeaseConstructionFault? {
        let start = try WingLeaseTick(issuedAt)
        do {
            _ = try WingLeaseGrant.make(
                grantedBy: grantor,
                writeOrigin: origin,
                issuedAt: start,
                durationTicks: duration,
                settingBudget: budget
            )
            return nil
        } catch {
            return error
        }
    }

    private static func tickFault(_ raw: Int) -> WingLeaseConstructionFault? {
        do {
            _ = try WingLeaseTick(raw)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Tick

    @Test func leaseTickAcceptsZeroAndTheMaximum() throws {
        #expect(try WingLeaseTick(0).rawValue == 0)
        #expect(try WingLeaseTick(1).rawValue == 1)
        #expect(try WingLeaseTick(1_000_000_000_000).rawValue == 1_000_000_000_000)
        #expect(Self.tickFault(0) == nil)
        #expect(Self.tickFault(1_000_000_000_000) == nil)
    }

    @Test func leaseTickRefusesOutOfRangeValuesWithoutTrapping() {
        #expect(Self.tickFault(-1) == .tickOutOfRange(-1))
        #expect(Self.tickFault(1_000_000_000_001) == .tickOutOfRange(1_000_000_000_001))
        #expect(Self.tickFault(Int.max) == .tickOutOfRange(Int.max))
        #expect(Self.tickFault(Int.min) == .tickOutOfRange(Int.min))
    }

    @Test func leaseTickComparesAndHashesByRawValue() throws {
        let low = try WingLeaseTick(5)
        let high = try WingLeaseTick(6)
        #expect(low < high)
        #expect(!(high < low))
        #expect(!(low < (try WingLeaseTick(5))))
        #expect(low == (try WingLeaseTick(5)))
        #expect(low != high)
        #expect(Set([low, try WingLeaseTick(5), high]).count == 2)
        #expect([high, low].sorted() == [low, high])
    }

    // MARK: Grant

    @Test func leaseGrantAcceptsAHumanGrantorForEveryWriteOrigin() throws {
        for origin in WingLeaseOrigin.allCases {
            let grant = try WingLeaseGrant.make(
                grantedBy: .human,
                writeOrigin: origin,
                issuedAt: try WingLeaseTick(100),
                durationTicks: 50,
                settingBudget: 7
            )
            #expect(grant.writeOrigin == origin)
            #expect(grant.issuedAt.rawValue == 100)
            #expect(grant.expiry.rawValue == 150)
            #expect(grant.settingBudget == 7)
        }
    }

    @Test func leaseGrantRefusesControllerAndAssistantGrantorsWhateverTheWriteOrigin() throws {
        for origin in WingLeaseOrigin.allCases {
            #expect(try Self.fault(grantor: .controller, origin: origin) == .grantorNotHuman(.controller))
            #expect(try Self.fault(grantor: .assistant, origin: origin) == .grantorNotHuman(.assistant))
            #expect(try Self.fault(grantor: .human, origin: origin) == nil)
        }
    }

    @Test func leaseGrantDurationAcceptsOneAndTheMaximumOnly() throws {
        #expect(try Self.fault(duration: 1) == nil)
        #expect(try Self.fault(duration: 3_600_000) == nil)
        #expect(try Self.fault(duration: 0) == .invalidDuration(0))
        #expect(try Self.fault(duration: -1) == .invalidDuration(-1))
        #expect(try Self.fault(duration: 3_600_001) == .invalidDuration(3_600_001))
        #expect(try Self.fault(duration: Int.max) == .invalidDuration(Int.max))
        #expect(try Self.fault(duration: Int.min) == .invalidDuration(Int.min))
    }

    @Test func leaseGrantBudgetAcceptsOneAndTheMaximumOnly() throws {
        #expect(try Self.fault(budget: 1) == nil)
        #expect(try Self.fault(budget: 1_024) == nil)
        #expect(try Self.fault(budget: 0) == .invalidBudget(0))
        #expect(try Self.fault(budget: -1) == .invalidBudget(-1))
        #expect(try Self.fault(budget: 1_025) == .invalidBudget(1_025))
        #expect(try Self.fault(budget: Int.max) == .invalidBudget(Int.max))
    }

    @Test func leaseGrantExpiryMayReachTheMaximumTickButNotPassIt() throws {
        #expect(try Self.fault(issuedAt: 1_000_000_000_000, duration: 1) == .expiryOverflow)
        #expect(try Self.fault(issuedAt: 999_996_400_000, duration: 3_600_000) == nil)
        #expect(try Self.fault(issuedAt: 999_996_400_001, duration: 3_600_000) == .expiryOverflow)
        #expect(try Self.fault(issuedAt: 999_999_999_999, duration: 1) == nil)
        let edge = try Self.makeGrant(issuedAt: 999_996_400_000, duration: 3_600_000)
        #expect(edge.expiry.rawValue == 1_000_000_000_000)
        #expect(edge.issuedAt.rawValue == 999_996_400_000)
    }

    @Test func leaseGrantFieldsAreIssuedAtDurationAndBudgetExactly() throws {
        let grant = try Self.makeGrant(origin: .assistant, issuedAt: 2_000, duration: 3_000, budget: 42)
        #expect(grant.writeOrigin == .assistant)
        #expect(grant.issuedAt.rawValue == 2_000)
        #expect(grant.expiry.rawValue == 5_000)
        #expect(grant.settingBudget == 42)
        #expect(grant == (try Self.makeGrant(origin: .assistant, issuedAt: 2_000, duration: 3_000, budget: 42)))
        #expect(grant != (try Self.makeGrant(origin: .human, issuedAt: 2_000, duration: 3_000, budget: 42)))
    }

    @Test func leaseGrantReportsTheFirstFailureOfAdjacentPairs() throws {
        #expect(try Self.fault(grantor: .controller, duration: 0) == .grantorNotHuman(.controller))
        #expect(try Self.fault(duration: 0, budget: 0) == .invalidDuration(0))
        #expect(try Self.fault(duration: 3_600_001, budget: 1_025) == .invalidDuration(3_600_001))
        #expect(try Self.fault(issuedAt: 1_000_000_000_000, duration: 1, budget: 0) == .invalidBudget(0))
        #expect(try Self.fault(issuedAt: 1_000_000_000_000, duration: 0) == .invalidDuration(0))
    }

    // MARK: A grant is spendable once (no reuse across lease cycles)

    enum CycleEnd: CaseIterable {
        case restored
        case abandoned
        case unused
    }

    /// One whole cycle under the default grant (issued at tick 100) ending as `end`, then back in discovery at 100.
    static func rediscovered(budget: Int = 1, ending end: CycleEnd = .restored) throws -> WingCompatibilityLease {
        let written = end == .unused ? 0 : 1
        var lease = try authorized(budget: budget, written: written)
        switch end {
        case .restored:
            lease = try step(lease, .beginRestore(plannedCount: 1), at: 100)
            lease = try step(lease, .admitRestoreWrite(settingCount: 1), at: 100)
            lease = try step(lease, .finishRestore(expectedCount: 1, confirmedCount: 1), at: 100)
        case .abandoned:
            lease = try step(lease, .beginRestore(plannedCount: 1), at: 100)
            lease = try step(lease, .release, at: 100)
        case .unused:
            lease = try step(lease, .release, at: 100)
        }
        return try step(lease, .beginDiscovery, at: 100)
    }

    @Test func leaseABudgetOneGrantCannotBeAppliedAgainAfterRestorationAndRediscovery() throws {
        let grant = try Self.makeGrant(budget: 1)
        var lease = try Self.step(Self.discovering(), .grant(grant), at: 100)
        lease = try Self.step(lease, .admitWrite(origin: .human, settingCount: 1), at: 100)
        lease = try Self.step(lease, .beginRestore(plannedCount: 1), at: 100)
        lease = try Self.step(lease, .admitRestoreWrite(settingCount: 1), at: 100)
        lease = try Self.step(lease, .finishRestore(expectedCount: 1, confirmedCount: 1), at: 100)
        lease = try Self.step(lease, .beginDiscovery, at: 100)
        #expect(lease.lastGrantIssuedAt?.rawValue == 100)
        try Self.expectRefusal(
            lease, .grant(grant), at: 100, .grantAlreadyApplied(issuedAt: 100, lastAppliedIssuedAt: 100)
        )
        let write = WingLeaseTraffic.write(origin: .human, settingCount: 1)
        let decision = try WingLeaseGate.decide(write, in: lease, at: Self.tick(100))
        #expect(decision == .refused(.notPermitted(phase: .readOnlyDiscovery, event: .admitWrite)))
        let fresh = try Self.makeGrant(issuedAt: 101, budget: 1)
        let renewed = try Self.step(lease, .grant(fresh), at: 101)
        #expect(renewed.phase == .authorizedWrite && renewed.writtenSettingCount == 0)
        #expect(renewed.lastGrantIssuedAt?.rawValue == 101)
        let spent = try Self.step(renewed, .admitWrite(origin: .human, settingCount: 1), at: 101)
        try Self.expectRefusal(
            spent, .admitWrite(origin: .human, settingCount: 1), at: 101, .budgetExceeded(requested: 1, remaining: 0)
        )
    }

    @Test func leaseABudgetTwoGrantIsSpentInTotalAndTheNextCycleNeedsAFreshGrant() throws {
        var lease = try Self.authorized(budget: 2, written: 1)
        lease = try Self.step(lease, .admitWrite(origin: .human, settingCount: 1), at: 100)
        try Self.expectRefusal(
            lease, .admitWrite(origin: .human, settingCount: 1), at: 100, .budgetExceeded(requested: 1, remaining: 0)
        )
        lease = try Self.step(lease, .beginRestore(plannedCount: 2), at: 100)
        lease = try Self.step(lease, .admitRestoreWrite(settingCount: 2), at: 100)
        lease = try Self.step(lease, .finishRestore(expectedCount: 2, confirmedCount: 2), at: 100)
        lease = try Self.step(lease, .beginDiscovery, at: 100)
        let old = try Self.makeGrant(budget: 2)
        try Self.expectRefusal(
            lease, .grant(old), at: 100, .grantAlreadyApplied(issuedAt: 100, lastAppliedIssuedAt: 100)
        )
        let fresh = try Self.makeGrant(issuedAt: 200, budget: 2)
        var renewed = try Self.step(lease, .grant(fresh), at: 200)
        renewed = try Self.step(renewed, .admitWrite(origin: .human, settingCount: 2), at: 200)
        try Self.expectRefusal(
            renewed, .admitWrite(origin: .human, settingCount: 1), at: 200, .budgetExceeded(requested: 1, remaining: 0)
        )
    }

    @Test func leaseAGrantIsRefusedAfterEveryWayOfEndingACycleInEveryStateThatCouldHoldIt() throws {
        for end in CycleEnd.allCases {
            let discovery = try Self.rediscovered(ending: end)
            let old = try Self.makeGrant(budget: 1)
            try Self.expectRefusal(
                discovery, .grant(old), at: 100, .grantAlreadyApplied(issuedAt: 100, lastAppliedIssuedAt: 100)
            )
            let released = try Self.step(discovery, .release, at: 100)
            try Self.expectRefusal(released, .grant(old), at: 100, .notPermitted(phase: .unleased, event: .grant))
            let again = try Self.step(released, .beginDiscovery, at: 100)
            try Self.expectRefusal(
                again, .grant(old), at: 100, .grantAlreadyApplied(issuedAt: 100, lastAppliedIssuedAt: 100)
            )
            let fresh = try Self.makeGrant(issuedAt: 101, budget: 1)
            #expect(try Self.step(again, .grant(fresh), at: 101).phase == .authorizedWrite)
        }
    }

    @Test func leaseTheNextGrantNeedsAStrictlyNewerIssuedAtThanTheAppliedOne() throws {
        let discovery = try Self.rediscovered(ending: .restored)
        let older = try Self.makeGrant(issuedAt: 99)
        let same = try Self.makeGrant(issuedAt: 100, budget: 5)
        let newer = try Self.makeGrant(issuedAt: 101)
        try Self.expectRefusal(
            discovery, .grant(older), at: 100, .grantAlreadyApplied(issuedAt: 99, lastAppliedIssuedAt: 100)
        )
        try Self.expectRefusal(
            discovery, .grant(same), at: 100, .grantAlreadyApplied(issuedAt: 100, lastAppliedIssuedAt: 100)
        )
        #expect(try Self.step(discovery, .grant(newer), at: 101).phase == .authorizedWrite)
    }

    @Test func leaseAGrantIssuedAfterTheAppliedOneButBeforeTheLastTickIsStillAccepted() throws {
        var lease = try Self.authorized()
        lease = try Self.step(lease, .release, at: 150)
        lease = try Self.step(lease, .beginDiscovery, at: 150)
        let fresh = try Self.makeGrant(issuedAt: 120)
        let renewed = try Self.step(lease, .grant(fresh), at: 150)
        #expect(renewed.phase == .authorizedWrite)
        #expect(renewed.lastGrantIssuedAt?.rawValue == 120)
    }

    @Test func leaseAReplayedGrantReportsTheOlderChecksFirst() throws {
        let discovery = try Self.rediscovered(ending: .restored)
        let old = try Self.makeGrant(duration: 1_000)
        try Self.expectRefusal(discovery, .grant(old), at: 99, .tickRegressed(last: 100, now: 99))
        try Self.expectRefusal(
            discovery, .grant(old), at: 1_100, .grantNotCurrent(issuedAt: 100, expiry: 1_100, now: 1_100)
        )
        try Self.expectRefusal(
            discovery, .grant(old), at: 1_099, .grantAlreadyApplied(issuedAt: 100, lastAppliedIssuedAt: 100)
        )
    }
}
