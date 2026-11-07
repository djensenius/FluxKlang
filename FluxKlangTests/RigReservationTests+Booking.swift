// swiftlint:disable identifier_name
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RigReservationTests {
    @Test("Rig booking creates a booked reservation with exact fields")
    func rigBookingCreatesBookedReservationWithExactFields() throws {
        let request = try Self.request("res-a", rig: "rig-a", start: 1_000, end: 2_000)
        let ledger = try RigReservationLedger.empty.booking(request, at: Self.instant(500))
        let reservation = try #require(ledger.reservation(try Self.tok("res-a", .reservationID)))
        #expect(reservation.id == request.id)
        #expect(reservation.rig == request.rig)
        #expect(reservation.owner == request.owner)
        #expect(reservation.window == request.window)
        #expect(reservation.phase == .booked)
        #expect(reservation.approvals == [])
        #expect(reservation.baseline == nil)
        #expect(reservation.experiments == [])
        #expect(reservation.unresolvedFieldCount == 0)
        #expect(ledger.reservations.count == 1)
        #expect(ledger.lastInstant == (try Self.instant(500)))
        #expect(RigReservationLedger.empty.reservations.isEmpty)
        #expect(RigReservationLedger.empty.lastInstant == nil)
    }

    @Test("Rig booking refuses same-rig overlaps")
    func rigBookingRejectsSameRigOverlaps() throws {
        let existing = try Self.request("res-a", start: 1_000, end: 2_000)
        let ledger = try RigReservationLedger.empty.booking(existing, at: Self.instant(10))
        let rig = try Self.tok("rig-a", .rigKey)
        let existingID = try Self.tok("res-a", .reservationID)
        let windows = [(1_000, 2_000), (1_200, 1_800), (500, 3_000), (1_500, 2_500), (500, 1_500), (1_999, 3_000),
                       (500, 1_001)]
        for (start, end) in windows {
            let request = try Self.request("res-b", start: start, end: end)
            let at = try Self.instant(11)
            Self.expectRefusal(.conflictingReservation(existing: existingID, rig: rig), from: ledger) {
                try $0.booking(request, at: at)
            }
        }
    }

    @Test("Rig booking accepts adjacent windows and other rigs")
    func rigBookingAcceptsAdjacentWindowsAndDifferentRigs() throws {
        var scenario = Scenario()
        try scenario.book("res-a", start: 3_000, end: 4_000)
        try scenario.book("res-b", start: 4_000, end: 5_000)
        try scenario.book("res-c", start: 2_000, end: 3_000)
        try scenario.book("res-d", rig: "rig-b", start: 3_000, end: 4_000)
        #expect(scenario.ledger.reservations.map(\.id.description) == ["res-a", "res-b", "res-c", "res-d"])
    }

    @Test("Rig released reservation no longer conflicts")
    func rigReleasedReservationNoLongerConflicts() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        let blocked = try Self.request("res-b")
        let rig = try Self.tok("rig-a", .rigKey)
        let at = try Self.instant(scenario.now)
        Self.expectRefusal(
            .conflictingReservation(existing: try Self.tok("res-a", .reservationID), rig: rig),
            from: scenario.ledger
        ) { try $0.booking(blocked, at: at) }
        try scenario.release("res-a")
        try scenario.book("res-b")
        #expect(scenario.ledger.reservations.map(\.phase) == [.released, .booked])
    }

    @Test("Rig booking reports the lowest conflicting id by bytes")
    func rigBookingReportsLowestConflictingIdByBytes() throws {
        for order in [["res-b", "res-c"], ["res-c", "res-b"]] {
            var scenario = Scenario()
            try scenario.book(order[0], start: 1_000, end: 1_500)
            try scenario.book(order[1], start: 1_500, end: 2_000)
            let request = try Self.request("res-a", start: 1_000, end: 2_000)
            let at = try Self.instant(scenario.now)
            let rig = try Self.tok("rig-a", .rigKey)
            Self.expectRefusal(
                .conflictingReservation(existing: try Self.tok("res-b", .reservationID), rig: rig),
                from: scenario.ledger
            ) { try $0.booking(request, at: at) }
        }
    }

    @Test("Rig booking reports a duplicate id before a conflict")
    func rigBookingDuplicateIdBeatsConflict() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        let same = try Self.request("res-a")
        let at = try Self.instant(scenario.now)
        Self.expectRefusal(.duplicateReservation(try Self.tok("res-a", .reservationID)), from: scenario.ledger) {
            try $0.booking(same, at: at)
        }
    }

    @Test("Rig booking refuses a duplicate id even after release")
    func rigBookingDuplicateIdIncludesReleased() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .released)
        let again = try Self.request("res-a", rig: "rig-z")
        let at = try Self.instant(scenario.now)
        Self.expectRefusal(.duplicateReservation(try Self.tok("res-a", .reservationID)), from: scenario.ledger) {
            try $0.booking(again, at: at)
        }
    }

    @Test("Rig booking reports a conflict before a full ledger")
    func rigBookingConflictBeatsLedgerFull() throws {
        var scenario = Scenario()
        for index in 0..<64 {
            try scenario.book("res-\(String(format: "%02d", index))", rig: "rig-\(index)")
        }
        let request = try Self.request("res-new", rig: "rig-0")
        let at = try Self.instant(scenario.now)
        Self.expectRefusal(
            .conflictingReservation(
                existing: try Self.tok("res-00", .reservationID),
                rig: try Self.tok("rig-0", .rigKey)
            ),
            from: scenario.ledger
        ) { try $0.booking(request, at: at) }
    }

    @Test("Rig ledger holds 64 reservations and refuses the 65th")
    func rigLedgerHoldsSixtyFourReservationsAndRefusesTheSixtyFifth() throws {
        var scenario = Scenario()
        for index in 0..<64 {
            try scenario.book("res-\(String(format: "%02d", index))", rig: "rig-\(index)")
        }
        #expect(scenario.ledger.reservations.count == RigReservationLimits.maximumReservations)
        let request = try Self.request("res-65", rig: "rig-65")
        let at = try Self.instant(scenario.now)
        Self.expectRefusal(.ledgerFull(count: 64), from: scenario.ledger) { try $0.booking(request, at: at) }
        try scenario.release("res-00")
        Self.expectRefusal(.ledgerFull(count: 64), from: scenario.ledger) { try $0.booking(request, at: at) }
    }

    @Test("Rig booking window end boundary")
    func rigBookingWindowEndBoundary() throws {
        let ended = try Self.request("res-a", start: 100, end: 200)
        let at = try Self.instant(200)
        Self.expectRefusal(.windowAlreadyEnded(end: 200, now: 200), from: .empty) { try $0.booking(ended, at: at) }
        let later = try Self.instant(201)
        Self.expectRefusal(.windowAlreadyEnded(end: 200, now: 201), from: .empty) { try $0.booking(ended, at: later) }
        let accepted = try RigReservationLedger.empty.booking(ended, at: Self.instant(199))
        #expect(accepted.reservations.count == 1)
    }

    @Test("Rig booking reports time going backwards before an ended window")
    func rigBookingTimeBackwardsBeatsWindowEnded() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        let ended = try Self.request("res-b", rig: "rig-b", start: 10, end: 20)
        let at = try Self.instant(scenario.now - 2)
        Self.expectRefusal(.timeWentBackwards(last: scenario.now - 1, got: scenario.now - 2), from: scenario.ledger) {
            try $0.booking(ended, at: at)
        }
    }

    @Test("Rig booking reports an ended window before a duplicate id")
    func rigBookingWindowEndedBeatsDuplicate() throws {
        var scenario = Scenario()
        try scenario.book("res-a", start: 1_000, end: 2_000)
        let same = try Self.request("res-a", start: 100, end: 200)
        let at = try Self.instant(scenario.now)
        Self.expectRefusal(.windowAlreadyEnded(end: 200, now: scenario.now), from: scenario.ledger) {
            try $0.booking(same, at: at)
        }
    }

    @Test("Rig booking keeps reservations sorted by id bytes")
    func rigBookingKeepsReservationsSortedByIdBytes() throws {
        var scenario = Scenario()
        for (index, id) in ["res-m", "res-a", "res_z", "res-z", "res0", "res.k"].enumerated() {
            try scenario.book(id, rig: "rig-\(index)")
        }
        let ids = scenario.ledger.reservations.map(\.id.description)
        #expect(ids == ["res-a", "res-m", "res-z", "res.k", "res0", "res_z"])
    }

    @Test("Rig booking a refused request keeps the last instant")
    func rigRefusedBookingKeepsLastInstant() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        let before = scenario.ledger.lastInstant
        let request = try Self.request("res-a")
        let later = try Self.instant(scenario.now + 50)
        let refused = Self.refusal { () throws(RigReservationRefusal) in
            try scenario.ledger.booking(request, at: later)
        }
        #expect(refused != nil)
        #expect(scenario.ledger.lastInstant == before)
    }
}
// swiftlint:enable identifier_name
