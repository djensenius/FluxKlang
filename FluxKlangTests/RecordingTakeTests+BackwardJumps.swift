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
}
