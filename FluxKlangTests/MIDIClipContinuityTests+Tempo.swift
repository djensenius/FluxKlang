import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI clip continuity: tempo, re-anchor and loops")
struct MIDIClipContinuityTempoTests {
    typealias Base = MIDIClipTimingTests
    typealias Continuity = MIDIClipContinuityTests
    static let quarter = MusicalTime.ticksPerQuarter
    static let live = Base.live

    static func volume(_ value: UInt8) -> MIDI1Semantic { .controlChange(channel: 1, controller: 7, value: value) }

    /// What an event is, apart from its frame: one Note On, one Note Off or one event of one pass.
    private struct Identity: Hashable {
        let pass: Int64
        let item: Int
        let isNoteOff: Bool

        init(_ event: MIDIClipEvent) {
            pass = event.pass
            item = event.item
            if case .noteOff = event.message { isNoteOff = true } else { isNoteOff = false }
        }
    }

    /// Renders `[start, end)` in up to four contiguous pieces cut by `generator`.
    private static func play(_ scheduler: inout MIDIClipScheduler, from start: Int64, to end: Int64,
                             on map: (clock: MusicalClockMap, current: MIDIClipGenerations),
                             generator: inout MIDIClipSplitMix64) throws -> [MIDIClipEvent] {
        var cuts = [start, end]
        for _ in 0..<Int(generator.next() % 4) where end > start {
            cuts.append(start + Int64(generator.next() % UInt64(end - start)))
        }
        cuts.sort()
        var played: [MIDIClipEvent] = []
        for (from, to) in zip(cuts, cuts.dropFirst()) {
            played += try scheduler.render(from: from, to: to, clock: map.clock, current: map.current)
        }
        return played
    }

    private static func segments(_ generator: inout MIDIClipSplitMix64) -> [(Int64, Int64)] {
        var result: [(Int64, Int64)] = [(0, 200_000 + Int64(generator.next() % 800_001))]
        for _ in 0..<Int(generator.next() % 3) {
            let atTicks = (result.last?.0 ?? 0) + 1 + Int64(generator.next() % UInt64(3 * quarter))
            result.append((atTicks, 200_000 + Int64(generator.next() % 800_001)))
        }
        return result
    }

    @Test
    func renderingOnOneMapThenRebindingEqualsPlayingTheNewMapFromTheCursorTick() throws {
        var generator = MIDIClipSplitMix64(seed: 0x112C_3)
        for round in 0..<48 {
            var items: [MIDIClipItem] = []
            for index in 0..<40 {
                let start = Int64(generator.next() % UInt64(4 * Self.quarter - 10))
                let length = 1 + Int64(generator.next() % 4000)
                items.append(index.isMultiple(of: 4) ? Base.controlChange(start)
                    : Base.note(start, min(start + length, 4 * Self.quarter), pitch: UInt8(index)))
            }
            let looped = round.isMultiple(of: 2)
            let offset = Int64(generator.next() % UInt64(Self.quarter))
            let placement = try Base.placement(items, start: offset,
                                               loop: looped ? (Self.quarter, 3 * Self.quarter) : nil)
            let tickEnd = offset + (looped ? 7 : 4) * Self.quarter
            let rate = round.isMultiple(of: 3) ? 44_100 : 48_000
            let old = try Continuity.clock(Self.live, rate: rate, segments: Self.segments(&generator))
            let moved = generator.next().isMultiple(of: 2)
            let next = try Continuity.generations(sample: moved ? 2 : 1, map: 2)
            let new = try Continuity.clock(next, frame: moved ? Int64(generator.next() % 9000) - 4000 : 0,
                                           ticks: moved ? Int64(generator.next() % UInt64(4 * Self.quarter)) : 0,
                                           rate: rate, segments: Self.segments(&generator))
            let cut = 1 + Int64(generator.next() % UInt64(try old.frame(atTicks: tickEnd)))
            var scheduler = MIDIClipScheduler(placement: placement)
            let before = try Self.play(&scheduler, from: 0, to: cut, on: (old, Self.live),
                                       generator: &generator)
            let ticks = try #require(scheduler.cursorTicks)
            try scheduler.rebind(clock: new, current: next, atFrame: cut)
            let resume = try #require(scheduler.cursor)
            // The cursor stays where the new map puts the tick boundary, else (when the new map rounds the tick
            // before it onto the same frame) it is the tick's own frame.
            let boundary = try MIDIClipPlacement.firstTick(atOrAfterFrame: resume, clock: new)
            let tickFrame = try new.frame(atTicks: ticks)
            #expect(boundary == ticks || (boundary < ticks && resume == tickFrame), "round \(round)")
            let end = try new.frame(atTicks: tickEnd) + 1
            let after = try Self.play(&scheduler, from: resume, to: end, on: (new, next),
                                      generator: &generator)
            let earlier = Set(before.map(Identity.init))
            // Equivalence: after the rebind, exactly the new map's events from the cursor tick play, at its frames.
            let expected = try placement.events(from: resume, to: end, clock: new, current: next)
                .filter { !earlier.contains(Identity($0)) }
            #expect(after == expected, "round \(round)")
            // Nothing is played twice and nothing of the new map up to `end` is lost.
            let all = (before + after).map(Identity.init)
            #expect(Set(all).count == all.count, "round \(round)")
            let start = try new.frame(atTicks: 0)
            let whole = try placement.events(from: start, to: end, clock: new, current: next)
            #expect(Set(whole.map(Identity.init)).isSubset(of: Set(all)), "round \(round)")
            // Every Note On is released exactly once, by the clip or by stop.
            let released = scheduler.stop()
            let notes = before + after + released
            let ons = notes.filter { if case .noteOn = $0.message { true } else { false } }
            let offs = notes.filter { if case .noteOff = $0.message { true } else { false } }
            #expect(Set(ons.map { [$0.pass, Int64($0.item)] }) == Set(offs.map { [$0.pass, Int64($0.item)] }))
            #expect(ons.count == offs.count, "round \(round)")
        }
    }

