import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum MIDI1StateFixture {
    static func control(_ controller: UInt8, _ value: UInt8, channel: UInt8 = 1) -> MIDI1Semantic {
        .controlChange(channel: channel, controller: controller, value: value)
    }

    static func noteOn(_ note: UInt8, _ velocity: UInt8 = 100, channel: UInt8 = 1) -> MIDI1Semantic {
        .noteOn(channel: channel, note: note, velocity: velocity)
    }

    static func noteOff(_ note: UInt8, channel: UInt8 = 1) -> MIDI1Semantic {
        .noteOff(channel: channel, note: note, velocity: 64)
    }

    static func state(
        _ messages: [MIDI1Semantic], policy: MIDI1StatePolicy = .standard
    ) throws -> MIDI1PerformanceState {
        var state = MIDI1PerformanceState(policy: policy)
        for message in messages { _ = try state.apply(message) }
        return state
    }

    /// A refusal must leave the whole state, held notes included, equal to its value before the message.
    static func expectRefused(
        _ message: MIDI1Semantic, _ refusal: MIDI1StateRefusal, in state: MIDI1PerformanceState
    ) {
        var copy = state
        #expect(throws: refusal) { try copy.apply(message) }
        #expect(copy == state)
    }

    static func first(_ state: MIDI1PerformanceState) throws -> MIDI1ChannelState {
        try #require(state.channel(1))
    }
}

@Suite(.productionAccessAudit)
struct MIDI1ChannelStateTests {
    typealias Fixture = MIDI1StateFixture

    @Test
    func initialStateDefaults() throws {
        let channel = try Fixture.first(MIDI1PerformanceState())
        #expect(channel.pitchBend == 8192)
        #expect(channel.channelPressure == 0)
        #expect(channel.polyPressure == [UInt8](repeating: 0, count: 128))
        let expected: [Int: UInt8] = [7: 100, 10: 64, 11: 127, 98: 127, 99: 127, 100: 127, 101: 127]
        for controller in 0..<128 { #expect(channel.controllers[controller] == expected[controller] ?? 0) }
        #expect(channel.program == nil)
        #expect(channel.activeParameterKind == nil)
        #expect(channel.heldNotes.notes.isEmpty)
        #expect(channel.mode == MIDI1ChannelMode(omni: true, voices: .poly))
        #expect(channel.localControl)
        #expect(channel.sustainDown == false)
    }

    @Test(arguments: [UInt8(1), 7, 31])
    func fourteenBitPairs(msb: UInt8) throws {
        var state = MIDI1PerformanceState()
        #expect(try state.apply(Fixture.control(msb, 127)).effect == .controller14(msb, value: 127 << 7))
        #expect(try state.apply(Fixture.control(msb + 32, 127)).effect == .controller14(msb, value: 16_383))
        #expect(try state.apply(Fixture.control(msb + 32, 0)).effect == .controller14(msb, value: 127 << 7))
        _ = try state.apply(Fixture.control(msb + 32, 5))
        #expect(try state.apply(Fixture.control(msb, 1)).effect == .controller14(msb, value: 128))
        #expect(try Fixture.first(state).controllers[Int(msb) + 32] == 0)

        let retaining = try #require(MIDI1StatePolicy(lsbReset: .retainLSB))
        let retained = try Fixture.state([Fixture.control(msb + 32, 5), Fixture.control(msb, 1)], policy: retaining)
        #expect(try Fixture.first(retained).value14(controller: msb) == 133)
    }

    @Test
    func pairingBoundaries() throws {
        var state = MIDI1PerformanceState()
        #expect(try state.apply(Fixture.control(63, 9)).effect == .controller14(31, value: 9))
        #expect(try state.apply(Fixture.control(65, 9)).effect == .controller(65, value: 9))
        #expect(try state.apply(Fixture.control(64, 0)).effect == .sustain(down: false, released: []))
        #expect(try Fixture.first(state).value14(controller: 32) == nil)
        #expect(try Fixture.first(state).value14(controller: 31) == 9)
    }

    @Test
    func bankLatchCommitsOnProgramChangeOnly() throws {
        var state = MIDI1PerformanceState()
        #expect(try state.apply(Fixture.control(32, 2)).effect == .bankLatched(msb: 0, lsb: 2))
        #expect(try state.apply(Fixture.control(0, 1)).effect == .bankLatched(msb: 1, lsb: 2))
        #expect(try Fixture.first(state).program == nil)
        let selection = MIDI1ProgramSelection(bankMSB: 1, bankLSB: 2, program: 5)
        #expect(try state.apply(.programChange(channel: 1, program: 5)).effect == .program(selection))
        _ = try state.apply(Fixture.control(0, 3))
        #expect(try Fixture.first(state).program == selection)
        #expect(try Fixture.first(state).controllers[32] == 2)
        _ = try state.apply(.programChange(channel: 1, program: 6))
        #expect(try Fixture.first(state).program == MIDI1ProgramSelection(bankMSB: 3, bankLSB: 2, program: 6))
    }

    @Test(arguments: [UInt16(0), 8192, 16_383])
    func pitchBendAndPressure(value: UInt16) throws {
        var state = MIDI1PerformanceState()
        #expect(try state.apply(.pitchBend(channel: 1, value: value)).effect == .pitchBend(value))
        #expect(try state.apply(.channelPressure(channel: 1, pressure: 127)).effect == .channelPressure(127))
        #expect(try state.apply(.polyphonicPressure(channel: 1, note: 127, pressure: 3)).effect
            == .polyPressure(note: 127, pressure: 3))
        let channel = try Fixture.first(state)
        #expect(channel.pitchBend == value && channel.channelPressure == 127 && channel.polyPressure[127] == 3)
        Fixture.expectRefused(.pitchBend(channel: 1, value: 16_384), .malformedEvent, in: state)
    }

