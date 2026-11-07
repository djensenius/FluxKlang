import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RigReservationTests {
    private static func permutations(_ items: [String]) -> [[String]] {
        guard items.count > 1 else { return [items] }
        var result: [[String]] = []
        for (index, item) in items.enumerated() {
            var rest = items
            rest.remove(at: index)
            result.append(contentsOf: permutations(rest).map { [item] + $0 })
        }
        return result
    }

    @Test("Rig booking any permutation of four non-conflicting requests gives equal ledgers")
    func rigBookingPermutationsGiveEqualLedgers() throws {
        let ids = ["res-d", "res-b", "res-c", "res-a"]
        let all = Self.permutations(ids)
        #expect(all.count == 24)
        var ledgers: [RigReservationLedger] = []
        for order in all {
            var ledger = RigReservationLedger.empty
            for id in order {
                ledger = try ledger.booking(try Self.request(id, rig: "rig-\(id)"), at: try Self.instant(100))
            }
            ledgers.append(ledger)
        }
        let first = try #require(ledgers.first)
        #expect(ledgers.allSatisfy { $0 == first })
        #expect(first.reservations.map(\.id.description) == ["res-a", "res-b", "res-c", "res-d"])
        #expect(first.lastInstant == (try Self.instant(100)))
    }

    @Test("Rig identical lifecycle scripts give equal ledgers and locks")
    func rigIdenticalLifecycleScriptsGiveEqualLedgers() throws {
        func run() throws -> Scenario {
            var scenario = Scenario()
            try scenario.drive("res-a", to: .released)
            try scenario.drive("res-b", to: .unresolved, rig: "rig-b")
            return scenario
        }
        let first = try run()
        let second = try run()
        #expect(first.ledger == second.ledger)
        #expect(first.lock.acquireCalls == second.lock.acquireCalls)
        #expect(first.lock.releaseCalls == second.lock.releaseCalls)
        #expect(first.ledger.hashValue == second.ledger.hashValue)
    }

    @Test("Rig a refusal depends only on its inputs")
    func rigRefusalDependsOnlyOnInputs() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        let id = try Self.tok("res-a", .reservationID)
        let value = try Self.baseline()
        let when = try Self.instant(scenario.now)
        let expected = RigReservationRefusal.invalidPhase(reservation: id, phase: .booked, operation: .stopExperiment)
        for _ in 0..<2 {
            let stop = Self.refusal { () throws(RigReservationRefusal) in
                try scenario.ledger.stoppingExperiment(reservation: id, reason: .completed, at: when)
            }
            #expect(stop == expected)
        }
        let report = Self.refusal { () throws(RigReservationRefusal) in
            try scenario.ledger.reportingRestoration(reservation: id, observed: value, at: when)
        }
        #expect(report == .invalidPhase(reservation: id, phase: .booked, operation: .reportRestoration))
    }

    @Test("Rig a successful operation returns a different ledger and leaves its input unchanged")
    func rigSuccessfulOperationLeavesInputUnchanged() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        let before = scenario.ledger
        let id = try Self.tok("res-a", .reservationID)
        let next = try before.approving(
            reservation: id,
            kind: .audibility,
            approver: try Self.tok("ops", .approver),
            at: try Self.instant(scenario.now)
        )
        #expect(next != before)
        #expect(before == scenario.ledger)
        #expect(before.reservation(id)?.approvals == [])
        let later = try next.recordingBaseline(
            reservation: id,
            baseline: try Self.baseline(),
            at: try Self.instant(scenario.now + 1)
        )
        #expect(later != next)
        #expect(next.reservation(id)?.baseline == nil)
    }

    @Test("Rig measurement stamp names the active experiment while running, restoring and unresolved")
    func rigMeasurementStampWhileActive() throws {
        let expected = try Self.stamp(experiment: "exp-res-a")
        for phase in [RigReservationPhase.running, .restoring, .unresolved] {
            var scenario = Scenario()
            try scenario.drive("res-a", to: phase)
            #expect(try scenario.ledger.measurementStamp() == expected, "\(phase)")
        }
    }

    @Test("Rig measurement stamp carries the kind, rig and owner of the active reservation")
    func rigMeasurementStampCarriesKindRigAndOwner() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .released)
        try scenario.book("res-b", rig: "rig-b")
        try scenario.prepare("res-b")
        try scenario.start("res-b", experiment: "exp-second", kind: .soak)
        let stamp = try scenario.ledger.measurementStamp()
        #expect(stamp == (try Self.stamp(experiment: "exp-second", reservation: "res-b", rig: "rig-b", kind: .soak)))
    }

    @Test("Rig measurement stamp is refused when no experiment is active")
    func rigMeasurementStampRefusedWithoutActiveExperiment() throws {
        let empty = Self.refusal { () throws(RigReservationRefusal) in
            try RigReservationLedger.empty.measurementStamp()
        }
        #expect(empty == .noActiveExperiment)
        for phase in [RigReservationPhase.booked, .restored, .released] {
            var scenario = Scenario()
            try scenario.drive("res-a", to: phase)
            let refused = Self.refusal { () throws(RigReservationRefusal) in try scenario.ledger.measurementStamp() }
            #expect(refused == .noActiveExperiment, "\(phase)")
        }
    }

    @Test("Rig limits are the documented numbers")
    func rigLimitsAreTheDocumentedNumbers() {
        #expect(RigReservationLimits.maximumTokenBytes == 64)
        #expect(RigReservationLimits.maximumInstantSeconds == 9_007_199_254_740_991)
        #expect(RigReservationLimits.maximumWindowSeconds == 604_800)
        #expect(RigReservationLimits.maximumReservations == 64)
        #expect(RigReservationLimits.maximumExperimentsPerReservation == 16)
        #expect(RigReservationLimits.minimumSampleRateHertz == 8_000)
        #expect(RigReservationLimits.maximumSampleRateHertz == 768_000)
        #expect(RigReservationLimits.minimumBufferFrames == 1)
        #expect(RigReservationLimits.maximumBufferFrames == 16_384)
    }
}
