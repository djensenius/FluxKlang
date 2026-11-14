import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum MIDIPerformanceFixture {
    static let keys = MIDIInputID(1)
    static let pads = MIDIInputID(2)
    static let piano = MIDIRouteID(10)
    static let strings = MIDIRouteID(20)
    static let bass = MIDIRouteID(30)

    static func rule(
        _ route: MIDIRouteID, from input: MIDIInputID = keys, channels: ClosedRange<UInt8> = 1...16,
        notes: ClosedRange<UInt8> = 0...127, transpose: Int = 0
    ) throws -> MIDIRoutingRule {
        try #require(
            MIDIRoutingRule(input: input, route: route, channels: channels, notes: notes, transpose: transpose)
        )
    }

    static func routing(_ rules: MIDIRoutingRule...) throws -> MIDIRouting {
        try #require(MIDIRouting(rules: rules))
    }

    static func event(_ message: MIDI1Semantic, from input: MIDIInputID = keys) -> MIDIPerformanceEvent {
        MIDIPerformanceEvent(input: input, message: message)
    }

    static func on(_ note: UInt8, _ velocity: UInt8 = 100, channel: UInt8 = 1, from input: MIDIInputID = keys)
        -> MIDIPerformanceEvent {
        event(.noteOn(channel: channel, note: note, velocity: velocity), from: input)
    }

    static func off(_ note: UInt8, _ velocity: UInt8 = 64, channel: UInt8 = 1, from input: MIDIInputID = keys)
        -> MIDIPerformanceEvent {
        event(.noteOff(channel: channel, note: note, velocity: velocity), from: input)
    }

    static func control(_ controller: UInt8, _ value: UInt8, channel: UInt8 = 1, from input: MIDIInputID = keys)
        -> MIDIPerformanceEvent {
        event(.controlChange(channel: channel, controller: controller, value: value), from: input)
    }

    static func sentOn(_ route: MIDIRouteID, _ note: UInt8, _ velocity: UInt8 = 100, channel: UInt8 = 1)
        -> MIDIRoutedOutput {
        MIDIRoutedOutput(route: route, message: .noteOn(channel: channel, note: note, velocity: velocity))
    }

    static func sentOff(_ route: MIDIRouteID, _ note: UInt8, _ velocity: UInt8 = 64, channel: UInt8 = 1)
        -> MIDIRoutedOutput {
        MIDIRoutedOutput(route: route, message: .noteOff(channel: channel, note: note, velocity: velocity))
    }

    static func sentControl(_ route: MIDIRouteID, _ controller: UInt8, _ value: UInt8, channel: UInt8 = 1)
        -> MIDIRoutedOutput {
        MIDIRoutedOutput(route: route, message: .controlChange(channel: channel, controller: controller, value: value))
    }

    static func sentPressure(_ route: MIDIRouteID, _ note: UInt8, _ pressure: UInt8) -> MIDIRoutedOutput {
        MIDIRoutedOutput(route: route, message: .polyphonicPressure(channel: 1, note: note, pressure: pressure))
    }

    /// Routes every event in order and returns everything sent.
    static func play(
        _ events: [MIDIPerformanceEvent], on ledger: inout MIDINoteLedger, routing: MIDIRouting
    ) throws -> [MIDIRoutedOutput] {
        var outputs: [MIDIRoutedOutput] = []
        for event in events { try ledger.route(event, routing: routing, into: &outputs) }
        return outputs
    }

    /// A refusal must append nothing to a buffer already in use and leave the ledger equal to its earlier value.
    static func expectRefused(
        _ event: MIDIPerformanceEvent, _ refusal: MIDIPerformanceRefusal, in ledger: MIDINoteLedger,
        routing: MIDIRouting
    ) {
        var copy = ledger
        let earlier = [sentControl(bass, 7, 1)]
        var outputs = earlier
        #expect(throws: refusal) { try copy.route(event, routing: routing, into: &outputs) }
        #expect(outputs == earlier)
        #expect(copy == ledger)
    }
}

@Suite(.productionAccessAudit)
struct MIDIPerformanceTests {
    typealias Fixture = MIDIPerformanceFixture

