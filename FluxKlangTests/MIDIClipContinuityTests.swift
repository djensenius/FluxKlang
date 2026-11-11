import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite("MIDI clip continuity across a clock re-anchor", .productionAccessAudit)
#else
@Suite("MIDI clip continuity across a clock re-anchor")
#endif
struct MIDIClipContinuityTests {
    typealias Base = MIDIClipTimingTests
    static let quarter = MusicalTime.ticksPerQuarter
    static let live = Base.live

    /// Generations with the given counters (1 is `.initial`).
    static func generations(sample: Int = 1, transport: Int = 1, map: Int = 1) throws -> ClockGenerationSnapshot {
        ClockGenerationSnapshot(sample: try Generation(sample), transport: try Generation(transport),
                                musicalMap: try Generation(map))
    }

    /// A clock for `current` whose anchor puts `ticks` on `frame`; 120 BPM at 48 kHz by default.
    static func clock(_ current: ClockGenerationSnapshot, frame: Int64 = 0, ticks: Int64 = 0, rate: Int = 48_000,
                      segments: [(Int64, Int64)] = [(0, 500_000)],
                      loopIteration: UInt32 = 0) throws -> MusicalClockMap {
        let anchor = ClockAnchor(
            sample: SampleStamp(clock: Base.primary, generation: current.sample, frame: frame),
            host: HostStamp(ticks: 0),
            musical: MusicalStamp(transport: current.transport, musicalMap: current.musicalMap, ticks: ticks,
                                  loopIteration: loopIteration)
        )
        let map = try MusicalMap(clock: Base.musical, revision: current.musicalMap,
                                 segments: segments.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) })
        return try MusicalClockMap(anchor: anchor, map: map, nominalRate: rate, currentSample: current.sample,
                                   currentTransport: current.transport)
    }

    static func on(_ pitch: UInt8) -> MIDI1Semantic { .noteOn(channel: 1, note: pitch, velocity: 100) }
    static func off(_ pitch: UInt8) -> MIDI1Semantic { .noteOff(channel: 1, note: pitch, velocity: 64) }

    @Test
    func aTempoHalvingMidNoteMovesItsNoteOffToTheNewMapFrame() throws {
        let placement = try Base.placement([Base.note(0, 2 * Self.quarter)])
        var scheduler = MIDIClipScheduler(placement: placement)
        #expect(try scheduler.render(from: 0, to: 36_000, clock: Base.clock(), current: Self.live)
            == [MIDIClipEvent(frame: 0, pass: 0, item: 0, message: Self.on(60))])
        // 36000 frames at 120 BPM is exactly 1.5 quarters; the tempo halves from there on revision 2.
        #expect(scheduler.cursorTicks == 23_040)
        let revised = try Self.generations(map: 2)
        let slower = try Self.clock(revised, segments: [(0, 500_000), (23_040, 1_000_000)])
        try scheduler.rebind(clock: slower, current: revised, atFrame: 36_000)
        #expect(scheduler.cursor == 36_000 && scheduler.binding == revised && scheduler.soundingCount == 1)
        #expect(try scheduler.render(from: 36_000, to: 59_999, clock: slower, current: revised).isEmpty)
        // Half a quarter at 60 BPM is 24000 frames: the Note Off moves from 48000 (the old map) to 60000.
        let release = try scheduler.render(from: 59_999, to: 100_000, clock: slower, current: revised)
        #expect(release == [MIDIClipEvent(frame: 60_000, pass: 0, item: 0, message: Self.off(60))])
        #expect(try slower.frame(atTicks: 2 * Self.quarter) == 60_000)
        #expect(scheduler.soundingCount == 0 && scheduler.stop().isEmpty)
    }

    @Test
    func aReAnchoredSlowerMapReleasesAtTheSameTicksFrame() throws {
        // The new map is 60 BPM throughout, anchored so the cursor tick keeps its frame.
        let placement = try Base.placement([Base.note(0, 2 * Self.quarter), Base.note(Self.quarter, 3 * Self.quarter,
                                                                                      pitch: 64)])
        var scheduler = MIDIClipScheduler(placement: placement)
        let played = try scheduler.render(from: 0, to: 36_000, clock: Base.clock(), current: Self.live)
        #expect(played.map(\.message) == [Self.on(60), Self.on(64)])
        let next = try Self.generations(sample: 2, map: 2)
        let slower = try Self.clock(next, frame: 36_000, ticks: 23_040, segments: [(0, 1_000_000)])
        try scheduler.rebind(clock: slower, current: next, atFrame: 36_000)
        #expect(scheduler.cursor == 36_000)
        let rest = try scheduler.render(from: 36_000, to: 200_000, clock: slower, current: next)
        #expect(rest == [MIDIClipEvent(frame: 60_000, pass: 0, item: 0, message: Self.off(60)),
                         MIDIClipEvent(frame: 108_000, pass: 0, item: 1, message: Self.off(64))])
    }

    @Test
    func aRebindKeepsTheSoundingSetAndNeverRetriggers() throws {
        let items = [Base.note(0, 3 * Self.quarter), Base.note(10, 2 * Self.quarter, pitch: 62),
                     Base.note(20, 30, pitch: 64), Base.controlChange(Self.quarter)]
        var scheduler = MIDIClipScheduler(placement: try Base.placement(items))
        _ = try scheduler.render(from: 0, to: 30_000, clock: Base.clock(), current: Self.live)
        #expect(scheduler.soundingCount == 2)
        let revised = try Self.generations(map: 2)
        let faster = try Self.clock(revised, segments: [(0, 500_000), (19_200, 250_000)])
        try scheduler.rebind(clock: faster, current: revised, atFrame: 30_000)
        #expect(scheduler.soundingCount == 2)
        let rest = try scheduler.render(from: 30_000, to: 100_000, clock: faster, current: revised)
        // 240 BPM from tick 19200: 2 quarters at 39000, 3 quarters at 51000. No Note On is played again.
        #expect(rest == [MIDIClipEvent(frame: 39_000, pass: 0, item: 1, message: Self.off(62)),
                         MIDIClipEvent(frame: 51_000, pass: 0, item: 0, message: Self.off(60))])
        #expect(scheduler.soundingCount == 0)
    }

    @Test
    func aRebindWithoutARenderIsRefusedAndChangesNothing() throws {
        let revised = try Self.generations(map: 2)
        let clock = try Self.clock(revised)
        var scheduler = MIDIClipScheduler(placement: try Base.placement([Base.note(0, Self.quarter)]))
        let fresh = scheduler
        #expect(Base.refusal { try scheduler.rebind(clock: clock, current: revised, atFrame: 0) }
            == .rebindWithoutRender)
        #expect(scheduler == fresh)
        // Checked first: a transport change without a render is still `rebindWithoutRender`.
        let moved = try Self.generations(transport: 2)
        #expect(Base.refusal { try scheduler.rebind(clock: Self.clock(moved), current: moved, atFrame: 0) }
            == .rebindWithoutRender)
        _ = try scheduler.render(from: 0, to: 100, clock: Base.clock(), current: Self.live)
        _ = scheduler.stop()
        let stopped = scheduler
        #expect(Base.refusal { try scheduler.rebind(clock: clock, current: revised, atFrame: 100) }
            == .rebindWithoutRender)
        #expect(scheduler == stopped && scheduler.cursorTicks == nil)
    }

    @Test
    func aRebindAwayFromTheCursorIsRefusedAndChangesNothing() throws {
        var scheduler = MIDIClipScheduler(placement: try Base.placement([Base.note(0, Self.quarter)]))
        _ = try scheduler.render(from: 0, to: 1000, clock: Base.clock(), current: Self.live)
        let before = scheduler
        let revised = try Self.generations(map: 2)
        let clock = try Self.clock(revised)
        for frame: Int64 in [999, 1001, 0] {
            #expect(Base.refusal { try scheduler.rebind(clock: clock, current: revised, atFrame: frame) }
                == .rebindCursorMismatch(expected: 1000, frame: frame))
        }
        // The cursor is checked before the transport.
        let moved = try Self.generations(transport: 2)
        #expect(Base.refusal { try scheduler.rebind(clock: Self.clock(moved), current: moved, atFrame: 999) }
            == .rebindCursorMismatch(expected: 1000, frame: 999))
        #expect(scheduler == before)
        try scheduler.rebind(clock: clock, current: revised, atFrame: 1000)
        #expect(scheduler.cursor == 1000 && scheduler.binding == revised)
    }

    @Test
    func aTransportChangeIsRefusedUntilStop() throws {
        let placement = try Base.placement([Base.note(0, Self.quarter), Base.note(100, 200, pitch: 62)])
        var scheduler = MIDIClipScheduler(placement: placement)
        _ = try scheduler.render(from: 0, to: 20_000, clock: Base.clock(), current: Self.live)
        #expect(scheduler.soundingCount == 1)
        let before = scheduler
        for moved in [try Self.generations(transport: 2), try Self.generations(sample: 2, transport: 2, map: 2)] {
            #expect(Base.refusal { try scheduler.rebind(clock: Self.clock(moved), current: moved, atFrame: 20_000) }
                == .transportChangedRequiresStop(expected: .initial, got: moved.transport))
            // A stale clock with a moved transport still reports the transport first.
            #expect(Base.refusal { try scheduler.rebind(clock: Base.clock(), current: moved, atFrame: 20_000) }
                == .transportChangedRequiresStop(expected: .initial, got: moved.transport))
        }
        #expect(scheduler == before)
        // The caller stops: the sounding note is released once at the cursor, then playback restarts after the locate.
        #expect(scheduler.stop() == [MIDIClipEvent(frame: 20_000, pass: 0, item: 0, message: Self.off(60))])
        let moved = try Self.generations(transport: 2)
        let located = try Self.clock(moved, frame: 20_000, ticks: 0)
        #expect(try scheduler.render(from: 20_000, to: 20_001, clock: located, current: moved).map(\.message)
            == [Self.on(60)])
        #expect(scheduler.binding == moved)
    }

    @Test
    func aLoopWrapIsRefusedUntilStop() throws {
        let placement = try Base.placement([Base.note(0, Self.quarter), Base.note(100, 200, pitch: 62)])
        var scheduler = MIDIClipScheduler(placement: placement)
        _ = try scheduler.render(from: 0, to: 20_000, clock: Base.clock(), current: Self.live)
        #expect(scheduler.soundingCount == 1 && scheduler.loopIteration == 0)
        let before = scheduler
        // A transport loop wrap re-anchors the loop start (tick 0) at the wrap frame and bumps only the loop
        // iteration, no generation (media contract §5.1, §5.5).
        let wrapped = try Self.clock(Self.live, frame: 20_000, ticks: 0, loopIteration: 1)
        #expect(Base.refusal { try scheduler.rebind(clock: wrapped, current: Self.live, atFrame: 20_000) }
            == .loopWrapRequiresStop(expected: 0, got: 1))
        #expect(Base.refusal { try scheduler.render(from: 20_000, to: 20_001, clock: wrapped, current: Self.live) }
            == .loopWrapRequiresStop(expected: 0, got: 1))
        // A tempo revision on the wrapped clock is still a wrap.
        let revised = try Self.generations(map: 2)
        let wrappedRevision = try Self.clock(revised, frame: 20_000, ticks: 0, loopIteration: 1)
        #expect(Base.refusal { try scheduler.rebind(clock: wrappedRevision, current: revised, atFrame: 20_000) }
            == .loopWrapRequiresStop(expected: 0, got: 1))
        #expect(scheduler == before)
        // The caller stops, then playback restarts on the wrapped clock and a later revision rebinds as usual.
        #expect(scheduler.stop() == [MIDIClipEvent(frame: 20_000, pass: 0, item: 0, message: Self.off(60))])
        #expect(scheduler.loopIteration == nil)
        #expect(try scheduler.render(from: 20_000, to: 20_001, clock: wrapped, current: Self.live).map(\.message)
            == [Self.on(60)])
        #expect(scheduler.loopIteration == 1)
        let slower = try Self.clock(revised, frame: 20_000, ticks: 0, segments: [(0, 1_000_000)], loopIteration: 1)
        try scheduler.rebind(clock: slower, current: revised, atFrame: 20_001)
        let resume = try #require(scheduler.cursor)
        // At 60 BPM a tick is 3.125 frames after the wrap: ticks 100 and 200 round up to 313 and 625 frames, and the
        // Note Off at tick 15,360 lands at 48,000.
        #expect(try scheduler.render(from: resume, to: 70_000, clock: slower, current: revised) == [
            MIDIClipEvent(frame: 20_313, pass: 0, item: 1, message: Self.on(62)),
            MIDIClipEvent(frame: 20_625, pass: 0, item: 1, message: Self.off(62)),
            MIDIClipEvent(frame: 68_000, pass: 0, item: 0, message: Self.off(60))
        ])
        #expect(scheduler.soundingCount == 0)
    }

    @Test
    func aLoopWrapIsCheckedAfterTheTransportAndTheClock() throws {
        // The refusal order (DESIGN.md): `rebind` checks the transport generation, then the clock against `current`,
        // then the loop iteration; `render` checks the clock and the bound generations before the loop iteration.
        var scheduler = MIDIClipScheduler(placement: try Base.placement([Base.note(0, Self.quarter)]))
        _ = try scheduler.render(from: 0, to: 20_000, clock: Base.clock(), current: Self.live)
        _ = scheduler.stop()
        let wrapped = try Self.clock(Self.live, frame: 20_000, ticks: 0, loopIteration: 1)
        _ = try scheduler.render(from: 20_000, to: 20_001, clock: wrapped, current: Self.live)
        #expect(scheduler.loopIteration == 1)
        let restarted = scheduler
        // Every clock below has loop iteration 0. A locate after the wrap re-anchors with loop iteration 0 (media
        // contract §5.4): it is a transport change, not a wrap.
        let located = try Self.generations(transport: 2)
        let locatedClock = try Self.clock(located, frame: 20_001)
        #expect(Base.refusal { try scheduler.rebind(clock: locatedClock, current: located, atFrame: 20_001) }
            == .transportChangedRequiresStop(expected: .initial, got: located.transport))
        // A stale clock is stale, in `rebind` and in `render`.
        let stale: [(ClockGenerationSnapshot, MIDIClipRefusal)] = [
            (try Self.generations(map: 2), .staleMusicalMap),
            (try Self.generations(sample: 2, map: 2), .clock(.staleSampleGeneration))
        ]
        for (current, expected) in stale {
            #expect(Base.refusal { try scheduler.rebind(clock: Base.clock(), current: current, atFrame: 20_001) }
                == expected)
            #expect(Base.refusal {
                try scheduler.render(from: 20_001, to: 20_002, clock: Base.clock(), current: current)
            } == expected)
        }
        // A live clock with other generations is a clock revision for `render`.
        let revised = try Self.generations(map: 2)
        let revisedClock = try Self.clock(revised)
        #expect(Base.refusal { try scheduler.render(from: 20_001, to: 20_002, clock: revisedClock, current: revised) }
            == .clockRevisionChanged(expected: Self.live, got: revised))
        #expect(scheduler == restarted)
    }

    @Test
    func aRebindToAStaleOrOverflowingClockIsRefusedAndChangesNothing() throws {
        var scheduler = MIDIClipScheduler(placement: try Base.placement([Base.note(0, Self.quarter)]))
        _ = try scheduler.render(from: 0, to: 30_000, clock: Base.clock(), current: Self.live)
        let before = scheduler
        let revised = try Self.generations(sample: 2, map: 2)
        let cases: [(MusicalClockMap, MIDIClipRefusal)] = [
            (try Self.clock(Self.live), .clock(.staleSampleGeneration)),
            (try Self.clock(Self.generations(sample: 2)), .staleMusicalMap),
            (try Self.clock(revised, frame: Int64.max - 10), .clock(.overflow))
        ]
        for (clock, expected) in cases {
            #expect(Base.refusal { try scheduler.rebind(clock: clock, current: revised, atFrame: 30_000) }
                == expected)
        }
        #expect(scheduler == before)
    }

    @Test
    func rendersAfterARebindNeedTheNewGenerations() throws {
        var scheduler = MIDIClipScheduler(placement: try Base.placement([Base.note(0, Self.quarter)]))
        _ = try scheduler.render(from: 0, to: 10, clock: Base.clock(), current: Self.live)
        let revised = try Self.generations(map: 2)
        let clock = try Self.clock(revised)
        try scheduler.rebind(clock: clock, current: revised, atFrame: 10)
        #expect(Base.refusal { try scheduler.render(from: 10, to: 20, clock: Base.clock(), current: Self.live) }
            == .clockRevisionChanged(expected: revised, got: Self.live))
        // Rebinding to the generations already bound is allowed and moves nothing on the same map.
        try scheduler.rebind(clock: clock, current: revised, atFrame: 10)
        #expect(scheduler.cursor == 10 && scheduler.soundingCount == 1)
        #expect(try scheduler.render(from: 10, to: 30_000, clock: clock, current: revised).map(\.frame) == [24_000])
    }

    @Test
    func stopAfterARebindReleasesOnlyThisClipsSoundingNotesOnce() throws {
        let drone = try Base.placement([Base.note(0, 4 * Self.quarter, pitch: 36)])
        let lead = try Base.placement([
            Base.note(0, Self.quarter), Base.note(Self.quarter / 2, 3 * Self.quarter, pitch: 64),
            Base.controlChange(Self.quarter)
        ])
        var droneScheduler = MIDIClipScheduler(placement: drone)
        var leadScheduler = MIDIClipScheduler(placement: lead)
        #expect(try droneScheduler.render(from: 0, to: 30_000, clock: Base.clock(), current: Self.live).count == 1)
        #expect(try leadScheduler.render(from: 0, to: 30_000, clock: Base.clock(), current: Self.live).map(\.message)
            == [Self.on(60), Self.on(64), Self.off(60), .controlChange(channel: 1, controller: 7, value: 1)])
        let revised = try Self.generations(map: 2)
        let faster = try Self.clock(revised, segments: [(0, 500_000), (19_200, 250_000)])
        try leadScheduler.rebind(clock: faster, current: revised, atFrame: 30_000)
        #expect(try leadScheduler.render(from: 30_000, to: 40_000, clock: faster, current: revised).isEmpty)
        let released = leadScheduler.stop()
        #expect(released == [MIDIClipEvent(frame: 40_000, pass: 0, item: 1, message: Self.off(64))])
        #expect(leadScheduler.stop().isEmpty && leadScheduler.soundingCount == 0)
        // The drone on the old map is untouched and releases at its own Note Off.
        #expect(droneScheduler.soundingCount == 1)
        #expect(try droneScheduler.render(from: 30_000, to: 100_000, clock: Base.clock(), current: Self.live)
            == [MIDIClipEvent(frame: 96_000, pass: 0, item: 0, message: Self.off(36))])
    }

    @Test
    func stopRightAfterARebindReleasesAtTheNewCursorFrame() throws {
        var scheduler = MIDIClipScheduler(placement: try Base.placement([Base.note(0, Self.quarter)]))
        _ = try scheduler.render(from: 0, to: 12_000, clock: Base.clock(), current: Self.live)
        let next = try Self.generations(sample: 2)
        // A sample-clock restart puts the cursor tick (7680) at frame 500.
        let restarted = try Self.clock(next, frame: 500, ticks: 7680)
        try scheduler.rebind(clock: restarted, current: next, atFrame: 12_000)
        #expect(scheduler.cursor == 500 && scheduler.cursorTicks == 7680)
        #expect(scheduler.stop() == [MIDIClipEvent(frame: 500, pass: 0, item: 0, message: Self.off(60))])
        #expect(scheduler.cursor == nil && scheduler.binding == nil && scheduler.cursorTicks == nil)
        // A restart after the stop plays from scratch: nothing of the old rebind skips tick 0.
        #expect(try scheduler.render(from: 0, to: 1, clock: Base.clock(), current: Self.live).map(\.message)
            == [Self.on(60)])
    }

    @Test
    func ticksAlreadyPlayedOnTheCursorFrameAreNotReplayed() throws {
        // At 120 BPM, ticks 3 and 4 land on frames 5 and 6; at 60000 µs per quarter ticks 3...7 share frame 1.
        let items = [Base.note(1, 4), Base.controlChange(3, value: 3), Base.controlChange(4, value: 4),
                     Base.note(3, 10, pitch: 62)]
        var scheduler = MIDIClipScheduler(placement: try Base.placement(items))
        let played = try scheduler.render(from: 0, to: 6, clock: Base.clock(), current: Self.live)
        #expect(played.map(\.item) == [0, 1, 3] && scheduler.cursorTicks == 4)
        let revised = try Self.generations(map: 2)
        let fast = try Self.clock(revised, segments: [(0, 60_000)])
        try scheduler.rebind(clock: fast, current: revised, atFrame: 6)
        #expect(scheduler.cursor == 1 && scheduler.cursorTicks == 4)
        // An empty render keeps the tick and the skip.
        #expect(try scheduler.render(from: 1, to: 1, clock: fast, current: revised).isEmpty)
        #expect(scheduler.cursorTicks == 4)
        let rest = try scheduler.render(from: 1, to: 3, clock: fast, current: revised)
        #expect(rest == [
            MIDIClipEvent(frame: 1, pass: 0, item: 0, message: Self.off(60)),
            MIDIClipEvent(frame: 1, pass: 0, item: 2, message: .controlChange(channel: 1, controller: 7, value: 4)),
            MIDIClipEvent(frame: 2, pass: 0, item: 3, message: Self.off(62))
        ])
        // Without the skip, the new map's window [1, 3) also holds tick 3's controller and Note On.
        #expect(try scheduler.placement.events(from: 1, to: 3, clock: fast, current: revised).count == 5)
        #expect(scheduler.cursorTicks == 14 && scheduler.soundingCount == 0)
        // The skip ends with that render: the next window plays everything on it.
        #expect(try scheduler.render(from: 3, to: 3000, clock: fast, current: revised).isEmpty)
    }

    @Test
    func twoRebindsWithoutARenderKeepTheTick() throws {
        let items = [Base.note(1, 4), Base.controlChange(3, value: 3), Base.controlChange(4, value: 4),
                     Base.note(3, 10, pitch: 62)]
        let placement = try Base.placement(items)
        let second = try Self.generations(map: 2)
        let third = try Self.generations(map: 3)
        let viaSecond = try Self.clock(second, segments: [(0, 1_000_000)])
        let fast = try Self.clock(third, segments: [(0, 60_000)])
        var direct = MIDIClipScheduler(placement: placement)
        var twice = MIDIClipScheduler(placement: placement)
        _ = try direct.render(from: 0, to: 6, clock: Base.clock(), current: Self.live)
        _ = try twice.render(from: 0, to: 6, clock: Base.clock(), current: Self.live)
        try direct.rebind(clock: fast, current: third, atFrame: 6)
        try twice.rebind(clock: viaSecond, current: second, atFrame: 6)
        // At 60 BPM frame 6 is the boundary of tick 2, not 4, so the cursor moves to tick 4's frame 13 (12.5 rounds
        // up).
        #expect(twice.cursor == 13 && twice.cursorTicks == 4)
        try twice.rebind(clock: fast, current: third, atFrame: 13)
        #expect(twice == direct)
        #expect(try twice.render(from: 1, to: 3, clock: fast, current: third).map(\.item) == [0, 2, 3])
    }
}
