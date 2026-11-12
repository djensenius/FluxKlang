#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif
import Foundation
import Testing

// MARK: - A forward sampleJump splits a take and exports `gapFrames` (#352)

extension RecordingTakeV1GateTests {
    /// The note example 12's `sampleJump` record carries.
    static let example12JumpNote = "The device's frame counter jumped forward: frame 240000 is the first frame "
        + "after the jump."

    /// Example 12's `tk.1` records (seqs 2 to 4), keys sorted, compact: 512 frames dropped at 48000, then a
    /// forward `sampleJump` to frame 240000 splits the take with 144000 frames never captured.
    static let example12OverflowJSON = #"{"frame":48000,"frames":512,"generation":1,"kind":"discontinuity","#
        + #""sampleClock":"smp.main","seq":2,"stream":"str.take-in","type":"overflow"}"#

    static let example12JumpJSON = #"{"frame":240000,"generation":1,"kind":"discontinuity","#
        + #""note":"The device's frame counter jumped forward: frame 240000 is the first frame after the jump.","#
        + #""sampleClock":"smp.main","seq":3,"type":"sampleJump"}"#

    static let example12TakeJSON = #"{"droppedFrames":512,"#
        + #""inputLatency":{"measuredFrames":null,"reportedFrames":312},"kind":"take","segments":["#
        + #"{"fileFrameStart":0,"frames":96000,"generation":1,"paddedFrames":512,"sampleClock":"smp.main","#
        + #""startFrame":0,"startOffsetNs":0},"#
        + #"{"fileFrameStart":96000,"frames":96000,"gapFrames":144000,"generation":1,"paddedFrames":0,"#
        + #""sampleClock":"smp.main","startFrame":240000,"startOffsetNs":5000000000}],"#
        + #""seq":4,"stopReason":"user","stream":"str.take-in","takeId":"tk.1"}"#

