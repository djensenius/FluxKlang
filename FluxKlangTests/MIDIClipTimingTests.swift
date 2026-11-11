import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite("MIDI clip timing", .productionAccessAudit)
#else
@Suite("MIDI clip timing")
#endif
struct MIDIClipTimingTests {
    static let primary = ClockID(validated: "smp.main")
    static let musical = ClockID(validated: "mus.main")
    static let live = ClockGenerationSnapshot(sample: .initial, transport: .initial, musicalMap: .initial)
    static let quarter = MusicalTime.ticksPerQuarter

    /// A clock whose anchor puts `ticks` on `frame`; 120 BPM at 48 kHz by default.
    static func clock(frame: Int64 = 0, ticks: Int64 = 0, rate: Int = 48_000, revision: Generation = .initial,
                      segments: [(Int64, Int64)] = [(0, 500_000)]) throws -> MusicalClockMap {
        let anchor = ClockAnchor(
            sample: SampleStamp(clock: primary, generation: .initial, frame: frame), host: HostStamp(ticks: 0),
            musical: MusicalStamp(transport: .initial, musicalMap: .initial, ticks: ticks, loopIteration: 0)
        )
        let map = try MusicalMap(clock: musical, revision: revision,
                                 segments: segments.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) })
        return try MusicalClockMap(anchor: anchor, map: map, nominalRate: rate,
                                   currentSample: .initial, currentTransport: .initial)
    }

    static func note(_ start: Int64, _ end: Int64, pitch: UInt8 = 60, channel: UInt8 = 1,
                     velocity: UInt8 = 100, release: UInt8 = 64) -> MIDIClipItem {
        .note(MIDIClipNote(channel: channel, note: pitch, velocity: velocity, releaseVelocity: release,
                           startTicks: start, endTicks: end))
    }

    static func controlChange(_ ticks: Int64, value: UInt8 = 1) -> MIDIClipItem {
        .event(ticks: ticks, message: .controlChange(channel: 1, controller: 7, value: value))
    }

    static func placement(_ items: [MIDIClipItem], length: Int64 = 4 * quarter, start: Int64 = 0,
                          loop: (Int64, Int64)? = nil) throws -> MIDIClipPlacement {
        let clip = try MIDIClip.make(lengthTicks: length, items: items)
        return try MIDIClipPlacement.make(clip: clip, startTicks: start,
                                          loop: loop.map { try LoopRange(startTicks: $0.0, endTicks: $0.1) })
    }

    static func events(_ placement: MIDIClipPlacement, _ start: Int64, _ end: Int64,
                       clock: MusicalClockMap? = nil) throws -> [MIDIClipEvent] {
        try placement.events(from: start, to: end, clock: clock ?? Self.clock(), current: live)
    }

    static func refusal(_ body: () throws -> some Any) -> MIDIClipRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? MIDIClipRefusal
        }
    }

    static func onFrames(_ events: [MIDIClipEvent]) -> [Int64] {
        events.filter { if case .noteOn = $0.message { true } else { false } }.map(\.frame)
    }

    @Test
    func aQuarterAt120BPMLandsOnFrame24000AndFramesRoundHalfUp() throws {
        let placement = try Self.placement([Self.note(Self.quarter, 2 * Self.quarter), Self.note(1, 2, pitch: 61)])
        let events = try Self.events(placement, 0, 96_000)
        #expect(events.map(\.frame) == [2, 3, 24_000, 48_000])
        #expect(events.first?.message == .noteOn(channel: 1, note: 61, velocity: 100))
        #expect(events.last?.message == .noteOff(channel: 1, note: 60, velocity: 64))
        // 768 ticks at 120 BPM and 44.1 kHz is exactly 1102.5 frames: half-up gives 1103.
        let half = try Self.placement([Self.note(768, 1000)])
        #expect(try Self.events(half, 0, 2000, clock: Self.clock(rate: 44_100)).first?.frame == 1103)
    }

    @Test
    func framesFollowTheAnchorAndThePlacementStart() throws {
        let placement = try Self.placement([Self.note(0, Self.quarter)], start: 2 * Self.quarter)
        let clock = try Self.clock(frame: 1000, ticks: Self.quarter)
        #expect(try Self.events(placement, 0, 100_000, clock: clock).map(\.frame) == [25_000, 49_000])
    }

    @Test
    func aTickRoundingUpIntoAWindowBelongsToThatWindow() throws {
        // Tick 1 is 1.5625 frames and rounds up to frame 2, so it belongs to [2, 3), not to [0, 2).
        let placement = try Self.placement([Self.note(1, 2)])
        #expect(try Self.events(placement, 0, 2).isEmpty)
        #expect(try Self.events(placement, 2, 3).map(\.frame) == [2])
        // At 300 BPM ticks 1 and 2 (0.625 and 1.25 frames) both round to frame 1.
        let fast = try Self.clock(segments: [(0, 200_000)])
        let close = try Self.placement([Self.note(1, 3)])
        #expect(try Self.events(close, 0, 1, clock: fast).isEmpty)
        #expect(try Self.events(close, 1, 2, clock: fast).map(\.frame) == [1])
    }

    @Test
    func aMidClipTempoChangeIsHonoured() throws {
        let items = [Self.note(0, Self.quarter), Self.note(2 * Self.quarter, 3 * Self.quarter, pitch: 62)]
        let placement = try Self.placement(items)
        let steady = try Self.events(placement, 0, 200_000)
        #expect(steady.map(\.frame) == [0, 24_000, 48_000, 72_000])
        // Twice as fast from the second quarter: 24000 frames, then 12000 per quarter.
        let faster = try Self.clock(segments: [(0, 500_000), (Self.quarter, 250_000)])
        let changed = try Self.events(placement, 0, 200_000, clock: faster)
        #expect(changed.map(\.frame) == [0, 24_000, 36_000, 48_000])
        for event in changed {
            let ticks: Int64 = event.item == 0 ? (event.frame == 0 ? 0 : Self.quarter)
                : (event.frame == 36_000 ? 2 * Self.quarter : 3 * Self.quarter)
            #expect(try faster.frame(atTicks: ticks) == event.frame)
        }
    }

    @Test
    func adjacentWindowsSplitTheEventsExactly() throws {
        let placement = try Self.placement([Self.note(0, Self.quarter), Self.note(Self.quarter, 2 * Self.quarter)],
                                           length: 2 * Self.quarter)
        #expect(try Self.events(placement, 0, 24_000).map(\.frame) == [0])
        #expect(try Self.events(placement, 24_000, 48_000).map(\.frame) == [24_000, 24_000])
        #expect(try Self.events(placement, 23_999, 24_000).isEmpty)
        #expect(try Self.events(placement, 48_000, 48_001).map(\.frame) == [48_000])

        var items: [MIDIClipItem] = []
        var generator = MIDIClipSplitMix64(seed: 112)
        for index in 0..<200 {
            let start = Int64(generator.next() % UInt64(4 * Self.quarter - 10))
            items.append(index.isMultiple(of: 3) ? Self.controlChange(start)
                : Self.note(start, start + 1 + Int64(generator.next() % 9), pitch: UInt8(index % 128),
                            channel: UInt8(1 + index / 128)))
        }
        let dense = try Self.placement(items)
        let clock = try Self.clock(frame: 17, rate: 44_100, segments: [(0, 431_211), (20_000, 60_000)])
        let whole = try Self.events(dense, -5, 200_000, clock: clock)
        #expect(whole.count == 67 + 2 * 133)
        var cuts: [Int64] = [-5, 200_000]
        for _ in 0..<40 { cuts.append(-5 + Int64(generator.next() % 200_005)) }
        cuts.sort()
        var pieces: [MIDIClipEvent] = []
        for (from, to) in zip(cuts, cuts.dropFirst()) {
            pieces += try Self.events(dense, from, to, clock: clock)
        }
        #expect(pieces == whole)
    }

    @Test
    func noteOffsPrecedeNoteOnsAtOneFrameThenAuthoringOrder() throws {
        let items = [
            Self.controlChange(Self.quarter),
            Self.note(Self.quarter, 2 * Self.quarter, velocity: 90),
            Self.note(0, Self.quarter, pitch: 60, release: 20),
            Self.note(0, Self.quarter, pitch: 64),
            .event(ticks: Self.quarter, message: .programChange(channel: 2, program: 5))
        ]
        let events = try Self.events(try Self.placement(items, length: 2 * Self.quarter + 1), 24_000, 24_001)
        #expect(events.map(\.item) == [2, 3, 0, 1, 4])
        #expect(events.map(\.message) == [
            .noteOff(channel: 1, note: 60, velocity: 20), .noteOff(channel: 1, note: 64, velocity: 64),
            .controlChange(channel: 1, controller: 7, value: 1), .noteOn(channel: 1, note: 60, velocity: 90),
            .programChange(channel: 2, program: 5)
        ])
    }

    @Test
    func aNoteRoundingToOneFrameHasItsOffRightAfterItsOn() throws {
        // At 1000 BPM and 44.1 kHz a tick is about 0.17 frames: ticks 0...2 all round to frame 0.
        let clock = try Self.clock(rate: 44_100, segments: [(0, 60_000)])
        let placement = try Self.placement([Self.note(1, 2, pitch: 61), Self.note(0, 1), Self.note(1, 6)])
        let events = try Self.events(placement, 0, 10, clock: clock)
        #expect(events.map(\.frame) == [0, 0, 0, 0, 0, 1])
        #expect(events.map(\.item) == [1, 1, 0, 0, 2, 2])
        #expect(events.map(\.message) == [
            .noteOn(channel: 1, note: 60, velocity: 100), .noteOff(channel: 1, note: 60, velocity: 64),
            .noteOn(channel: 1, note: 61, velocity: 100), .noteOff(channel: 1, note: 61, velocity: 64),
            .noteOn(channel: 1, note: 60, velocity: 100), .noteOff(channel: 1, note: 60, velocity: 64)
        ])
        var scheduler = MIDIClipScheduler(placement: placement)
        #expect(try scheduler.render(from: 0, to: 1, clock: clock, current: Self.live).count == 5)
        #expect(scheduler.soundingCount == 1)
        #expect(try scheduler.render(from: 1, to: 10, clock: clock, current: Self.live).count == 1)
        #expect(scheduler.soundingCount == 0)
    }

    @Test
    func sameFrameNotesFollowTheirOnsetTicksBeforeAuthoringOrder() throws {
        // Ticks 0...2 share frame 0; item 1 starts and ends before item 0 starts, though authored after it.
        let clock = try Self.clock(rate: 44_100, segments: [(0, 60_000)])
        let placement = try Self.placement([Self.note(2, 30), Self.note(1, 2)])
        let events = try Self.events(placement, 0, 10, clock: clock)
        #expect(events.map(\.item) == [1, 1, 0, 0])
        #expect(events.map(\.frame) == [0, 0, 0, 5])
        #expect(events.map(\.message) == [
            .noteOn(channel: 1, note: 60, velocity: 100), .noteOff(channel: 1, note: 60, velocity: 64),
            .noteOn(channel: 1, note: 60, velocity: 100), .noteOff(channel: 1, note: 60, velocity: 64)
        ])
        var scheduler = MIDIClipScheduler(placement: placement)
        #expect(try scheduler.render(from: 0, to: 1, clock: clock, current: Self.live).count == 3)
        #expect(scheduler.soundingCount == 1)
        #expect(try scheduler.render(from: 1, to: 10, clock: clock, current: Self.live).map(\.frame) == [5])
    }

    @Test
    func clipsAreValidated() throws {
        let length = 4 * Self.quarter
        let cases: [([MIDIClipItem], MIDIClipRefusal)] = [
            ([Self.note(0, 1, channel: 0)], .invalidChannel(item: 0, channel: 0)),
            ([Self.note(0, 1), Self.note(0, 1, channel: 17)], .invalidChannel(item: 1, channel: 17)),
            ([Self.note(0, 1, pitch: 128)], .invalidData(item: 0)),
            ([Self.note(0, 1, velocity: 0)], .invalidData(item: 0)),
            ([Self.note(0, 1, velocity: 128)], .invalidData(item: 0)),
            ([.note(MIDIClipNote(channel: 1, note: 1, velocity: 1, releaseVelocity: 128, startTicks: 0, endTicks: 1))],
             .invalidData(item: 0)),
            ([Self.note(-1, 1)], .invalidNoteSpan(item: 0, startTicks: -1, endTicks: 1)),
            ([Self.note(5, 5)], .invalidNoteSpan(item: 0, startTicks: 5, endTicks: 5)),
            ([Self.note(0, length + 1)], .invalidNoteSpan(item: 0, startTicks: 0, endTicks: length + 1)),
            ([Self.controlChange(length)], .eventOutsideClip(item: 0, ticks: length)),
            ([Self.controlChange(-1)], .eventOutsideClip(item: 0, ticks: -1)),
            ([Self.controlChange(0, value: 128)], .invalidData(item: 0)),
            ([.event(ticks: 0, message: .controlChange(channel: 1, controller: 128, value: 0))], .invalidData(item: 0)),
            ([.event(ticks: 0, message: .programChange(channel: 0, program: 1))], .invalidChannel(item: 0, channel: 0)),
            ([.event(ticks: 0, message: .programChange(channel: 1, program: 128))], .invalidData(item: 0)),
            ([.event(ticks: 0, message: .channelPressure(channel: 1, pressure: 128))], .invalidData(item: 0)),
            ([.event(ticks: 0, message: .polyphonicPressure(channel: 1, note: 128, pressure: 0))],
             .invalidData(item: 0)),
            ([.event(ticks: 0, message: .polyphonicPressure(channel: 1, note: 0, pressure: 128))],
             .invalidData(item: 0)),
            ([.event(ticks: 0, message: .pitchBend(channel: 1, value: 0x4000))], .invalidData(item: 0)),
            ([.event(ticks: 0, message: .pitchBend(channel: 17, value: 0))], .invalidChannel(item: 0, channel: 17)),
            ([.event(ticks: 0, message: .noteOn(channel: 1, note: 1, velocity: 1))], .noteMessageOutsideSpan(item: 0)),
            ([.event(ticks: 0, message: .noteOff(channel: 1, note: 1, velocity: 1))], .noteMessageOutsideSpan(item: 0)),
            ([.event(ticks: 0, message: .sysEx(payload: [1]))], .unsupportedMessage(item: 0)),
            ([.event(ticks: 0, message: .realTime(status: 0xF8))], .unsupportedMessage(item: 0)),
            ([Self.note(10, 20), Self.note(0, 11)], .overlappingNotes(first: 1, second: 0)),
            ([Self.note(10, 20), Self.note(5, 8), Self.note(19, 30)], .overlappingNotes(first: 0, second: 2))
        ]
        for (items, expected) in cases {
            #expect(Self.refusal { try MIDIClip.make(lengthTicks: length, items: items) } == expected)
        }
        let valid: [MIDIClipItem] = [
            Self.note(0, 10), Self.note(10, 20), Self.note(5, 15, channel: 2), Self.note(5, 15, pitch: 61),
            Self.note(0, length, pitch: 127, channel: 16, velocity: 127),
            .note(MIDIClipNote(channel: 3, note: 0, velocity: 1, releaseVelocity: 0, startTicks: 0, endTicks: 1)),
            .event(ticks: length - 1, message: .pitchBend(channel: 16, value: 0x3FFF)),
            .event(ticks: 0, message: .polyphonicPressure(channel: 1, note: 127, pressure: 127)),
            .event(ticks: 0, message: .channelPressure(channel: 1, pressure: 127)),
            .event(ticks: 0, message: .programChange(channel: 1, program: 127)),
            // Controllers 120...127 (channel mode) and the hold pedals 64, 66 and 69 are refused; see the loop suite.
            .event(ticks: 0, message: .controlChange(channel: 1, controller: 119, value: 127))
        ]
        #expect(try MIDIClip.make(lengthTicks: length, items: valid).items == valid)
    }

    @Test
    func clipSizeIsBounded() throws {
        let maximum = MIDIClip.maximumLengthTicks
        #expect(maximum == 62_914_560)
        #expect(try MIDIClip.make(lengthTicks: maximum, items: []).lengthTicks == maximum)
        #expect(try MIDIClip.make(lengthTicks: 1, items: []).lengthTicks == 1)
        #expect(Self.refusal { try MIDIClip.make(lengthTicks: maximum + 1, items: []) }
            == .lengthOutOfRange(maximum + 1))
        #expect(Self.refusal { try MIDIClip.make(lengthTicks: 0, items: []) } == .lengthOutOfRange(0))
        let limit = MIDIClip.maximumItems
        #expect(limit == 16_384)
        let full = (0..<limit).map { Self.controlChange(Int64($0)) }
        #expect(try MIDIClip.make(lengthTicks: Int64(limit), items: full).items.count == limit)
        #expect(Self.refusal { try MIDIClip.make(lengthTicks: Int64(limit), items: full + [Self.controlChange(0)]) }
            == .tooManyItems(count: limit + 1, limit: limit))
    }

    @Test
    func placementsAreValidated() throws {
        let clip = try MIDIClip.make(lengthTicks: 100, items: [])
        for policy in [MediaTimePolicy.fixedRate, .timeStretch] {
            #expect(Self.refusal { try MIDIClipPlacement.make(clip: clip, startTicks: 0, timePolicy: policy) }
                == .unsupportedTimePolicy(policy))
        }
        #expect(try MIDIClipPlacement.make(clip: clip, startTicks: 0, timePolicy: .tempoFollowing).startTicks == 0)
        #expect(Self.refusal { try MIDIClipPlacement.make(clip: clip, startTicks: -1) } == .startOutOfRange(-1))
        #expect(try MIDIClipPlacement.make(clip: clip, startTicks: Int64.max - 100).startTicks == Int64.max - 100)
        #expect(Self.refusal { try MIDIClipPlacement.make(clip: clip, startTicks: Int64.max - 99) }
            == .startOutOfRange(Int64.max - 99))
        let outside = try LoopRange(startTicks: 50, endTicks: 101)
        #expect(Self.refusal { try MIDIClipPlacement.make(clip: clip, startTicks: 0, loop: outside) }
            == .loopOutsideClip(startTicks: 50, endTicks: 101, lengthTicks: 100))
        let whole = try LoopRange(startTicks: 0, endTicks: 100)
        #expect(try MIDIClipPlacement.make(clip: clip, startTicks: 0, loop: whole).loop == whole)
    }

    @Test
    func windowsAreCheckedAndBounded() throws {
        let placement = try Self.placement([Self.note(0, Self.quarter)])
        #expect(Self.refusal { try Self.events(placement, 10, 9) } == .invalidWindow(start: 10, end: 9))
        #expect(try Self.events(placement, 0, 0).isEmpty)
        let limit = MIDIClipPlacement.maximumWindowFrames
        #expect(limit == 1_048_576)
        #expect(try Self.events(placement, -limit + 1, 1).count == 1)
        #expect(Self.refusal { try Self.events(placement, -limit, 1) }
            == .windowTooLong(start: -limit, end: 1, limit: limit))
        #expect(Self.refusal { try Self.events(placement, Int64.min, Int64.max) }
            == .windowTooLong(start: Int64.min, end: Int64.max, limit: limit))
        #expect(try Self.events(placement, -100, 0).isEmpty)
    }

    @Test
    func staleGenerationsAndClockErrorsAreRefused() throws {
        let placement = try Self.placement([Self.note(0, Self.quarter)])
        let second = try Generation(2)
        let stale = [
            (ClockGenerationSnapshot(sample: second, transport: .initial, musicalMap: .initial),
             MIDIClipRefusal.clock(.staleSampleGeneration)),
            (ClockGenerationSnapshot(sample: .initial, transport: second, musicalMap: .initial),
             .clock(.staleTransport)),
            (ClockGenerationSnapshot(sample: .initial, transport: .initial, musicalMap: second), .staleMusicalMap)
        ]
        for (current, expected) in stale {
            #expect(Self.refusal { try placement.events(from: 0, to: 10, clock: Self.clock(), current: current) }
                == expected)
        }
        #expect(Self.refusal { try placement.events(from: 0, to: 0, clock: Self.clock(), current: stale[2].0) }
            == .staleMusicalMap)
        let edge = try Self.clock(ticks: Int64.max - 10)
        #expect(Self.refusal { try Self.events(placement, 0, 1000, clock: edge) } == .clock(.overflow))
    }

    @Test
    func aFullWindowIsRefusedNotTruncated() throws {
        let limit = MIDIClipPlacement.maximumEvents
        #expect(limit == 4096)
        let items = (0..<(limit + 1)).map { Self.controlChange(Int64($0)) }
        let placement = try Self.placement(items, length: Int64(limit + 1))
        // Tick k lands on frame round(1.5625 k); tick 4096 is frame 6400.
        #expect(try Self.events(placement, 0, 6400).count == limit)
        #expect(Self.refusal { try Self.events(placement, 0, 6401) } == .tooManyEvents(limit: limit))
        #expect(try Self.events(placement, 1, 6401).count == limit)
    }
}

/// A seeded deterministic generator for tests.
struct MIDIClipSplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
