#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif
import Foundation
import Testing

struct RecordingTakeV1GateTests {
    typealias Fixture = TakeLedgerTestFixture
    typealias Refusal = RecordingTakeV1Refusal

    /// The refusal `clear` throws for `take`, or nil when it clears.
    private func refusal(_ take: RecordingTake) -> Refusal? {
        do {
            _ = try RecordingTakeV1Gate.clear(take)
            return nil
        } catch {
            return error
        }
    }

    private func anchoredLedger() throws -> TakeLedger {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.observe(Fixture.anchor(1, 0, host: 0), nominalRate: 48_000)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 0))
        return ledger
    }

    private func unanchoredLedger(from frame: Int64) throws -> TakeLedger {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.open(Fixture.opening(Fixture.take1, 1, frame))
        return ledger
    }

    /// A hand-built segment `index` of a chain: 10 frames, contiguous in the file.
    private func segment(index: Int, generation: Int, foreign: Bool = false,
                         placed: Bool = true) throws -> RecordingSegment {
        let placement: SegmentPlacement = placed
            ? .placed(startOffsetNs: Int64(index) * 1_000) : .unplaced(.anchorNotObserved)
        let opened: SegmentBoundaryReason? = index == 0 ? nil : .clockRestart(previousFrame: 10)
        let source = foreign ? type(of: Fixture.clock).init(validated: "smp.other") : Fixture.clock
        return try RecordingSegment(
            clock: source, generation: Generation(generation), nominalRate: 48_000, startFrame: 0,
            placement: placement, fileFrameStart: Int64(index) * 10, frames: 10, overflows: [], openedBy: opened)
    }

    private func handTake(_ segments: [RecordingSegment]) throws -> RecordingTake {
        try RecordingTake(take: Fixture.take1, stream: Fixture.stream, inputLatency: Fixture.latency(),
                          segments: segments, boundaries: [], stopReason: .user, stopMark: nil)
    }

    /// `count` segments with generations 1...count, the last one optionally moved or unplaced.
    private func chain(count: Int, lastGeneration: Int, lastPlaced: Bool) throws -> RecordingTake {
        var segments = try (0..<(count - 1)).map { try segment(index: $0, generation: $0 + 1) }
        segments.append(try segment(index: count - 1, generation: lastGeneration, placed: lastPlaced))
        return try handTake(segments)
    }

    @Test
    func recordingTakeV1GateClearsTheExampleTakesAndPassesTheTakeThrough() throws {
        var example = try Fixture.example08Take1()
        let take = try example.finish(Fixture.take1, reason: .diskFull)
        #expect(take.segments.map(\.generation.value) == [1, 2])
        #expect(take.unplacedSegments.isEmpty)
        let clearance = try RecordingTakeV1Gate.clear(take)
        #expect(clearance.take == take)
        let again = try RecordingTakeV1Gate.clear(take)
        #expect(again.take == clearance.take)

        var user = try Fixture.ledger()
        try user.advance(Fixture.take1, to: Fixture.stamp(1, 100))
        let userTake = try user.finish(Fixture.take1, reason: .user)
        #expect(userTake.segments.count == 1)
        let userClearance = try RecordingTakeV1Gate.clear(userTake)
        #expect(userClearance.take == userTake)

        var lost = try Fixture.ledger()
        try lost.advance(Fixture.take1, to: Fixture.stamp(1, 100))
        #expect(try lost.ingest(Fixture.stop(1, 100, .deviceLost)) == [.recorded(Fixture.take1)])
        let lostTake = try lost.finish(Fixture.take1, reason: .deviceLost)
        #expect(lostTake.stopReason == .deviceLost)
        #expect(refusal(lostTake) == nil)
    }

    @Test
    func recordingTakeV1GateRefusesALedgerStop() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.observe(Fixture.anchor(1, 0, host: 0), nominalRate: 48_000)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 1000))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
        let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        #expect(try ledger.ingest(Fixture.jump(1, 500)) == [.ended(Fixture.take1, ended)])
        let take = try ledger.finish(Fixture.take1, reason: ended)
        #expect(take.segments.count == 1)
        #expect(take.unplacedSegments.isEmpty)
        Fixture.refusal(.stopReasonNotInContractV1(ended)) { () throws(TakeLedgerError) in
            _ = try ended.contractV1StopReason()
        }
        #expect(refusal(take) == Refusal.stopReason(ended))
    }

    @Test
    func recordingTakeV1GateRefusesASameGenerationSampleJumpSplit() throws {
        var forward = try anchoredLedger()
        try forward.advance(Fixture.take1, to: Fixture.stamp(1, 48_000))
        #expect(try forward.ingest(Fixture.jump(1, 96_000)) == [.split(Fixture.take1)])
        try forward.advance(Fixture.take1, to: Fixture.stamp(1, 144_000))
        let forwardTake = try forward.finish(Fixture.take1, reason: .user)
        #expect(forwardTake.segments.map(\.generation.value) == [1, 1])
        #expect(forwardTake.unplacedSegments.isEmpty)
        #expect(refusal(forwardTake) == Refusal.notRestartSplit(after: 0))

        var backward = try anchoredLedger()
        try backward.advance(Fixture.take1, to: Fixture.stamp(1, 48_000))
        #expect(try backward.ingest(Fixture.jump(1, 24_000)) == [.split(Fixture.take1)])
        try backward.advance(Fixture.take1, to: Fixture.stamp(1, 36_000))
        let backwardTake = try backward.finish(Fixture.take1, reason: .user)
        #expect(backwardTake.segments.map(\.generation.value) == [1, 1])
        #expect(backwardTake.unplacedSegments.isEmpty)
        #expect(refusal(backwardTake) == Refusal.notRestartSplit(after: 0))
    }

    @Test
    func recordingTakeV1GateRefusesAGenerationSkipAfterADroppedEmptySegment() throws {
        var ledger = try anchoredLedger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        let first = Fixture.restart(2, 0, previousFrame: 1000, host: 1_000_000_000)
        #expect(try ledger.ingest(first) == [.split(Fixture.take1)])
        try ledger.observe(Fixture.anchor(2, 0, host: 1_000_000_000), nominalRate: 48_000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 500))
        let second = Fixture.restart(3, 0, previousFrame: 500, host: 1_500_000_000)
        #expect(try ledger.ingest(second) == [.split(Fixture.take1)])
        let third = Fixture.restart(4, 0, previousFrame: 0, host: 2_000_000_000)
        #expect(try ledger.ingest(third) == [.split(Fixture.take1)])
        try ledger.observe(Fixture.anchor(4, 0, host: 2_000_000_000), nominalRate: 48_000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(4, 300))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.generation.value) == [1, 2, 4])
        #expect(take.boundaries.map(\.droppedEmptySegment) == [false, false, true])
        #expect(take.unplacedSegments.isEmpty)
        #expect(refusal(take) == Refusal.notRestartSplit(after: 1))
    }

    @Test
    func recordingTakeV1GateRefusesAnUnplacedSegment() throws {
        var single = try unanchoredLedger(from: 0)
        try single.advance(Fixture.take1, to: Fixture.stamp(1, 100))
        let singleTake = try single.finish(Fixture.take1, reason: .user)
        #expect(singleTake.unplacedSegments == [0])
        #expect(refusal(singleTake) == Refusal.unplacedSegment(0))

        var late = try Fixture.ledger()
        try late.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        let restart = Fixture.restart(2, 5, previousFrame: 1000, host: 2_500_000_000)
        #expect(try late.ingest(restart) == [.split(Fixture.take1)])
        try late.advance(Fixture.take1, to: Fixture.stamp(2, 6))
        let lateTake = try late.finish(Fixture.take1, reason: .user)
        #expect(lateTake.segments.map(\.placement) == [.placed(startOffsetNs: 0), .unplaced(.anchorNotObserved)])
        #expect(lateTake.segments.map(\.generation.value) == [1, 2])
        #expect(refusal(lateTake) == Refusal.unplacedSegment(1))

        var both = try unanchoredLedger(from: 0)
        try both.advance(Fixture.take1, to: Fixture.stamp(1, 100))
        let bothRestart = Fixture.restart(2, 0, previousFrame: 100, host: 1_000_000_000)
        #expect(try both.ingest(bothRestart) == [.split(Fixture.take1)])
        try both.advance(Fixture.take1, to: Fixture.stamp(2, 50))
        let bothTake = try both.finish(Fixture.take1, reason: .user)
        #expect(bothTake.segments.map(\.generation.value) == [1, 2])
        #expect(bothTake.unplacedSegments == [0, 1])
        #expect(refusal(bothTake) == Refusal.unplacedSegment(0))
    }

    @Test
    func recordingTakeV1GateReportsTheFirstRefusalInFixedOrder() throws {
        var split = try unanchoredLedger(from: 1000)
        try split.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
        #expect(try split.ingest(Fixture.jump(1, 1500)) == [.split(Fixture.take1)])
        try split.advance(Fixture.take1, to: Fixture.stamp(1, 1600))
        var ended = split
        let pairFirst = try split.finish(Fixture.take1, reason: .user)
        #expect(pairFirst.segments.map(\.generation.value) == [1, 1])
        #expect(pairFirst.unplacedSegments == [0, 1])
        #expect(refusal(pairFirst) == Refusal.notRestartSplit(after: 0))

        let stop = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        #expect(try ended.ingest(Fixture.jump(1, 500)) == [.ended(Fixture.take1, stop)])
        let allThree = try ended.finish(Fixture.take1, reason: stop)
        #expect(allThree.segments.map(\.generation.value) == [1, 1])
        #expect(allThree.unplacedSegments == [0, 1])
        #expect(refusal(allThree) == Refusal.stopReason(stop))

        var lone = try unanchoredLedger(from: 0)
        try lone.advance(Fixture.take1, to: Fixture.stamp(1, 100))
        #expect(try lone.ingest(Fixture.stop(1, 100, .diskFull)) == [.recorded(Fixture.take1)])
        let loneTake = try lone.finish(Fixture.take1, reason: .diskFull)
        #expect(loneTake.unplacedSegments == [0])
        #expect(refusal(loneTake) == Refusal.unplacedSegment(0))
    }

    @Test
    func recordingTakeV1GateRefusesASampleSourceChangeAndAMaximumGeneration() throws {
        let same = try handTake([segment(index: 0, generation: 1), segment(index: 1, generation: 2)])
        #expect(refusal(same) == nil)
        let changed = try handTake([
            segment(index: 0, generation: 1),
            segment(index: 1, generation: 2, foreign: true)
        ])
        #expect(refusal(changed) == Refusal.notRestartSplit(after: 0))

        let top = Generation.maximumValue
        let reachesTop = try handTake([segment(index: 0, generation: top - 1), segment(index: 1, generation: top)])
        #expect(refusal(reachesTop) == nil)
        let wraps = try handTake([segment(index: 0, generation: top), segment(index: 1, generation: 1)])
        #expect(refusal(wraps) == Refusal.notRestartSplit(after: 0))

        let twoBad = try handTake([
            segment(index: 0, generation: 1),
            segment(index: 1, generation: 3),
            segment(index: 2, generation: 5)
        ])
        #expect(refusal(twoBad) == Refusal.notRestartSplit(after: 0))
    }

    @Test
    func recordingTakeV1GateScansEverySegmentPairAtTheLedgerLimit() throws {
        let count = TakeLedger.maximumSegmentsPerTake
        #expect(count == 1_024)
        let clear = try chain(count: count, lastGeneration: count, lastPlaced: true)
        #expect(clear.segments.count == count)
        #expect(refusal(clear) == nil)
        let skipped = try chain(count: count, lastGeneration: count + 1, lastPlaced: true)
        #expect(refusal(skipped) == Refusal.notRestartSplit(after: 1_022))
        let unplaced = try chain(count: count, lastGeneration: count, lastPlaced: false)
        #expect(refusal(unplaced) == Refusal.unplacedSegment(1_023))
    }

    // MARK: - RecordingTakeV1Record (#110 TKX1)

    typealias RecordRefusal = RecordingTakeV1RecordRefusal

    /// Example 08's `tk.1` record (seq 8), keys sorted, compact.
    static let example08TakeOneJSON = #"{"droppedFrames":1536,"#
        + #""inputLatency":{"measuredFrames":null,"reportedFrames":312},"kind":"take","#
        + #""note":"Reported latency is not measured latency; no loopback measurement was made.","#
        + #""segments":[{"fileFrameStart":0,"frames":960000,"generation":1,"paddedFrames":1024,"#
        + #""sampleClock":"smp.main","startFrame":0,"startOffsetNs":0},{"fileFrameStart":960000,"frames":480000,"#
        + #""generation":2,"paddedFrames":512,"sampleClock":"smp.main","startFrame":0,"startOffsetNs":20833333333}],"#
        + #""seq":8,"stopReason":"diskFull","stream":"str.take-in","takeId":"tk.1"}"#

    private func json(_ record: RecordingTakeV1Record) throws -> String {
        try #require(String(data: record.encodedJSON(), encoding: .utf8))
    }

    private func recordRefusal(_ take: RecordingTake, seq: Int = 1, note: String? = nil) throws -> RecordRefusal? {
        let clearance = try RecordingTakeV1Gate.clear(take)
        do {
            _ = try RecordingTakeV1Record.make(clearance, seq: seq, note: note)
            return nil
        } catch {
            return error
        }
    }

    /// A one-segment `user` take of 100 frames with the given IDs and latency.
    private func idTake(take: String = "tk.1", stream: String = "str.take-in", clock: String = "smp.main",
                        latency: InputLatency? = nil) throws -> RecordingTake {
        let segment = try RecordingSegment(
            clock: ClockID(clock), generation: Generation(1), nominalRate: 48_000, startFrame: 0,
            placement: .placed(startOffsetNs: 0), fileFrameStart: 0, frames: 100, overflows: [], openedBy: nil)
        return try RecordingTake(take: TakeID(take), stream: StreamID(stream),
                                 inputLatency: latency ?? Fixture.latency(), segments: [segment], boundaries: [],
                                 stopReason: .user, stopMark: nil)
    }

    @Test
    func recordingTakeV1RecordEncodesExample08TakeOneExactly() throws {
        var example = try Fixture.example08Take1()
        let take = try example.finish(Fixture.take1, reason: .diskFull)
        let note = "Reported latency is not measured latency; no loopback measurement was made."
        let record = try RecordingTakeV1Record.make(RecordingTakeV1Gate.clear(take), seq: 8, note: note)
        #expect(record.segments.count == 2)
        let second = try #require(record.segments.last)
        #expect(second.startOffsetNs == 20_833_333_333)
        #expect(second.fileFrameStart == 960_000)
        #expect(record.droppedFrames == 1_536)
        #expect(try json(record) == Self.example08TakeOneJSON)

        let again = try RecordingTakeV1Record.make(RecordingTakeV1Gate.clear(take), seq: 8, note: note)
        #expect(again == record)
        #expect(try again.encodedJSON() == record.encodedJSON())
    }

    @Test
    func recordingTakeV1RecordEncodesExample08TakeTwoExactly() throws {
        var ledger = try Fixture.example08Take1()
        _ = try ledger.finish(Fixture.take1, reason: .diskFull)
        try ledger.open(Fixture.opening(Fixture.take2, 2, 600_000))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(2, 720_000))
        #expect(try ledger.ingest(Fixture.stop(2, 720_000, .deviceLost)) == [.recorded(Fixture.take2)])
        let take = try ledger.finish(Fixture.take2, reason: .deviceLost)
        let record = try RecordingTakeV1Record.make(RecordingTakeV1Gate.clear(take), seq: 10)
        let only = try #require(record.segments.first)
        #expect(record.segments.count == 1 && only.generation.value == 2 && only.startFrame == 600_000)
        // Example 08 seq 10, keys sorted, compact; it has no note.
        let expected = #"{"droppedFrames":0,"inputLatency":{"measuredFrames":null,"reportedFrames":312},"kind":"take","#
            + #""segments":[{"fileFrameStart":0,"frames":120000,"generation":2,"paddedFrames":0,"#
            + #""sampleClock":"smp.main","startFrame":600000,"startOffsetNs":0}],"seq":10,"stopReason":"deviceLost","#
            + #""stream":"str.take-in","takeId":"tk.2"}"#
        #expect(try json(record) == expected)
    }

    @Test
    func recordingTakeV1RecordMapsEveryContractV1StopReasonAndOmitsAnAbsentNote() throws {
        var user = try Fixture.ledger()
        try user.advance(Fixture.take1, to: Fixture.stamp(1, 100))
        let userRecord = try RecordingTakeV1Record.make(
            RecordingTakeV1Gate.clear(user.finish(Fixture.take1, reason: .user)), seq: 1)
        #expect(userRecord.stopReason == "user")
        #expect(userRecord.note == nil)
        let userJSON = #"{"droppedFrames":0,"inputLatency":{"measuredFrames":null,"reportedFrames":312},"kind":"take","#
            + #""segments":[{"fileFrameStart":0,"frames":100,"generation":1,"paddedFrames":0,"sampleClock":"smp.main","#
            + #""startFrame":0,"startOffsetNs":0}],"seq":1,"stopReason":"user","stream":"str.take-in","takeId":"tk.1"}"#
        #expect(try json(userRecord) == userJSON)

        for reason in [RuntimeCaptureStopReason.diskFull, .deviceLost] {
            var ledger = try Fixture.ledger()
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 100))
            #expect(try ledger.ingest(Fixture.stop(1, 100, reason)) == [.recorded(Fixture.take1)])
            let take = try ledger.finish(Fixture.take1, reason: TakeStopReason(reason))
            let record = try RecordingTakeV1Record.make(RecordingTakeV1Gate.clear(take), seq: 2)
            let expected = reason == .diskFull ? "diskFull" : "deviceLost"
            #expect(record.stopReason == expected)
            #expect(try json(record).contains(#""stopReason":"\#(expected)","#))
            #expect(try !json(record).contains(#""note""#))
        }
    }

    @Test
    func recordingTakeV1RecordWritesMeasuredLatencyOnlyWhenMeasured() throws {
        let unmeasured = try RecordingTakeV1Record.make(RecordingTakeV1Gate.clear(idTake()), seq: 3)
        #expect(unmeasured.inputLatency.measuredFrames == nil)
        #expect(try json(unmeasured).contains(#""inputLatency":{"measuredFrames":null,"reportedFrames":312}"#))

        let measured = try InputLatency(reportedFrames: 312,
                                        measured: MeasuredLatency(frames: 296, evidence: "loopback run 1/3"))
        let record = try RecordingTakeV1Record.make(RecordingTakeV1Gate.clear(idTake(latency: measured)), seq: 3)
        #expect(record.inputLatency.measuredFrames == 296)
        #expect(record.inputLatency.reportedFrames == 312)
        let expected = #""inputLatency":{"evidence":"loopback run 1/3","measuredFrames":296,"reportedFrames":312}"#
        #expect(try json(record).contains(expected))

        let zero = try InputLatency(reportedFrames: 0, measured: MeasuredLatency(frames: 0, evidence: "loopback"))
        let zeroRecord = try RecordingTakeV1Record.make(RecordingTakeV1Gate.clear(idTake(latency: zero)), seq: 3)
        #expect(try json(zeroRecord).contains(#"{"evidence":"loopback","measuredFrames":0,"reportedFrames":0}"#))
    }

    @Test
    func recordingTakeV1RecordReportsTheFirstRefusalInFixedOrder() throws {
        let allBad = try idTake(take: "TK.1", stream: "str_in", clock: "smp:main")
        #expect(try recordRefusal(allBad, seq: 0, note: "") == RecordRefusal.invalidSeq(0))
        #expect(try recordRefusal(allBad, seq: Int.min) == RecordRefusal.invalidSeq(Int.min))
        #expect(try recordRefusal(allBad, note: "") == RecordRefusal.invalidTakeID(TakeID("TK.1")))
        let badStream = try idTake(stream: "str_in", clock: "smp:main")
        #expect(try recordRefusal(badStream, note: "") == RecordRefusal.invalidStream(StreamID("str_in")))
        let badClock = try idTake(clock: "smp:main")
        #expect(try recordRefusal(badClock, note: "") == RecordRefusal.invalidSampleClock(segment: 0))

        let good = try idTake()
        #expect(try recordRefusal(good, note: "") == RecordRefusal.invalidNote(bytes: 0))
        #expect(try recordRefusal(good, note: " \n\t") == RecordRefusal.invalidNote(bytes: 3))
        let limit = RecordingTakeV1Record.maximumNoteBytes
        #expect(limit == 256)
        #expect(try recordRefusal(good, note: String(repeating: "a", count: limit + 1))
            == RecordRefusal.invalidNote(bytes: 257))
        #expect(try recordRefusal(good, note: String(repeating: "é", count: 129))
            == RecordRefusal.invalidNote(bytes: 258))
        #expect(try recordRefusal(good, note: String(repeating: "a", count: limit)) == nil)
        #expect(try recordRefusal(good, note: String(repeating: "é", count: 128)) == nil)
        #expect(try recordRefusal(good, seq: 1, note: nil) == nil)

        // Zero frames never reach the record: the segment itself refuses them.
        Fixture.refusal(.inconsistentRecord(.frames)) { () throws(TakeLedgerError) in
            _ = try RecordingSegment(
                clock: Fixture.clock, generation: Generation.initial, nominalRate: 48_000, startFrame: 0,
                placement: .placed(startOffsetNs: 0), fileFrameStart: 0, frames: 0, overflows: [], openedBy: nil)
        }
    }

    @Test
    func recordingTakeV1RecordMatchesTheMediaContractIDPatternExactly() {
        for valid in ["tk.1", "a.b", "a-b.c.d-e", "str.take-in", "a..b", "a.-", "z9-.0"] {
            #expect(MediaContractV1ID.matches(valid), "\(valid)")
        }
        for invalid in ["", "tk", "tk.", ".tk", "1k.a", "-a.b", "Tk.1", "tk.A", "tk_1.a", "tk.a_b", "tk:1.a", "tk.1\n",
                        "tk.é"] {
            #expect(!MediaContractV1ID.matches(invalid), "\(invalid)")
        }
    }

    @Test
    func recordingTakeV1RecordKeepsEverySegmentAtTheLedgerLimitAndRefusesOneMore() throws {
        let count = TakeLedger.maximumSegmentsPerTake
        let take = try chain(count: count, lastGeneration: count, lastPlaced: true)
        let record = try RecordingTakeV1Record.make(RecordingTakeV1Gate.clear(take), seq: 1)
        #expect(record.segments.count == count)
        let last = try #require(record.segments.last)
        #expect(last.generation.value == count)
        #expect(last.fileFrameStart == Int64(count - 1) * 10)
        #expect(last.startOffsetNs == Int64(count - 1) * 1_000)
        #expect(try record.encodedJSON() == record.encodedJSON())

        // The gate sets no count limit, so a hand-built take one past the ledger limit clears and is refused here.
        let over = try chain(count: count + 1, lastGeneration: count + 1, lastPlaced: true)
        #expect(refusal(over) == nil)
        #expect(try recordRefusal(over) == RecordRefusal.tooManySegments(count: count + 1, limit: count))
        #expect(try recordRefusal(over, seq: 0) == RecordRefusal.invalidSeq(0))
    }
}
