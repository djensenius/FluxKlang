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
}
