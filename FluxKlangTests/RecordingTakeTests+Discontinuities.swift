import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct RecordingTakeDiscontinuityTests {
    typealias Fixture = TakeLedgerTestFixture

    @Test
    func overflowMustLieWhollyInsideCapturedFrames() throws {
        var ledger = try Fixture.ledger()
        let take = Fixture.take1
        try ledger.advance(take, to: Fixture.stamp(1, 1000))
        Fixture.refusal(.overflowOutsideSegment(startFrame: 990, endFrame: 1010)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 990, frames: 20))
        }
        Fixture.refusal(.overflowOutsideSegment(startFrame: 1000, endFrame: 1001)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 1000, frames: 1))
        }
        #expect(try ledger.ingest(Fixture.overflow(1, 980, frames: 20)) == [.recorded(take)])
        Fixture.refusal(.overflowOverlapsPrevious(startFrame: 990)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 990, frames: 5))
        }
        for frames in [nil, 0] as [UInt32?] {
            Fixture.refusal(.missingOverflowFrames) { () throws(TakeLedgerError) in
                try ledger.append(Fixture.overflow(1, 10, frames: frames), to: take)
            }
        }
        Fixture.refusal(.streamMismatch) { () throws(TakeLedgerError) in
            try ledger.append(Fixture.overflow(1, 10, frames: 1, stream: 5), to: take)
        }
        Fixture.refusal(.missingStream) { () throws(TakeLedgerError) in
            try ledger.append(Fixture.overflow(1, 10, frames: 1, stream: nil), to: take)
        }
        Fixture.refusal(.missingStream) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 10, frames: 1, stream: nil))
        }
        Fixture.refusal(.generationMismatch(expected: 1, actual: 2)) { () throws(TakeLedgerError) in
            try ledger.append(Fixture.overflow(2, 10, frames: 1), to: take)
        }
        Fixture.refusal(.unsupportedDiscontinuity) { () throws(TakeLedgerError) in
            let underrun = RuntimeDiscontinuity(kind: .underrun, sample: Fixture.stamp(1, 10), frames: 1,
                                                stream: Fixture.streamSlot, host: nil)
            try ledger.append(underrun, to: take)
        }
        Fixture.refusal(.clockMismatch) { () throws(TakeLedgerError) in
            let foreign = RuntimeDiscontinuity(kind: .overflow, sample: Fixture.stamp(1, 10, clock: 7), frames: 1,
                                               stream: Fixture.streamSlot, host: nil)
            try ledger.append(foreign, to: take)
        }
        #expect(try ledger.ingest(Fixture.overflow(1, 10, frames: 1, stream: 5)).isEmpty)
        let locate = RuntimeDiscontinuity(kind: .locate, sample: Fixture.stamp(1, 10), frames: nil,
                                          stream: Fixture.streamSlot, host: nil)
        #expect(try ledger.ingest(locate).isEmpty)
        #expect(try ledger.finish(take, reason: .user).droppedFrames == 20)
    }

    @Test
    func openTakeOwnsFramesFromItsStart() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.observe(Fixture.anchor(1, 0, host: 0), nominalRate: 48_000)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 1000))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1010))
        #expect(try ledger.ingest(Fixture.overflow(1, 990, frames: 10)).isEmpty)
        Fixture.refusal(.overflowOutsideSegment(startFrame: 990, endFrame: 1001)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 990, frames: 11))
        }
        #expect(ledger.owner(of: Fixture.stop(1, 1000, .diskFull)) == nil)
        #expect(ledger.owner(of: Fixture.overflow(2, 1005, frames: 1)) == nil)
        #expect(try ledger.ingest(Fixture.overflow(1, 1000, frames: 10)) == [.recorded(Fixture.take1)])
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.droppedFrames == 10 && take.segments[0].paddedFrames == 10)
    }

    @Test
    func sealedSegmentOwnershipEdges() throws {
        var ledger = try Fixture.example08Take1()
        _ = try ledger.finish(Fixture.take1, reason: .diskFull)
        #expect(ledger.owner(of: Fixture.stop(2, 480_000, .deviceLost)) == Fixture.take1)
        #expect(ledger.owner(of: Fixture.stop(2, 480_001, .deviceLost)) == nil)
        #expect(ledger.owner(of: Fixture.stop(2, 0, .deviceLost)) == nil)
        #expect(ledger.owner(of: Fixture.overflow(2, 479_999, frames: 1)) == Fixture.take1)
        #expect(ledger.owner(of: Fixture.overflow(2, 480_000, frames: 1)) == nil)
        #expect(ledger.owner(of: Fixture.overflow(1, 960_000, frames: 1)) == nil)
        #expect(ledger.owner(of: Fixture.overflow(3, 10, frames: 1)) == nil)
        #expect(ledger.owner(of: Fixture.overflow(1, 10, frames: 1, stream: 5)) == nil)
        #expect(ledger.owner(of: Fixture.overflow(1, 10, frames: 1, stream: nil)) == nil)
        #expect(try ledger.ingest(Fixture.overflow(2, 480_000, frames: 1)).isEmpty)
    }

    @Test
    func closedSegmentAcceptsLateOverflowOnlyWhollyInside() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 960_000))
        _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: 960_000, host: 2_900_000_000))
        try ledger.observe(Fixture.anchor(2, 96_000, host: 2_924_000_000), nominalRate: 96_000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 100))
        Fixture.refusal(.overflowOutsideSegment(startFrame: 959_990, endFrame: 960_010)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 959_990, frames: 20))
        }
        #expect(try ledger.ingest(Fixture.overflow(1, 959_990, frames: 10)) == [.recorded(Fixture.take1)])
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.paddedFrames) == [10, 0] && take.droppedFrames == 10)
        #expect(take.segments.map(\.frames) == [960_000, 100])
    }

    @Test
    func restartEndsTheSegmentAtItsPreviousFrame() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        for previous: Int64 in [999, 1001] {
            let expected = TakeLedgerError.segmentEndMismatch(frontier: 1000, previousFrame: previous)
            Fixture.refusal(expected) { () throws(TakeLedgerError) in
                _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: previous, host: 2_500_000_000))
            }
        }
        #expect(try ledger.ingest(Fixture.restart(2, 5, previousFrame: 1000, host: 2_500_000_000))
            == [.split(Fixture.take1)])
        Fixture.refusal(.generationMismatch(expected: 2, actual: 1)) { () throws(TakeLedgerError) in
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
        }
        Fixture.refusal(.progressRegressed(frontier: 5, frame: 4)) { () throws(TakeLedgerError) in
            try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 4))
        }
        Fixture.refusal(.staleGeneration(2)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.restart(2, 5, previousFrame: 1000, host: 2_500_000_000))
        }
        Fixture.refusal(.staleGeneration(1)) { () throws(TakeLedgerError) in
            try ledger.open(Fixture.opening(Fixture.take2, 1, 0, stream: Fixture.otherStream, streamSlot: 9))
        }
        // Ruling 1c: a segment without an anchor finishes unplaced, with the reason.
        try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 6))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.placement) == [.placed(startOffsetNs: 0), .unplaced(.anchorNotObserved)])
        #expect(take.segments.map(\.nominalRate) == [48_000, nil] && take.unplacedSegments == [1])
    }

    @Test
    func restartRefusalsChangeNothing() throws {
        var ledger = try Fixture.ledger()
        try ledger.open(Fixture.opening(Fixture.take2, 1, 0, stream: Fixture.otherStream, streamSlot: 9))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 100))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 90))
        Fixture.refusal(.segmentEndMismatch(frontier: 90, previousFrame: 100)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: 100, host: 2_500_000_000))
        }
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 110))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 110))
        Fixture.refusal(.missedRestart(Fixture.take1)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.restart(3, 0, previousFrame: 110, host: 2_500_000_000))
        }
        Fixture.refusal(.generationOutOfRange(1)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.restart(1, 0, previousFrame: 110, host: 2_500_000_000))
        }
        #expect(try ledger.ingest(Fixture.restart(2, 0, previousFrame: 7, host: 1, clock: 4)).isEmpty)
        #expect(try ledger.ingest(Fixture.restart(2, 0, previousFrame: 110, host: 2_500_000_000))
            == [.split(Fixture.take1), .split(Fixture.take2)])
    }

    @Test
    func rateChangeSegmentUsesItsOwnGenerationRate() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.observe(Fixture.anchor(1, 0, host: 0), nominalRate: 48_000)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 0))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 48_000))
        _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: 48_000, host: 24_000_000))
        // 48,000,000 ticks = 2 s; 44,100 frames at 44.1 kHz = 1 s, so frame 0 is at 1 s.
        try ledger.observe(Fixture.anchor(2, 44_100, host: 48_000_000), nominalRate: 44_100)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 44_100))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.nominalRate) == [48_000, 44_100])
        #expect(take.segments.map(\.startOffsetNs) == [0, 1_000_000_000])
        #expect(take.segments.map(\.fileFrameStart) == [0, 48_000] && take.fileFrames == 92_100)
    }

    @Test
    func segmentPlacedBeforeTheTakeAnchorFinishesUnplaced() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.observe(Fixture.anchor(1, 0, host: 1_000_000), nominalRate: 48_000)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 0))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 10))
        _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: 10, host: 10))
        try ledger.observe(Fixture.anchor(2, 0, host: 10), nominalRate: 48_000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 10))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.placement) == [.placed(startOffsetNs: 0), .unplaced(.beforeTakeStart)])
        #expect(take.segments.map(\.nominalRate) == [48_000, 48_000] && take.fileFrames == 20)
    }

    @Test
    func startOffsetRoundsHalfUpOnceAtTheEnd() throws {
        func offset(host: UInt64, baseHost: UInt64 = 0, numer: UInt32, denom: UInt32,
                    frame: Int64 = 0, rate: Int = 48_000) throws(TakeLedgerError) -> Int64 {
            let base = AnchoredFrame(frame: 0, anchor: GenerationAnchor(frame: 0, hostTicks: baseHost,
                                                                        nominalRate: 48_000))
            let position = AnchoredFrame(frame: frame, anchor: GenerationAnchor(frame: 0, hostTicks: host,
                                                                                nominalRate: rate))
            return try TakeOffsetMath.offsetNs(of: position, from: base,
                                               timebase: HostTimebase(numer: numer, denom: denom))
        }
        #expect(try offset(host: 1, numer: 1, denom: 2) == 1)
        #expect(try offset(host: 1, numer: 1, denom: 4) == 0)
        #expect(try offset(host: 1, numer: 3, denom: 4) == 1)
        #expect(try offset(host: 0, baseHost: 1, numer: 1, denom: 2) == 0)
        #expect(try offset(host: 0, baseHost: 1, numer: 3, denom: 4) == -1)
        // 1 frame at 48 kHz is 20,833.33 ns, at 96 kHz 10,416.67 ns.
        #expect(try offset(host: 0, numer: 1, denom: 1, frame: 1) == 20_833)
        #expect(try offset(host: 0, numer: 1, denom: 1, frame: 1, rate: 96_000) == 10_417)
        // 0.4 ns of host time plus 20,833.33 ns of frames: rounding each term would give 20,833.
        #expect(try offset(host: 1, numer: 2, denom: 5, frame: 1) == 20_834)
        #expect(try offset(host: 500_000_000, numer: 125, denom: 3) == 20_833_333_333)
        Fixture.refusal(.arithmeticOverflow) { () throws(TakeLedgerError) in
            _ = try offset(host: .max, numer: .max, denom: 1, rate: 192_000)
        }
        Fixture.refusal(.arithmeticOverflow) { () throws(TakeLedgerError) in
            _ = try offset(host: 1 << 63, numer: 1, denom: 1)
        }
    }

    /// Ruling 1: an empty segment is dropped, never stored or refused; the boundary stays in the history.
    @Test
    func restartImmediatelyAfterOpenDropsTheEmptySegment() throws {
        var ledger = try Fixture.ledger()
        #expect(try ledger.ingest(Fixture.restart(2, 0, previousFrame: 0, host: 2_500_000_000))
            == [.split(Fixture.take1)])
        try ledger.observe(Fixture.anchor(2, 0, host: 2_500_000_000), nominalRate: 96_000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 960))
        #expect(try ledger.ingest(Fixture.stop(2, 960, .diskFull)) == [.recorded(Fixture.take1)])
        let take = try ledger.finish(Fixture.take1, reason: .diskFull)
        let restart = SegmentBoundaryReason.clockRestart(previousFrame: 0)
        let second = try Generation(2)
        let boundary = try #require(take.boundaries.first)
        #expect(take.boundaries.count == 1 && boundary.reason == restart && boundary.generation == second)
        #expect(boundary.frame == 0 && boundary.closedAt == 0 && boundary.droppedEmptySegment)
        #expect(take.segments.count == 1 && take.segments[0].generation == second)
        #expect(take.segments[0].startOffsetNs == 0 && take.segments[0].frames == 960)
        #expect(take.segments[0].openedBy == restart && take.captureStopped?.frame == 960)
        var trailing = try Fixture.ledger()
        try trailing.advance(Fixture.take1, to: Fixture.stamp(1, 10))
        _ = try trailing.ingest(Fixture.jump(1, 20))
        let stopped = try trailing.finish(Fixture.take1, reason: .user)
        #expect(stopped.segments.map(\.frames) == [10] && stopped.boundaries.map(\.closedAt) == [10])
        var empty = try Fixture.ledger()
        _ = try empty.ingest(Fixture.jump(1, 5))
        Fixture.refusal(.emptySegment) { () throws(TakeLedgerError) in
            _ = try empty.finish(Fixture.take1, reason: .user)
        }
    }

    /// Ruling 2: an anchor for an older generation is a typed refusal and never applied.
    @Test
    func staleAnchorIsRefusedAndNeverApplied() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 0))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 10))
        _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: 10, host: 1_000))
        Fixture.refusal(.staleGeneration(1)) { () throws(TakeLedgerError) in
            try ledger.observe(Fixture.anchor(1, 0, host: 5), nominalRate: 48_000)
        }
        #expect(ledger.anchor(clock: Fixture.clockSlot, generation: 1) == nil)
        #expect(ledger.staleAnchors == [GenerationSlot(clock: Fixture.clockSlot, generation: 1)])
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.placement) == [.unplaced(.anchorRefusedStale)] && take.unplacedSegments == [0])
    }

    /// Ruling 3: a jump closes the segment at the last captured frame and opens a new one; no stitching.
    @Test
    func sampleJumpSplitsAtTheLastCapturedFrame() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.observe(Fixture.anchor(1, 0, host: 0), nominalRate: 48_000)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 0))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 48_000))
        #expect(try ledger.ingest(Fixture.jump(1, 96_000)) == [.split(Fixture.take1)])
        Fixture.refusal(.progressRegressed(frontier: 96_000, frame: 50_000)) { () throws(TakeLedgerError) in
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 50_000))
        }
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 144_000))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.startFrame) == [0, 96_000] && take.segments.map(\.frames) == [48_000, 48_000])
        #expect(take.segments.map(\.startOffsetNs) == [0, 2_000_000_000])
        #expect(take.segments.map(\.fileFrameStart) == [0, 48_000] && take.droppedFrames == 0)
        #expect(take.segments.map(\.openedBy) == [nil, .sampleJump])
        let boundary = try #require(take.boundaries.first)
        #expect(take.boundaries.count == 1 && boundary.reason == .sampleJump && boundary.generation == .initial)
        #expect(boundary.frame == 96_000 && boundary.closedAt == 48_000 && !boundary.droppedEmptySegment)
    }

    @Test
    func backwardJumpAttributesOverflowsToTheSegmentThatHoldsThem() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.observe(Fixture.anchor(1, 0, host: 0), nominalRate: 48_000)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 0))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 48_000))
        _ = try ledger.ingest(Fixture.jump(1, 24_000))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 36_000))
        _ = try ledger.ingest(Fixture.overflow(1, 30_000, frames: 100))
        _ = try ledger.ingest(Fixture.overflow(1, 47_000, frames: 10))
        let crossing = TakeLedgerError.overflowOutsideSegment(startFrame: 47_990, endFrame: 48_010)
        Fixture.refusal(crossing) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 47_990, frames: 20))
        }
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.startOffsetNs) == [0, 500_000_000])
        #expect(take.segments.map(\.paddedFrames) == [10, 100] && take.droppedFrames == 110)
        #expect(take.fileFrames == 60_000)
    }

    @Test
    func sampleJumpScopeAndRefusals() throws {
        var ledger = try Fixture.ledger()
        try ledger.open(Fixture.opening(Fixture.take2, 1, 0, stream: Fixture.otherStream, streamSlot: 9))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 100))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 100))
        #expect(try ledger.ingest(Fixture.jump(1, 200, stream: 9)) == [.split(Fixture.take2)])
        #expect(try ledger.ingest(Fixture.jump(1, 300, stream: 3)).isEmpty)
        Fixture.refusal(.missedRestart(Fixture.take1)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.jump(2, 300, stream: nil))
        }
        #expect(try ledger.ingest(Fixture.jump(1, 400, stream: nil)) == [.split(Fixture.take1), .split(Fixture.take2)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 410))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 410))
        _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: 410, host: 2_500_000_000))
        Fixture.refusal(.staleGeneration(1)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.jump(1, 500, stream: nil))
        }
        try ledger.observe(Fixture.anchor(2, 0, host: 2_500_000_000), nominalRate: 48_000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 10))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.boundaries.map(\.closedAt) == [100, 410] && take.segments.map(\.startFrame) == [0, 400, 0])
        #expect(take.boundaries.map(\.droppedEmptySegment) == [false, false])
    }

    /// Dropped empty segments do not count against the segment bound, only against the boundary bound.
    @Test
    func boundaryBoundIsPinned() throws {
        var ledger = try Fixture.ledger()
        let limit: Int64 = 2_048
        for frame in 1...limit { _ = try ledger.ingest(Fixture.jump(1, frame)) }
        Fixture.refusal(.tooManyBoundaries) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.jump(1, limit + 1))
        }
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, limit + 10))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.count == 1 && take.segments[0].startFrame == limit && take.fileFrames == 10)
        #expect(take.boundaries.count == 2_048 && take.boundaries.allSatisfy(\.droppedEmptySegment))
    }

    /// Round 5 (Copilot): while a take the ledger ended is open, an unowned overflow at or after the
    /// jump's target in its generation is refused, below the old segment's start too. Earlier frames
    /// stay pre-roll and another generation is not the take's. Finishing or discarding the take
    /// returns the same overflows to `[]`.
    @Test
    func overflowFromTheJumpTargetIsRefusedUntilTheEndedTakeCloses() throws {
        let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        for finishes in [true, false] {
            var ledger = try TakeLedger(timebase: Fixture.timebase)
            try ledger.observe(Fixture.anchor(1, 0, host: 0), nominalRate: 48_000)
            try ledger.open(Fixture.opening(Fixture.take1, 1, 1000))
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
            #expect(try ledger.ingest(Fixture.jump(1, 500)) == [.ended(Fixture.take1, ended)])
            for frame: Int64 in [500, 600, 999, 1000, 2500] {
                Fixture.refusal(.recordNotOwned(stream: 0, frame: frame)) { () throws(TakeLedgerError) in
                    _ = try ledger.ingest(Fixture.overflow(1, frame, frames: 10))
                }
            }
            #expect(try ledger.ingest(Fixture.overflow(1, 490, frames: 10)).isEmpty)
            #expect(try ledger.ingest(Fixture.overflow(2, 600, frames: 10)).isEmpty)
            #expect(ledger.isOpen(Fixture.take1) && ledger.ledgerStop(Fixture.take1) == ended)
            #expect(ledger.order == [Fixture.take1])
            if finishes {
                let take = try ledger.finish(Fixture.take1, reason: ended)
                #expect(take.droppedFrames == 0 && take.segments.map(\.frames) == [1000])
                #expect(take.stopMark?.frame == 2000 && take.stopMark?.reportedFrame == 500)
            } else {
                let record = try ledger.discard(Fixture.take1, reason: .abandoned)
                #expect(record.segments.map(\.overflows) == [[]] && record.segments.map(\.endFrame) == [2000])
                #expect(record.stop?.reason == ended && record.stop?.reportedFrame == 500)
            }
            for frame: Int64 in [500, 600, 1000, 2500] {
                #expect(try ledger.ingest(Fixture.overflow(1, frame, frames: 10)).isEmpty)
            }
        }
    }

    /// Round 5: the target is the jump's own generation and frame. Here the take's first segment came
    /// from a restart, so the jump ends it in generation 2, not in the generation it opened in.
    @Test
    func jumpTargetRefusalFollowsTheJumpsGeneration() throws {
        var ledger = try Fixture.ledger()
        let restart = Fixture.restart(2, 1000, previousFrame: 0, host: 2_500_000_000)
        #expect(try ledger.ingest(restart) == [.split(Fixture.take1)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 2000))
        let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        #expect(try ledger.ingest(Fixture.jump(2, 500)) == [.ended(Fixture.take1, ended)])
        for frame: Int64 in [500, 600, 1000] {
            Fixture.refusal(.recordNotOwned(stream: 0, frame: frame)) { () throws(TakeLedgerError) in
                _ = try ledger.ingest(Fixture.overflow(2, frame, frames: 10))
            }
        }
        #expect(try ledger.ingest(Fixture.overflow(2, 490, frames: 10)).isEmpty)
        #expect(try ledger.ingest(Fixture.overflow(1, 600, frames: 10)).isEmpty)
        let take = try ledger.finish(Fixture.take1, reason: ended)
        #expect(take.droppedFrames == 0 && take.segments.map(\.frames) == [1000])
        #expect(take.stopMark?.generation.value == 2 && take.stopMark?.reportedGeneration.value == 2)
        #expect(take.stopMark?.frame == 2000 && take.stopMark?.reportedFrame == 500)
    }

    /// Round 5: a take the device stopped (no ledger stop) still refuses an unowned overflow exactly
    /// at its empty segment's start; that edge does not rest on the jump-target rule.
    @Test
    func overflowAtAStoppedTakesEmptySegmentStartIsRefused() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: 1000, host: 2_500_000_000))
        #expect(try ledger.ingest(Fixture.stop(2, 0, .deviceLost)) == [.recorded(Fixture.take1)])
        Fixture.refusal(.recordNotOwned(stream: 0, frame: 0)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(2, 0, frames: 10))
        }
        let take = try ledger.finish(Fixture.take1, reason: .deviceLost)
        #expect(take.droppedFrames == 0 && take.segments.map(\.frames) == [1000])
    }
}
