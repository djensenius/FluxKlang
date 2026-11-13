import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Numbers from docs/transformation/media-contract/examples/08-audio-capture-discontinuities.json
/// (host timebase 125/3 ns per tick; smp.main 48 kHz, restarting at 96 kHz; str.take-in).
enum TakeLedgerTestFixture {
    static let take1 = TakeID(validated: "tk.1")
    static let take2 = TakeID(validated: "tk.2")
    static let stream = StreamID(validated: "str.take-in")
    static let otherStream = StreamID(validated: "str.other-in")
    static let clock = ClockID(validated: "smp.main")
    static let streamSlot: UInt32 = 0
    static let clockSlot: UInt32 = 0
    static let timebase = HostTimebase(numer: 125, denom: 3)

    static func stamp(_ generation: UInt64, _ frame: Int64, clock: UInt32 = clockSlot) -> RuntimeSampleStamp {
        RuntimeSampleStamp(clock: clock, generation: generation, frame: frame)
    }

    static func anchor(_ generation: UInt64, _ frame: Int64, host: UInt64) -> RuntimeClockAnchor {
        RuntimeClockAnchor(sample: stamp(generation, frame), host: HostStamp(ticks: host), musical: nil)
    }

    static func overflow(_ generation: UInt64, _ frame: Int64, frames: UInt32?,
                         stream: UInt32? = streamSlot) -> RuntimeDiscontinuity {
        RuntimeDiscontinuity(kind: .overflow, sample: stamp(generation, frame), frames: frames, stream: stream,
                             host: nil)
    }

    static func stop(_ generation: UInt64, _ frame: Int64, _ reason: RuntimeCaptureStopReason,
                     stream: UInt32? = streamSlot) -> RuntimeDiscontinuity {
        RuntimeDiscontinuity(kind: .captureStopped(reason: reason), sample: stamp(generation, frame), frames: nil,
                             stream: stream, host: nil)
    }

    static func restart(_ generation: UInt64, _ frame: Int64, previousFrame: Int64, host: UInt64,
                        clock: UInt32 = clockSlot) -> RuntimeDiscontinuity {
        RuntimeDiscontinuity(kind: .clockRestart(previousFrame: previousFrame),
                             sample: stamp(generation, frame, clock: clock), frames: nil, stream: nil,
                             host: HostStamp(ticks: host))
    }

    static func jump(_ generation: UInt64, _ frame: Int64, stream: UInt32? = streamSlot) -> RuntimeDiscontinuity {
        RuntimeDiscontinuity(kind: .sampleJump, sample: stamp(generation, frame), frames: nil, stream: stream,
                             host: nil)
    }

    static func latency() throws(TakeLedgerError) -> InputLatency {
        try InputLatency(reportedFrames: 312)
    }

    static func opening(_ take: TakeID, _ generation: UInt64, _ frame: Int64, stream: StreamID = stream,
                        streamSlot: UInt32 = streamSlot) throws(TakeLedgerError) -> TakeOpening {
        TakeOpening(take: take, stream: stream, streamSlot: streamSlot, clock: clock,
                    start: stamp(generation, frame), inputLatency: try latency())
    }

    /// A ledger with example 08's generation-1 anchor and an open take (at frame 0 by default).
    static func ledger(opening take: TakeID = take1, at frame: Int64 = 0) throws -> TakeLedger {
        var ledger = try TakeLedger(timebase: timebase)
        try ledger.observe(anchor(1, 48_000, host: 2_424_000_000), nominalRate: 48_000)
        try ledger.open(opening(take, 1, frame))
        return ledger
    }

    /// Example 08 `tk.1` up to, not including, its finish.
    static func example08Take1() throws -> TakeLedger {
        var ledger = try ledger()
        try ledger.advance(take1, to: stamp(1, 481_024))
        #expect(try ledger.ingest(overflow(1, 480_000, frames: 1024)) == [.recorded(take1)])
        try ledger.advance(take1, to: stamp(1, 960_000))
        #expect(try ledger.ingest(restart(2, 0, previousFrame: 960_000, host: 2_900_000_000)) == [.split(take1)])
        try ledger.observe(anchor(2, 96_000, host: 2_924_000_000), nominalRate: 96_000)
        try ledger.advance(take1, to: stamp(2, 192_512))
        #expect(try ledger.ingest(overflow(2, 192_000, frames: 512)) == [.recorded(take1)])
        try ledger.advance(take1, to: stamp(2, 480_000))
        #expect(try ledger.ingest(stop(2, 480_000, .diskFull)) == [.recorded(take1)])
        return ledger
    }

