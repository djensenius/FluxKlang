import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Rounds 8 (Copilot) and 8b (coordinator): §8.3, no segment, the last included, ends after its
/// generation's `previousFrame`, in any take on the restarting clock: capturing, stopped, ended by
/// the ledger, finished or discarded. A segment closed before a backward jump can, so the restart is
/// refused, never trimmed: its frames already sit in the file ahead of the later segments.
struct RecordingTakeBackwardJumpTests {
    typealias Fixture = TakeLedgerTestFixture

    /// Capturing: take 1 records [0, end), jumps back to 500 and records [500, 1500); take 2 records
    /// [0, 1500) on another stream. A first segment ending exactly at `previousFrame` (N = 1500) is
    /// kept. One ending a frame later (N + 1) refuses the restart for both takes, and nothing changes.
    @Test
    func capturingTakeKeepsNoSegmentPastTheRestart() throws {
        for end: Int64 in [1500, 1501] {
            var ledger = try Fixture.ledger()
            try ledger.open(Fixture.opening(Fixture.take2, 1, 0, stream: Fixture.otherStream, streamSlot: 9))
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, end))
            #expect(try ledger.ingest(Fixture.jump(1, 500)) == [.split(Fixture.take1)])
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1500))
            try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 1500))
            var previous: Int64 = 1500
            if end > previous {
                let early = Fixture.restart(2, 0, previousFrame: previous, host: 2_500_000_000)
                let refusal = TakeLedgerError.segmentAfterRestart(Fixture.take1, segmentEnd: end,
                                                                  previousFrame: previous)
                Fixture.refusal(refusal) { () throws(TakeLedgerError) in _ = try ledger.ingest(early) }
                // Nothing changed: both takes still capture generation 1, and generation 2 is unused.
                previous = 1600
                try ledger.advance(Fixture.take1, to: Fixture.stamp(1, previous))
                try ledger.advance(Fixture.take2, to: Fixture.stamp(1, previous))
            }
            let restart = Fixture.restart(2, 0, previousFrame: previous, host: 2_500_000_000)
            #expect(try ledger.ingest(restart) == [.split(Fixture.take1), .split(Fixture.take2)])
            let take = try ledger.finish(Fixture.take1, reason: .user)
            #expect(take.segments.map(\.startFrame) == [0, 500] && take.segments.map(\.frames) == [end, previous - 500])
            #expect(take.segments.allSatisfy { $0.startFrame + $0.frames <= previous })
            #expect(take.boundaries.map(\.reason) == [.sampleJump, .clockRestart(previousFrame: previous)])
            #expect(try ledger.finish(Fixture.take2, reason: .user).segments.map(\.frames) == [previous])
        }
    }

    /// Device-stopped: take 1 records [0, end), jumps back to 500, records [500, 1500) and the device
    /// stops it at 1500. Its stop does not lie past `previousFrame: 1500`, but its first segment can.
    /// Like a recorded stop (round 6), that segment bounds the restart whether the take is open,
    /// finished or discarded: N is kept, N + 1 is refused, and nothing changes.
    @Test
    func deviceStoppedTakeKeepsNoSegmentPastTheRestart() throws {
        enum Closing { case open, finish, discard }
        for end: Int64 in [1500, 1501] {
            for closing in [Closing.open, .finish, .discard] {
                var ledger = try Fixture.ledger()
                try ledger.advance(Fixture.take1, to: Fixture.stamp(1, end))
                #expect(try ledger.ingest(Fixture.jump(1, 500)) == [.split(Fixture.take1)])
                try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1500))
                #expect(try ledger.ingest(Fixture.stop(1, 1500, .deviceLost)) == [.recorded(Fixture.take1)])
                var finished: RecordingTake?
                var discarded: DiscardedTake?
                switch closing {
                case .open: break
                case .finish: finished = try ledger.finish(Fixture.take1, reason: .deviceLost)
                case .discard: discarded = try ledger.discard(Fixture.take1, reason: .abandoned)
                }
                if end > 1500 {
                    let early = Fixture.restart(2, 0, previousFrame: 1500, host: 2_500_000_000)
                    let refusal = TakeLedgerError.segmentAfterRestart(Fixture.take1, segmentEnd: end,
                                                                      previousFrame: 1500)
                    Fixture.refusal(refusal) { () throws(TakeLedgerError) in _ = try ledger.ingest(early) }
                }
                // Nothing changed: generation 1 is still the latest and generation 2 unused. A restart
                // that ends the generation exactly where the first segment ends is accepted.
                try ledger.open(Fixture.opening(Fixture.take2, 1, end, stream: Fixture.otherStream, streamSlot: 9))
                let restart = Fixture.restart(2, 0, previousFrame: end, host: 2_500_000_000)
                #expect(try ledger.ingest(restart) == [.split(Fixture.take2)])
                #expect(ledger.take(Fixture.take1) == finished && ledger.discarded(Fixture.take1) == discarded)
                switch closing {
                case .open:
                    let take = try ledger.finish(Fixture.take1, reason: .deviceLost)
                    #expect(take.segments.map(\.frames) == [end, 1000] && take.stopMark?.frame == 1500)
                case .finish:
                    #expect(finished?.segments.map(\.frames) == [end, 1000])
                case .discard:
                    #expect(discarded?.segments.map(\.endFrame) == [end, 1500])
                }
                #expect(ledger.order == [Fixture.take1, Fixture.take2])
            }
        }
    }

    /// Round 3, moved here from the recovery suite and revised in round 8b: the caller sees
    /// `.ended` when the jump arrives, and both takes stay recoverable. The ended take's segment
    /// [1000, 2000) still bounds a restart (§8.3): N + 1 (`previousFrame: 1999`) refuses it for
    /// every take and nothing changes; N (2000) is accepted.
    @Test
    func ledgerEndedTakeBoundsARestartByItsSegment() throws {
        var ledger = try TakeLedger(timebase: Fixture.timebase)
        try ledger.observe(Fixture.anchor(1, 0, host: 0), nominalRate: 48_000)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 1000))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
        let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        #expect(try ledger.ingest(Fixture.jump(1, 500)) == [.ended(Fixture.take1, ended)])
        try ledger.open(Fixture.opening(Fixture.take2, 1, 500))
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 1999))
        let early = Fixture.restart(2, 0, previousFrame: 1999, host: 2_500_000_000)
        let refusal = TakeLedgerError.segmentAfterRestart(Fixture.take1, segmentEnd: 2000, previousFrame: 1999)
        Fixture.refusal(refusal) { () throws(TakeLedgerError) in _ = try ledger.ingest(early) }
        // Nothing changed: take 2 still captures generation 1, and generation 2 is unused.
        try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 2000))
        let restart = Fixture.restart(2, 0, previousFrame: 2000, host: 2_500_000_000)
        #expect(try ledger.ingest(restart) == [.split(Fixture.take2)])
        try ledger.advance(Fixture.take2, to: Fixture.stamp(2, 100))
        #expect(try ledger.finish(Fixture.take1, reason: ended).segments.map(\.frames) == [1000])
        #expect(try ledger.finish(Fixture.take2, reason: .user).segments.map(\.frames) == [1500, 100])
    }

    /// Round 8b, the stop exemption: a ledger stop sits at the end of the take's last stored
    /// segment, which the segment check already bounds, except in a take that captured nothing. Its
    /// stop sits at its empty segment's start (1000), past `previousFrame: 600`, and bounds
    /// nothing: that restart is accepted whether the take is still open or discarded.
    @Test
    func ledgerStopAloneNeverBoundsARestart() throws {
        let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        for discards in [false, true] {
            var ledger = try Fixture.ledger(opening: Fixture.take1, at: 1000)
            #expect(try ledger.ingest(Fixture.jump(1, 500)) == [.ended(Fixture.take1, ended)])
            if discards {
                #expect(try ledger.discard(Fixture.take1, reason: .noCapturedFrames).stop?.frame == 1000)
            } else {
                #expect(ledger.ledgerStop(Fixture.take1) == ended)
            }
            #expect(try ledger.ingest(Fixture.restart(2, 0, previousFrame: 600, host: 2_500_000_000)).isEmpty)
        }
    }

    /// Round 8b: a closed take that recorded no stop (finished by the user, or abandoned while
    /// capturing) bounds a restart by its segment too: N + 1 is refused and nothing changes; N is
    /// accepted.
    @Test
    func closedTakeWithoutAStopBoundsARestart() throws {
        for finishes in [true, false] {
            var ledger = try Fixture.ledger()
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
            var finished: RecordingTake?
            var discarded: DiscardedTake?
            if finishes {
                finished = try ledger.finish(Fixture.take1, reason: .user)
            } else {
                discarded = try ledger.discard(Fixture.take1, reason: .abandoned)
            }
            #expect(finished?.stopMark == nil && discarded?.stop == nil)
            let early = Fixture.restart(2, 0, previousFrame: 999, host: 2_500_000_000)
            let refusal = TakeLedgerError.segmentAfterRestart(Fixture.take1, segmentEnd: 1000, previousFrame: 999)
            Fixture.refusal(refusal) { () throws(TakeLedgerError) in _ = try ledger.ingest(early) }
            #expect(ledger.take(Fixture.take1) == finished && ledger.discarded(Fixture.take1) == discarded)
            #expect(try ledger.ingest(Fixture.restart(2, 0, previousFrame: 1000, host: 2_500_000_000)).isEmpty)
        }
    }

    /// Round 8c: only takes on the restarting clock bound it. A take on clock 1 records [0, 2000)
    /// and is device-stopped at 2000, finished or discarded; a clock-0 restart with `previousFrame:
    /// 1000` is accepted and leaves it untouched, while a clock-1 one is still refused.
    @Test
    func takeOnAnotherClockNeverBoundsARestart() throws {
        enum Closing { case deviceStop, finish, discard }
        for closing in [Closing.deviceStop, .finish, .discard] {
            var ledger = try TakeLedger(timebase: Fixture.timebase)
            let start = Fixture.stamp(1, 0, clock: 1)
            try ledger.observe(RuntimeClockAnchor(sample: start, host: HostStamp(ticks: 0), musical: nil),
                               nominalRate: 48_000)
            try ledger.open(TakeOpening(take: Fixture.take1, stream: Fixture.stream, streamSlot: Fixture.streamSlot,
                                        clock: Fixture.clock, start: start,
                                        inputLatency: try Fixture.latency()))
            try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000, clock: 1))
            var finished: RecordingTake?
            var discarded: DiscardedTake?
            var refusal = TakeLedgerError.segmentAfterRestart(Fixture.take1, segmentEnd: 2000, previousFrame: 1000)
            switch closing {
            case .deviceStop:
                let stop = RuntimeDiscontinuity(kind: .captureStopped(reason: .deviceLost),
                                                sample: Fixture.stamp(1, 2000, clock: 1), frames: nil,
                                                stream: Fixture.streamSlot, host: nil)
                #expect(try ledger.ingest(stop) == [.recorded(Fixture.take1)])
                refusal = .stopAfterRestart(Fixture.take1, stopFrame: 2000, previousFrame: 1000)
            case .finish: finished = try ledger.finish(Fixture.take1, reason: .user)
            case .discard: discarded = try ledger.discard(Fixture.take1, reason: .abandoned)
            }
            #expect(try ledger.ingest(Fixture.restart(2, 0, previousFrame: 1000, host: 2_500_000_000)).isEmpty)
            #expect(ledger.take(Fixture.take1) == finished && ledger.discarded(Fixture.take1) == discarded)
            let sameClock = Fixture.restart(2, 0, previousFrame: 1000, host: 2_500_000_000, clock: 1)
            Fixture.refusal(refusal) { () throws(TakeLedgerError) in _ = try ledger.ingest(sameClock) }
            if closing == .deviceStop {
                let take = try ledger.finish(Fixture.take1, reason: .deviceLost)
                #expect(take.segments.map(\.frames) == [2000] && take.stopMark?.frame == 2000)
            }
        }
    }

    /// Round 8c (Copilot 4486448555): take 1 records [1000, 2000) and a jump to 500 ends it. An
    /// overflow [s, e) is pre-roll only when e <= 500. An unowned one crossing 500 is routed exactly
    /// like its part [500, e), never dropped: with no take after the jump, it is refused
    /// `.recordNotOwned` at 500, like one starting at 500 (lengthless included). Take 2, capturing
    /// from 500 on the stream, owns a crossing overflow and refuses it by its own start rule; it
    /// records one starting at 500 and refuses a lengthless one's length.
    @Test
    func overflowCrossingTheJumpTargetIsNeverDropped() throws {
        let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        let notOwned = TakeLedgerError.recordNotOwned(stream: Fixture.streamSlot, frame: 500)
        for opensTake2 in [false, true] {
            for (frame, frames) in [(Int64(490), UInt32(20)), (500, 20), (500, 0)] {
                var ledger = try Fixture.ledger(opening: Fixture.take1, at: 1000)
                try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
                #expect(try ledger.ingest(Fixture.jump(1, 500)) == [.ended(Fixture.take1, ended)])
                var expected: TakeLedgerError? = notOwned
                if opensTake2 {
                    try ledger.open(Fixture.opening(Fixture.take2, 1, 500))
                    try ledger.advance(Fixture.take2, to: Fixture.stamp(1, 600))
                    expected = frame < 500 ? .overflowOutsideSegment(startFrame: 490, endFrame: 510) : nil
                    if frames == 0 { expected = .missingOverflowFrames }
                }
                // Pre-roll ends at or before the target; a lengthless overflow spans one frame.
                for (start, length) in [(Int64(490), UInt32?(10)), (499, 1), (499, 0), (499, nil), (490, 0)] {
                    #expect(try ledger.ingest(Fixture.overflow(1, start, frames: length)).isEmpty)
                }
                let record = Fixture.overflow(1, frame, frames: frames)
                if let expected {
                    Fixture.refusal(expected) { () throws(TakeLedgerError) in _ = try ledger.ingest(record) }
                } else {
                    #expect(try ledger.ingest(record) == [.recorded(Fixture.take2)])
                }
                if opensTake2 {
                    #expect(try ledger.finish(Fixture.take2, reason: .user).droppedFrames == (expected == nil ? 20 : 0))
                }
            }
        }
    }

    /// Round 8d (Copilot, delta review): a closed take's empty segment [s, s) holds no frames and
    /// owns nothing, so an overflow crossing s is never refused `.takeSealed` by it. A: take 1 opens
    /// at 1000 and is discarded with no frames (take 2 then opened at 2000, or not): [990, 1010) is
    /// pre-roll, like [900, 920). C: take 1 records [0, 1000), a jump to 5000 leaves an empty
    /// trailing segment and take 1 is finished; take 2 opens at 6000: [4990, 5010) is ignored,
    /// like [3000, 3020).
    @Test
    func closedTakesEmptySegmentOwnsNothing() throws {
        for opensTake2 in [false, true] {
            var ledger = try Fixture.ledger(opening: Fixture.take1, at: 1000)
            try ledger.discard(Fixture.take1, reason: .noCapturedFrames)
            if opensTake2 { try ledger.open(Fixture.opening(Fixture.take2, 1, 2000)) }
            #expect(try ledger.ingest(Fixture.overflow(1, 990, frames: 20)).isEmpty)
            #expect(try ledger.ingest(Fixture.overflow(1, 900, frames: 20)).isEmpty)
        }
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        #expect(try ledger.ingest(Fixture.jump(1, 5000)) == [.split(Fixture.take1)])
        #expect(try ledger.finish(Fixture.take1, reason: .user).segments.map(\.frames) == [1000])
        try ledger.open(Fixture.opening(Fixture.take2, 1, 6000))
        #expect(try ledger.ingest(Fixture.overflow(1, 4990, frames: 20)).isEmpty)
        #expect(try ledger.ingest(Fixture.overflow(1, 3000, frames: 20)).isEmpty)
    }

    /// Round 8d, D: take 2 opens at 500 and is discarded with no frames; take 1 records [1000,
    /// 2000) and a jump to 500 ends it. [490, 510) is refused `.recordNotOwned` at 500, like [500,
    /// 520), not `.takeSealed` by take 2's empty segment.
    @Test
    func discardedEmptyTakeNeverHidesTheJumpTarget() throws {
        var ledger = try Fixture.ledger(opening: Fixture.take2, at: 500)
        try ledger.discard(Fixture.take2, reason: .noCapturedFrames)
        try ledger.open(Fixture.opening(Fixture.take1, 1, 1000))
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 2000))
        let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        #expect(try ledger.ingest(Fixture.jump(1, 500)) == [.ended(Fixture.take1, ended)])
        let notOwned = TakeLedgerError.recordNotOwned(stream: Fixture.streamSlot, frame: 500)
        for frame: Int64 in [490, 500] {
            let record = Fixture.overflow(1, frame, frames: 20)
            Fixture.refusal(notOwned) { () throws(TakeLedgerError) in _ = try ledger.ingest(record) }
        }
    }

    /// Round 8d, unchanged: an open, device-stopped take keeps its empty segment's ownership. Take 1
    /// records [0, 1000), restarts into generation 2 at 1000, records [1000, 2000), jumps back to
    /// 500 and is stopped there. [490, 510) only crosses the empty segment [500, 500): it is owned
    /// and refused `.overflowOutsideSegment`, never ignored.
    @Test
    func stoppedTakesEmptySegmentStillOwnsACrossingOverflow() throws {
        var ledger = try Fixture.ledger()
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, 1000))
        let restart = Fixture.restart(2, 1000, previousFrame: 1000, host: 2_500_000_000)
        #expect(try ledger.ingest(restart) == [.split(Fixture.take1)])
        try ledger.advance(Fixture.take1, to: Fixture.stamp(2, 2000))
        #expect(try ledger.ingest(Fixture.jump(2, 500)) == [.split(Fixture.take1)])
        #expect(try ledger.ingest(Fixture.stop(2, 500, .deviceLost)) == [.recorded(Fixture.take1)])
        let refusal = TakeLedgerError.overflowOutsideSegment(startFrame: 490, endFrame: 510)
        Fixture.refusal(refusal) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(2, 490, frames: 20))
        }
        #expect(try ledger.finish(Fixture.take1, reason: .deviceLost).segments.map(\.frames) == [1000, 1000])
    }

    /// Round 8d: the crossing check saturates the overflow's end. Take 1 opens at Int64.max - 3 and
    /// a jump to Int64.max - 5 ends it; [Int64.max - 10, +20) crosses the target and is refused there.
    @Test
    func crossingCheckSaturatesTheOverflowEnd() throws {
        var ledger = try Fixture.ledger(opening: Fixture.take1, at: Int64.max - 3)
        try ledger.advance(Fixture.take1, to: Fixture.stamp(1, Int64.max - 1))
        let ended = TakeStopReason.discontinuity(.jumpBeforeTakeStart)
        #expect(try ledger.ingest(Fixture.jump(1, Int64.max - 5)) == [.ended(Fixture.take1, ended)])
        let refusal = TakeLedgerError.recordNotOwned(stream: Fixture.streamSlot, frame: Int64.max - 5)
        Fixture.refusal(refusal) { () throws(TakeLedgerError) in
            _ = try ledger.ingest(Fixture.overflow(1, Int64.max - 10, frames: 20))
        }
    }
}
