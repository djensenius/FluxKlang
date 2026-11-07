import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Pressure thresholds, the decision table, the integer arithmetic, invalid requests and the validation
/// order of `ResourcePressurePolicy` (#78, PLG6, slice A).
extension PluginResourceTests {
    private struct InvalidRequest {
        let thresholds: PressureThresholds
        let used: Int
        let total: Int
        let held: Int
        let expected: PressureRejection
    }

    /// One request per way of being invalid, each with numbers that would be deferred or rejected if the
    /// request kind were looked at first (90 percent of 1,000, or 900 of a 800 total).
    private static func invalidRequests() -> [InvalidRequest] {
        let crossed = PressureThresholds(defer: 50, reject: 49)
        let sound = PressureThresholds(defer: 50, reject: 80)
        return [
            InvalidRequest(
                thresholds: crossed, used: 900, total: 1_000, held: 0, expected: .invalidThresholds(crossed)
            ),
            InvalidRequest(
                thresholds: sound, used: 900, total: 800, held: 0,
                expected: .invalidLedger(usedScratchBytes: 900, totalScratchBytes: 800)
            ),
            InvalidRequest(thresholds: sound, used: 900, total: 1_000, held: -1, expected: .invalidHeldNotes(-1))
        ]
    }

    private static func decision(_ item: InvalidRequest, _ request: WorkRequest) -> PressureDecision {
        evaluate(
            ResourcePressurePolicy(thresholds: item.thresholds), used: item.used, total: item.total, request,
            held: item.held
        )
    }

    private static func allKinds() throws -> [WorkRequest] {
        try [.realTimeCritical, .scan, .stateWork, newRequest()]
    }

    @Test func thresholdsStoreTheirPercentages() {
        let thresholds = PressureThresholds(defer: 20, reject: 70)
        #expect(thresholds.deferAtPercent == 20)
        #expect(thresholds.rejectAtPercent == 70)
    }

    @Test func thresholdsAreValidOnlyWhenOneToHundredAndOrdered() {
        for (deferAt, rejectAt) in [(1, 1), (1, 100), (100, 100), (50, 50), (50, 51), (99, 100)] {
            #expect(PressureThresholds(defer: deferAt, reject: rejectAt).isValid)
        }
        let invalid = [(0, 50), (0, 0), (-1, 50), (50, 49), (51, 50), (2, 1), (1, 101), (100, 101), (101, 101)]
        for (deferAt, rejectAt) in invalid + [(50, Int.max), (Int.min, 5), (Int.max, Int.max)] {
            #expect(!PressureThresholds(defer: deferAt, reject: rejectAt).isValid)
        }
    }

    @Test func evaluateRejectsInvalidThresholdsWithTheirOwnValues() {
        let invalid = [(0, 50), (50, 49), (1, 101), (-3, -2), (Int.max, Int.max)]
        for (deferAt, rejectAt) in invalid {
            let bad = PressureThresholds(defer: deferAt, reject: rejectAt)
            let decision = Self.evaluate(ResourcePressurePolicy(thresholds: bad), used: 0, .scan)
            #expect(decision == .reject(.invalidThresholds(bad)))
        }
    }

    @Test func evaluateAcceptsThresholdsAtTheEdgesOfTheValidRange() {
        for (deferAt, rejectAt) in [(1, 1), (1, 100), (100, 100), (50, 50)] {
            #expect(Self.evaluate(Self.policy(deferAt, rejectAt), used: 0, .scan) == .proceed)
        }
    }

    @Test func scanAndStateWorkAreDeferredFromTheDeferThresholdUp() {
        let policy = Self.policy(50, 80)
        for request in [WorkRequest.scan, .stateWork] {
            #expect(Self.evaluate(policy, used: 0, request) == .proceed)
            #expect(Self.evaluate(policy, used: 499, request) == .proceed)
            #expect(Self.evaluate(policy, used: 500, request) == .defer(percent: 50))
            #expect(Self.evaluate(policy, used: 799, request) == .defer(percent: 79))
            #expect(Self.evaluate(policy, used: 800, request) == .defer(percent: 80))
            #expect(Self.evaluate(policy, used: 999, request) == .defer(percent: 99))
            #expect(Self.evaluate(policy, used: 1_000, request) == .defer(percent: 100))
        }
    }