    static func refusal(_ expected: TakeLedgerError, _ body: () throws(TakeLedgerError) -> Void) {
        do {
            try body()
            Issue.record("Expected \(expected), but the input was accepted")
        } catch {
            #expect(error == expected)
        }
    }
}

@Suite(.productionAccessAudit)
struct RecordingTakeTests {
    typealias Fixture = TakeLedgerTestFixture

    @Test
    func example08TakeOneSplitsAtRestartAndCountsPadding() throws {
        var ledger = try Fixture.example08Take1()
        let take = try ledger.finish(Fixture.take1, reason: .diskFull)
        #expect(take.segments.count == 2)
        let first = take.segments[0]
        #expect(first.generation.value == 1 && first.nominalRate == 48_000)
        #expect(first.startFrame == 0 && first.startOffsetNs == 0 && first.fileFrameStart == 0)
        #expect(first.frames == 960_000 && first.paddedFrames == 1024)
        let interval = try OverflowInterval(startFrame: 480_000, frames: 1024)
        #expect(first.overflows == [interval] && interval.endFrame == 481_024)
        let second = take.segments[1]
        #expect(second.generation.value == 2 && second.nominalRate == 96_000)
        #expect(second.startFrame == 0 && second.startOffsetNs == 20_833_333_333)
        #expect(second.fileFrameStart == 960_000 && second.frames == 480_000 && second.paddedFrames == 512)
        #expect(take.droppedFrames == 1536 && take.fileFrames == 1_440_000)
        #expect(take.stopReason == .diskFull)
        let mark = try #require(take.captureStopped)
        #expect(mark.generation.value == 2 && mark.frame == 480_000 && mark.reason == .diskFull)
        #expect(mark.reportedGeneration.value == 2 && mark.reportedFrame == 480_000 && take.unplacedSegments.isEmpty)
        #expect(take.inputLatency.reportedFrames == 312 && take.inputLatency.measuredFrames == nil)
        #expect(ledger.take(Fixture.take1) == take && !ledger.isOpen(Fixture.take1))
    }

