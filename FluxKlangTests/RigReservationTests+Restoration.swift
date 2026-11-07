// swiftlint:disable identifier_name
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RigReservationTests {
    private static let allStopReasons: [RigStopReason] =
        [.completed, .operatorAbort, .windowEnded] + RigStopCondition.allCases.map { .condition($0) }

    @Test("Rig stop records every reason verbatim and enters restoring")
    func rigStopRecordsEveryReasonVerbatim() throws {
        #expect(Self.allStopReasons.count == 10)
        for reason in Self.allStopReasons {
            var scenario = Scenario()
            try scenario.drive("res-a", to: .running)
            let stopAt = scenario.now
            try scenario.stop("res-a", reason: reason)
            let reservation = try scenario.reservation("res-a")
            #expect(reservation.phase == .restoring, "\(reason)")
            let record = try #require(reservation.experiments.last)
            #expect(record.stop == RigStopRecord(reason: reason, at: try Self.instant(stopAt)), "\(reason)")
            #expect(scenario.lock.releaseCalls.isEmpty)
        }
    }

    @Test("Rig stop is allowed after the window ended and keeps the lock")
    func rigStopAllowedAfterWindowEnd() throws {
        var scenario = Scenario()
        try scenario.book("res-a", start: 1_000, end: 1_100)
        try scenario.prepare("res-a")
        try scenario.start("res-a", experiment: "exp-a")
        scenario.now = 9_000
        try scenario.stop("res-a", reason: .windowEnded)
        #expect(scenario.reservationPhase("res-a") == .restoring)
        scenario.now = 9_500
        try scenario.report("res-a")
        #expect(scenario.reservationPhase("res-a") == .restored)
        #expect(scenario.lock.releaseCalls.isEmpty)
    }

    @Test("Rig stop is refused outside the running phase")
    func rigStopRefusedOutsideRunning() throws {
        let id = try Self.tok("res-a", .reservationID)
        for phase in RigReservationPhase.allCases where phase != .running {
            var scenario = Scenario()
            try scenario.drive("res-a", to: phase)
            let at = try Self.instant(scenario.now)
            Self.expectRefusal(
                .invalidPhase(reservation: id, phase: phase, operation: .stopExperiment),
                from: scenario.ledger
            ) { try $0.stoppingExperiment(reservation: id, reason: .completed, at: at) }
        }
    }

    @Test("Rig matching restoration report verifies restoration")
    func rigMatchingReportRestores() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .restoring)
        try scenario.report("res-a")
        let reservation = try scenario.reservation("res-a")
        #expect(reservation.phase == .restored)
        #expect(reservation.unresolvedFieldCount == 0)
        #expect(reservation.baseline == (try Self.baseline()))
        #expect(scenario.lock.releaseCalls.isEmpty)
    }

    @Test("Rig mismatching restoration report is a success that leaves the reservation unresolved")
    func rigMismatchLeavesReservationUnresolved() throws {
        for field in 0..<7 {
            var scenario = Scenario()
            try scenario.drive("res-a", to: .restoring)
            try scenario.report("res-a", changing: [field])
            let reservation = try scenario.reservation("res-a")
            #expect(reservation.phase == .unresolved, "field \(field)")
            #expect(reservation.unresolvedFieldCount == 1, "field \(field)")
            #expect(reservation.baseline == (try Self.baseline()), "the baseline is never replaced")
        }
        var all = Scenario()
        try all.drive("res-a", to: .restoring)
        try all.report("res-a", changing: [0, 1, 2, 3, 4, 5, 6])
        #expect(try all.reservation("res-a").unresolvedFieldCount == 7)
        #expect(try all.reservation("res-a").phase == .unresolved)
    }

    @Test("Rig repeated mismatch stays unresolved and a later match restores")
    func rigRepeatedMismatchStaysUnresolvedThenMatchRestores() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .unresolved)
        #expect(try scenario.reservation("res-a").unresolvedFieldCount == 1)
        try scenario.report("res-a", changing: [1, 2, 4])
        #expect(try scenario.reservation("res-a").phase == .unresolved)
        #expect(try scenario.reservation("res-a").unresolvedFieldCount == 3)
        try scenario.report("res-a")
        #expect(try scenario.reservation("res-a").phase == .restored)
        #expect(try scenario.reservation("res-a").unresolvedFieldCount == 0)
    }

    @Test("Rig restoration report is refused outside restoring and unresolved")
    func rigRestorationReportRefusedOutsidePhases() throws {
        let id = try Self.tok("res-a", .reservationID)
        let observed = try Self.baseline()
        for phase in [RigReservationPhase.booked, .running, .restored, .released] {
            var scenario = Scenario()
            try scenario.drive("res-a", to: phase)
            let at = try Self.instant(scenario.now)
            Self.expectRefusal(
                .invalidPhase(reservation: id, phase: phase, operation: .reportRestoration),
                from: scenario.ledger
            ) { try $0.reportingRestoration(reservation: id, observed: observed, at: at) }
        }
    }

    @Test("Rig experiment start after restoration clears the unresolved count")
    func rigNextExperimentStartsFromRestoredWithZeroUnresolved() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .unresolved)
        try scenario.report("res-a")
        try scenario.start("res-a", experiment: "exp-next")
        let reservation = try scenario.reservation("res-a")
        #expect(reservation.phase == .running)
        #expect(reservation.unresolvedFieldCount == 0)
    }
}
// swiftlint:enable identifier_name