    @Test
    func aSampleReAnchorWithAnIdenticalMapAddsAndLosesNothing() throws {
        let items = [Base.note(0, Self.quarter), Base.note(100, 30_000, pitch: 62), Base.controlChange(20_000),
                     Base.note(20_000, 20_001, pitch: 64), Base.note(40_000, 4 * Self.quarter, pitch: 65)]
        let placement = try Base.placement(items)
        let whole = try Base.events(placement, 0, 100_000)
        for (frame, ticks) in [(Int64(0), Int64(0)), (777, 32_000), (-3, 640)] {
            var scheduler = MIDIClipScheduler(placement: placement)
            let before = try scheduler.render(from: 0, to: 50_001, clock: Base.clock(), current: Self.live)
            let next = try Continuity.generations(sample: 2)
            let restarted = try Continuity.clock(next, frame: frame, ticks: ticks)
            try scheduler.rebind(clock: restarted, current: next, atFrame: 50_001)
            let resume = try #require(scheduler.cursor)
            let after = try scheduler.render(from: resume, to: resume + 60_000, clock: restarted, current: next)
            let shifted = try restarted.frame(atTicks: 0)
            // The same events in the same order, the later ones moved by the anchor's offset.
            #expect(before + after.map { MIDIClipEvent(frame: $0.frame - shifted, pass: $0.pass, item: $0.item,
                                                       message: $0.message) } == whole)
            #expect(scheduler.soundingCount == 0)
        }
    }

    @Test
    func aRevisionKeepsTheCursorFrameOnlyWhereTheTickBoundaryStays() throws {
        // At 60 BPM ticks 4 and 5 land on frames 13 and 16 (12.5 and 15.625), so frame 15 is tick 5's boundary.
        let placement = try Base.placement([Base.controlChange(4), Base.controlChange(5, value: 5)])
        var kept = MIDIClipScheduler(placement: placement)
        let slow = try Continuity.clock(Self.live, segments: [(0, 1_000_000)])
        #expect(try kept.render(from: 0, to: 15, clock: slow, current: Self.live).map(\.frame) == [13])
        #expect(kept.cursorTicks == 5)
        var moved = kept
        let revised = try Continuity.generations(map: 2)
        let same = try Continuity.clock(revised, segments: [(0, 1_000_000)])
        try kept.rebind(clock: same, current: revised, atFrame: 15)
        #expect(kept.cursor == 15)
        #expect(try kept.render(from: 15, to: 20, clock: same, current: revised).map(\.frame) == [16])
        // Two frames earlier, tick 5 is frame 14 and tick 6 is frame 17: frame 15 is tick 6's boundary, so the cursor
        // moves back to 14 and tick 5 still plays.
        let next = try Continuity.generations(sample: 2, map: 2)
        let earlier = try Continuity.clock(next, frame: -2, segments: [(0, 1_000_000)])
        try moved.rebind(clock: earlier, current: next, atFrame: 15)
        #expect(moved.cursor == 14 && moved.cursorTicks == 5)
        #expect(try moved.render(from: 14, to: 20, clock: earlier, current: next)
            == [MIDIClipEvent(frame: 14, pass: 0, item: 1, message: Self.volume(5))])
        // A map that puts tick 4 (already played) on frame 15 moves the cursor to tick 5's frame 18 (18.125).
        var later = MIDIClipScheduler(placement: placement)
        _ = try later.render(from: 0, to: 15, clock: slow, current: Self.live)
        let shifted = try Continuity.clock(next, frame: 15, ticks: 4, segments: [(0, 1_000_000)])
        try later.rebind(clock: shifted, current: next, atFrame: 15)
        #expect(later.cursor == 18 && later.cursorTicks == 5)
        #expect(try later.render(from: 18, to: 30, clock: shifted, current: next).map(\.frame) == [18])
    }

    @Test
    func eventTicksFollowPassesLoopsCutsAndThePlacementStart() throws {
        // At 120 BPM a tick is 1.5625 frames, so each frame holds at most one tick and fixes the event's tick.
        let items = [Base.note(110, 150), Base.controlChange(119), Base.note(5, 30, pitch: 62), Base.controlChange(0)]
        let placement = try Base.placement(items, length: 200, start: 1001, loop: (20, 120))
        let clock = try Base.clock()
        let events = try Base.events(placement, 0, 4000, clock: clock)
        #expect(events.count == 6 + 3 * 14)
        for event in events {
            #expect(try clock.frame(atTicks: ExactMath.int64(placement.timelineTicks(of: event))) == event.frame)
        }
    }

    @Test
    func aCollapsedLoopBoundarySkipsOnlyThePassAlreadyPlayed() throws {
        // Clip ticks 110...150 are cut at the loop end 120; pass 2 ends at timeline tick 1001 + 200 + 120 = 1321.
        let placement = try Base.placement([Base.note(110, 150), Base.controlChange(119)], length: 200, start: 1001,
                                           loop: (20, 120))
        var scheduler = MIDIClipScheduler(placement: placement)
        let played = try scheduler.render(from: 0, to: 2064, clock: Base.clock(), current: Self.live)
        #expect(played.last == MIDIClipEvent(frame: 2063, pass: 2, item: 1, message: Self.volume(1)))
        #expect(scheduler.cursorTicks == 1321 && scheduler.soundingCount == 1)
        // At 60000 µs per quarter ticks 1320 and 1321 (247.5 and 247.6875 frames) both round to frame 248.
        let revised = try Continuity.generations(map: 2)
        let fast = try Continuity.clock(revised, segments: [(0, 60_000)])
        try scheduler.rebind(clock: fast, current: revised, atFrame: 2064)
        #expect(scheduler.cursor == 248)
        #expect(try scheduler.render(from: 248, to: 252, clock: fast, current: revised)
            == [MIDIClipEvent(frame: 248, pass: 2, item: 0, message: Continuity.off(60))])
        #expect(scheduler.soundingCount == 0)
    }

    @Test
    func loopPassesKeepTheirPassAndItemAcrossARebind() throws {
        let items = [Base.note(Self.quarter, 3 * Self.quarter), Base.note(0, Self.quarter / 2, pitch: 62),
                     Base.controlChange(Self.quarter / 2)]
        let placement = try Base.placement(items, loop: (0, 2 * Self.quarter))
        var scheduler = MIDIClipScheduler(placement: placement)
        let before = try scheduler.render(from: 0, to: 80_000, clock: Base.clock(), current: Self.live)
        #expect(before.last == MIDIClipEvent(frame: 72_000, pass: 1, item: 0, message: Continuity.on(60)))
        #expect(scheduler.cursorTicks == 51_200 && scheduler.soundingCount == 1)
        // Twice as fast from the cursor tick (3⅓ quarters) on revision 2.
        let revised = try Continuity.generations(map: 2)
        let faster = try Continuity.clock(revised, segments: [(0, 500_000), (51_200, 250_000)])
        try scheduler.rebind(clock: faster, current: revised, atFrame: 80_000)
        let after = try scheduler.render(from: 80_000, to: 100_001, clock: faster, current: revised)
        #expect(after == [
            MIDIClipEvent(frame: 88_000, pass: 1, item: 0, message: Continuity.off(60)),
            MIDIClipEvent(frame: 88_000, pass: 2, item: 1, message: Continuity.on(62)),
            MIDIClipEvent(frame: 94_000, pass: 2, item: 1, message: Continuity.off(62)),
            MIDIClipEvent(frame: 94_000, pass: 2, item: 2, message: Self.volume(1)),
            MIDIClipEvent(frame: 100_000, pass: 2, item: 0, message: Continuity.on(60))
        ])
        #expect(scheduler.stop() == [MIDIClipEvent(frame: 100_001, pass: 2, item: 0, message: Continuity.off(60))])
    }

    @Test
    func aSameFrameNoteOnTheNewMapKeepsItsOffRightAfterItsOn() throws {
        // At 1000 BPM and 44.1 kHz a tick is about 0.17 frames. Anchored with tick q − 1 on frame 0, ticks q and q + 1
        // share frame 0, so the note [q, q + 1) collapses onto one frame, and tick q + 2 is frame 1.
        let placement = try Base.placement([Base.note(Self.quarter, Self.quarter + 1), Base.note(0, Self.quarter + 2,
                                                                                               pitch: 62)])
        var scheduler = MIDIClipScheduler(placement: placement)
        _ = try scheduler.render(from: 0, to: 20_000, clock: Base.clock(rate: 44_100), current: Self.live)
        let next = try Continuity.generations(sample: 2, map: 2)
        let fast = try Continuity.clock(next, ticks: Self.quarter - 1, rate: 44_100, segments: [(0, 60_000)])
        try scheduler.rebind(clock: fast, current: next, atFrame: 20_000)
        let resume = try #require(scheduler.cursor)
        #expect(resume < 0)
        #expect(try scheduler.render(from: resume, to: 2, clock: fast, current: next).map(\.message)
            == [Continuity.on(60), Continuity.off(60), Continuity.off(62)])
    }
}
