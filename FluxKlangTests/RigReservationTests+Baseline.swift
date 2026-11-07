// swiftlint:disable identifier_name
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RigReservationTests {
    @Test("Rig clock baseline sample rate bounds")
    func rigClockBaselineSampleRateBounds() throws {
        let source = try Self.tok("clock-a", .clockSource)
        for rate in [8_000, 48_000, 768_000] {
            let sampled = try RigClockBaseline(source: source, sampleRateHertz: rate, bufferFrames: 256)
            #expect(sampled.sampleRateHertz == rate)
        }
        for rate in [7_999, 768_001, 0, -48_000, Int.max] {
            let refused = Self.refusal { () throws(RigReservationRefusal) in
                try RigClockBaseline(source: source, sampleRateHertz: rate, bufferFrames: 256)
            }
            #expect(refused == .invalidSampleRate(rate))
        }
    }

    @Test("Rig clock baseline buffer bounds")
    func rigClockBaselineBufferBounds() throws {
        let source = try Self.tok("clock-a", .clockSource)
        for frames in [1, 256, 16_384] {
            let sized = try RigClockBaseline(source: source, sampleRateHertz: 48_000, bufferFrames: frames)
            #expect(sized.bufferFrames == frames)
        }
        for frames in [0, 16_385, -1, Int.max] {
            let refused = Self.refusal { () throws(RigReservationRefusal) in
                try RigClockBaseline(source: source, sampleRateHertz: 48_000, bufferFrames: frames)
            }
            #expect(refused == .invalidBufferFrames(frames))
        }
    }

    @Test("Rig clock baseline checks the sample rate before the buffer")
    func rigClockBaselineChecksRateBeforeBuffer() throws {
        let source = try Self.tok("clock-a", .clockSource)
        let refused = Self.refusal { () throws(RigReservationRefusal) in
            try RigClockBaseline(source: source, sampleRateHertz: 7_999, bufferFrames: 0)
        }
        #expect(refused == .invalidSampleRate(7_999))
        let reversed = Self.refusal { () throws(RigReservationRefusal) in
            try RigClockBaseline(source: source, sampleRateHertz: 768_001, bufferFrames: 16_385)
        }
        #expect(reversed == .invalidSampleRate(768_001))
    }

    @Test("Rig differing field count is zero only for equal baselines")
    func rigDifferingFieldCountIsZeroOnlyForEqualBaselines() throws {
        let first = try Self.baseline()
        let second = try Self.baseline()
        #expect(first == second)
        #expect(first.differingFieldCount(from: second) == 0)
        #expect(try first.differingFieldCount(from: Self.baseline(changing: [0])) == 1)
    }

    @Test("Rig differing field count counts each single-field change")
    func rigDifferingFieldCountCountsEachSingleFieldChange() throws {
        let reference = try Self.baseline()
        for field in 0..<7 {
            let changed = try Self.baseline(changing: [field])
            #expect(changed != reference, "field \(field)")
            #expect(changed.differingFieldCount(from: reference) == 1, "field \(field)")
            #expect(reference.differingFieldCount(from: changed) == 1, "field \(field)")
        }
    }

    @Test("Rig differing field count adds up several changes")
    func rigDifferingFieldCountAddsUpSeveralChanges() throws {
        let reference = try Self.baseline()
        #expect(try Self.baseline(changing: [0, 1, 2, 3, 4, 5, 6]).differingFieldCount(from: reference) == 7)
        #expect(try Self.baseline(changing: [1, 4]).differingFieldCount(from: reference) == 2)
        #expect(try Self.baseline(changing: [0, 2, 6]).differingFieldCount(from: reference) == 3)
        #expect(try Self.baseline(changing: [3, 4, 5, 6]).differingFieldCount(from: reference) == 4)
    }

    // MARK: Recording the baseline

    @Test("Rig baseline is recorded once and kept verbatim")
    func rigBaselineRecordedOnceAndKeptVerbatim() throws {
        var scenario = Scenario()
        try scenario.book("res-a")
        let id = try Self.tok("res-a", .reservationID)
        let value = try Self.baseline()
        let before = scenario.ledger
        let next = try before.recordingBaseline(reservation: id, baseline: value, at: Self.instant(1_001))
        #expect(next.reservation(id)?.baseline == value)
        #expect(before.reservation(id)?.baseline == nil)
        #expect(next.lastInstant == (try Self.instant(1_001)))
        let altered = try Self.baseline(changing: [1])
        let later = try Self.instant(1_002)
        Self.expectRefusal(.baselineAlreadyRecorded(reservation: id), from: next) {
            try $0.recordingBaseline(reservation: id, baseline: altered, at: later)
        }
        #expect(next.reservation(id)?.baseline == value)
    }

    @Test("Rig baseline is refused once the phase is not booked")
    func rigBaselineRefusedOutsideBookedPhase() throws {
        let id = try Self.tok("res-a", .reservationID)
        let value = try Self.baseline()
        for phase in RigReservationPhase.allCases where phase != .booked {
            var scenario = Scenario()
            try scenario.drive("res-a", to: phase)
            let at = try Self.instant(scenario.now)
            Self.expectRefusal(
                .invalidPhase(reservation: id, phase: phase, operation: .recordBaseline),
                from: scenario.ledger
            ) { try $0.recordingBaseline(reservation: id, baseline: value, at: at) }
        }
    }

    @Test("Rig baseline window boundary")
    func rigBaselineBoundaryAtWindowEnd() throws {
        var scenario = Scenario()
        try scenario.book("res-a", start: 1_000, end: 2_000)
        let id = try Self.tok("res-a", .reservationID)
        let value = try Self.baseline()
        let accepted = try scenario.ledger.recordingBaseline(reservation: id, baseline: value, at: Self.instant(1_999))
        #expect(accepted.reservation(id)?.baseline == value)
        let end = try Self.instant(2_000)
        Self.expectRefusal(.windowExpired(reservation: id), from: scenario.ledger) {
            try $0.recordingBaseline(reservation: id, baseline: value, at: end)
        }
    }

    @Test("Rig baseline may be recorded before the window starts")
    func rigBaselineMayBeRecordedBeforeTheWindowStarts() throws {
        var scenario = Scenario()
        try scenario.book("res-a", start: 3_000, end: 4_000)
        let id = try Self.tok("res-a", .reservationID)
        let next = try scenario.ledger.recordingBaseline(
            reservation: id,
            baseline: try Self.baseline(),
            at: Self.instant(1_001)
        )
        #expect(next.reservation(id)?.phase == .booked)
        #expect(next.reservation(id)?.baseline == (try Self.baseline()))
    }

    @Test("Rig baseline checks phase, then window, then a second record")
    func rigBaselineChecksPhaseBeforeWindowBeforeDuplicate() throws {
        let id = try Self.tok("res-a", .reservationID)
        let value = try Self.baseline()
        var running = Scenario()
        try running.book("res-a", start: 1_000, end: 1_100)
        try running.prepare("res-a")
        try running.start("res-a", experiment: "exp-a")
        let late = try Self.instant(1_100)
        Self.expectRefusal(
            .invalidPhase(reservation: id, phase: .running, operation: .recordBaseline),
            from: running.ledger
        ) { try $0.recordingBaseline(reservation: id, baseline: value, at: late) }

        var booked = Scenario()
        try booked.book("res-a", start: 1_000, end: 1_100)
        booked.ledger = try booked.ledger.recordingBaseline(reservation: id, baseline: value, at: Self.instant(1_001))
        Self.expectRefusal(.windowExpired(reservation: id), from: booked.ledger) {
            try $0.recordingBaseline(reservation: id, baseline: value, at: late)
        }
    }
}
// swiftlint:enable identifier_name
