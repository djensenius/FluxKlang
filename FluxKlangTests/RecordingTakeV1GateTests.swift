#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif
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
}
