import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI clip loop and stop", .productionAccessAudit)
struct MIDIClipLoopTests {
    typealias Base = MIDIClipTimingTests
    static let quarter = MusicalTime.ticksPerQuarter
    static let live = Base.live

    static func on(_ pitch: UInt8, channel: UInt8 = 1) -> MIDI1Semantic {
        .noteOn(channel: channel, note: pitch, velocity: 100)
    }

    static func off(_ pitch: UInt8, channel: UInt8 = 1) -> MIDI1Semantic {
        .noteOff(channel: channel, note: pitch, velocity: 64)
    }

    @Test
    func loopedContentRetriggersEachPass() throws {
        let placement = try Base.placement([Base.note(0, Self.quarter), Base.controlChange(Self.quarter / 2)],
                                           loop: (0, 2 * Self.quarter))
        let events = try Base.events(placement, 0, 150_000)
        #expect(events.map(\.frame) == [0, 12_000, 24_000, 48_000, 60_000, 72_000, 96_000, 108_000, 120_000,
                                        144_000])
        #expect(events.map(\.pass) == [0, 0, 0, 1, 1, 1, 2, 2, 2, 3])
        #expect(events.map(\.item) == [0, 1, 0, 0, 1, 0, 0, 1, 0, 0])
    }

    @Test
    func aNoteCrossingTheLoopEndIsCutAtTheBoundary() throws {
        let items = [Base.note(Self.quarter, 3 * Self.quarter), Base.note(0, 3 * Self.quarter, pitch: 62)]
        let placement = try Base.placement(items, loop: (0, 2 * Self.quarter))
        let events = try Base.events(placement, 0, 100_000)
        #expect(events.map(\.frame) == [0, 24_000, 48_000, 48_000, 48_000, 72_000, 96_000, 96_000, 96_000])
        let boundary = try Base.events(placement, 48_000, 48_001)
        // Same-frame Offs follow their notes' onset ticks: pitch 62 started at tick 0, pitch 60 a quarter later.
        #expect(boundary.map(\.message) == [Self.off(62), Self.off(60), Self.on(62)])
        #expect(boundary.map(\.pass) == [0, 0, 1])
        #expect(try Base.events(placement, 72_000, 72_001).map(\.message) == [Self.on(60)])
        #expect(try Base.events(placement, 72_001, 96_000).isEmpty)
    }

    @Test
    func introPlaysOnceAndTheTailNeverPlaysWhileLooping() throws {
        let items = [
            Base.controlChange(0),
            Base.note(Self.quarter / 2, Self.quarter + Self.quarter / 2),
            Base.note(Self.quarter, Self.quarter + 100, pitch: 61),
            Base.note(3 * Self.quarter, 4 * Self.quarter, pitch: 63),
            Base.controlChange(2 * Self.quarter, value: 2),
            Base.note(Self.quarter / 2, 3 * Self.quarter, pitch: 62)
        ]
        let placement = try Base.placement(items, loop: (Self.quarter, 2 * Self.quarter))
        let events = try Base.events(placement, 0, 96_000)
        #expect(events.map(\.frame) == [0, 12_000, 12_000, 24_000, 24_156, 36_000, 48_000, 48_000, 48_156,
                                        72_000, 72_156])
        #expect(events.map(\.item) == [0, 1, 5, 2, 2, 1, 5, 2, 2, 2, 2])
        #expect(events.map(\.pass) == [0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2])
        #expect(events[6].message == Self.off(62))
    }

    @Test
    func passesRoundEachEventFromItsTicks() throws {
        // 256 ticks at 120 BPM and 44.1 kHz is 367.5 frames; accumulating a rounded period would drift.
        let placement = try Base.placement([Base.controlChange(0)], length: 256, loop: (0, 256))
        let clock = try Base.clock(rate: 44_100)
        #expect(try Base.events(placement, 0, 1500, clock: clock).map(\.frame) == [0, 368, 735, 1103, 1470])
    }

    @Test
    func loopPassesFollowATempoChange() throws {
        let placement = try Base.placement([Base.note(0, Self.quarter / 2)], loop: (0, Self.quarter))
        let clock = try Base.clock(segments: [(0, 500_000), (2 * Self.quarter, 250_000)])
        let events = try Base.events(placement, 0, 73_000, clock: clock)
        #expect(events.map(\.frame) == [0, 12_000, 24_000, 36_000, 48_000, 54_000, 60_000, 66_000, 72_000])
        #expect(events.map(\.pass) == [0, 0, 1, 1, 2, 2, 3, 3, 4])
    }

    @Test
    func aLaterStartShiftsEveryPass() throws {
        let placement = try Base.placement([Base.note(0, Self.quarter / 2)], start: 4 * Self.quarter,
                                           loop: (0, Self.quarter))
        #expect(try Base.events(placement, 0, 96_000).isEmpty)
        #expect(try Base.events(placement, 0, 130_000).map(\.frame) == [96_000, 108_000, 120_000])
    }

    @Test
    func aLoopWithoutContentPlaysOnlyTheFirstPass() throws {
        let placement = try Base.placement([Base.controlChange(0)], loop: (Self.quarter, 2 * Self.quarter))
        #expect(try Base.events(placement, 0, 10).map(\.frame) == [0])
        #expect(try Base.events(placement, 1_000_000, 2_000_000).isEmpty)
        #expect(try Base.events(placement, 1 << 40, (1 << 40) + 1_000_000).isEmpty)
    }

    @Test
    func manyLoopPassesInOneWindowAreBounded() throws {
        let placement = try Base.placement([Base.controlChange(0)], length: 1, loop: (0, 1))
        let limit = MIDIClipPlacement.maximumEvents
        #expect(try Base.events(placement, 0, 6400).count == limit)
        #expect(try Base.events(placement, 0, 6400).last?.pass == Int64(limit - 1))
        #expect(Base.refusal { try Base.events(placement, 0, 6401) } == .tooManyEvents(limit: limit))
        #expect(Base.refusal { try Base.events(placement, 1 << 40, (1 << 40) + 1_000_000) }
            == .tooManyEvents(limit: limit))
    }

    @Test
    func stopReleasesEachSoundingNoteExactlyOnce() throws {
        let items = [
            Base.note(0, 2 * Self.quarter),
            Base.note(0, Self.quarter / 2, pitch: 61),
            Base.note(0, 3 * Self.quarter, pitch: 62, channel: 2, release: 30)
        ]
        var scheduler = MIDIClipScheduler(placement: try Base.placement(items))
        let played = try scheduler.render(from: 0, to: 30_000, clock: Base.clock(), current: Self.live)
        #expect(played.map(\.message) == [Self.on(60), Self.on(61), Self.on(62, channel: 2), Self.off(61)])
        #expect(scheduler.soundingCount == 2)
        let released = scheduler.stop()
        #expect(released == [
            MIDIClipEvent(frame: 30_000, pass: 0, item: 0, message: Self.off(60)),
            MIDIClipEvent(frame: 30_000, pass: 0, item: 2, message: .noteOff(channel: 2, note: 62, velocity: 30))
        ])
        #expect(scheduler.soundingCount == 0 && scheduler.cursor == nil && scheduler.binding == nil)
        #expect(scheduler.stop().isEmpty)
    }

    @Test
    func stopBeforeAnyRenderReleasesNothing() throws {
        var scheduler = MIDIClipScheduler(placement: try Base.placement([Base.note(0, Self.quarter)]))
        #expect(scheduler.stop().isEmpty)
        #expect(scheduler.cursor == nil && scheduler.binding == nil)
    }

    @Test
    func stopReleasesOnlyTheCurrentPassOfALoopedNote() throws {
        let placement = try Base.placement([Base.note(0, Self.quarter)], loop: (0, Self.quarter))
        var scheduler = MIDIClipScheduler(placement: placement)
        let played = try scheduler.render(from: 0, to: 72_000, clock: Base.clock(), current: Self.live)
        #expect(played.map(\.message) == [Self.on(60), Self.off(60), Self.on(60), Self.off(60), Self.on(60)])
        #expect(played.map(\.pass) == [0, 0, 1, 1, 2])
        #expect(scheduler.soundingCount == 1)
        #expect(scheduler.stop() == [MIDIClipEvent(frame: 72_000, pass: 2, item: 0, message: Self.off(60))])
    }

    @Test
    func contiguousRendersCarryCutNotesAcrossTheLoopEnd() throws {
        let placement = try Base.placement([Base.note(Self.quarter, 3 * Self.quarter)], loop: (0, 2 * Self.quarter))
        var scheduler = MIDIClipScheduler(placement: placement)
        let clock = try Base.clock()
        #expect(try scheduler.render(from: 0, to: 48_000, clock: clock, current: Self.live).map(\.frame) == [24_000])
        #expect(try scheduler.render(from: 48_000, to: 48_000, clock: clock, current: Self.live).isEmpty)
        let next = try scheduler.render(from: 48_000, to: 80_000, clock: clock, current: Self.live)
        #expect(next == [
            MIDIClipEvent(frame: 48_000, pass: 0, item: 0, message: Self.off(60)),
            MIDIClipEvent(frame: 72_000, pass: 1, item: 0, message: Self.on(60))
        ])
        #expect(scheduler.cursor == 80_000)
        #expect(scheduler.stop() == [MIDIClipEvent(frame: 80_000, pass: 1, item: 0, message: Self.off(60))])
    }

    @Test
    func aFirstRenderInsideANoteDoesNotReleaseIt() throws {
        let placement = try Base.placement([Base.note(0, 2 * Self.quarter), Base.note(Self.quarter, 3 * Self.quarter,
                                                                                      pitch: 61)])
        var scheduler = MIDIClipScheduler(placement: placement)
        let played = try scheduler.render(from: 30_000, to: 100_000, clock: Base.clock(), current: Self.live)
        #expect(played == [])
        #expect(scheduler.soundingCount == 0)
        #expect(scheduler.stop().isEmpty)
    }

    @Test
    func refusedRendersLeaveTheSchedulerUnchanged() throws {
        let items = (0..<4099).map { Base.controlChange(Int64($0)) } + [Base.note(0, 5000, pitch: 1)]
        var scheduler = MIDIClipScheduler(placement: try Base.placement(items, length: 8000))
        let clock = try Base.clock()
        _ = try scheduler.render(from: 0, to: 1, clock: clock, current: Self.live)
        let before = scheduler
        #expect(scheduler.soundingCount == 1)
        #expect(Base.refusal { try scheduler.render(from: 2, to: 10, clock: clock, current: Self.live) }
            == .nonContiguousWindow(expected: 1, start: 2))
        #expect(Base.refusal { try scheduler.render(from: 1, to: 6403, clock: clock, current: Self.live) }
            == .tooManyEvents(limit: 4096))
        let stale = ClockGenerationSnapshot(sample: .initial, transport: .initial, musicalMap: try Generation(2))
        #expect(Base.refusal { try scheduler.render(from: 1, to: 10, clock: clock, current: stale) }
            == .staleMusicalMap)
        #expect(Base.refusal { try scheduler.render(from: 1, to: 0, clock: clock, current: Self.live) }
            == .invalidWindow(start: 1, end: 0))
        #expect(scheduler == before)
        #expect(try scheduler.render(from: 1, to: 6401, clock: clock, current: Self.live).count == 4096)
        #expect(scheduler.cursor == 6401)
    }

    @Test
    func aClockRevisionChangeWhileANoteSoundsIsRefusedUntilStop() throws {
        let placement = try Base.placement([Base.note(0, Self.quarter)])
        var scheduler = MIDIClipScheduler(placement: placement)
        #expect(try scheduler.render(from: 0, to: 20_000, clock: Base.clock(), current: Self.live).map(\.message)
            == [Self.on(60)])
        #expect(scheduler.binding == Self.live)
        let before = scheduler
        let revised = try Base.clock(revision: Generation(2), segments: [(0, 250_000)])
        let current = ClockGenerationSnapshot(sample: .initial, transport: .initial, musicalMap: try Generation(2))
        #expect(Base.refusal { try scheduler.render(from: 20_000, to: 60_000, clock: revised, current: current) }
            == .clockRevisionChanged(expected: Self.live, got: current))
        #expect(scheduler == before)
        // Stop releases the note at the cursor, so nothing hangs; the next render binds to the new revision.
        #expect(scheduler.stop() == [MIDIClipEvent(frame: 20_000, pass: 0, item: 0, message: Self.off(60))])
        #expect(scheduler.soundingCount == 0)
        let fresh = try scheduler.render(from: 0, to: 20_000, clock: revised, current: current)
        #expect(fresh.map(\.frame) == [0, 12_000])
        #expect(scheduler.binding == current && scheduler.soundingCount == 0)
        #expect(Base.refusal { try scheduler.render(from: 20_000, to: 30_000, clock: Base.clock(), current: Self.live) }
            == .clockRevisionChanged(expected: current, got: Self.live))
    }

    @Test
    func aClockRevisionChangeIsRefusedWithNothingSounding() throws {
        var scheduler = MIDIClipScheduler(placement: try Base.placement([Base.controlChange(0)]))
        #expect(try scheduler.render(from: 0, to: 10, clock: Base.clock(), current: Self.live).count == 1)
        #expect(scheduler.soundingCount == 0)
        let before = scheduler
        let current = ClockGenerationSnapshot(sample: .initial, transport: .initial, musicalMap: try Generation(2))
        let revised = try Base.clock(revision: Generation(2))
        #expect(Base.refusal { try scheduler.render(from: 10, to: 20, clock: revised, current: current) }
            == .clockRevisionChanged(expected: Self.live, got: current))
        #expect(scheduler == before)
    }

    @Test
    func sameGenerationRendersKeepPlaying() throws {
        var scheduler = MIDIClipScheduler(placement: try Base.placement([Base.note(0, Self.quarter)]))
        let clock = try Base.clock()
        #expect(try scheduler.render(from: 0, to: 20_000, clock: clock, current: Self.live).count == 1)
        #expect(try scheduler.render(from: 20_000, to: 30_000, clock: clock, current: Self.live).map(\.frame)
            == [24_000])
        #expect(scheduler.binding == Self.live && scheduler.cursor == 30_000)
    }

    static func controller(_ number: UInt8, value: UInt8 = 127, ticks: Int64 = 0,
                           channel: UInt8 = 1) -> MIDIClipItem {
        .event(ticks: ticks, message: .controlChange(channel: channel, controller: number, value: value))
    }

    static func admission(_ items: [MIDIClipItem], length: Int64 = 4 * quarter) -> MIDIClipRefusal? {
        let before = items
        let refusal = Base.refusal { try MIDIClip.make(lengthTicks: length, items: items) }
        #expect(items == before)
        return refusal
    }

    @Test(arguments: [UInt8(64), 66, 69])
    func holdControllersAreRefusedAtAdmission(controller: UInt8) throws {
        for value: UInt8 in [127, 0] {
            #expect(Self.admission([Self.controller(controller, value: value)]) == .unsupportedMessage(item: 0))
            let items = [Base.note(0, Self.quarter), Base.controlChange(1),
                         Self.controller(controller, value: value, ticks: 2, channel: 16)]
            #expect(Self.admission(items) == .unsupportedMessage(item: 2))
        }
    }

    @Test
    func stoppingBeforeSustainPedalUpIsUnreachable() throws {
        // Copilot's case: Note On, CC 64 down, the note ends, then stop before CC 64 up. The clip is refused at
        // admission, so no scheduler can hold a sustained note that stop() cannot release.
        let items = [Base.note(0, Self.quarter), Self.controller(64, value: 127, ticks: Self.quarter / 2),
                     Self.controller(64, value: 0, ticks: 3 * Self.quarter)]
        #expect(Self.admission(items) == .unsupportedMessage(item: 1))
        #expect(Base.refusal { try Base.placement(items) } == .unsupportedMessage(item: 1))
    }

    @Test(arguments: UInt8(120)...127)
    func channelModeMessagesAreRefusedAtAdmission(controller: UInt8) throws {
        let items = [Base.controlChange(0), Base.note(0, 1), Self.controller(controller, value: 0, ticks: 1)]
        #expect(Self.admission(items) == .unsupportedMessage(item: 2))
        #expect(Self.admission([Self.controller(controller, value: 127)]) == .unsupportedMessage(item: 0))
    }

    @Test
    func theFirstNoteHoldingItemIsReportedAfterThePerItemChecks() throws {
        let length = 4 * Self.quarter
        #expect(Self.admission([Base.controlChange(0), Self.controller(66), Self.controller(120),
                                Self.controller(64), Self.controller(69)]) == .unsupportedMessage(item: 1))
        #expect(Self.admission([Self.controller(1), Self.controller(127), Self.controller(64)])
            == .unsupportedMessage(item: 1))
        // Per-item checks run first, in item order; the hold check runs before the overlap check.
        #expect(Self.admission([Self.controller(64, channel: 0)]) == .invalidChannel(item: 0, channel: 0))
        #expect(Self.admission([Self.controller(64, value: 128)]) == .invalidData(item: 0))
        #expect(Self.admission([Self.controller(64), Self.controller(1, ticks: length)])
            == .eventOutsideClip(item: 1, ticks: length))
        #expect(Self.admission([Self.controller(64), .event(ticks: 0, message: .sysEx(payload: [1]))])
            == .unsupportedMessage(item: 1))
        #expect(Self.admission([Base.note(0, 10), Base.note(5, 15), Self.controller(64)])
            == .unsupportedMessage(item: 2))
    }

    @Test
    func ordinaryControllersAreStillScheduled() throws {
        let ordinary: [UInt8] = [0, 1, 7, 10, 11, 63, 65, 67, 68, 70, 119]
        let items = [Base.note(0, Self.quarter)] + ordinary.map { Self.controller($0, ticks: Self.quarter / 2) }
        var scheduler = MIDIClipScheduler(placement: try Base.placement(items))
        let played = try scheduler.render(from: 0, to: 30_000, clock: Base.clock(), current: Self.live)
        #expect(played.map(\.frame) == [0] + Array(repeating: 12_000, count: ordinary.count) + [24_000])
        #expect(played.dropFirst().dropLast().map(\.message)
            == ordinary.map { .controlChange(channel: 1, controller: $0, value: 127) })
        #expect(played.last?.message == Self.off(60))
        #expect(scheduler.soundingCount == 0 && scheduler.stop().isEmpty)
    }

    @Test
    func onlyControlChangesAreCheckedForHoldAndModeNumbers() throws {
        // First data bytes 64, 66, 69 and 120...127 in messages other than Control Change are ordinary content.
        let messages: [MIDI1Semantic] = [
            .programChange(channel: 1, program: 64), .polyphonicPressure(channel: 1, note: 64, pressure: 69),
            .channelPressure(channel: 1, pressure: 66), .programChange(channel: 2, program: 69),
            .programChange(channel: 3, program: 120), .channelPressure(channel: 2, pressure: 127),
            .polyphonicPressure(channel: 2, note: 121, pressure: 64), .pitchBend(channel: 1, value: 64),
            .pitchBend(channel: 2, value: 0x3F7F)
        ]
        let notes = [UInt8(64), 66, 69, 120, 127].map { Base.note(0, Self.quarter, pitch: $0) }
        let items = notes + messages.map { MIDIClipItem.event(ticks: Self.quarter / 2, message: $0) }
        let clip = try MIDIClip.make(lengthTicks: 4 * Self.quarter, items: items)
        #expect(clip.items == items)
        let played = try Base.events(try Base.placement(items), 0, 30_000)
        #expect(played.filter { $0.frame == 12_000 }.map(\.message) == messages)
        #expect(played.filter { $0.frame == 24_000 }.count == notes.count)
        // CC 64 itself is still refused (see also holdControllersAreRefusedAtAdmission).
        #expect(Self.admission(items + [Self.controller(64)]) == .unsupportedMessage(item: items.count))
    }
}
