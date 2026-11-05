import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Round 2: no abnormal path leaves a take stuck, drops a record or loses captured audio.
struct RecordingTakeRecoveryTests {
    typealias Fixture = TakeLedgerTestFixture

    @Test
    func zeroFrameTakeIsDiscardedAndFreesItsStream() throws {
        var ledger = try Fixture.ledger()
        _ = try ledger.ingest(Fixture.jump(1, 5))
        Fixture.refusal(.emptySegment) { () throws(TakeLedgerError) in
            _ = try ledger.finish(Fixture.take1, reason: .user)
        }
        Fixture.refusal(.streamBusy(Fixture.stream)) { () throws(TakeLedgerError) in
            try ledger.open(Fixture.opening(Fixture.take2, 1, 5))
        }
        let record = try ledger.discard(Fixture.take1, reason: .noCapturedFrames)
        #expect(record.reason == .noCapturedFrames && record.segments.isEmpty && record.stop == nil)
        #expect(record.boundaries.map(\.droppedEmptySegment) == [true] && record.take == Fixture.take1)
        #expect(ledger.discarded(Fixture.take1) == record && ledger.take(Fixture.take1) == nil)
        #expect(!ledger.isOpen(Fixture.take1) && ledger.order == [Fixture.take1])
        Fixture.refusal(.takeSealed(Fixture.take1)) { () throws(TakeLedgerError) in
            try ledger.discard(Fixture.take1, reason: .abandoned)
        }
        Fixture.refusal(.takeSealed(Fixture.take1)) { () throws(TakeLedgerError) in
            _ = try ledger.finish(Fixture.take1, reason: .user)
        }
        try ledger.open(Fixture.opening(Fixture.take2, 1, 5))
    }

