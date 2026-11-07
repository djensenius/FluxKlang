import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CompatibilityLeaseTests {
    private static func write(_ count: Int, _ origin: WingLeaseOrigin = .human) -> WingLeaseEvent {
        .admitWrite(origin: origin, settingCount: count)
    }

    // MARK: admitWrite bounds

    @Test func leaseAdmitWriteRefusesZeroAndNegativeCounts() throws {
        let lease = try Self.authorized()
        try Self.expectRefusal(lease, Self.write(0), at: 100, .invalidCount(0))
        try Self.expectRefusal(lease, Self.write(-1), at: 100, .invalidCount(-1))
        try Self.expectRefusal(lease, Self.write(Int.min), at: 100, .invalidCount(Int.min))
    }

    @Test func leaseAdmitWriteAcceptsOneAnd256AndRefusesMoreThanThat() throws {
        let lease = try Self.authorized(budget: 1_024)
        #expect(try Self.step(lease, Self.write(1), at: 100).writtenSettingCount == 1)
        #expect(try Self.step(lease, Self.write(256), at: 100).writtenSettingCount == 256)
        try Self.expectRefusal(lease, Self.write(257), at: 100, .tooManySettings(count: 257, limit: 256))
        try Self.expectRefusal(lease, Self.write(Int.max), at: 100, .tooManySettings(count: Int.max, limit: 256))
    }

    @Test func leaseAdmitWriteBudgetMayBeConsumedExactlyInOneRequest() throws {
        let lease = try Self.authorized(budget: 256)
        let spent = try Self.step(lease, Self.write(256), at: 100)
        #expect(spent.writtenSettingCount == 256)
        try Self.expectRefusal(spent, Self.write(1), at: 100, .budgetExceeded(requested: 1, remaining: 0))
        #expect(try Self.step(spent, .beginRestore(plannedCount: 256), at: 100).phase == .restoring)
    }

    @Test func leaseAdmitWriteBudgetNAcceptedAndNPlusOneRefusedWithTheExactRemainder() throws {
        let lease = try Self.authorized(budget: 10, written: 4)
        #expect(try Self.step(lease, Self.write(6), at: 100).writtenSettingCount == 10)
        try Self.expectRefusal(lease, Self.write(7), at: 100, .budgetExceeded(requested: 7, remaining: 6))
        let twice = try Self.step(Self.step(lease, Self.write(2), at: 100), Self.write(4), at: 100)
        #expect(twice.writtenSettingCount == 10)
        try Self.expectRefusal(twice, Self.write(1), at: 100, .budgetExceeded(requested: 1, remaining: 0))
    }

    @Test func leaseAdmitWriteBudgetOfOneAndOfTheMaximum() throws {
        let one = try Self.authorized(budget: 1)
        #expect(try Self.step(one, Self.write(1), at: 100).writtenSettingCount == 1)
        try Self.expectRefusal(one, Self.write(2), at: 100, .budgetExceeded(requested: 2, remaining: 1))
        let full = try Self.authorized(budget: 1_024, written: 1_024)
        #expect(full.writtenSettingCount == 1_024)
        try Self.expectRefusal(full, Self.write(1), at: 100, .budgetExceeded(requested: 1, remaining: 0))
        let almost = try Self.authorized(budget: 1_024, written: 1_023)
        try Self.expectRefusal(almost, Self.write(2), at: 100, .budgetExceeded(requested: 2, remaining: 1))
    }

    @Test func leaseAdmitWriteRefusesEveryWrongOriginPair() throws {
        var pairs = 0
        for expected in WingLeaseOrigin.allCases {
            let lease = try Self.authorized(origin: expected)
            #expect(try Self.step(lease, Self.write(1, expected), at: 100).writtenSettingCount == 1)
            for got in WingLeaseOrigin.allCases where got != expected {
                pairs += 1
                try Self.expectRefusal(
                    lease, Self.write(1, got), at: 100, .originMismatch(expected: expected, got: got)
                )
            }
        }
        #expect(pairs == 6)
    }

    @Test func leaseAdmitWriteStopsAtTheExpiryTickButRestoreStillWorks() throws {
        let lease = try Self.authorized(issuedAt: 100, duration: 1_000, written: 2)
        #expect(try Self.step(lease, Self.write(1), at: 1_099).writtenSettingCount == 3)
        try Self.expectRefusal(lease, Self.write(1), at: 1_100, .grantExpired(expiry: 1_100, now: 1_100))
        try Self.expectRefusal(lease, Self.write(1), at: 1_101, .grantExpired(expiry: 1_100, now: 1_101))
        let expired = try Self.step(lease, .beginRestore(plannedCount: 2), at: 5_000)
        #expect(expired.phase == .restoring && expired.plannedRestoreCount == 2)
        #expect(lease.phase == .authorizedWrite)
        try Self.expectRefusal(lease, .release, at: 9_000, .restoreRequired(writtenSettingCount: 2))
    }

    @Test func leaseAdmitWriteReportsTheFirstFailureOfAdjacentPairs() throws {
        let lease = try Self.authorized(origin: .human, budget: 10)
        try Self.expectRefusal(lease, Self.write(0, .assistant), at: 100, .invalidCount(0))
        try Self.expectRefusal(
            lease, Self.write(257, .assistant), at: 100, .tooManySettings(count: 257, limit: 256)
        )
        try Self.expectRefusal(
            lease, Self.write(1, .assistant), at: 1_100, .originMismatch(expected: .human, got: .assistant)
        )
        try Self.expectRefusal(lease, Self.write(11), at: 1_100, .grantExpired(expiry: 1_100, now: 1_100))
        try Self.expectRefusal(lease, Self.write(11), at: 100, .budgetExceeded(requested: 11, remaining: 10))
        let discovery = try Self.discovering()
        try Self.expectRefusal(
            discovery, Self.write(0), at: 100, .notPermitted(phase: .readOnlyDiscovery, event: .admitWrite)
        )
        try Self.expectRefusal(lease, Self.write(0), at: 50, .tickRegressed(last: 100, now: 50))
    }

    // MARK: Gate

    private static func gate(
        _ traffic: WingLeaseTraffic, _ lease: WingCompatibilityLease, at raw: Int = 100
    ) throws -> WingLeaseDecision {
        try WingLeaseGate.decide(traffic, in: lease, at: tick(raw))
    }

    @Test func leaseGateTruthTableOverFourPhasesAndThreeTrafficKinds() throws {
        let leases: [WingCompatibilityLease] = try [
            .unleased, Self.discovering(), Self.authorized(), Self.restoring(written: 3, planned: 3)
        ]
        let traffic: [WingLeaseTraffic] = [
            .read, .write(origin: .human, settingCount: 1), .restoreWrite(settingCount: 1)
        ]
        let expected: [[WingLeaseDecision]] = [
            [
                .refused(.readNotPermitted(phase: .unleased)),
                .refused(.notPermitted(phase: .unleased, event: .admitWrite)),
                .refused(.notPermitted(phase: .unleased, event: .admitRestoreWrite))
            ],
            [
                .permitted,
                .refused(.notPermitted(phase: .readOnlyDiscovery, event: .admitWrite)),
                .refused(.notPermitted(phase: .readOnlyDiscovery, event: .admitRestoreWrite))
            ],
            [
                .permitted,
                .permitted,
                .refused(.notPermitted(phase: .authorizedWrite, event: .admitRestoreWrite))
            ],
            [
                .permitted,
                .refused(.notPermitted(phase: .restoring, event: .admitWrite)),
                .permitted
            ]
        ]
        for (index, lease) in leases.enumerated() {
            let actual = try traffic.map { try Self.gate($0, lease) }
            #expect(actual == expected[index], "phase row \(index)")
        }
    }

    @Test func leaseGateZeroWriteProofForUnleasedAndDiscoveryAtEveryTickAndCount() throws {
        let leases: [WingCompatibilityLease] = try [.unleased, Self.discovering(at: 0)]
        let phases: [WingLeasePhase] = [.unleased, .readOnlyDiscovery]
        for (lease, phase) in zip(leases, phases) {
            for raw in [0, 1, 1_000_000_000_000] {
                for count in [1, 256] {
                    #expect(try Self.gate(.write(origin: .human, settingCount: count), lease, at: raw)
                        == .refused(.notPermitted(phase: phase, event: .admitWrite)))
                    #expect(try Self.gate(.restoreWrite(settingCount: count), lease, at: raw)
                        == .refused(.notPermitted(phase: phase, event: .admitRestoreWrite)))
                }
            }
        }
    }

    @Test func leaseGateReadIsNeverTickCheckedAndWriteStopsAtExpiry() throws {
        let lease = try Self.authorized(issuedAt: 100, duration: 50)
        #expect(try Self.gate(.read, lease, at: 100) == .permitted)
        #expect(try Self.gate(.read, lease, at: 1_000_000) == .permitted)
        #expect(try Self.gate(.read, lease, at: 0) == .permitted)
        #expect(try Self.gate(.write(origin: .human, settingCount: 1), lease, at: 149) == .permitted)
        #expect(try Self.gate(.write(origin: .human, settingCount: 1), lease, at: 150)
            == .refused(.grantExpired(expiry: 150, now: 150)))
        #expect(try Self.gate(.write(origin: .human, settingCount: 1), lease, at: 99)
            == .refused(.tickRegressed(last: 100, now: 99)))
    }

    @Test func leaseGateRestoreWriteStaysWithinThePlan() throws {
        let lease = try Self.restoring(written: 3, planned: 3, sent: 2)
        #expect(try Self.gate(.restoreWrite(settingCount: 1), lease) == .permitted)
        #expect(try Self.gate(.restoreWrite(settingCount: 2), lease)
            == .refused(.restoreBudgetExceeded(requested: 2, remaining: 1)))
        #expect(try Self.gate(.restoreWrite(settingCount: 0), lease) == .refused(.invalidCount(0)))
    }

    @Test func leaseGateDoesNotConsumeBudgetOrChangeTheLease() throws {
        let lease = try Self.authorized(budget: 10)
        let before = lease
        for _ in 0 ..< 5 {
            #expect(try Self.gate(.write(origin: .human, settingCount: 10), lease, at: 500) == .permitted)
        }
        #expect(lease == before)
        #expect(lease.writtenSettingCount == 0 && lease.lastTick?.rawValue == 100)
        let refused = try Self.gate(.write(origin: .human, settingCount: 11), lease)
        #expect(refused == .refused(.budgetExceeded(requested: 11, remaining: 10)))
        #expect(lease == before)
    }

    @Test func leaseGateAndMachineAgreeForEveryScriptedLeaseTrafficAndTick() throws {
        let leases: [WingCompatibilityLease] = try [
            .unleased, Self.discovering(), Self.authorized(budget: 3), Self.authorized(budget: 3, written: 3),
            Self.restoring(written: 3, planned: 2, sent: 1), Self.restoring(written: 3, planned: 2, sent: 2)
        ]
        let traffic: [WingLeaseTraffic] = [
            .write(origin: .human, settingCount: 1), .write(origin: .controller, settingCount: 1),
            .write(origin: .human, settingCount: 0), .restoreWrite(settingCount: 1), .restoreWrite(settingCount: 300)
        ]
        var permitted = 0
        for lease in leases {
            for item in traffic {
                for raw in [50, 100, 1_099, 1_100] {
                    let event: WingLeaseEvent
                    switch item {
                    case .read: event = .release
                    case let .write(origin, count): event = .admitWrite(origin: origin, settingCount: count)
                    case let .restoreWrite(count): event = .admitRestoreWrite(settingCount: count)
                    }
                    let decision = try Self.gate(item, lease, at: raw)
                    if let error = try Self.refusal(lease, event, at: raw) {
                        #expect(decision == .refused(error))
                    } else {
                        permitted += 1
                        #expect(decision == .permitted)
                    }
                }
            }
        }
        #expect(permitted == 5)
    }
}