    @Test
    func example08TakeTwoOwnsOnlyItsOwnStop() throws {
        var ledger = try Fixture.example08Take1()
        _ = try ledger.finish(Fixture.take1, reason: .diskFull)
        try ledger.open(Fixture.opening(Fixture.take2, 2, 600_000))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(2, 720_000))
        #expect(ledger.owner(of: Fixture.stop(2, 720_000, .deviceLost)) == Fixture.take2)
        #expect(try ledger.ingest(Fixture.stop(2, 720_000, .deviceLost)) == [.recorded(Fixture.take2)])
        let take = try ledger.finish(Fixture.take2, reason: .deviceLost)
        #expect(take.segments.count == 1 && take.droppedFrames == 0)
        let segment = take.segments[0]
        #expect(segment.startFrame == 600_000 && segment.startOffsetNs == 0 && segment.fileFrameStart == 0)
        #expect(segment.frames == 120_000 && segment.paddedFrames == 0)
        #expect(take.captureStopped?.frame == 720_000 && take.captureStopped?.reason == .deviceLost)
    }

    @Test
    func sealedTakeRefusesEverything() throws {
        var ledger = try Fixture.example08Take1()
        _ = try ledger.finish(Fixture.take1, reason: .diskFull)
        Fixture.refusal(.takeSealed(Fixture.take1)) { () throws(TakeLedgerError) in
            try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 480_001))
        }
        Fixture.refusal(.takeSealed(Fixture.take1)) { () throws(TakeLedgerError) in
            _ = try ledger.finish(Fixture.take1, reason: .diskFull)
        }
        // A late record inside a sealed take is owned by it and refused, never dropped.
        Fixture.refusal(.takeSealed(Fixture.take1)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(2, 100_000, frames: 10))
        }
        Fixture.refusal(.takeSealed(Fixture.take1)) { () throws(TakeLedgerError) in
            try ledger.append(Fixture.overflow(1, 0, frames: 10), to: Fixture.take1)
        }
        #expect(ledger.take(Fixture.take1)?.droppedFrames == 1536)
    }

    @Test
    func userStopOwnsNoCaptureStopped() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        let clean = try ledger.finish(Fixture.take1, reason: .user)
        #expect(clean.captureStopped == nil && clean.stopReason == .user)

        var stopped = try Fixture.ledger()
        try stopped.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        _ = try stopped.ingest(Fixture.stop(1, 1000, .diskFull))
        Fixture.refusal(.stopReasonMismatch(expected: .user, recorded: .diskFull)) { () throws(TakeLedgerError) in
            _ = try stopped.finish(Fixture.take1, reason: .user)
        }
        #expect(stopped.isOpen(Fixture.take1))
    }

    @Test
    func otherStopsOwnExactlyOneMatchingCaptureStopped() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        Fixture.refusal(.missingCaptureStopped(.deviceLost)) { () throws(TakeLedgerError) in
            _ = try ledger.finish(Fixture.take1, reason: .deviceLost)
        }
        _ = try ledger.ingest(Fixture.stop(1, 1000, .deviceLost))
        Fixture.refusal(.stopReasonMismatch(expected: .diskFull, recorded: .deviceLost)) { () throws(TakeLedgerError) in
            _ = try ledger.finish(Fixture.take1, reason: .diskFull)
        }
        Fixture.refusal(.duplicateCaptureStopped) { () throws(TakeLedgerError) in
            try ledger.append(Fixture.stop(1, 1000, .deviceLost), to: Fixture.take1)
        }
        #expect(try ledger.finish(Fixture.take1, reason: .deviceLost).captureStopped?.frame == 1000)
    }

    @Test
    func captureStoppedSitsAtTheEndAndEndsProgress() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        Fixture.refusal(.stopNotAtEnd(frame: 999, frontier: 1000)) { () throws(TakeLedgerError) in
            try ledger.append(Fixture.stop(1, 999, .diskFull), to: Fixture.take1)
        }
        try ledger.append(Fixture.stop(1, 1000, .diskFull), to: Fixture.take1)
        Fixture.refusal(.captureAlreadyStopped) { () throws(TakeLedgerError) in
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1001))
        }
        // A stopped take is no longer capturing: later restarts and jumps pass it by.
        #expect(try ledger.ingest(Fixture.restart(2, 0, previousFrame: 1000, host: 2_500_000_000)).isEmpty)
        #expect(try ledger.ingest(Fixture.jump(2, 50)).isEmpty)
        let take = try ledger.finish(Fixture.take1, reason: .diskFull)
        #expect(take.segments.count == 1 && take.boundaries.isEmpty && take.captureStopped?.frame == 1000)
    }

    @Test
    func takeStopReasonMapsCaptureReasons() {
        #expect(TakeStopReason.user.captureReason == nil)
        for reason in [RuntimeCaptureStopReason.diskFull, .deviceLost] {
            #expect(TakeStopReason(reason).captureReason == reason)
        }
    }

    @Test
    func measuredLatencyMustCiteEvidence() throws {
        let reported = try InputLatency(reportedFrames: 312)
        #expect(reported.measured == nil && reported.measuredFrames == nil)
        let measured = try InputLatency(reportedFrames: 312,
                                        measured: MeasuredLatency(frames: 298, evidence: "loopback run 3"))
        #expect(measured.measuredFrames == 298 && measured.measured?.evidence == "loopback run 3")
        for evidence in ["", "  ", String(repeating: "x", count: MeasuredLatency.maximumEvidenceBytes + 1)] {
            Fixture.refusal(.invalidLatencyEvidence(bytes: evidence.utf8.count)) { () throws(TakeLedgerError) in
                _ = try MeasuredLatency(frames: 298, evidence: evidence)
            }
        }
        let longest = String(repeating: "x", count: MeasuredLatency.maximumEvidenceBytes)
        #expect(try MeasuredLatency(frames: 0, evidence: longest).evidence == longest)
        Fixture.refusal(.negativeLatency(-1)) { () throws(TakeLedgerError) in
            _ = try MeasuredLatency(frames: -1, evidence: "loopback")
        }
        Fixture.refusal(.negativeLatency(-1)) { () throws(TakeLedgerError) in
            _ = try InputLatency(reportedFrames: -1)
        }
    }

    @Test
    func openingRefusals() throws {
        var ledger = try Fixture.ledger()
        Fixture.refusal(.duplicateTake(Fixture.take1)) { () throws(TakeLedgerError) in
            try ledger.open(Fixture.opening(Fixture.take1, 1, 10, stream: Fixture.otherStream, streamSlot: 9))
        }
        Fixture.refusal(.streamBusy(Fixture.stream)) { () throws(TakeLedgerError) in
            try ledger.open(Fixture.opening(Fixture.take2, 1, 10))
        }
        Fixture.refusal(.streamBusy(Fixture.otherStream)) { () throws(TakeLedgerError) in
            try ledger.open(Fixture.opening(Fixture.take2, 1, 10, stream: Fixture.otherStream))
        }
        Fixture.refusal(.unknownTake(Fixture.take2)) { () throws(TakeLedgerError) in
            try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 10))
        }
        Fixture.refusal(.generationOutOfRange(.max)) { () throws(TakeLedgerError) in
            try ledger.open(Fixture.opening(Fixture.take2, .max, 10, stream: Fixture.otherStream, streamSlot: 9))
        }
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 10))
        _ = try ledger.finish(Fixture.take1, reason: .user)
        try ledger.open(Fixture.opening(Fixture.take2, 1, 10))
        #expect(ledger.order == [Fixture.take1, Fixture.take2])
    }

    @Test
    func finishNeedsAnchorsAndFrames() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 0))
        Fixture.refusal(.emptySegment) { () throws(TakeLedgerError) in
            _ = try ledger.finish(Fixture.take1, reason: .user)
        }
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 10))
        Fixture.refusal(.invalidRate(47_999)) { () throws(TakeLedgerError) in
            try ledger.observe(Fixture.anchor(1, 0, host: 1), nominalRate: 47_999)
        }
        try ledger.observe(Fixture.anchor(1, 0, host: 1), nominalRate: 48_000)
        Fixture.refusal(.rateMismatch(generation: 1)) { () throws(TakeLedgerError) in
            try ledger.observe(Fixture.anchor(1, 96, host: 100), nominalRate: 96_000)
        }
        try ledger.observe(Fixture.anchor(1, 96_000, host: 9), nominalRate: 48_000)
        #expect(ledger.anchor(clock: Fixture.clockSlot, generation: 1)?.hostTicks == 1)
        #expect(try ledger.finish(Fixture.take1, reason: .user).segments[0].frames == 10)
        Fixture.refusal(.invalidTimebase) { () throws(TakeLedgerError) in
            _ = try TakeLedger(timebase: HostTimebase(numer: 0, denom: 3))
        }
        Fixture.refusal(.invalidTimebase) { () throws(TakeLedgerError) in
            _ = try TakeLedger(timebase: HostTimebase(numer: 1, denom: 0))
        }
    }

    @Test
    func progressIsMonotonicAndOnTheCurrentGeneration() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 100))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 100))
        Fixture.refusal(.progressRegressed(frontier: 100, frame: 99)) { () throws(TakeLedgerError) in
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 99))
        }
        Fixture.refusal(.generationMismatch(expected: 1, actual: 2)) { () throws(TakeLedgerError) in
            try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 200))
        }
        Fixture.refusal(.clockMismatch) { () throws(TakeLedgerError) in
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 200, clock: 7))
        }
    }

    /// Literal bounds: N is accepted and N + 1 refused.
    @Test
    func boundsArePinned() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        for index in 0..<256 {
            let take = try TakeID("tk.\(index)")
            try ledger.open(Fixture.opening(take, 1, 0, stream: StreamID("str.s\(index)"), streamSlot: UInt32(index)))
        }
        Fixture.refusal(.tooManyTakes) { () throws(TakeLedgerError) in
            try ledger.open(Fixture.opening(TakeID(validated: "tk.extra"), 1, 0, stream: Fixture.otherStream,
                                            streamSlot: 9_999))
        }
        var anchors = try TakeLedger(timebase: Fixture.timebase)
        for generation in UInt64(1)...4_096 {
            try anchors.observe(Fixture.anchor(generation, 0, host: generation), nominalRate: 48_000)
        }
        Fixture.refusal(.tooManyGenerationRecords) { () throws(TakeLedgerError) in
            let next: UInt64 = 4_097
            try anchors.observe(Fixture.anchor(next, 0, host: next), nominalRate: 48_000)
        }
        var overflows = try Fixture.ledger()
        let limit: Int64 = 4_096
        try overflows.advance(Fixture.take1, to: Fixture.stamp(1, 2 * limit + 2))
        for index in 0..<limit { _ = try overflows.ingest(Fixture.overflow(1, 2 * index, frames: 1)) }
        Fixture.refusal(.tooManyOverflows) { () throws(TakeLedgerError) in
            _ = try overflows.ingest(Fixture.overflow(1, 2 * limit, frames: 1))
        }
        #expect(try overflows.finish(Fixture.take1, reason: .user).droppedFrames == limit)
    }

    @Test
    func segmentBoundIsPinned() throws {
        var ledger = try Fixture.ledger()
        let limit: UInt64 = 1_024
        for generation in 1..<limit {
            try ledger.advance(Fixture.take1, to: Fixture.stamp(generation, 1))
            let restart = Fixture.restart(generation + 1, 0, previousFrame: 1, host: 2_400_000_000 + generation)
            _ = try ledger.ingest(restart)
            try ledger.observe(Fixture.anchor(generation + 1, 0, host: 2_400_000_000 + generation),
                               nominalRate: 48_000)
        }
        // At the bound, an empty current segment can still be replaced: it is dropped, not counted.
        _ = try ledger.ingest(Fixture.jump(limit, 0))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(limit, 1))
        Fixture.refusal(.tooManySegments) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.restart(limit + 1, 0, previousFrame: 1, host: 2_500_000_000))
        }
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.count == 1_024 && take.fileFrames == Int64(limit))
    }

    /// Round 6 (Copilot): a recorded stop keeps bounding the next restart after its take is finished
    /// or discarded (§8.3: capture ended no later than the restart's `previousFrame`). Equal is
    /// accepted: both frames are exclusive ends, so capture ended exactly where the generation did.
    @Test
    func recordedStopBoundsARestartAfterItsTakeCloses() throws {
        for reason in [RuntimeCaptureStopReason.deviceLost, .diskFull] {
            for finishes in [true, false] {
                var ledger = try Fixture.ledger()
                try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
                #expect(try ledger.ingest(Fixture.stop(1, 1000, reason)) == [.recorded(Fixture.take1)])
                let early = Fixture.restart(2, 0, previousFrame: 999, host: 2_500_000_000)
                let refusal = TakeLedgerError.stopAfterRestart(Fixture.take1, stopFrame: 1000, previousFrame: 999)
                Fixture.refusal(refusal) { () throws(TakeLedgerError) in _ = try ledger.ingest(early) }
                var finished: RecordingTake?
                var discarded: DiscardedTake?
                if finishes {
                    finished = try ledger.finish(Fixture.take1, reason: TakeStopReason(reason))
                } else {
                    discarded = try ledger.discard(Fixture.take1, reason: .abandoned)
                }
                Fixture.refusal(refusal) { () throws(TakeLedgerError) in _ = try ledger.ingest(early) }
                #expect(ledger.take(Fixture.take1) == finished && ledger.discarded(Fixture.take1) == discarded)
                // Nothing changed: generation 1 is still the latest and the restart is still unused.
                try ledger.open(Fixture.opening(Fixture.take2, 1, 1000))
                let boundary = Fixture.restart(2, 0, previousFrame: 1000, host: 2_500_000_000)
                #expect(try ledger.ingest(boundary) == [.split(Fixture.take2)])
                #expect(ledger.order == [Fixture.take1, Fixture.take2])
            }
        }
    }

    /// Round 6, revised in round 8b: after a take the ledger ended is finished or discarded, its
    /// segment still bounds a restart (§8.3). One ending past `previousFrame` (N + 1, and below)
    /// refuses it and nothing changes; one ending at it (N) is accepted.
    @Test
    func ledgerEndedTakeBoundsARestartAfterItCloses() throws {
        let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        for finishes in [true, false] {
            var ledger = try Fixture.ledger(opening: Fixture.take1, at: 1000)
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
            #expect(try ledger.ingest(Fixture.jump(1, 500)) == [.ended(Fixture.take1, ended)])
            var finished: RecordingTake?
            var discarded: DiscardedTake?
            if finishes {
                finished = try ledger.finish(Fixture.take1, reason: ended)
                #expect(finished?.segments.map(\.frames) == [1000])
            } else {
                discarded = try ledger.discard(Fixture.take1, reason: .abandoned)
                #expect(discarded?.stop?.frame == 2000)
            }
            for previous: Int64 in [600, 1999] {
                let early = Fixture.restart(2, 0, previousFrame: previous, host: 2_500_000_000)
                let refusal = TakeLedgerError.segmentAfterRestart(Fixture.take1, segmentEnd: 2000,
                                                                  previousFrame: previous)
                Fixture.refusal(refusal) { () throws(TakeLedgerError) in _ = try ledger.ingest(early) }
            }
            #expect(ledger.take(Fixture.take1) == finished && ledger.discarded(Fixture.take1) == discarded)
            #expect(try ledger.ingest(Fixture.restart(2, 0, previousFrame: 2000, host: 2_500_000_000)).isEmpty)
        }
    }

    /// Round 7 (Copilot): an overflow without a length (nil or 0 frames) is owned like a 1-frame
    /// overflow, so one at a segment's start is owned. Ownership is decided first; then
    /// `appendOverflow` refuses the length `.missingOverflowFrames` and nothing changes.
    @Test
    func overflowWithoutFramesIsOwnedLikeOneFrame() throws {
        var ledger = try Fixture.ledger(opening: Fixture.take1, at: 1000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
        for frames in [nil, 0] as [UInt32?] {
            // The segment's start, inside it, and its frontier (a capturing segment owns past it).
            for frame: Int64 in [1000, 1500, 2000] {
                let record = Fixture.overflow(1, frame, frames: frames)
                #expect(ledger.owner(of: record) == Fixture.take1)
                #expect(ledger.owner(of: Fixture.overflow(1, frame, frames: 1)) == Fixture.take1)
                Fixture.refusal(.missingOverflowFrames) { () throws(TakeLedgerError) in _ = try ledger.ingest(record) }
            }
            // Pre-roll stays unowned and ignored, as for a 1-frame overflow.
            #expect(ledger.owner(of: Fixture.overflow(1, 999, frames: frames)) == nil)
            #expect(try ledger.ingest(Fixture.overflow(1, 999, frames: frames)).isEmpty)
        }
        #expect(try ledger.ingest(Fixture.overflow(1, 1000, frames: 1)) == [.recorded(Fixture.take1)])
        let interval = try OverflowInterval(startFrame: 1000, frames: 1)
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.overflows) == [[interval]] && take.droppedFrames == 1)
    }

    /// Round 7: outside every segment's half-open range (a closed segment's end is exclusive) a
    /// lengthless overflow is still refused `.recordNotOwned`, or ignored as pre-roll. A closed take
    /// that owns one refuses it `.takeSealed`: ownership first, then the length.
    @Test
    func overflowWithoutFramesOutsideEverySegmentIsNotOwned() throws {
        var ledger = try Fixture.ledger(opening: Fixture.take1, at: 1000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
        #expect(try ledger.ingest(Fixture.jump(1, 5000)) == [.split(Fixture.take1)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 6000))
        for frames in [nil, 0] as [UInt32?] {
            for frame: Int64 in [1000, 1999, 5000] {
                Fixture.refusal(.missingOverflowFrames) { () throws(TakeLedgerError) in
                    _ = try ledger.ingest(Fixture.overflow(1, frame, frames: frames))
                }
            }
            // The closed segment's exclusive end, and the gap before the jump's target.
            for frame: Int64 in [2000, 3000] {
                #expect(ledger.owner(of: Fixture.overflow(1, frame, frames: 1)) == nil)
                let refusal = TakeLedgerError.recordNotOwned(stream: Fixture.streamSlot, frame: frame)
                Fixture.refusal(refusal) { () throws(TakeLedgerError) in
                    _ = try ledger.ingest(Fixture.overflow(1, frame, frames: frames))
                }
            }
            #expect(try ledger.ingest(Fixture.overflow(1, 999, frames: frames)).isEmpty)
        }
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.frames) == [1000, 1000] && take.droppedFrames == 0)
        Fixture.refusal(.takeSealed(Fixture.take1)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 1000, frames: nil))
        }
    }

    /// Round 7: the round-5 jump-target rule is unchanged for a lengthless overflow. Once a new take
    /// records from the jump's target, it owns one at its start, so the length is refused instead.
    @Test
    func overflowWithoutFramesKeepsTheJumpTargetRule() throws {
        var ledger = try Fixture.ledger(opening: Fixture.take1, at: 1000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
        let ended = TakeIngestEffect.ended(Fixture.take1, .discontinuity(.jumpBeforeTakeStart))
        #expect(try ledger.ingest(Fixture.jump(1, 500)) == [ended])
        for frame: Int64 in [500, 600, 1000] {
            let refusal = TakeLedgerError.recordNotOwned(stream: Fixture.streamSlot, frame: frame)
            Fixture.refusal(refusal) { () throws(TakeLedgerError) in
                _ = try ledger.ingest(Fixture.overflow(1, frame, frames: nil))
            }
        }
        try ledger.open(Fixture.opening(Fixture.take2, 1, 500))
        Fixture.refusal(.missingOverflowFrames) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 500, frames: nil))
        }
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 600))
        #expect(try ledger.ingest(Fixture.overflow(1, 500, frames: 1)) == [.recorded(Fixture.take2)])
    }
}