    @Test
    func anyUnfinishedTakeCanBeDiscardedWithItsEvidence() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        _ = try ledger.ingest(Fixture.overflow(1, 100, frames: 10))
        _ = try ledger.ingest(Fixture.jump(1, 2000))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2500))
        Fixture.refusal(.discardReasonMismatch(.noCapturedFrames)) { () throws(TakeLedgerError) in
            try ledger.discard(Fixture.take1, reason: .noCapturedFrames)
        }
        #expect(ledger.isOpen(Fixture.take1))
        let record = try ledger.discard(Fixture.take1, reason: .abandoned)
        #expect(record.segments.map(\.startFrame) == [0, 2000] && record.segments.map(\.endFrame) == [1000, 2500])
        #expect(record.segments.map(\.paddedFrames) == [10, 0] && record.boundaries.map(\.closedAt) == [1000])
        #expect(record.inputLatency.reportedFrames == 312 && record.stream == Fixture.stream)
    }

    /// Fix 2: a stop right after a restart or jump lands on an empty segment; it moves to the
    /// last stored segment's end, so the take finishes with the device's reason.
    @Test
    func stopRightAfterABoundaryAttachesToTheLastStoredSegment() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: 1000, host: 2_500_000_000))
        #expect(try ledger.ingest(Fixture.stop(2, 0, .deviceLost)) == [.recorded(Fixture.take1)])
        let take = try ledger.finish(Fixture.take1, reason: .deviceLost)
        let mark = try #require(take.captureStopped)
        #expect(take.segments.count == 1 && mark.generation.value == 1 && mark.frame == 1000)
        #expect(mark.reportedGeneration.value == 2 && mark.reportedFrame == 0 && mark.reason == .deviceLost)

        var jumped = try Fixture.ledger(opening: Fixture.take2)
        try jumped.advance(Fixture.take2, to: Fixture.stamp(1, 1000))
        _ = try jumped.ingest(Fixture.jump(1, 5000))
        #expect(try jumped.ingest(Fixture.stop(1, 5000, .diskFull)) == [.recorded(Fixture.take2)])
        let stopped = try jumped.finish(Fixture.take2, reason: .diskFull)
        #expect(stopped.captureStopped?.frame == 1000 && stopped.captureStopped?.reportedFrame == 5000)
        #expect(stopped.segments.map(\.frames) == [1000] && stopped.boundaries.count == 1)
    }

    @Test
    func stopOnATakeWithoutFramesIsKeptAndTheTakeIsDiscardable() throws {
        var ledger = try Fixture.ledger()
        _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: 0, host: 2_500_000_000))
        #expect(try ledger.ingest(Fixture.stop(2, 0, .deviceLost)) == [.recorded(Fixture.take1)])
        Fixture.refusal(.emptySegment) { () throws(TakeLedgerError) in
            _ = try ledger.finish(Fixture.take1, reason: .deviceLost)
        }
        let record = try ledger.discard(Fixture.take1, reason: .noCapturedFrames)
        #expect(record.stop?.reason == .deviceLost && record.stop?.frame == 0 && record.stop?.generation == 2)
    }

    @Test
    func unownedStopOnARecordedStreamIsRefused() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 1000))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1010))
        Fixture.refusal(.recordNotOwned(stream: 0, frame: 500)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.stop(1, 500, .diskFull))
        }
        Fixture.refusal(.recordNotOwned(stream: 0, frame: 1000)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.stop(1, 1000, .diskFull))
        }
        #expect(try ledger.ingest(Fixture.stop(1, 500, .diskFull, stream: 5)).isEmpty)
        #expect(ledger.isOpen(Fixture.take1))
    }

    /// Fix 1b: detected when the jump arrives, never first at finish.
    @Test
    func jumpBeforeTheTakeStartEndsItAtTheLastGoodFrame() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.observe(Fixture.anchor(1, 0, host: 0), nominalRate: 48_000)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 1000))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 49_000))
        #expect(try ledger.ingest(Fixture.jump(1, 1000)) == [.split(Fixture.take1)])
        let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        #expect(try ledger.ingest(Fixture.jump(1, 500)) == [.ended(Fixture.take1, ended)])
        #expect(ledger.ledgerStop(Fixture.take1) == ended)
        Fixture.refusal(.captureAlreadyStopped) { () throws(TakeLedgerError) in
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 600))
        }
        try ledger.open(Fixture.opening(Fixture.take2, 1, 500))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 2000))
        #expect(try ledger.ingest(Fixture.overflow(1, 1500, frames: 10)) == [.recorded(Fixture.take2)])
        Fixture.refusal(.stopReasonMismatch(expected: .user, recorded: ended)) { () throws(TakeLedgerError) in
            _ = try ledger.finish(Fixture.take1, reason: .user)
        }
        let take = try ledger.finish(Fixture.take1, reason: ended)
        #expect(take.segments.map(\.startFrame) == [1000] && take.segments.map(\.frames) == [48_000])
        #expect(take.stopMark?.frame == 49_000 && take.stopMark?.reportedFrame == 500 && take.captureStopped == nil)
        #expect(take.boundaries.map(\.droppedEmptySegment) == [false])
    }

    @Test
    func jumpBeforeTheStartOfAnEmptyTakeLeavesItDiscardable() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 1000))
        _ = try ledger.ingest(Fixture.jump(1, 10))
        Fixture.refusal(.emptySegment) { () throws(TakeLedgerError) in
            _ = try ledger.finish(Fixture.take1, reason: .discontinuity(.jumpBeforeTakeStart))
        }
        let record = try ledger.discard(Fixture.take1, reason: .noCapturedFrames)
        #expect(record.stop?.reason == .discontinuity(.jumpBeforeTakeStart) && record.stop?.reportedFrame == 10)
    }

    /// A jump in a later generation splits normally, even to a frame below the take's start.
    @Test
    func missingAnchorsFinishUnplacedAndLaterJumpsSplit() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 1000))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
        _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: 2000, host: 2_500_000_000))
        try ledger.observe(Fixture.anchor(2, 0, host: 2_500_000_000), nominalRate: 48_000)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 100))
        #expect(try ledger.ingest(Fixture.jump(2, 50)) == [.split(Fixture.take1)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 60))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments.map(\.placement) == [.unplaced(.anchorNotObserved), .unplaced(.takeAnchorMissing),
                                                   .unplaced(.takeAnchorMissing)])
        #expect(take.unplacedSegments == [0, 1, 2] && take.fileFrames == 1110)
    }

    /// Round 3, the reviewer's repro: after a jump ends take 1, an overflow at 1200 (inside its old
    /// segment's frame numbers) is refused or routed to the take that owns the post-jump range.
    @Test
    func ledgerEndedTakeOwnsNoFurtherRecord() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.observe(Fixture.anchor(1, 0, host: 0), nominalRate: 48_000)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 1000))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
        _ = try ledger.ingest(Fixture.jump(1, 500))
        Fixture.refusal(.recordNotOwned(stream: 0, frame: 1200)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 1200, frames: 10))
        }
        Fixture.refusal(.recordNotOwned(stream: 0, frame: 1200)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.stop(1, 1200, .deviceLost))
        }
        // Round 4: exactly at the old segment's start is still refused; another generation is not this take's.
        Fixture.refusal(.recordNotOwned(stream: 0, frame: 1000)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 1000, frames: 10))
        }
        #expect(try ledger.ingest(Fixture.overflow(2, 1100, frames: 10)).isEmpty)
        try ledger.open(Fixture.opening(Fixture.take2, 1, 500))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 1500))
        // Take 2 is stopped, not capturing: the late overflow still goes to it, never to the ended take 1.
        #expect(try ledger.ingest(Fixture.stop(1, 1500, .deviceLost)) == [.recorded(Fixture.take2)])
        #expect(try ledger.ingest(Fixture.overflow(1, 1200, frames: 10)) == [.recorded(Fixture.take2)])
        let old = try ledger.finish(Fixture.take1, reason: .discontinuity(.jumpBeforeTakeStart))
        #expect(old.droppedFrames == 0 && old.segments.map(\.overflows) == [[]] && old.segments[0].frames == 1000)
        #expect(try ledger.finish(Fixture.take2, reason: .deviceLost).droppedFrames == 10)
    }

    /// Round 4, the reviewer's probe: `append` applies the same ownership rule as `ingest`.
    @Test
    func appendNeverReachesALedgerEndedTake() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.observe(Fixture.anchor(1, 0, host: 0), nominalRate: 48_000)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 1000))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
        #expect(ledger.ledgerStop(Fixture.take1) == nil)
        let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        #expect(try ledger.ingest(Fixture.jump(1, 500)) == [.ended(Fixture.take1, ended)])
        Fixture.refusal(.recordNotOwned(stream: 0, frame: 1200)) { () throws(TakeLedgerError) in
            try ledger.append(Fixture.overflow(1, 1200, frames: 10), to: Fixture.take1)
        }
        Fixture.refusal(.recordNotOwned(stream: 0, frame: 2000)) { () throws(TakeLedgerError) in
            try ledger.append(Fixture.stop(1, 2000, .deviceLost), to: Fixture.take1)
        }
        try ledger.open(Fixture.opening(Fixture.take2, 1, 500))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 600))
        _ = try ledger.ingest(Fixture.stop(1, 600, .deviceLost))
        #expect(ledger.ledgerStop(Fixture.take2) == nil && ledger.ledgerStop(Fixture.take1) == ended)
        let old = try ledger.finish(Fixture.take1, reason: ended)
        #expect(old.droppedFrames == 0 && old.segments.map(\.frames) == [1000])
        #expect(ledger.ledgerStop(Fixture.take1) == ended)
    }

    @Test
    func jumpEffectsAreInOpeningOrder() throws {
        var ledger = try Fixture.ledger(opening: Fixture.take1, at: 1000)
        try ledger.open(Fixture.opening(Fixture.take2, 1, 0, stream: Fixture.otherStream, streamSlot: 9))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 2000))
        let effects = try ledger.ingest(Fixture.jump(1, 500, stream: nil))
        #expect(effects == [.ended(Fixture.take1, .discontinuity(.jumpBeforeTakeStart)), .split(Fixture.take2)])
        #expect(effects.map(\.take) == [Fixture.take1, Fixture.take2])
    }

    /// Round 3: a late overflow past a closed segment's end is refused, never dropped; pre-roll,
    /// another clock or another stream is not the take's and stays `[]`.
    @Test
    func unownedRecordsAreRefusedUnlessPreRollOrElsewhere() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: 1000, host: 2_500_000_000))
        Fixture.refusal(.recordNotOwned(stream: 0, frame: 1000)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 1000, frames: 10))
        }
        let otherClock = Fixture.stamp(1, 500, clock: 1)
        let stop = RuntimeDiscontinuity(kind: .captureStopped(reason: .diskFull), sample: otherClock, frames: nil,
                                        stream: Fixture.streamSlot, host: nil)
        let overflow = RuntimeDiscontinuity(kind: .overflow, sample: otherClock, frames: 10,
                                            stream: Fixture.streamSlot, host: nil)
        #expect(try ledger.ingest(stop).isEmpty)
        #expect(try ledger.ingest(overflow).isEmpty)

        var preRoll = try Fixture.ledger(opening: Fixture.take1, at: 1000)
        #expect(try preRoll.ingest(Fixture.overflow(1, 100, frames: 10)).isEmpty)
    }

    /// Ruling 6b applies only to a stop in the generation the restart ends.
    @Test
    func olderStopDoesNotBlockALaterRestart() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        _ = try ledger.ingest(Fixture.stop(1, 1000, .diskFull))
        #expect(try ledger.ingest(Fixture.restart(2, 0, previousFrame: 1000, host: 2_500_000_000)).isEmpty)
        #expect(try ledger.ingest(Fixture.restart(3, 0, previousFrame: 10, host: 2_600_000_000)).isEmpty)
    }

    /// Round 3 (info): every capturing take on the clock must stand at the restart's previous
    /// frame; one lagging take refuses it for all, and the same restart succeeds once it advances.
    @Test
    func laggingTakeBlocksARestartUntilItAdvances() throws {
        var ledger = try Fixture.ledger()
        try ledger.open(Fixture.opening(Fixture.take2, 1, 0, stream: Fixture.otherStream, streamSlot: 9))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 900))
        let restart = Fixture.restart(2, 0, previousFrame: 1000, host: 2_500_000_000)
        Fixture.refusal(.segmentEndMismatch(frontier: 900, previousFrame: 1000)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(restart)
        }
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 1000))
        #expect(try ledger.ingest(restart) == [.split(Fixture.take1), .split(Fixture.take2)])
    }

    @Test
    func staleAnchorEvidenceBoundIsPinned() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.observe(Fixture.anchor(4_098, 0, host: 1), nominalRate: 48_000)
        for generation in UInt64(1)...4_097 {
            Fixture.refusal(.staleGeneration(generation)) { () throws(TakeLedgerError) in
                try ledger.observe(Fixture.anchor(generation, 0, host: 1), nominalRate: 48_000)
            }
        }
        #expect(ledger.staleAnchors.count == 4_096)
        #expect(ledger.staleAnchors.contains { $0.generation == 4_096 } && !ledger.staleAnchors.contains {
            $0.generation == 4_097
        })
    }

    /// The take initializer checks that a stop mark sits at the last segment's end.
    @Test
    func stopMarkMustSitAtTheLastSegmentsEnd() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        _ = try ledger.ingest(Fixture.stop(1, 1000, .diskFull))
        let mark = try #require(try ledger.finish(Fixture.take1, reason: .diskFull).stopMark)
        func take(generation: UInt64, startFrame: Int64, frames: Int64) throws(TakeLedgerError) -> RecordingTake {
            let segment = try RecordingSegment(
                clock: Fixture.clock, generation: try TakeLedger.contractGeneration(generation), nominalRate: 48_000,
                startFrame: startFrame, placement: .placed(startOffsetNs: 0), fileFrameStart: 0, frames: frames,
                overflows: [], openedBy: nil)
            return try RecordingTake(take: Fixture.take1, stream: Fixture.stream, inputLatency: try Fixture.latency(),
                                     segments: [segment], boundaries: [], stopReason: .diskFull, stopMark: mark)
        }
        Fixture.refusal(.inconsistentRecord(.stopMark)) { () throws(TakeLedgerError) in
            _ = try take(generation: 1, startFrame: 0, frames: 100)
        }
        Fixture.refusal(.inconsistentRecord(.stopMark)) { () throws(TakeLedgerError) in
            _ = try take(generation: 2, startFrame: 900, frames: 100)
        }
        #expect(try take(generation: 1, startFrame: 0, frames: 1000).stopMark == mark)
    }

    /// Fix 4: a closed take never receives a record when an open take also owns it.
    @Test
    func ownerPrefersTheOpenTake() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 48_000))
        _ = try ledger.finish(Fixture.take1, reason: .user)
        try ledger.open(Fixture.opening(Fixture.take2, 1, 24_000))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 36_000))
        #expect(ledger.owner(of: Fixture.overflow(1, 30_000, frames: 10)) == Fixture.take2)
        #expect(try ledger.ingest(Fixture.overflow(1, 30_000, frames: 10)) == [.recorded(Fixture.take2)])
        Fixture.refusal(.takeSealed(Fixture.take1)) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, 10_000, frames: 10))
        }
        #expect(ledger.take(Fixture.take1)?.droppedFrames == 0)
        #expect(try ledger.finish(Fixture.take2, reason: .user).droppedFrames == 10)
    }

    /// Ruling 6b: a stopped take is passed by, but its stop must not lie past the restart.
    @Test
    func stoppedTakeMustNotEndPastTheRestart() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        _ = try ledger.ingest(Fixture.stop(1, 1000, .diskFull))
        let refusal = TakeLedgerError.stopAfterRestart(Fixture.take1, stopFrame: 1000, previousFrame: 999)
        Fixture.refusal(refusal) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.restart(2, 0, previousFrame: 999, host: 2_500_000_000))
        }
        #expect(try ledger.ingest(Fixture.restart(2, 0, previousFrame: 1000, host: 2_500_000_000)).isEmpty)
        #expect(try ledger.finish(Fixture.take1, reason: .diskFull).captureStopped?.frame == 1000)
    }

    @Test
    func restartRecordBoundIsPinned() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        for generation in UInt64(2)...4_097 {
            _ = try ledger.ingest(Fixture.restart(generation, 0, previousFrame: 0, host: generation))
        }
        Fixture.refusal(.tooManyGenerationRecords) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.restart(4_098, 0, previousFrame: 0, host: 1))
        }
    }

    @Test
    func streamBusyChecksTheStreamIDAndJumpsAdvanceTheGeneration() throws {
        var ledger = try Fixture.ledger()
        Fixture.refusal(.streamBusy(Fixture.stream)) { () throws(TakeLedgerError) in
            try ledger.open(Fixture.opening(Fixture.take2, 1, 0, streamSlot: 9))
        }
        #expect(try ledger.ingest(Fixture.jump(3, 0, stream: 9)).isEmpty)
        Fixture.refusal(.staleGeneration(2)) { () throws(TakeLedgerError) in
            try ledger.open(Fixture.opening(Fixture.take2, 2, 0, stream: Fixture.otherStream, streamSlot: 9))
        }
    }

    /// Touching overflow intervals are accepted as separate records, never merged.
    @Test
    func touchingOverflowsAreKeptSeparately() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 100))
        _ = try ledger.ingest(Fixture.overflow(1, 10, frames: 5))
        _ = try ledger.ingest(Fixture.overflow(1, 15, frames: 5))
        let take = try ledger.finish(Fixture.take1, reason: .user)
        #expect(take.segments[0].overflows.map(\.startFrame) == [10, 15] && take.droppedFrames == 10)
    }

    /// Only v1's three stop reasons export; a ledger stop waits for the contract revision (#336).
    @Test
    func contractV1StopReasonRefusesLedgerStops() throws {
        #expect(try TakeStopReason.user.contractV1StopReason() == "user")
        #expect(try TakeStopReason.diskFull.contractV1StopReason() == "diskFull")
        #expect(try TakeStopReason.deviceLost.contractV1StopReason() == "deviceLost")
        let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        Fixture.refusal(.stopReasonNotInContractV1(ended)) { () throws(TakeLedgerError) in
            _ = try ended.contractV1StopReason()
        }
    }

    /// Fix 3: take records are built only through validating initializers.
    @Test
    func handBuiltRecordsAreValidated() throws {
        Fixture.refusal(.missingOverflowFrames) { () throws(TakeLedgerError) in
            _ = try OverflowInterval(startFrame: 0, frames: 0)
        }
        Fixture.refusal(.arithmeticOverflow) { () throws(TakeLedgerError) in
            _ = try OverflowInterval(startFrame: .max, frames: 1)
        }
        let inside = try OverflowInterval(startFrame: 10, frames: 5)
        let overlapping = try OverflowInterval(startFrame: 12, frames: 5)
        let outside = try OverflowInterval(startFrame: 95, frames: 10)
        func segment(frames: Int64 = 100, rate: Int? = 48_000, placement: SegmentPlacement = .placed(startOffsetNs: 0),
                     fileFrameStart: Int64 = 0,
                     overflows: [OverflowInterval] = []) throws(TakeLedgerError) -> RecordingSegment {
            try RecordingSegment(clock: Fixture.clock, generation: .initial, nominalRate: rate, startFrame: 0,
                                 placement: placement, fileFrameStart: fileFrameStart, frames: frames,
                                 overflows: overflows, openedBy: nil)
        }
        let faults: [(TakeRecordFault, () throws(TakeLedgerError) -> RecordingSegment)] = [
            (.frames, { () throws(TakeLedgerError) in try segment(frames: 0) }),
            (.frames, { () throws(TakeLedgerError) in try segment(fileFrameStart: -1) }),
            (.nominalRate, { () throws(TakeLedgerError) in try segment(rate: 47_999) }),
            (.placement, { () throws(TakeLedgerError) in try segment(placement: .placed(startOffsetNs: -1)) }),
            (.overflows, { () throws(TakeLedgerError) in try segment(overflows: [inside, overlapping]) }),
            (.overflows, { () throws(TakeLedgerError) in try segment(overflows: [outside]) })
        ]
        for (fault, build) in faults {
            Fixture.refusal(.inconsistentRecord(fault)) { () throws(TakeLedgerError) in _ = try build() }
        }
        let valid = try segment(overflows: [inside])
        #expect(valid.paddedFrames == 5 && valid.endFrame == 100)
        func take(_ segments: [RecordingSegment], reason: TakeStopReason = .user) throws(TakeLedgerError) {
            _ = try RecordingTake(take: Fixture.take1, stream: Fixture.stream, inputLatency: try Fixture.latency(),
                                  segments: segments, boundaries: [], stopReason: reason, stopMark: nil)
        }
        Fixture.refusal(.emptySegment) { () throws(TakeLedgerError) in try take([]) }
        Fixture.refusal(.inconsistentRecord(.fileContinuity)) { () throws(TakeLedgerError) in
            try take([valid, try segment(fileFrameStart: 99)])
        }
        Fixture.refusal(.inconsistentRecord(.placement)) { () throws(TakeLedgerError) in
            try take([try segment(placement: .placed(startOffsetNs: 5))])
        }
        Fixture.refusal(.inconsistentRecord(.stopMark)) { () throws(TakeLedgerError) in
            try take([valid], reason: .diskFull)
        }
        let built = try RecordingTake(take: Fixture.take1, stream: Fixture.stream, inputLatency: try Fixture.latency(),
                                      segments: [valid, try segment(fileFrameStart: 100, overflows: [inside])],
                                      boundaries: [], stopReason: .user, stopMark: nil)
        #expect(built.droppedFrames == 10 && built.fileFrames == 200)
    }
}
