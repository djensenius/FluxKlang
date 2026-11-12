#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif
import Foundation
import Testing

// MARK: - A take the ledger ended exports as the `discontinuity` stop (#336)

extension RecordingTakeV1GateTests {
    typealias CaptureStoppedReason = DiscontinuityV1Record.CaptureStoppedReason

    /// The note example 11's `captureStopped` carries.
    static let example11StopNote = "The recorder ended the take: a sampleJump landed before its start, "
        + "so it keeps the audio up to this frame."

    /// Example 11's `tk.1` records (seqs 2 to 4), keys sorted, compact. The ledger ended that take: a `sampleJump`
    /// to frame 48000 landed before its start, frame 96000, in its generation, so it stops at its last frame.
    static let example11OverflowJSON = #"{"frame":120000,"frames":512,"generation":1,"kind":"discontinuity","#
        + #""sampleClock":"smp.main","seq":2,"stream":"str.take-in","type":"overflow"}"#

    static let example11StopJSON = #"{"frame":240000,"generation":1,"kind":"discontinuity","#
        + #""note":"The recorder ended the take: a sampleJump landed before its start, "#
        + #"so it keeps the audio up to this frame.","reason":"discontinuity","sampleClock":"smp.main","seq":3,"#
        + #""stream":"str.take-in","type":"captureStopped"}"#

    static let example11TakeJSON = #"{"droppedFrames":512,"#
        + #""inputLatency":{"measuredFrames":null,"reportedFrames":312},"kind":"take","#
        + #""segments":[{"fileFrameStart":0,"frames":144000,"generation":1,"paddedFrames":512,"#
        + #""sampleClock":"smp.main","startFrame":96000,"startOffsetNs":0}],"seq":4,"stopReason":"discontinuity","#
        + #""stream":"str.take-in","takeId":"tk.1"}"#

    private static let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)

    /// Example 11's `tk.1`: opened at frame 96000, 512 frames dropped at 120000, then a `sampleJump` to frame 48000
    /// lands before its start and the ledger ends it at its last good frame, 240000.
    private func example11Take() throws -> RecordingTake {
        var ledger = try Fixture.ledger(at: 96_000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 120_512))
        #expect(try ledger.ingest(Fixture.overflow(1, 120_000, frames: 512)) == [.recorded(Fixture.take1)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 240_000))
        #expect(try ledger.ingest(Fixture.jump(1, 48_000)) == [.ended(Fixture.take1, Self.ended)])
        return try ledger.finish(Fixture.take1, reason: Self.ended)
    }

    private func encoded(_ records: [DiscontinuityV1Record]) throws -> [String] {
        try records.map { try #require(String(data: $0.encodedJSON(), encoding: .utf8)) }
    }

    @Test
    func recordingTakeV1ExportsALedgerEndedTakeAsExample11() throws {
        let take = try example11Take()
        #expect(take.stopReason == Self.ended && take.segments.count == 1 && take.boundaries.isEmpty)
        let mark = try #require(take.stopMark)
        #expect(mark.reason == Self.ended && mark.generation.value == 1 && mark.frame == 240_000)
        #expect(take.captureStopped == nil)

        let clearance = try RecordingTakeV1Gate.clear(take)
        #expect(RecordingTakeV1Discontinuities.count(of: clearance) == 2)
        let notes = [3: Self.example11StopNote]
        let records = try RecordingTakeV1Discontinuities.make(clearance, seqs: [2, 3], notes: notes)
        #expect(records.map(\.event.type) == ["overflow", "captureStopped"])
        let stop = try #require(records.last)
        let stream = StreamID(validated: "str.take-in")
        #expect(stop.generation.value == 1 && stop.frame == 240_000
            && stop.event == .captureStopped(stream, reason: .discontinuity))
        #expect(try encoded(records) == [Self.example11OverflowJSON, Self.example11StopJSON])

        let record = try RecordingTakeV1Record.make(clearance, seq: 4)
        let only = try #require(record.segments.first)
        #expect(record.segments.count == 1 && only.startFrame == 96_000 && only.frames == 144_000)
        #expect(record.droppedFrames == 512)
        #expect(try #require(String(data: record.encodedJSON(), encoding: .utf8)) == Self.example11TakeJSON)

        // The take and its `captureStopped` carry the one value, the pairing the contract checker enforces.
        #expect(record.stopReason == "discontinuity")
        #expect(record.stopReason == CaptureStoppedReason.discontinuity.contractV1Name)

        let again = try RecordingTakeV1Record.make(RecordingTakeV1Gate.clear(example11Take()), seq: 4)
        #expect(again == record)
        #expect(try again.encodedJSON() == record.encodedJSON())
    }

    @Test
    func recordingTakeV1ALedgerEndedTakeWithoutOverflowsWritesOnlyItsCaptureStopped() throws {
        var ledger = try Fixture.ledger(at: 1_000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2_000))
        #expect(try ledger.ingest(Fixture.jump(1, 500)) == [.ended(Fixture.take1, Self.ended)])
        let clearance = try RecordingTakeV1Gate.clear(ledger.finish(Fixture.take1, reason: Self.ended))
        #expect(RecordingTakeV1Discontinuities.count(of: clearance) == 1)
        let records = try RecordingTakeV1Discontinuities.make(clearance, seqs: [5])
        let expected = #"{"frame":2000,"generation":1,"kind":"discontinuity","reason":"discontinuity","#
            + #""sampleClock":"smp.main","seq":5,"stream":"str.take-in","type":"captureStopped"}"#
        #expect(try encoded(records) == [expected])
        #expect(try RecordingTakeV1Record.make(clearance, seq: 6).stopReason == "discontinuity")
    }

    private struct StopCase {
        let stop: TakeStopReason
        let reason: CaptureStoppedReason?
        let name: String
    }

    @Test
    func recordingTakeV1EveryStopReasonNamesItsCaptureStoppedReasonOneToOne() {
        let cases = [
            StopCase(stop: .user, reason: nil, name: "user"),
            StopCase(stop: .diskFull, reason: .diskFull, name: "diskFull"),
            StopCase(stop: .deviceLost, reason: .deviceLost, name: "deviceLost"),
            StopCase(stop: Self.ended, reason: .discontinuity, name: "discontinuity")
        ]
        for entry in cases {
            #expect(entry.stop.contractV1CaptureStoppedReason == entry.reason, "\(entry.stop)")
            #expect(entry.stop.contractV1StopReason() == entry.name, "\(entry.stop)")
            #expect((entry.reason?.contractV1Name ?? "user") == entry.name, "\(entry.stop)")
        }
        #expect(Set(cases.map(\.name)).count == cases.count)
        // Capture reports only the device stops; the ledger's own stop has no runtime value.
        #expect(Self.ended.captureReason == nil && Self.ended.isLedgerStop)
        #expect(TakeStopReason(.diskFull).contractV1StopReason() == "diskFull")
        #expect(TakeStopReason(.deviceLost).contractV1StopReason() == "deviceLost")
    }
}