    @Test func newReservationsAreRejectedFromTheRejectThresholdUp() throws {
        let policy = Self.policy(50, 80)
        let request = try Self.newRequest()
        #expect(Self.evaluate(policy, used: 0, request) == .proceed)
        #expect(Self.evaluate(policy, used: 499, request) == .proceed)
        #expect(Self.evaluate(policy, used: 500, request) == .proceed)
        #expect(Self.evaluate(policy, used: 799, request) == .proceed)
        #expect(Self.evaluate(policy, used: 800, request) == .reject(.overPressure(percent: 80)))
        #expect(Self.evaluate(policy, used: 999, request) == .reject(.overPressure(percent: 99)))
        #expect(Self.evaluate(policy, used: 1_000, request) == .reject(.overPressure(percent: 100)))
    }

    @Test func realTimeCriticalWorkProceedsAtEveryPressure() {
        let policy = Self.policy(50, 80)
        for used in [0, 1, 499, 500, 799, 800, 999, 1_000] {
            #expect(Self.evaluate(policy, used: used, .realTimeCritical) == .proceed)
        }
        #expect(Self.evaluate(Self.policy(1, 1), used: 1_000, .realTimeCritical) == .proceed)
    }

    @Test func equalDeferAndRejectThresholdsActAtTheSamePressure() throws {
        let policy = Self.policy(60, 60)
        let request = try Self.newRequest()
        #expect(Self.evaluate(policy, used: 599, .scan) == .proceed)
        #expect(Self.evaluate(policy, used: 599, request) == .proceed)
        #expect(Self.evaluate(policy, used: 600, .scan) == .defer(percent: 60))
        #expect(Self.evaluate(policy, used: 600, request) == .reject(.overPressure(percent: 60)))
    }

    @Test func thresholdsAtTheEdgesOfTheRangeBehave() throws {
        let request = try Self.newRequest()
        let tightest = Self.policy(1, 1)
        #expect(Self.evaluate(tightest, used: 9, .scan) == .proceed)
        #expect(Self.evaluate(tightest, used: 10, .scan) == .defer(percent: 1))
        #expect(Self.evaluate(tightest, used: 9, request) == .proceed)
        #expect(Self.evaluate(tightest, used: 10, request) == .reject(.overPressure(percent: 1)))
        let loosest = Self.policy(100, 100)
        #expect(Self.evaluate(loosest, used: 999, .scan) == .proceed)
        #expect(Self.evaluate(loosest, used: 1_000, .scan) == .defer(percent: 100))
        #expect(Self.evaluate(loosest, used: 999, request) == .proceed)
        #expect(Self.evaluate(loosest, used: 1_000, request) == .reject(.overPressure(percent: 100)))
    }

    @Test func pressureIsTheFloorOfUsedOverTotalInPercent() {
        let policy = Self.policy(1, 100)
        #expect(Self.evaluate(policy, used: 1, total: 3, .scan) == .defer(percent: 33))
        #expect(Self.evaluate(policy, used: 2, total: 3, .scan) == .defer(percent: 66))
        #expect(Self.evaluate(policy, used: 1, total: 7, .scan) == .defer(percent: 14))
        #expect(Self.evaluate(policy, used: 6, total: 7, .scan) == .defer(percent: 85))
        #expect(Self.evaluate(policy, used: 199, total: 200, .scan) == .defer(percent: 99))
        #expect(Self.evaluate(policy, used: 1, total: 101, .scan) == .proceed)
        #expect(Self.evaluate(policy, used: 1, total: 100, .scan) == .defer(percent: 1))
    }

    @Test func pressureIsExactAtTheLargestTotal() {
        let policy = Self.policy(1, 100)
        let total = 16_777_216
        #expect(Self.evaluate(policy, used: 0, total: total, .scan) == .proceed)
        #expect(Self.evaluate(policy, used: 167_772, total: total, .scan) == .proceed)
        #expect(Self.evaluate(policy, used: 167_773, total: total, .scan) == .defer(percent: 1))
        #expect(Self.evaluate(policy, used: 8_388_608, total: total, .scan) == .defer(percent: 50))
        #expect(Self.evaluate(policy, used: 16_777_215, total: total, .scan) == .defer(percent: 99))
        #expect(Self.evaluate(policy, used: 16_777_216, total: total, .scan) == .defer(percent: 100))
    }

