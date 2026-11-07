// swiftlint:disable identifier_name
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RigReservationTests {
    @Test("Rig release is refused until restoration is verified, with no port call")
    func rigReleaseRefusedUntilRestorationVerified() throws {
        let id = try Self.tok("res-a", .reservationID)
        for phase in [RigReservationPhase.running, .restoring, .unresolved] {
            var scenario = Scenario()
            try scenario.drive("res-a", to: phase)
            let at = try Self.instant(scenario.now)
            Self.expectRefusal(.restorationNotVerified(reservation: id, phase: phase), from: scenario.ledger) {
                try $0.releasing(reservation: id, at: at, port: &scenario.lock)
            }
            #expect(scenario.lock.releaseCalls.isEmpty, "\(phase)")
        }
    }

    @Test("Rig release from restored calls the port once and releases")
    func rigReleaseFromRestoredCallsPortOnce() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .restored)
        let id = try Self.tok("res-a", .reservationID)
        let rig = try Self.tok("rig-a", .rigKey)
        let before = scenario.ledger
        let next = try before.releasing(reservation: id, at: Self.instant(scenario.now), port: &scenario.lock)
        #expect(scenario.lock.releaseCalls == [RigLockRequest(rig: rig, holder: id)])
        #expect(next.reservation(id)?.phase == .released)
        #expect(before.reservation(id)?.phase == .restored)
        #expect(next.reservations.count == 1)
    }

    @Test("Rig release refusals from the port leave the reservation restored")
    func rigReleaseLockOutcomesLeaveRestored() throws {
        let id = try Self.tok("res-a", .reservationID)
        let rig = try Self.tok("rig-a", .rigKey)
        let cases: [(RigLockReleaseOutcome?, RigReservationRefusal)] = [
            (.notHeld, .lockNotHeld(rig: rig)), (.unavailable, .lockUnavailable(rig: rig)),
            (nil, .lockUnavailable(rig: rig))
        ]
        for (outcome, expected) in cases {
            var scenario = Scenario()
            try scenario.drive("res-a", to: .restored)
            var lock = ScriptedRigLock(release: outcome.map { [$0] } ?? [])
            let at = try Self.instant(scenario.now)
            Self.expectRefusal(expected, from: scenario.ledger) {
                try $0.releasing(reservation: id, at: at, port: &lock)
            }
            #expect(lock.releaseCalls == [RigLockRequest(rig: rig, holder: id)])
            #expect(scenario.reservationPhase("res-a") == .restored)
        }
    }

    @Test("Rig release of a booked reservation cancels it without a port call")
    func rigReleaseFromBookedMakesNoPortCall() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        try scenario.release("res-a")
        #expect(scenario.lock.releaseCalls.isEmpty)
        #expect(scenario.lock.acquireCalls.isEmpty)
        #expect(scenario.reservationPhase("res-a") == .released)
    }

    @Test("Rig second release is an invalid phase")
    func rigSecondReleaseIsInvalidPhase() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .released)
        let id = try Self.tok("res-a", .reservationID)
        let at = try Self.instant(scenario.now)
        let calls = scenario.lock.releaseCalls.count
        Self.expectRefusal(
            .invalidPhase(reservation: id, phase: .released, operation: .release),
            from: scenario.ledger
        ) { try $0.releasing(reservation: id, at: at, port: &scenario.lock) }
        #expect(scenario.lock.releaseCalls.count == calls)
    }

    @Test("Rig release frees the rig and clears the measurement stamp")
    func rigReleaseFreesRigAndClearsStamp() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .restored)
        let blocked = try Self.request("res-b")
        let blockedAt = try Self.instant(scenario.now)
        Self.expectRefusal(
            .conflictingReservation(
                existing: try Self.tok("res-a", .reservationID),
                rig: try Self.tok("rig-a", .rigKey)
            ),
            from: scenario.ledger
        ) { try $0.booking(blocked, at: blockedAt) }
        try scenario.release("res-a")
        try scenario.book("res-b")
        #expect(scenario.reservationPhase("res-b") == .booked)
        let stamp = Self.refusal { () throws(RigReservationRefusal) in try scenario.ledger.measurementStamp() }
        #expect(stamp == .noActiveExperiment)
    }

    @Test("Rig released reservation never reactivates")
    func rigReleasedReservationRefusesEveryOperation() throws {
        var scenario = Scenario()
        try scenario.drive("res-a", to: .released)
        let id = try Self.tok("res-a", .reservationID)
        let approver = try Self.tok("ops", .approver)
        let plan = try Self.plan("exp-new")
        let value = try Self.baseline()
        let at = try Self.instant(scenario.now)
        func invalid(_ operation: RigOperation) -> RigReservationRefusal {
            .invalidPhase(reservation: id, phase: .released, operation: operation)
        }
        Self.expectRefusal(invalid(.approve), from: scenario.ledger) {
            try $0.approving(reservation: id, kind: .audibility, approver: approver, at: at)
        }
        Self.expectRefusal(invalid(.recordBaseline), from: scenario.ledger) {
            try $0.recordingBaseline(reservation: id, baseline: value, at: at)
        }
        Self.expectRefusal(invalid(.startExperiment), from: scenario.ledger) {
            try $0.startingExperiment(reservation: id, plan: plan, at: at, port: &scenario.lock)
        }
        Self.expectRefusal(invalid(.stopExperiment), from: scenario.ledger) {
            try $0.stoppingExperiment(reservation: id, reason: .completed, at: at)
        }
        Self.expectRefusal(invalid(.reportRestoration), from: scenario.ledger) {
            try $0.reportingRestoration(reservation: id, observed: value, at: at)
        }
        Self.expectRefusal(invalid(.release), from: scenario.ledger) {
            try $0.releasing(reservation: id, at: at, port: &scenario.lock)
        }
    }

    static func stamp(experiment: String, reservation: String = "res-a", rig: String = "rig-a",
                      kind: RigExperimentKind = .analogLoopback) throws -> RigMeasurementStamp {
        RigMeasurementStamp(
            reservation: try tok(reservation, .reservationID),
            experiment: try tok(experiment, .experimentID),
            rig: try tok(rig, .rigKey),
            owner: try tok("owner-1", .owner),
            kind: kind
        )
    }
}
// swiftlint:enable identifier_name