    @Test
    func offFollowsLedgerAfterRoutingChange() throws {
        var ledger = MIDINoteLedger()
        let layered = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.strings))
        let moved = try Fixture.routing(Fixture.rule(Fixture.bass))
        #expect(try ledger.route(Fixture.on(60), routing: layered)
            == [Fixture.sentOn(Fixture.piano, 60), Fixture.sentOn(Fixture.strings, 60)])
        #expect(try ledger.route(Fixture.on(62), routing: moved) == [Fixture.sentOn(Fixture.bass, 62)])
        #expect(try ledger.route(Fixture.off(60, 30), routing: moved)
            == [Fixture.sentOff(Fixture.piano, 60, 30), Fixture.sentOff(Fixture.strings, 60, 30)])
        #expect(try ledger.route(Fixture.off(62), routing: layered) == [Fixture.sentOff(Fixture.bass, 62)])
        #expect(ledger.notes.isEmpty)

        // With no routing left at all, the release still reaches the route that received the note-on.
        _ = try ledger.route(Fixture.on(64), routing: moved)
        #expect(try ledger.route(Fixture.off(64), routing: .empty) == [Fixture.sentOff(Fixture.bass, 64)])
        Fixture.expectRefused(Fixture.off(64), .unownedNote(input: Fixture.keys, channel: 1, note: 64), in: ledger,
                              routing: moved)
    }

    @Test
    func releaseCarriesRecordedTransposition() throws {
        var ledger = MIDINoteLedger()
        let upper = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.strings, transpose: 12))
        let changed = try Fixture.routing(
            Fixture.rule(Fixture.piano, transpose: 2), Fixture.rule(Fixture.strings, transpose: -12)
        )
        #expect(try ledger.route(Fixture.on(60), routing: upper)
            == [Fixture.sentOn(Fixture.piano, 60), Fixture.sentOn(Fixture.strings, 72)])
        #expect(ledger.notes.map(\.note) == [60, 72])
        #expect(ledger.notes.map(\.inputNote) == [60, 60])
        let pressure = Fixture.event(.polyphonicPressure(channel: 1, note: 60, pressure: 50))
        #expect(try ledger.route(pressure, routing: changed)
            == [Fixture.sentPressure(Fixture.piano, 60, 50), Fixture.sentPressure(Fixture.strings, 72, 50)])
        #expect(try ledger.route(Fixture.off(60), routing: changed)
            == [Fixture.sentOff(Fixture.piano, 60), Fixture.sentOff(Fixture.strings, 72)])
        #expect(try ledger.route(Fixture.on(60), routing: changed)
            == [Fixture.sentOn(Fixture.piano, 62), Fixture.sentOn(Fixture.strings, 48)])
    }

    @Test
    func splitMovedMidNote() throws {
        var ledger = MIDINoteLedger()
        let split = try Fixture.routing(
            Fixture.rule(Fixture.bass, notes: 0...59), Fixture.rule(Fixture.piano, notes: 60...127)
        )
        let moved = try Fixture.routing(
            Fixture.rule(Fixture.bass, notes: 0...61), Fixture.rule(Fixture.piano, notes: 62...127)
        )
        #expect(try Fixture.play([Fixture.on(59), Fixture.on(60)], on: &ledger, routing: split)
            == [Fixture.sentOn(Fixture.bass, 59), Fixture.sentOn(Fixture.piano, 60)])
        #expect(try ledger.route(Fixture.on(61), routing: moved) == [Fixture.sentOn(Fixture.bass, 61)])
        #expect(try ledger.route(Fixture.off(60), routing: moved) == [Fixture.sentOff(Fixture.piano, 60)])
        #expect(try Fixture.play([Fixture.off(59), Fixture.off(61)], on: &ledger, routing: split)
            == [Fixture.sentOff(Fixture.bass, 59), Fixture.sentOff(Fixture.bass, 61)])
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func outOfRangeTranspositionSkipsLayer() throws {
        var ledger = MIDINoteLedger()
        let octave = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.strings, transpose: 8))
        #expect(try ledger.route(Fixture.on(120), routing: octave) == [Fixture.sentOn(Fixture.piano, 120)])
        #expect(try ledger.route(Fixture.on(119), routing: octave)
            == [Fixture.sentOn(Fixture.piano, 119), Fixture.sentOn(Fixture.strings, 127)])
        #expect(try ledger.route(Fixture.off(120), routing: octave) == [Fixture.sentOff(Fixture.piano, 120)])
        #expect(ledger.notes.map(\.note) == [119, 127])

        var unrouted = MIDINoteLedger()
        let lower = try Fixture.routing(Fixture.rule(Fixture.bass, transpose: -12))
        #expect(try unrouted.route(Fixture.on(11), routing: lower).isEmpty)
        #expect(try unrouted.route(Fixture.on(12), routing: .empty).isEmpty)
        #expect(unrouted == MIDINoteLedger())
        #expect(try unrouted.route(Fixture.on(12), routing: lower) == [Fixture.sentOn(Fixture.bass, 0)])
    }

    @Test
    func duplicateNotesReleaseOldestPressFirst() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let layered = try Fixture.routing(Fixture.rule(Fixture.strings), Fixture.rule(Fixture.bass))
        #expect(try ledger.route(Fixture.on(60), routing: piano) == [Fixture.sentOn(Fixture.piano, 60)])
        #expect(try ledger.route(Fixture.on(60, 90), routing: layered)
            == [Fixture.sentOn(Fixture.strings, 60, 90), Fixture.sentOn(Fixture.bass, 60, 90)])
        #expect(try ledger.route(Fixture.off(60), routing: piano) == [Fixture.sentOff(Fixture.piano, 60)])
        #expect(try ledger.route(Fixture.off(60), routing: piano)
            == [Fixture.sentOff(Fixture.strings, 60), Fixture.sentOff(Fixture.bass, 60)])
        Fixture.expectRefused(Fixture.off(60), .unownedNote(input: Fixture.keys, channel: 1, note: 60), in: ledger,
                              routing: piano)
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func duplicatesOnOneOutputSendOneNoteOff() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        #expect(try Fixture.play([Fixture.on(60), Fixture.on(60, 90)], on: &ledger, routing: piano)
            == [Fixture.sentOn(Fixture.piano, 60), Fixture.sentOn(Fixture.piano, 60, 90)])
        #expect(ledger.notes.count == 2)
        #expect(try ledger.route(Fixture.off(60), routing: piano).isEmpty)
        #expect(ledger.notes.count == 1)
        #expect(try ledger.route(Fixture.off(60), routing: piano) == [Fixture.sentOff(Fixture.piano, 60)])
        #expect(ledger.notes.isEmpty)

        // Two inputs on one output note: only the last release sends the note-off.
        let merged = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, from: Fixture.pads))
        _ = try Fixture.play([Fixture.on(64), Fixture.on(64, from: Fixture.pads)], on: &ledger, routing: merged)
        #expect(try ledger.route(Fixture.off(64, from: Fixture.pads), routing: merged).isEmpty)
        #expect(try ledger.route(Fixture.off(64), routing: merged) == [Fixture.sentOff(Fixture.piano, 64)])
    }

    @Test
    func layersCollidingOnOneOutputNote() throws {
        var ledger = MIDINoteLedger()
        let octaves = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, transpose: 12))
        #expect(try Fixture.play([Fixture.on(48), Fixture.on(60)], on: &ledger, routing: octaves) == [
            Fixture.sentOn(Fixture.piano, 48), Fixture.sentOn(Fixture.piano, 60),
            Fixture.sentOn(Fixture.piano, 60), Fixture.sentOn(Fixture.piano, 72)
        ])
        // Key 60 still sounds piano 60, so releasing key 48 only ends piano 48.
        #expect(try ledger.route(Fixture.off(48), routing: .empty) == [Fixture.sentOff(Fixture.piano, 48)])
        #expect(try ledger.route(Fixture.off(60), routing: .empty)
            == [Fixture.sentOff(Fixture.piano, 60), Fixture.sentOff(Fixture.piano, 72)])
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func overlappingRulesSendEachOutputOnce() throws {
        var ledger = MIDINoteLedger()
        let overlapping = try Fixture.routing(
            Fixture.rule(Fixture.piano, notes: 0...64), Fixture.rule(Fixture.piano, notes: 60...127),
            Fixture.rule(Fixture.strings)
        )
        #expect(try ledger.route(Fixture.on(62), routing: overlapping)
            == [Fixture.sentOn(Fixture.piano, 62), Fixture.sentOn(Fixture.strings, 62)])
        #expect(ledger.notes.count == 2)
        #expect(try ledger.route(Fixture.control(1, 40), routing: overlapping)
            == [Fixture.sentControl(Fixture.piano, 1, 40), Fixture.sentControl(Fixture.strings, 1, 40)])
        #expect(try ledger.route(Fixture.off(62), routing: overlapping)
            == [Fixture.sentOff(Fixture.piano, 62), Fixture.sentOff(Fixture.strings, 62)])
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func mpeMemberChannelsAreSeparate() throws {
        var ledger = MIDINoteLedger()
        let zone = try Fixture.routing(
            Fixture.rule(Fixture.piano, channels: 2...16), Fixture.rule(Fixture.strings, channels: 2...16)
        )
        let moved = try Fixture.routing(Fixture.rule(Fixture.bass, channels: 2...16))
        #expect(try Fixture.play([Fixture.on(60, channel: 2), Fixture.on(60, channel: 3)], on: &ledger, routing: zone)
            == [
                Fixture.sentOn(Fixture.piano, 60, channel: 2), Fixture.sentOn(Fixture.strings, 60, channel: 2),
                Fixture.sentOn(Fixture.piano, 60, channel: 3), Fixture.sentOn(Fixture.strings, 60, channel: 3)
            ])
        #expect(try ledger.route(Fixture.off(60, channel: 3), routing: moved)
            == [Fixture.sentOff(Fixture.piano, 60, channel: 3), Fixture.sentOff(Fixture.strings, 60, channel: 3)])
        #expect(try ledger.route(Fixture.on(60, channel: 4), routing: moved)
            == [Fixture.sentOn(Fixture.bass, 60, channel: 4)])
        #expect(try ledger.route(Fixture.on(60, channel: 1), routing: moved).isEmpty)
        #expect(ledger.notes.map(\.channel) == [2, 2, 4])
        #expect(try ledger.route(Fixture.off(60, channel: 2), routing: moved)
            == [Fixture.sentOff(Fixture.piano, 60, channel: 2), Fixture.sentOff(Fixture.strings, 60, channel: 2)])
        #expect(try ledger.route(Fixture.off(60, channel: 4), routing: zone)
            == [Fixture.sentOff(Fixture.bass, 60, channel: 4)])
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func dronesHaveNoTimeout() throws {
        var ledger = MIDINoteLedger()
        let drone = try Fixture.routing(Fixture.rule(Fixture.bass, transpose: -12))
        let tables = try [
            Fixture.routing(Fixture.rule(Fixture.piano)),
            Fixture.routing(Fixture.rule(Fixture.strings, transpose: 5), Fixture.rule(Fixture.piano))
        ]
        #expect(try ledger.route(Fixture.on(36), routing: drone) == [Fixture.sentOn(Fixture.bass, 24)])
        let held = ledger.notes
        var outputs: [MIDIRoutedOutput] = []
        for round in 0..<10_000 {
            let routing = tables[round % 2]
            let note = UInt8(60 + round % 12)
            outputs.removeAll(keepingCapacity: true)
            try ledger.route(Fixture.on(note), routing: routing, into: &outputs)
            try ledger.route(Fixture.control(1, UInt8(round % 128)), routing: routing, into: &outputs)
            let bend = Fixture.event(.pitchBend(channel: 1, value: UInt16(round)))
            try ledger.route(bend, routing: routing, into: &outputs)
            try ledger.route(Fixture.off(note), routing: tables[(round + 1) % 2], into: &outputs)
        }
        #expect(ledger.notes == held)
        #expect(try ledger.route(Fixture.off(36), routing: tables[0]) == [Fixture.sentOff(Fixture.bass, 24)])
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func channelMessagesFollowCurrentRoutingOnce() throws {
        var ledger = MIDINoteLedger()
        let split = try Fixture.routing(
            Fixture.rule(Fixture.bass, channels: 1...1, notes: 0...59),
            Fixture.rule(Fixture.piano, channels: 1...1, notes: 60...127),
            Fixture.rule(Fixture.piano, channels: 2...2), Fixture.rule(Fixture.strings, from: Fixture.pads)
        )
        #expect(try ledger.route(Fixture.control(1, 9), routing: split)
            == [Fixture.sentControl(Fixture.bass, 1, 9), Fixture.sentControl(Fixture.piano, 1, 9)])
        let bend = Fixture.event(.pitchBend(channel: 1, value: 16_383))
        #expect(try ledger.route(bend, routing: split) == [
            MIDIRoutedOutput(route: Fixture.bass, message: bend.message),
            MIDIRoutedOutput(route: Fixture.piano, message: bend.message)
        ])
        let program = Fixture.event(.programChange(channel: 2, program: 5))
        #expect(try ledger.route(program, routing: split)
            == [MIDIRoutedOutput(route: Fixture.piano, message: program.message)])
        #expect(try ledger.route(Fixture.event(.channelPressure(channel: 3, pressure: 1)), routing: split).isEmpty)
        #expect(try ledger.route(Fixture.control(7, 90, from: Fixture.pads), routing: split)
            == [Fixture.sentControl(Fixture.strings, 7, 90)])

        // A note left on an old route does not pull ordinary controllers there.
        _ = try ledger.route(Fixture.on(40), routing: split)
        let moved = try Fixture.routing(Fixture.rule(Fixture.piano))
        #expect(try ledger.route(Fixture.control(1, 3), routing: moved) == [Fixture.sentControl(Fixture.piano, 1, 3)])
    }

    @Test
    func polyPressureFollowsNewestPress() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        let strings = try Fixture.routing(Fixture.rule(Fixture.strings, transpose: 1))
        let pressure = Fixture.event(.polyphonicPressure(channel: 1, note: 60, pressure: 7))
        let unowned = MIDIPerformanceRefusal.unownedNote(input: Fixture.keys, channel: 1, note: 60)
        Fixture.expectRefused(pressure, unowned, in: ledger, routing: piano)
        _ = try ledger.route(Fixture.on(60), routing: piano)
        _ = try ledger.route(Fixture.on(60), routing: strings)
        #expect(try ledger.route(pressure, routing: piano) == [Fixture.sentPressure(Fixture.strings, 61, 7)])
        _ = try ledger.route(Fixture.off(60), routing: piano)
        #expect(try ledger.route(pressure, routing: piano) == [Fixture.sentPressure(Fixture.strings, 61, 7)])
        _ = try ledger.route(Fixture.off(60), routing: piano)
        Fixture.expectRefused(pressure, unowned, in: ledger, routing: strings)
    }

    @Test(arguments: [UInt8(123), 124, 125, 126, 127])
    func allNotesOffReleasesOwnKeysOnRecordedRoutes(controller: UInt8) throws {
        var ledger = MIDINoteLedger()
        let first = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, from: Fixture.pads))
        let second = try Fixture.routing(Fixture.rule(Fixture.strings), Fixture.rule(Fixture.piano, from: Fixture.pads))
        _ = try Fixture.play([Fixture.on(60), Fixture.on(64, from: Fixture.pads)], on: &ledger, routing: first)
        _ = try Fixture.play([Fixture.on(62), Fixture.on(61, channel: 2)], on: &ledger, routing: second)
        // All Notes Off itself is not forwarded; the mode messages follow the releases to the current routes.
        let forwarded = controller == 123 ? [] : [Fixture.sentControl(Fixture.strings, controller, 0)]
        #expect(try ledger.route(Fixture.control(controller, 0), routing: second)
            == [Fixture.sentOff(Fixture.piano, 60), Fixture.sentOff(Fixture.strings, 62)] + forwarded)
        #expect(ledger.notes.map(\.note) == [64, 61])
    }

    @Test
    func monoModeReleasesOwnKeysThenReachesCurrentRoutesOnce() throws {
        var ledger = MIDINoteLedger()
        let first = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, from: Fixture.pads))
        let current = try Fixture.routing(
            Fixture.rule(Fixture.strings), Fixture.rule(Fixture.bass, transpose: 12),
            Fixture.rule(Fixture.strings, notes: 0...59), Fixture.rule(Fixture.piano, from: Fixture.pads)
        )
        let played = [Fixture.on(60), Fixture.on(64, from: Fixture.pads), Fixture.on(61, channel: 2)]
        _ = try Fixture.play(played, on: &ledger, routing: first)
        #expect(try ledger.route(Fixture.control(126, 1), routing: current) == [
            Fixture.sentOff(Fixture.piano, 60), Fixture.sentControl(Fixture.strings, 126, 1),
            Fixture.sentControl(Fixture.bass, 126, 1)
        ])
        #expect(ledger.notes.map(\.note) == [64, 61])
        // With nothing of its own sounding, the mode message is still forwarded and not refused.
        #expect(try ledger.route(Fixture.control(126, 1), routing: current)
            == [Fixture.sentControl(Fixture.strings, 126, 1), Fixture.sentControl(Fixture.bass, 126, 1)])
    }

    @Test(arguments: [UInt8(124), 125, 126, 127])
    func modeMessagesRefusedWhereAnotherInputOwns(controller: UInt8) throws {
        var ledger = MIDINoteLedger()
        let shared = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.piano, from: Fixture.pads))
        // Keys' sustain holds pads' released note (pads hold no pedal); keys also keep a key of their own down.
        _ = try Fixture.play([
            Fixture.control(64, 127), Fixture.on(62, from: Fixture.pads), Fixture.off(62, from: Fixture.pads),
            Fixture.on(60)
        ], on: &ledger, routing: shared)
        Fixture.expectRefused(Fixture.control(controller, 0), .sharedDestinationOwned(
            input: Fixture.keys, channel: 1, controller: controller, route: Fixture.piano, owner: Fixture.pads
        ), in: ledger, routing: shared)
        // Routed only where keys own everything, the releases and the mode message go out as before.
        let exclusive = try Fixture.routing(
            Fixture.rule(Fixture.strings), Fixture.rule(Fixture.piano, from: Fixture.pads)
        )
        #expect(try ledger.route(Fixture.control(controller, 0), routing: exclusive)
            == [Fixture.sentOff(Fixture.piano, 60), Fixture.sentControl(Fixture.strings, controller, 0)])
        #expect(ledger.notes.map(\.sustained) == [true, true])
    }

    @Test
    func noteOnVelocityZeroReleases() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        _ = try ledger.route(Fixture.on(60), routing: piano)
        #expect(try ledger.route(Fixture.on(60, 0), routing: piano) == [Fixture.sentOff(Fixture.piano, 60, 64)])
        #expect(ledger.notes.isEmpty)
    }

    @Test
    func invalidMessagesRefusedWithoutChange() throws {
        var ledger = MIDINoteLedger()
        let piano = try Fixture.routing(Fixture.rule(Fixture.piano))
        _ = try Fixture.play([Fixture.on(60), Fixture.control(64, 127)], on: &ledger, routing: piano)
        let malformed: [MIDI1Semantic] = [
            .noteOn(channel: 0, note: 60, velocity: 1), .noteOn(channel: 17, note: 60, velocity: 1),
            .noteOn(channel: 1, note: 128, velocity: 1), .noteOn(channel: 1, note: 60, velocity: 128),
            .noteOff(channel: 1, note: 60, velocity: 128), .controlChange(channel: 1, controller: 128, value: 0),
            .controlChange(channel: 1, controller: 64, value: 128), .programChange(channel: 1, program: 128),
            .channelPressure(channel: 1, pressure: 128), .pitchBend(channel: 1, value: 16_384),
            .polyphonicPressure(channel: 1, note: 60, pressure: 128)
        ]
        for message in malformed {
            Fixture.expectRefused(Fixture.event(message), .malformedEvent, in: ledger, routing: piano)
        }
        let system: [MIDI1Semantic] = [
            .realTime(status: 0xF8), .sysEx(payload: [1]), .systemCommon(status: 0xF2, data1: 0, data2: 0)
        ]
        for message in system {
            Fixture.expectRefused(Fixture.event(message), .systemMessage, in: ledger, routing: piano)
        }
        #expect(try ledger.route(Fixture.event(.noteOn(channel: 16, note: 127, velocity: 127)), routing: piano)
            == [Fixture.sentOn(Fixture.piano, 127, 127, channel: 16)])
    }

    @Test
    func steadyStateRoutingKeepsReservedStorage() throws {
        var ledger = MIDINoteLedger()
        let layered = try Fixture.routing(Fixture.rule(Fixture.piano), Fixture.rule(Fixture.strings, transpose: 7))
        let noteStorage = ledger.notes.capacity
        let holdStorage = ledger.pedalHolds.capacity
        #expect(noteStorage >= ledger.policy.noteCapacity)
        #expect(holdStorage >= ledger.policy.pedalCapacity)
        var outputs: [MIDIRoutedOutput] = []
        outputs.reserveCapacity(ledger.maximumOutputsPerEvent)
        let outputStorage = outputs.capacity
        let chord: [MIDIPerformanceEvent] = [
            Fixture.on(60), Fixture.on(64), Fixture.control(64, 127), Fixture.control(66, 127), Fixture.off(60),
            Fixture.off(64), Fixture.control(66, 0), Fixture.control(64, 0), Fixture.control(1, 5)
        ]
        for _ in 0..<200 {
            for event in chord {
                outputs.removeAll(keepingCapacity: true)
                try ledger.route(event, routing: layered, into: &outputs)
            }
        }
        #expect(ledger.notes.isEmpty)
        #expect(ledger.notes.capacity == noteStorage)
        #expect(ledger.pedalHolds.capacity == holdStorage)
        #expect(outputs.capacity == outputStorage)
    }
}