    @Test func theSmallestTotalIsOneByte() throws {
        let policy = Self.policy(1, 100)
        #expect(Self.evaluate(policy, used: 0, total: 1, .scan) == .proceed)
        #expect(Self.evaluate(policy, used: 1, total: 1, .scan) == .defer(percent: 100))
        let request = try Self.newRequest()
        #expect(Self.evaluate(policy, used: 1, total: 1, request) == .reject(.overPressure(percent: 100)))
    }

    @Test func evaluateRejectsLedgerNumbersNoLedgerCanHoldWithoutTrapping() throws {
        let policy = Self.policy(50, 80)
        let numbers = [
            (0, 0), (0, -1), (0, 16_777_217), (0, Int.max), (0, Int.min), (-1, 1_000), (1_001, 1_000),
            (Int.max, 1_000), (Int.min, 1_000), (16_777_217, 16_777_216), (2, 1), (-1, 1)
        ]
        for request in try Self.allKinds() {
            for (used, total) in numbers {
                let decision = Self.evaluate(policy, used: used, total: total, request)
                #expect(decision == .reject(.invalidLedger(usedScratchBytes: used, totalScratchBytes: total)))
            }
        }
    }

    @Test func negativeHeldNotesAreRejectedAndZeroIsAccepted() throws {
        let policy = Self.policy(50, 80)
        let base = try Self.ledger()
        for request in try Self.allKinds() {
            #expect(Self.evaluate(policy, used: 0, request, held: -1) == .reject(.invalidHeldNotes(-1)))
            #expect(Self.evaluate(policy, used: 0, request, held: Int.min) == .reject(.invalidHeldNotes(Int.min)))
            #expect(Self.evaluate(policy, used: 0, request, held: 0) == .proceed)
            #expect(policy.evaluate(ledger: base, request: request, heldNotes: -1) == .reject(.invalidHeldNotes(-1)))
            #expect(policy.evaluate(ledger: base, request: request, heldNotes: 0) == .proceed)
        }
    }

    @Test func heldNotesNeverChangeAValidDecision() throws {
        let policy = Self.policy(50, 80)
        let request = try Self.newRequest()
        for held in [0, 1, 2, 64, 1_000_000, Int.max] {
            #expect(Self.evaluate(policy, used: 900, .scan, held: held) == .defer(percent: 90))
            #expect(Self.evaluate(policy, used: 900, .stateWork, held: held) == .defer(percent: 90))
            #expect(Self.evaluate(policy, used: 900, request, held: held) == .reject(.overPressure(percent: 90)))
            #expect(Self.evaluate(policy, used: 900, .realTimeCritical, held: held) == .proceed)
            #expect(Self.evaluate(policy, used: 100, .scan, held: held) == .proceed)
            #expect(Self.evaluate(policy, used: 100, request, held: held) == .proceed)
        }
    }

    @Test func noPressureDecisionReleasesAReservation() throws {
        let requests = try Self.allKinds()
        var decisions = 0
        for (deferAt, rejectAt) in [(1, 1), (50, 80), (100, 100), (1, 100), (0, 0), (90, 10)] {
            let policy = Self.policy(deferAt, rejectAt)
            for request in requests {
                for used in [-1, 0, 1, 499, 500, 799, 800, 999, 1_000, 1_001] {
                    for held in [-1, 0, 1, 64, Int.max] {
                        let decision = Self.evaluate(policy, used: used, request, held: held)
                        #expect(!decision.releasesReservation)
                        decisions += 1
                    }
                }
            }
        }
        #expect(decisions == 1_200)
    }

    @Test func instanceExhaustionIsNotPressure() throws {
        let policy = Self.policy(1, 1)
        let base = try Self.ledger(total: 1_000, instances: 4)
        let allInstances = try base.reserve(Self.reservation(Self.identity("Aaaa"), instances: 4))
        #expect(allInstances.availableInstances == 0)
        for request in [WorkRequest.scan, .stateWork, try Self.newRequest()] {
            #expect(policy.evaluate(ledger: allInstances, request: request, heldNotes: 0) == .proceed)
        }
    }

