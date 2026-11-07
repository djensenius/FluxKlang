import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CompatibilityLeaseTests {
    private struct Attempt {
        let lease: WingCompatibilityLease
        let event: WingLeaseEvent
        let tick: Int
        let expected: WingLeaseRefusal

        init(_ lease: WingCompatibilityLease, _ event: WingLeaseEvent, _ tick: Int, _ expected: WingLeaseRefusal) {
            self.lease = lease
            self.event = event
            self.tick = tick
            self.expected = expected
        }
    }

    /// The case name through reflection (every case has a payload).
    private static func caseName(_ refusal: WingLeaseRefusal) -> String {
        Mirror(reflecting: refusal).children.first?.label ?? ""
    }

    /// Exhaustive on purpose, in ONE clause: adding a refusal case breaks compilation here until the count is raised.
    private static func caseCount(_ refusal: WingLeaseRefusal) -> Int {
        switch refusal {
        case .notPermitted, .readNotPermitted, .tickRegressed, .invalidCount, .tooManySettings, .originMismatch,
             .grantNotCurrent, .grantExpired, .budgetExceeded, .restoreRequired, .restoreExceedsWritten,
             .restoreBudgetExceeded, .restoreCountMismatch, .invalidConfirmedCount, .confirmedExceedsSent:
            15
        }
    }

    private static func attempts() throws -> [Attempt] {
        let grant = try makeGrant(issuedAt: 100, duration: 50)
        let written = try authorized(budget: 5, written: 5)
        let restore = try restoring(written: 5, planned: 5, sent: 2)
        return [
            Attempt(.unleased, .release, 5, .notPermitted(phase: .unleased, event: .release)),
            Attempt(try discovering(at: 10), .grant(grant), 99, .grantNotCurrent(issuedAt: 100, expiry: 150, now: 99)),
            Attempt(written, .release, 100, .restoreRequired(writtenSettingCount: 5)),
            Attempt(written, .admitWrite(origin: .human, settingCount: 0), 100, .invalidCount(0)),
            Attempt(
                written, .admitWrite(origin: .human, settingCount: 257), 100,
                .tooManySettings(count: 257, limit: 256)
            ),
            Attempt(
                written, .admitWrite(origin: .controller, settingCount: 1), 100,
                .originMismatch(expected: .human, got: .controller)
            ),
            Attempt(
                written, .admitWrite(origin: .human, settingCount: 1), 1_100,
                .grantExpired(expiry: 1_100, now: 1_100)
            ),
            Attempt(
                written, .admitWrite(origin: .human, settingCount: 1), 100,
                .budgetExceeded(requested: 1, remaining: 0)
            ),
            Attempt(
                written, .beginRestore(plannedCount: 6), 100,
                .restoreExceedsWritten(plannedCount: 6, writtenSettingCount: 5)
            ),
            Attempt(
                restore, .admitRestoreWrite(settingCount: 4), 100,
                .restoreBudgetExceeded(requested: 4, remaining: 3)
            ),
            Attempt(
                restore, .finishRestore(expectedCount: 4, confirmedCount: 1), 100,
                .restoreCountMismatch(expectedCount: 4, plannedCount: 5)
            ),
            Attempt(
                restore, .finishRestore(expectedCount: 5, confirmedCount: 6), 100,
                .invalidConfirmedCount(confirmedCount: 6, expectedCount: 5)
            ),
            Attempt(
                restore, .finishRestore(expectedCount: 5, confirmedCount: 3), 100,
                .confirmedExceedsSent(confirmedCount: 3, restoreSentCount: 2)
            ),
            Attempt(restore, .release, 99, .tickRegressed(last: 100, now: 99))
        ]
    }

    @Test func leaseEveryRefusalLeavesTheLeaseAndItsLastTickUnchangedAndRepeatsIdentically() throws {
        let all = try Self.attempts()
        #expect(all.count == 14)
        for attempt in all {
            let lastTick = attempt.lease.lastTick
            try Self.expectRefusal(attempt.lease, attempt.event, at: attempt.tick, attempt.expected)
            #expect(attempt.lease.lastTick == lastTick)
        }
    }

    @Test func leaseAllFifteenRefusalCasesAreProducedByAtLeastOneTest() throws {
        var names = Set(try Self.attempts().map { Self.caseName($0.expected) })
        let gate = try WingLeaseGate.decide(.read, in: .unleased, at: Self.tick(0))
        guard case let .refused(read) = gate else {
            Issue.record("a read in unleased must be refused")
            return
        }
        #expect(read == .readNotPermitted(phase: .unleased))
        names.insert(Self.caseName(read))
        #expect(names == [
            "notPermitted", "readNotPermitted", "tickRegressed", "invalidCount", "tooManySettings", "originMismatch",
            "grantNotCurrent", "grantExpired", "budgetExceeded", "restoreRequired", "restoreExceedsWritten",
            "restoreBudgetExceeded", "restoreCountMismatch", "invalidConfirmedCount", "confirmedExceedsSent"
        ])
        #expect(names.count == Self.caseCount(read))
    }

    @Test func leaseReadNotPermittedIsNeverProducedByTheMachineItself() throws {
        let leases: [WingCompatibilityLease] = try [.unleased, Self.discovering(), Self.authorized()]
        for lease in leases {
            for kind in WingLeaseEventKind.allCases {
                let event: WingLeaseEvent = switch kind {
                case .beginDiscovery: .beginDiscovery
                case .grant: try .grant(Self.makeGrant())
                case .admitWrite: .admitWrite(origin: .human, settingCount: 1)
                case .beginRestore: .beginRestore(plannedCount: 1)
                case .admitRestoreWrite: .admitRestoreWrite(settingCount: 1)
                case .finishRestore: .finishRestore(expectedCount: 1, confirmedCount: 1)
                case .release: .release
                }
                if let refusal = try Self.refusal(lease, event, at: 100) {
                    #expect(Self.caseName(refusal) != "readNotPermitted")
                }
            }
        }
    }

    // MARK: Determinism

    private static func script() throws -> [(WingLeaseEvent, Int)] {
        let grant = try makeGrant(origin: .assistant, issuedAt: 100, duration: 500, budget: 6)
        return [
            (.beginDiscovery, 50), (.grant(grant), 100), (.admitWrite(origin: .assistant, settingCount: 4), 120),
            (.admitWrite(origin: .assistant, settingCount: 2), 130), (.beginRestore(plannedCount: 5), 700),
            (.admitRestoreWrite(settingCount: 3), 701), (.admitRestoreWrite(settingCount: 2), 702),
            (.finishRestore(expectedCount: 5, confirmedCount: 4), 703)
        ]
    }

    private static func states(of events: [(WingLeaseEvent, Int)]) throws -> [WingCompatibilityLease] {
        var lease = WingCompatibilityLease.unleased
        var seen: [WingCompatibilityLease] = [lease]
        for (event, raw) in events {
            lease = try step(lease, event, at: raw)
            seen.append(lease)
        }
        return seen
    }

    @Test func leaseTheSameScriptFromTwoIndependentLeasesGivesIdenticalStatesAtEveryStep() throws {
        let first = try Self.states(of: Self.script())
        let second = try Self.states(of: Self.script())
        #expect(first == second)
        #expect(first.map(\.phase) == [
            .unleased, .readOnlyDiscovery, .authorizedWrite, .authorizedWrite, .authorizedWrite,
            .restoring, .restoring, .restoring, .unleased
        ])
        #expect(first.map(\.writtenSettingCount) == [0, 0, 0, 4, 6, 6, 6, 6, 0])
        #expect(first.map(\.restoreSentCount) == [0, 0, 0, 0, 0, 0, 3, 5, 0])
        #expect(first.last?.lastOutcome == .partial(confirmedCount: 4, plannedCount: 5))
    }

    @Test func leaseARefusedStepInsideAScriptLeavesItResumableFromTheSameState() throws {
        let events = try Self.script()
        let clean = try Self.states(of: events)
        var lease = WingCompatibilityLease.unleased
        for (index, item) in events.enumerated() {
            if index == 4 {
                try Self.expectRefusal(
                    lease, .admitWrite(origin: .assistant, settingCount: 1), at: 130,
                    .budgetExceeded(requested: 1, remaining: 0)
                )
                #expect(lease == clean[4])
            }
            lease = try Self.step(lease, item.0, at: item.1)
            #expect(lease == clean[index + 1])
        }
        #expect(lease == clean.last)
    }
}