    /// A ledger that opened `tk.1` at frame 0 and has dropped 512 frames at 48000, advanced to the jump's frontier.
    private func ledgerBeforeTheJump(overflowAt frame: Int64 = 48_000) throws -> TakeLedger {
        var ledger = try Fixture.ledger(at: 0)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, frame + 512))
        #expect(try ledger.ingest(Fixture.overflow(1, frame, frames: 512)) == [.recorded(Fixture.take1)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 96_000))
        return ledger
    }

    private func clear(_ take: RecordingTake) throws -> RecordingTakeV1Clearance {
        try RecordingTakeV1Gate.clear(take)
    }

    private func json(_ record: RecordingTakeV1Record) throws -> String {
        try #require(String(data: record.encodedJSON(), encoding: .utf8))
    }

    @Test
    func recordingTakeV1ExportsAForwardSampleJumpSplitAsExample12() throws {
        var ledger = try ledgerBeforeTheJump()
        #expect(try ledger.ingest(Fixture.jump(1, 240_000)) == [.split(Fixture.take1)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 336_000))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.startFrame) == [0, 240_000] && take.segments.map(\.frames) == [96_000, 96_000])
        #expect(take.segments.map(\.fileFrameStart) == [0, 96_000] && take.droppedFrames == 512)
        #expect(take.segments.map(\.startOffsetNs) == [0, 5_000_000_000])
        let boundary = try #require(take.boundaries.first)
        #expect(take.boundaries.count == 1 && boundary.reason == .sampleJump && boundary.frame == 240_000)

        let clearance = try clear(take)
        #expect(RecordingTakeV1Discontinuities.count(of: clearance) == 1)
        let overflow = try RecordingTakeV1Discontinuities.make(clearance, seqs: [2])
        // The recorder states the jump itself: the boundary the ledger kept is the record's frame.
        let jump = try DiscontinuityV1Record.make(
            .sampleJump, sampleClock: Fixture.clock, generation: boundary.generation, frame: boundary.frame, seq: 3,
            note: Self.example12JumpNote)
        let record = try RecordingTakeV1Record.make(clearance, seq: 4)
        #expect(record.segments.map(\.gapFrames) == [nil, 144_000])
        #expect(try overflow.map { try #require(String(data: $0.encodedJSON(), encoding: .utf8)) }
            == [Self.example12OverflowJSON])
        #expect(try #require(String(data: jump.encodedJSON(), encoding: .utf8)) == Self.example12JumpJSON)
        #expect(try json(record) == Self.example12TakeJSON)
        // The gap is not padding: the file stays contiguous and nothing but the overflow is dropped.
        #expect(record.droppedFrames == 512 && record.segments.map(\.paddedFrames) == [512, 0])
        #expect(try json(RecordingTakeV1Record.make(clear(take), seq: 4)) == Self.example12TakeJSON)
    }

    @Test
    func recordingTakeV1ExportsAForwardSampleJumpWithAnOverflowInBothSegments() throws {
        var ledger = try ledgerBeforeTheJump()
        #expect(try ledger.ingest(Fixture.jump(1, 240_000)) == [.split(Fixture.take1)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 250_100))
        #expect(try ledger.ingest(Fixture.overflow(1, 250_000, frames: 100)) == [.recorded(Fixture.take1)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 336_000))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.paddedFrames) == [512, 100] && take.droppedFrames == 612)

        let clearance = try clear(take)
        let seqs = Array(2..<(2 + RecordingTakeV1Discontinuities.count(of: clearance)))
        let overflows = try RecordingTakeV1Discontinuities.make(clearance, seqs: seqs)
        #expect(overflows.map(\.frame) == [48_000, 250_000] && overflows.map(\.event.type) == ["overflow", "overflow"])
        let record = try RecordingTakeV1Record.make(clearance, seq: 4)
        #expect(record.segments.map(\.gapFrames) == [nil, 144_000])
        #expect(record.segments.map(\.paddedFrames) == [512, 100] && record.droppedFrames == 612)
    }

    @Test
    func recordingTakeV1AJumpThenARestartGivesOnlyTheSameGenerationPairAGap() throws {
        var ledger = try ledgerBeforeTheJump()
        #expect(try ledger.ingest(Fixture.jump(1, 240_000)) == [.split(Fixture.take1)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 336_000))
        #expect(try ledger.ingest(Fixture.restart(2, 0, previousFrame: 336_000, host: 2_900_000_000))
            == [.split(Fixture.take1)])
        try ledger.observe(Fixture.anchor(2, 48_000, host: 2_924_000_000), nominalRate: 48_000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 48_000))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.generation.value) == [1, 1, 2])

        let record = try RecordingTakeV1Record.make(clear(take), seq: 7)
        #expect(record.segments.map(\.gapFrames) == [nil, 144_000, nil])
        #expect(record.segments.map(\.startOffsetNs) == [0, 5_000_000_000, 20_833_333_333])
        #expect(record.segments.map(\.fileFrameStart) == [0, 96_000, 192_000])
        #expect(try json(record).components(separatedBy: "gapFrames").count == 2)
    }

    @Test
    func recordingTakeV1AZeroGapAndABackwardPairAreRefused() throws {
        var zero = try ledgerBeforeTheJump()
        #expect(try zero.ingest(Fixture.jump(1, 96_000)) == [.split(Fixture.take1)])
        try zero.advance(Fixture.take1, to: Fixture.stamp(1, 144_000))
        let zeroTake = try zero.finish(Fixture.take1, reason: .user)
        #expect(zeroTake.segments.map(\.startFrame) == [0, 96_000])
        #expect(refusal(zeroTake) == Refusal.sampleJumpNotForward(after: 0))

        var backward = try ledgerBeforeTheJump()
        #expect(try backward.ingest(Fixture.jump(1, 90_000)) == [.split(Fixture.take1)])
        try backward.advance(Fixture.take1, to: Fixture.stamp(1, 100_000))
        let backwardTake = try backward.finish(Fixture.take1, reason: .user)
        #expect(backwardTake.segments.map(\.startFrame) == [0, 90_000])
        #expect(refusal(backwardTake) == Refusal.sampleJumpNotForward(after: 0))
        #expect(throws: RecordingTakeV1Refusal.sampleJumpNotForward(after: 0)) { try clear(backwardTake) }
    }

    @Test
    func recordingTakeV1TheGapIsMeasuredFromThePreviousStoredSegment() throws {
        var ledger = try ledgerBeforeTheJump()
        #expect(try ledger.ingest(Fixture.jump(1, 240_000)) == [.split(Fixture.take1)])
        // The second jump lands before anything was captured after the first: the empty segment is dropped.
        #expect(try ledger.ingest(Fixture.jump(1, 300_000)) == [.split(Fixture.take1)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 396_000))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.boundaries.map(\.droppedEmptySegment) == [false, true])
        #expect(take.segments.map(\.startFrame) == [0, 300_000])

        let record = try RecordingTakeV1Record.make(clear(take), seq: 5)
        #expect(record.segments.map(\.gapFrames) == [nil, 204_000])
        #expect(record.segments.map(\.startOffsetNs) == [0, 6_250_000_000])
    }

    @Test
    func recordingTakeV1AForwardPairClearsBeforeAnUnplacedSegmentRefuses() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 0))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1_000))
        #expect(try ledger.ingest(Fixture.jump(1, 5_000)) == [.split(Fixture.take1)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 6_000))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.unplacedSegments == [0, 1])
        #expect(refusal(take) == Refusal.unplacedSegment(0))
    }

    private func gapTake(firstStart: Int64, secondStart: Int64) throws -> RecordingTake {
        func segment(_ start: Int64, fileFrameStart: Int64) throws -> RecordingSegment {
            try RecordingSegment(clock: Fixture.clock, generation: .initial, nominalRate: 48_000, startFrame: start,
                                 placement: .placed(startOffsetNs: 0), fileFrameStart: fileFrameStart, frames: 10,
                                 overflows: [], openedBy: nil)
        }
        return try RecordingTake(take: Fixture.take1, stream: Fixture.stream, inputLatency: Fixture.latency(),
                                 segments: [segment(firstStart, fileFrameStart: 0),
                                            segment(secondStart, fileFrameStart: 10)],
                                 boundaries: [], stopReason: .user, stopMark: nil)
    }

    @Test
    func recordingTakeV1AGapOutsideTheSchemaRangeIsRefusedNotClamped() throws {
        // The second segment must still fit (startFrame + frames), so the largest gap here is Int64.max - 10.
        let largest = try gapTake(firstStart: -10, secondStart: .max - 10)
        let record = try RecordingTakeV1Record.make(clear(largest), seq: 1)
        #expect(record.segments.map(\.gapFrames) == [nil, Int64.max - 10])
        #expect(try json(record).contains(#""gapFrames":9223372036854775797"#))

        let tooFar = try gapTake(firstStart: .min, secondStart: 100)
        let clearance = try clear(tooFar)
        #expect(throws: RecordingTakeV1RecordRefusal.gapFramesOutOfRange(segment: 1)) {
            try RecordingTakeV1Record.make(clearance, seq: 1)
        }
    }
}