    @Test func evaluateReadsTheLedgersReservedScratchOverItsTotal() throws {
        let policy = Self.policy(50, 80)
        let base = try Self.ledger(total: 1_000, instances: 8)
        let half = try base.reserve(Self.reservation(Self.identity("Aaaa"), scratch: 500, instances: 1))
        let request = try Self.newRequest()
        #expect(policy.evaluate(ledger: base, request: .scan, heldNotes: 3) == .proceed)
        #expect(policy.evaluate(ledger: half, request: .scan, heldNotes: 3) == .defer(percent: 50))
        #expect(policy.evaluate(ledger: half, request: request, heldNotes: 3) == .proceed)
        let most = try half.reserve(Self.reservation(Self.identity("Bbbb"), scratch: 300, instances: 1))
        #expect(policy.evaluate(ledger: most, request: request, heldNotes: 3) == .reject(.overPressure(percent: 80)))
        let relieved = try most.release(owner: Self.identity("Bbbb"))
        #expect(policy.evaluate(ledger: relieved, request: request, heldNotes: 3) == .proceed)
        let quarter = try Self.reservation(Self.identity("Cccc"), scratch: 500)
        let wide = try Self.ledger(total: 2_000, instances: 8).reserve(quarter)
        #expect(policy.evaluate(ledger: wide, request: .scan, heldNotes: 0) == .proceed)
    }

    @Test func aNewReservationIsJudgedByThePressureNotByItsOwnContents() throws {
        let policy = Self.policy(50, 80)
        let contents = try [
            Self.reservation(Self.identity("Aaaa"), scratch: 1),
            Self.reservation(Self.identity("Bbbb"), pinned: true),
            Self.reservation(Self.identity("Cccc"), scratch: 16_777_216, instances: 256, pinned: true),
            Self.reservation(Self.identity("Dddd"), instances: 1)
        ]
        for item in contents {
            #expect(Self.evaluate(policy, used: 799, .newReservation(item)) == .proceed)
            #expect(Self.evaluate(policy, used: 800, .newReservation(item)) == .reject(.overPressure(percent: 80)))
        }
    }

    @Test func validityChecksThresholdsBeforeTheLedgerNumbersAndHeldNotes() {
        let crossed = PressureThresholds(defer: 0, reject: 0)
        let policy = ResourcePressurePolicy(thresholds: crossed)
        let decision = Self.evaluate(policy, used: -1, total: 0, .scan, held: -1)
        #expect(decision == .reject(.invalidThresholds(crossed)))
    }

    @Test func validityChecksTheLedgerNumbersBeforeHeldNotes() {
        let decision = Self.evaluate(Self.policy(50, 80), used: 5, total: 4, .scan, held: -1)
        #expect(decision == .reject(.invalidLedger(usedScratchBytes: 5, totalScratchBytes: 4)))
    }

    @Test func invalidRequestsAreRejectedWhateverTheHeldNotes() throws {
        let crossed = PressureThresholds(defer: 50, reject: 49)
        let kinds = try Self.allKinds()
        for held in [1, 64, Int.max] {
            for request in kinds {
                let badThresholds = Self.evaluate(
                    ResourcePressurePolicy(thresholds: crossed), used: 900, request, held: held
                )
                #expect(badThresholds == .reject(.invalidThresholds(crossed)))
                let badLedger = Self.evaluate(Self.policy(50, 80), used: 900, total: 800, request, held: held)
                #expect(badLedger == .reject(.invalidLedger(usedScratchBytes: 900, totalScratchBytes: 800)))
            }
        }
    }

    @Test func invalidRequestsBeatRealTimeCriticalWork() {
        for item in Self.invalidRequests() {
            #expect(Self.decision(item, .realTimeCritical) == .reject(item.expected))
        }
    }

    @Test func invalidRequestsBeatScanAndStateWork() {
        for item in Self.invalidRequests() {
            #expect(Self.decision(item, .scan) == .reject(item.expected))
            #expect(Self.decision(item, .stateWork) == .reject(item.expected))
        }
    }

    @Test func invalidRequestsBeatNewReservations() throws {
        let request = try Self.newRequest()
        for item in Self.invalidRequests() {
            #expect(Self.decision(item, request) == .reject(item.expected))
        }
    }
}