    @Test
    func sustainHoldsAndReleases() throws {
        var state = try Fixture.state([Fixture.noteOn(60), Fixture.noteOn(62), Fixture.noteOn(64)])
        #expect(try state.apply(Fixture.control(64, 63)).effect == .sustain(down: false, released: []))
        #expect(try state.apply(Fixture.control(64, 64)).effect == .sustain(down: true, released: []))
        #expect(try state.apply(Fixture.noteOff(60)).effect == .noteOff(note: 60, sustained: true))
        let zeroVelocity = MIDI1Event.channel(status: 0x90, data1: 62, data2: 0)
        #expect(try state.apply(zeroVelocity).effect == .noteOff(note: 62, sustained: true))
        #expect(try state.apply(Fixture.noteOff(62)).effect == .unchanged)
        #expect(try state.apply(Fixture.noteOff(70)).effect == .unchanged)
        #expect(try state.apply(Fixture.noteOn(62, 9)).effect == .noteOn(note: 62, velocity: 9))
        #expect(try state.apply(Fixture.control(64, 127)).effect == .sustain(down: true, released: []))
        #expect(try Fixture.first(state).heldNotes.phase(of: 60) == .sustained)
        #expect(try state.apply(Fixture.control(64, 63)).effect == .sustain(down: false, released: [60]))
        #expect(try Fixture.first(state).heldNotes.notes == [
            MIDI1HeldNote(note: 62, velocity: 9, phase: .keyDown),
            MIDI1HeldNote(note: 64, velocity: 100, phase: .keyDown)
        ])
        #expect(try state.apply(Fixture.noteOn(64, 0)).effect == .noteOff(note: 64, sustained: false))
        #expect(try Fixture.first(state).heldNotes.phase(of: 64) == nil)
    }

    @Test
    func heldNoteLimit() throws {
        let policy = try #require(MIDI1StatePolicy(maximumHeldNotes: 2))
        var state = try Fixture.state([Fixture.noteOn(60), Fixture.noteOn(61)], policy: policy)
        Fixture.expectRefused(Fixture.noteOn(62), .heldNoteLimit(channel: 1, note: 62), in: state)
        #expect(try state.apply(Fixture.noteOn(61, 5)).effect == .noteOn(note: 61, velocity: 5))
        _ = try state.apply(Fixture.noteOff(60))
        #expect(try state.apply(Fixture.noteOn(62)).effect == .noteOn(note: 62, velocity: 100))

        let full = try Fixture.state((0...127).map { Fixture.noteOn($0) })
        #expect(try Fixture.first(full).heldNotes.notes.map(\.note) == Array(0...127))
        #expect(MIDI1StatePolicy(maximumHeldNotes: 0) == nil && MIDI1StatePolicy(maximumHeldNotes: 129) == nil)
        #expect(MIDI1StatePolicy(maximumHeldNotes: 1) != nil && MIDI1StatePolicy(maximumHeldNotes: 128) != nil)
        #expect(MIDI1StatePolicy(maximumParameterValues: 0) == nil)
        #expect(MIDI1StatePolicy(maximumParameterValues: 32_768) != nil)
        #expect(MIDI1StatePolicy(maximumParameterValues: 32_769) == nil)
    }

    @Test(arguments: [UInt8(0), 99])
    func allSoundOffClearsEveryNote(value: UInt8) throws {
        var state = try Fixture.state([
            Fixture.noteOn(40), Fixture.noteOn(50), Fixture.control(64, 127), Fixture.noteOff(40)
        ])
        #expect(try state.apply(Fixture.control(120, value)).effect == .allSoundOff(released: [40, 50]))
        #expect(try Fixture.first(state).heldNotes.notes.isEmpty)
    }

    @Test(arguments: [UInt8(123), 124, 125, 126, 127])
    func allNotesOffRespectsSustain(controller: UInt8) throws {
        let value: UInt8 = controller == 123 ? 55 : 0
        var free = try Fixture.state([Fixture.noteOn(40), Fixture.noteOn(50)])
        let freeEffect = try free.apply(Fixture.control(controller, value)).effect
        #expect(try Fixture.first(free).heldNotes.notes.isEmpty)
        var held = try Fixture.state([Fixture.noteOn(40), Fixture.control(64, 64), Fixture.noteOn(50)])
        let heldEffect = try held.apply(Fixture.control(controller, value)).effect
        #expect(try Fixture.first(held).heldNotes.notes.map(\.phase) == [.sustained, .sustained])
        if controller == 123 {
            #expect(freeEffect == .allNotesOff(released: [40, 50]) && heldEffect == .allNotesOff(released: []))
        } else {
            let mode = try Fixture.first(free).mode
            #expect(freeEffect == .mode(mode, released: [40, 50]) && heldEffect == .mode(mode, released: []))
        }
        #expect(try held.apply(Fixture.control(64, 0)).effect == .sustain(down: false, released: [40, 50]))
    }

    @Test(arguments: [
        (UInt8(122), UInt8(0), true), (122, 127, true), (122, 1, false), (122, 64, false),
        (124, 0, true), (124, 1, false), (125, 0, true), (125, 127, false),
        (126, 0, true), (126, 16, true), (126, 17, false), (127, 0, true), (127, 1, false)
    ])
    func modeMessageValues(controller: UInt8, value: UInt8, valid: Bool) throws {
        let base = try Fixture.state([Fixture.control(124, 0), Fixture.control(122, 0), Fixture.noteOn(60)])
        guard valid else {
            let refusal = MIDI1StateRefusal.invalidModeValue(channel: 1, controller: controller, value: value)
            Fixture.expectRefused(Fixture.control(controller, value), refusal, in: base)
            return
        }
        var state = base
        _ = try state.apply(Fixture.control(controller, value))
        let channel = try Fixture.first(state)
        switch controller {
        case 122: #expect(channel.localControl == (value == 127) && channel.heldNotes.notes.count == 1)
        case 124: #expect(channel.mode == MIDI1ChannelMode(omni: false, voices: .poly))
        case 125: #expect(channel.mode == MIDI1ChannelMode(omni: true, voices: .poly))
        case 126: #expect(channel.mode == MIDI1ChannelMode(omni: false, voices: .mono(channels: value)))
        default: #expect(channel.mode == MIDI1ChannelMode(omni: false, voices: .poly))
        }
    }

    @Test
    func resetAllControllersFollowsRP015() throws {
        let kept: [UInt8] = [0, 7, 10, 32, 39, 42] + Array(70...79) + Array(91...95)
        let reset: [(UInt8, UInt8)] = [
            (1, 0), (33, 0), (11, 127), (43, 0), (64, 0), (65, 0), (66, 0), (67, 0),
            (98, 127), (99, 127), (100, 127), (101, 127)
        ]
        var setup = kept.map { Fixture.control($0, 9) } + reset.map { Fixture.control($0.0, 9) }
        setup += [
            .programChange(channel: 1, program: 4), .pitchBend(channel: 1, value: 3),
            .channelPressure(channel: 1, pressure: 5), .polyphonicPressure(channel: 1, note: 60, pressure: 7),
            Fixture.control(6, 2), Fixture.control(122, 0), Fixture.control(126, 3),
            Fixture.noteOn(60), Fixture.noteOn(61), Fixture.control(64, 127), Fixture.noteOff(61)
        ]
        var state = try Fixture.state(setup)
        let before = try Fixture.first(state)
        #expect(try state.apply(Fixture.control(121, 77)).effect == .controllersReset(released: [61]))
        let after = try Fixture.first(state)
        for controller in kept { #expect(after.controllers[Int(controller)] == 9) }
        for (controller, value) in reset { #expect(after.controllers[Int(controller)] == value) }
        #expect(after.pitchBend == 8192 && after.channelPressure == 0 && after.polyPressure[60] == 0)
        #expect(after.activeParameterKind == nil && after.selectedParameter(policy: .standard) == nil)
        #expect(after.program == before.program && after.parameters == before.parameters)
        #expect(after.parameters.count == 1)
        #expect(after.localControl == false && after.mode == before.mode)
        #expect(after.heldNotes.notes == [MIDI1HeldNote(note: 60, velocity: 100, phase: .keyDown)])
    }

    @Test
    func channelsAreIndependent() throws {
        var state = try Fixture.state([
            Fixture.control(1, 5, channel: 2), Fixture.noteOn(60, channel: 2),
            .pitchBend(channel: 16, value: 0), Fixture.control(101, 0, channel: 16)
        ])
        #expect(try Fixture.first(state) == MIDI1ChannelState())
        #expect(state.channel(2)?.controllers[1] == 5 && state.channel(16)?.pitchBend == 0)
        #expect(state.channel(0) == nil && state.channel(17) == nil)
        #expect(try state.apply(Fixture.control(7, 1, channel: 16)).channel == 16)
        Fixture.expectRefused(Fixture.control(7, 1, channel: 0), .malformedEvent, in: state)
        Fixture.expectRefused(Fixture.control(7, 1, channel: 17), .malformedEvent, in: state)
    }

    @Test
    func systemMessagesAreInert() throws {
        var state = try Fixture.state([Fixture.noteOn(60), Fixture.control(101, 0), Fixture.control(100, 0)])
        let before = state
        let messages: [MIDI1Semantic] = [
            .realTime(status: 0xFF), .realTime(status: 0xF8), .sysEx(payload: [0x7E, 1]),
            .systemCommon(status: 0xF2, data1: 0, data2: 0)
        ]
        for message in messages {
            #expect(try state.apply(message) == MIDI1StateUpdate(channel: nil, effect: .unchanged))
        }
        #expect(state == before)
    }

    /// Each semantic paired with the raw event it denotes; both overloads must agree.
    static let malformedSystemMessages: [(MIDI1Semantic, MIDI1Event)] = [
        (.realTime(status: 0x90), .realTime(status: 0x90)),
        (.realTime(status: 0xF7), .realTime(status: 0xF7)),
        (.systemCommon(status: 0xF1, data1: nil, data2: nil), .systemCommon(status: 0xF1, data1: nil, data2: nil)),
        (.systemCommon(status: 0xF1, data1: 1, data2: 2), .systemCommon(status: 0xF1, data1: 1, data2: 2)),
        (.systemCommon(status: 0xF3, data1: 0x80, data2: nil), .systemCommon(status: 0xF3, data1: 0x80, data2: nil)),
        (.systemCommon(status: 0xF2, data1: 1, data2: nil), .systemCommon(status: 0xF2, data1: 1, data2: nil)),
        (.systemCommon(status: 0xF2, data1: 1, data2: 0x80), .systemCommon(status: 0xF2, data1: 1, data2: 0x80)),
        (.systemCommon(status: 0xF6, data1: 0, data2: nil), .systemCommon(status: 0xF6, data1: 0, data2: nil)),
        (.systemCommon(status: 0xF0, data1: nil, data2: nil), .systemCommon(status: 0xF0, data1: nil, data2: nil)),
        (.systemCommon(status: 0xF8, data1: nil, data2: nil), .systemCommon(status: 0xF8, data1: nil, data2: nil)),
        (.sysEx(payload: [0x80]), .sysEx(payload: [0x80])),
        (.sysEx(payload: [0x01, 0xFF]), .sysEx(payload: [0x01, 0xFF]))
    ]

    @Test
    func systemValidationParity() throws {
        let state = try Fixture.state([Fixture.noteOn(60), Fixture.control(101, 0), Fixture.control(100, 0)])
        for (semantic, event) in Self.malformedSystemMessages {
            #expect(event.semantic == nil)
            Fixture.expectRefused(semantic, .malformedEvent, in: state)
            var copy = state
            #expect(throws: MIDI1StateRefusal.malformedEvent) { try copy.apply(event) }
            #expect(copy == state)
        }
        let valid: [MIDI1Event] = [
            .realTime(status: 0xF8), .realTime(status: 0xFF), .systemCommon(status: 0xF1, data1: 0x7F, data2: nil),
            .systemCommon(status: 0xF2, data1: 0x7F, data2: 0x7F), .systemCommon(status: 0xF3, data1: 0, data2: nil),
            .systemCommon(status: 0xF4, data1: nil, data2: nil), .systemCommon(status: 0xF7, data1: nil, data2: nil),
            .sysEx(payload: []), .sysEx(payload: [0x7F])
        ]
        for event in valid {
            var copy = state
            let semantic = try #require(event.semantic)
            #expect(try copy.apply(semantic) == MIDI1StateUpdate(channel: nil, effect: .unchanged))
            #expect(try copy.apply(event) == MIDI1StateUpdate(channel: nil, effect: .unchanged))
            #expect(copy == state)
        }
    }

    @Test
    func malformedEventsRefused() throws {
        let state = try Fixture.state([Fixture.noteOn(60), Fixture.control(64, 127)])
        var copy = state
        #expect(throws: MIDI1StateRefusal.malformedEvent) {
            try copy.apply(MIDI1Event.channel(status: 0xB0, data1: 0x80, data2: 0))
        }
        #expect(throws: MIDI1StateRefusal.malformedEvent) {
            try copy.apply(MIDI1Event.channel(status: 0xC0, data1: 1, data2: 2))
        }
        #expect(copy == state)
        Fixture.expectRefused(Fixture.control(7, 128), .malformedEvent, in: state)
        Fixture.expectRefused(Fixture.noteOn(128), .malformedEvent, in: state)
        Fixture.expectRefused(.programChange(channel: 1, program: 128), .malformedEvent, in: state)
    }
}
