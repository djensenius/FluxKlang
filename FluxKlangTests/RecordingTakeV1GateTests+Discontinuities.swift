#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif
import Foundation
import Testing

// MARK: - RecordingTakeV1Discontinuities (#110 TKX2)

extension RecordingTakeV1GateTests {
    typealias DiscontinuityRefusal = RecordingTakeV1DiscontinuityRefusal

    /// Example 08's `tk.1` discontinuities (seqs 2, 6 and 7), keys sorted, compact.
    static let example08TakeOneDiscontinuityJSON = [
        #"{"frame":480000,"frames":1024,"generation":1,"kind":"discontinuity","sampleClock":"smp.main","seq":2,"#
            + #""stream":"str.take-in","type":"overflow"}"#,
        #"{"frame":192000,"frames":512,"generation":2,"kind":"discontinuity","sampleClock":"smp.main","seq":6,"#
            + #""stream":"str.take-in","type":"overflow"}"#,
        #"{"frame":480000,"generation":2,"kind":"discontinuity","note":"Writer finalised the partial file.","#
            + #""reason":"diskFull","sampleClock":"smp.main","seq":7,"stream":"str.take-in","type":"captureStopped"}"#
    ]

    private func json(_ records: [RecordingTakeV1DiscontinuityRecord]) throws -> [String] {
        var lines: [String] = []
        for record in records {
            lines.append(try #require(String(data: record.encodedJSON(), encoding: .utf8)))
        }
        return lines
    }

    private func discontinuityRefusal(_ take: RecordingTake, seqs: [Int],
                                      notes: [Int: String] = [:]) throws -> DiscontinuityRefusal? {
        let clearance = try RecordingTakeV1Gate.clear(take)
        do {
            _ = try RecordingTakeV1Discontinuities.make(clearance, seqs: seqs, notes: notes)
            return nil
        } catch {
            return error
        }
    }

    /// A `user` take with one restart-split segment of `frames` frames per element of `overflows`.
    private func overflowTake(stream: String = "str.take-in", clock: String = "smp.main", frames: Int64 = 1_000,
                              overflows: [[OverflowInterval]]) throws -> RecordingTake {
        let segments = try overflows.enumerated().map { index, intervals in
            try RecordingSegment(
                clock: ClockID(clock), generation: Generation(index + 1), nominalRate: 48_000, startFrame: 0,
                placement: .placed(startOffsetNs: Int64(index) * 1_000), fileFrameStart: Int64(index) * frames,
                frames: frames, overflows: intervals, openedBy: index == 0 ? nil : .clockRestart(previousFrame: frames))
        }
        return try RecordingTake(take: Fixture.take1, stream: StreamID(stream), inputLatency: Fixture.latency(),
                                 segments: segments, boundaries: [], stopReason: .user, stopMark: nil)
    }

    @Test
    func recordingTakeV1DiscontinuitiesEncodeExample08TakeOneExactly() throws {
        var example = try Fixture.example08Take1()
        let clearance = try RecordingTakeV1Gate.clear(example.finish(Fixture.take1, reason: .diskFull))
        #expect(RecordingTakeV1Discontinuities.count(of: clearance) == 3)
        let note = "Writer finalised the partial file."
        let records = try RecordingTakeV1Discontinuities.make(clearance, seqs: [2, 6, 7], notes: [7: note])
        #expect(records.map(\.type) == [.overflow, .overflow, .captureStopped])
        let stop = try #require(records.last)
        #expect(stop.generation.value == 2 && stop.frame == 480_000 && stop.reason == "diskFull")
        #expect(try json(records) == Self.example08TakeOneDiscontinuityJSON)

        let again = try RecordingTakeV1Discontinuities.make(clearance, seqs: [2, 6, 7], notes: [7: note])
        #expect(again == records)
        #expect(try json(again) == json(records))

        let bare = try RecordingTakeV1Discontinuities.make(clearance, seqs: [1, 2, 3])
        #expect(bare.map(\.seq) == [1, 2, 3] && bare.allSatisfy { $0.note == nil })
        let bareStop = try #require(json(bare).last)
        #expect(!bareStop.contains(#""note""#) && !bareStop.contains(#""frames""#))
    }

    @Test
    func recordingTakeV1DiscontinuitiesEncodeExample08TakeTwoExactly() throws {
        var ledger = try Fixture.example08Take1()
        _ = try ledger.finish(Fixture.take1, reason: .diskFull)
        try ledger.open(Fixture.opening(Fixture.take2, 2, 600_000))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(2, 720_000))
        #expect(try ledger.ingest(Fixture.stop(2, 720_000, .deviceLost)) == [.recorded(Fixture.take2)])
        let clearance = try RecordingTakeV1Gate.clear(ledger.finish(Fixture.take2, reason: .deviceLost))
        #expect(RecordingTakeV1Discontinuities.count(of: clearance) == 1)
        let records = try RecordingTakeV1Discontinuities.make(clearance, seqs: [9])
        // Example 08 seq 9, keys sorted, compact.
        let expected = #"{"frame":720000,"generation":2,"kind":"discontinuity","reason":"deviceLost","#
            + #""sampleClock":"smp.main","seq":9,"stream":"str.take-in","type":"captureStopped"}"#
        #expect(try json(records) == [expected])
    }

    @Test
    func recordingTakeV1DiscontinuitiesWriteNoCaptureStoppedForAUserStop() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2_000))
        #expect(try ledger.ingest(Fixture.overflow(1, 1_000, frames: 16)) == [.recorded(Fixture.take1)])
        let clearance = try RecordingTakeV1Gate.clear(ledger.finish(Fixture.take1, reason: .user))
        #expect(RecordingTakeV1Discontinuities.count(of: clearance) == 1)
        let records = try RecordingTakeV1Discontinuities.make(clearance, seqs: [4])
        let only = try #require(records.first)
        #expect(records.count == 1 && only.type == .overflow && only.frame == 1_000 && only.frames == 16)

        var quiet = try Fixture.ledger()
        try quiet.advance(Fixture.take1, to: Fixture.stamp(1, 100))
        let quietClearance = try RecordingTakeV1Gate.clear(quiet.finish(Fixture.take1, reason: .user))
        #expect(RecordingTakeV1Discontinuities.count(of: quietClearance) == 0)
        #expect(try RecordingTakeV1Discontinuities.make(quietClearance, seqs: []).isEmpty)
    }

    @Test
    func recordingTakeV1DiscontinuitiesReportTheFirstRefusalInFixedOrder() throws {
        let one = try OverflowInterval(startFrame: 10, frames: 5)
        let huge = try OverflowInterval(startFrame: 0, frames: RecordingTakeV1DiscontinuityRecord.maximumFrames + 1)
        let allBad = try overflowTake(stream: "str_in", clock: "smp:main", overflows: [[one]])
        #expect(try discontinuityRefusal(allBad, seqs: []) == DiscontinuityRefusal.seqCount(expected: 1, actual: 0))
        #expect(try discontinuityRefusal(allBad, seqs: [1, 2]) == DiscontinuityRefusal.seqCount(expected: 1, actual: 2))
        #expect(try discontinuityRefusal(allBad, seqs: [0]) == DiscontinuityRefusal.invalidSeq(index: 0, seq: 0))
        #expect(try discontinuityRefusal(allBad, seqs: [1], notes: [1: ""])
            == DiscontinuityRefusal.invalidStream(StreamID("str_in")))
        let badClock = try overflowTake(clock: "smp:main", overflows: [[one]])
        #expect(try discontinuityRefusal(badClock, seqs: [1], notes: [1: ""])
            == DiscontinuityRefusal.invalidSampleClock(segment: 0))
        let badClockAndFrames = try overflowTake(clock: "smp:main", frames: 5_000_000_000, overflows: [[huge]])
        #expect(try discontinuityRefusal(badClockAndFrames, seqs: [1])
            == DiscontinuityRefusal.invalidSampleClock(segment: 0))

        let big = try overflowTake(frames: 5_000_000_000, overflows: [[], [huge], [one]])
        #expect(try discontinuityRefusal(big, seqs: [3, 0]) == DiscontinuityRefusal.invalidSeq(index: 1, seq: 0))
        #expect(try discontinuityRefusal(big, seqs: [3, 3]) == DiscontinuityRefusal.seqNotIncreasing(index: 1, seq: 3))
        #expect(try discontinuityRefusal(big, seqs: [3, 2]) == DiscontinuityRefusal.seqNotIncreasing(index: 1, seq: 2))
        #expect(try discontinuityRefusal(big, seqs: [2, 3], notes: [1: ""])
            == DiscontinuityRefusal.overflowFramesOutOfRange(segment: 1, frames: 4_294_967_296))

        let good = try overflowTake(overflows: [[one], [one]])
        let limit = RecordingTakeV1Record.maximumNoteBytes
        #expect(try discontinuityRefusal(good, seqs: [2, 5], notes: [2: "", 1: "x"])
            == DiscontinuityRefusal.noteWithoutRecord(seq: 1))
        #expect(try discontinuityRefusal(good, seqs: [2, 5], notes: [2: " \n", 9: "x"])
            == DiscontinuityRefusal.invalidNote(seq: 2, bytes: 2))
        #expect(try discontinuityRefusal(good, seqs: [2, 5], notes: [2: "ok", 5: String(repeating: "é", count: 129)])
            == DiscontinuityRefusal.invalidNote(seq: 5, bytes: 258))
        #expect(try discontinuityRefusal(good, seqs: [2, 5], notes: [2: "ok", 6: "x"])
            == DiscontinuityRefusal.noteWithoutRecord(seq: 6))
        #expect(try discontinuityRefusal(good, seqs: [2, 5], notes: [5: String(repeating: "a", count: limit)]) == nil)
    }

    @Test
    func recordingTakeV1DiscontinuitiesKeepTheSchemaFramesMaximumAndOrderEverySegment() throws {
        let maximum = RecordingTakeV1DiscontinuityRecord.maximumFrames
        #expect(maximum == 4_294_967_295)
        let first = try OverflowInterval(startFrame: 0, frames: 10)
        let second = try OverflowInterval(startFrame: 20, frames: maximum)
        let take = try overflowTake(frames: 5_000_000_000, overflows: [[first, second], [], [first]])
        let clearance = try RecordingTakeV1Gate.clear(take)
        #expect(RecordingTakeV1Discontinuities.count(of: clearance) == 3)
        let records = try RecordingTakeV1Discontinuities.make(clearance, seqs: [1, 5, 9], notes: [5: "Long drop."])
        #expect(records.map(\.generation.value) == [1, 1, 3])
        #expect(records.map(\.frame) == [0, 20, 0])
        #expect(records.map(\.frames) == [10, maximum, 10])
        let long = try #require(json(records).dropFirst().first)
        #expect(long.hasPrefix(#"{"frame":20,"frames":4294967295,"generation":1,"kind":"discontinuity","#))
        #expect(long.contains(#""note":"Long drop.","sampleClock":"smp.main","seq":5,"#))
    }

    @Test
    func recordingTakeV1DiscontinuitiesRefuseATakePastTheLedgerSegmentLimitLikeTheTakeRecord() throws {
        let limit = TakeLedger.maximumSegmentsPerTake
        let one = try OverflowInterval(startFrame: 10, frames: 5)
        let atLimit = try overflowTake(overflows: Array(repeating: [], count: limit - 1) + [[one]])
        let records = try RecordingTakeV1Discontinuities.make(RecordingTakeV1Gate.clear(atLimit), seqs: [3])
        let last = try #require(records.first)
        #expect(records.count == 1 && last.generation.value == limit)

        let over = try overflowTake(overflows: Array(repeating: [], count: limit) + [[one]])
        let tooMany = DiscontinuityRefusal.tooManySegments(count: limit + 1, limit: limit)
        #expect(try discontinuityRefusal(over, seqs: [3], notes: [3: ""]) == tooMany)
        #expect(try discontinuityRefusal(over, seqs: []) == DiscontinuityRefusal.seqCount(expected: 1, actual: 0))
        let overBadStream = try overflowTake(stream: "str_in", overflows: Array(repeating: [], count: limit + 1))
        #expect(try discontinuityRefusal(overBadStream, seqs: []) == .invalidStream(StreamID("str_in")))
        let overBadClock = try overflowTake(clock: "smp:main", overflows: Array(repeating: [], count: limit + 1))
        #expect(try discontinuityRefusal(overBadClock, seqs: []) == tooMany)
    }
}
