import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct MIDI1ParameterStateTests {
    typealias Fixture = MIDI1StateFixture

    static func rpn(_ msb: UInt8, _ lsb: UInt8) -> MIDI1ParameterNumber {
        MIDI1ParameterNumber(kind: .registered, msb: msb, lsb: lsb)
    }

    static func nrpn(_ msb: UInt8, _ lsb: UInt8) -> MIDI1ParameterNumber {
        MIDI1ParameterNumber(kind: .nonRegistered, msb: msb, lsb: lsb)
    }

    static func selectRPN(_ msb: UInt8, _ lsb: UInt8) -> [MIDI1Semantic] {
        [Fixture.control(101, msb), Fixture.control(100, lsb)]
    }

    static func selectNRPN(_ msb: UInt8, _ lsb: UInt8) -> [MIDI1Semantic] {
        [Fixture.control(99, msb), Fixture.control(98, lsb)]
    }

    static func feed(_ bytes: [UInt8], parser: inout MIDI1Parser, state: inout MIDI1PerformanceState) throws {
        for byte in bytes {
            if let event = parser.consume(byte) { _ = try state.apply(event) }
        }
    }

    @Test
    func rpnSelectionAndDataEntry() throws {
        var state = MIDI1PerformanceState()
        #expect(try state.apply(Fixture.control(101, 0)).effect == .parameterSelected(Self.rpn(0, 127)))
        #expect(try state.apply(Fixture.control(100, 0)).effect == .parameterSelected(Self.rpn(0, 0)))
        #expect(try state.apply(Fixture.control(6, 2)).effect == .parameter(Self.rpn(0, 0), value: 256))
        #expect(try state.apply(Fixture.control(38, 50)).effect == .parameter(Self.rpn(0, 0), value: 306))
        #expect(try state.apply(Fixture.control(6, 3)).effect == .parameter(Self.rpn(0, 0), value: 384))
        let channel = try Fixture.first(state)
        #expect(channel.controllers[6] == 3 && channel.controllers[38] == 0)
        #expect(channel.parameterValue(Self.rpn(0, 0)) == 384)

        let retaining = try #require(MIDI1StatePolicy(lsbReset: .retainLSB))
        let retained = try Fixture.state(
            Self.selectRPN(0, 0) + [Fixture.control(6, 2), Fixture.control(38, 50), Fixture.control(6, 3)],
            policy: retaining
        )
        #expect(try Fixture.first(retained).parameterValue(Self.rpn(0, 0)) == 434)
        #expect(try Fixture.first(retained).controllers[38] == 50)
    }

    @Test
    func nrpnIsSeparateFromRpn() throws {
        var state = try Fixture.state(Self.selectNRPN(0, 0) + [Fixture.control(6, 5)])
        _ = try state.apply(Fixture.control(101, 0))
        #expect(try state.apply(Fixture.control(100, 0)).effect == .parameterSelected(Self.rpn(0, 0)))
        _ = try state.apply(Fixture.control(6, 1))
        #expect(try state.apply(Fixture.control(98, 0)).effect == .parameterSelected(Self.nrpn(0, 0)))
        #expect(try state.apply(Fixture.control(38, 1)).effect == .parameter(Self.nrpn(0, 0), value: 641))
        let channel = try Fixture.first(state)
        #expect(channel.parameters == [Self.nrpn(0, 0): 641, Self.rpn(0, 0): 128])
        #expect(channel.activeParameterKind == .nonRegistered)
    }

    @Test(arguments: [UInt8(6), 38, 96, 97])
    func nullAndUnselectedRefuseDataEntry(controller: UInt8) throws {
        let refusal = MIDI1StateRefusal.noParameterSelected(channel: 1, controller: controller)
        Fixture.expectRefused(Fixture.control(controller, 1), refusal, in: MIDI1PerformanceState())
        var state = try Fixture.state(Self.selectRPN(0, 0) + [Fixture.control(6, 4), Fixture.control(101, 127)])
        #expect(try state.apply(Fixture.control(100, 127)).effect == .parameterSelected(nil))
        Fixture.expectRefused(Fixture.control(controller, 1), refusal, in: state)
        let nrpnNull = try Fixture.state(Self.selectNRPN(127, 127))
        Fixture.expectRefused(Fixture.control(controller, 1), refusal, in: nrpnNull)
        #expect(try Fixture.first(state).parameterValue(Self.rpn(0, 0)) == 512)
    }

    @Test
    func onlyBothHalvesAreNull() throws {
        for (msb, lsb) in [(UInt8(127), UInt8(0)), (0, 127)] {
            var state = try Fixture.state(Self.selectRPN(msb, lsb))
            #expect(try state.apply(Fixture.control(6, 1)).effect == .parameter(Self.rpn(msb, lsb), value: 128))
        }
        let open = try #require(MIDI1StatePolicy(nrpnNullDeselects: false))
        var state = try Fixture.state(Self.selectNRPN(127, 127), policy: open)
        #expect(try state.apply(Fixture.control(6, 1)).effect == .parameter(Self.nrpn(127, 127), value: 128))
    }

    @Test(arguments: [UInt8(0), 127])
    func incrementDecrementSaturates(ignoredValue: UInt8) throws {
        let fine = Self.rpn(0, 1)
        var state = try Fixture.state(Self.selectRPN(0, 1))
        #expect(try state.apply(Fixture.control(96, ignoredValue)).effect == .parameter(fine, value: 1))
        _ = try state.apply(Fixture.control(6, 127))
        _ = try state.apply(Fixture.control(38, 126))
        #expect(try state.apply(Fixture.control(96, ignoredValue)).effect == .parameter(fine, value: 16_383))
        #expect(try state.apply(Fixture.control(96, ignoredValue)).effect == .parameter(fine, value: 16_383))
        #expect(try state.apply(Fixture.control(97, ignoredValue)).effect == .parameter(fine, value: 16_382))
        _ = try state.apply(Fixture.control(6, 0))
        #expect(try state.apply(Fixture.control(97, ignoredValue)).effect == .parameter(fine, value: 0))
        #expect(try Fixture.first(state).controllers[97] == ignoredValue)

        var nrpn = try Fixture.state(Self.selectNRPN(0, 2) + [Fixture.control(6, 1)])
        #expect(try nrpn.apply(Fixture.control(96, ignoredValue)).effect == .parameter(Self.nrpn(0, 2), value: 129))
    }

    @Test
    func coarseTuningStepsSemitones() throws {
        let coarse = Self.rpn(0, 2)
        var state = try Fixture.state(Self.selectRPN(0, 2) + [Fixture.control(6, 64), Fixture.control(38, 5)])
        #expect(try state.apply(Fixture.control(96, 0)).effect == .parameter(coarse, value: 65 << 7 | 5))
        #expect(try state.apply(Fixture.control(97, 0)).effect == .parameter(coarse, value: 64 << 7 | 5))
        _ = try state.apply(Fixture.control(6, 127))
        _ = try state.apply(Fixture.control(38, 5))
        #expect(try state.apply(Fixture.control(96, 0)).effect == .parameter(coarse, value: 127 << 7 | 5))
        _ = try state.apply(Fixture.control(6, 0))
        _ = try state.apply(Fixture.control(38, 5))
        #expect(try state.apply(Fixture.control(97, 0)).effect == .parameter(coarse, value: 5))
    }

    @Test
    func parameterStoreIsBounded() throws {
        let policy = try #require(MIDI1StatePolicy(maximumParameterValues: 1))
        var state = try Fixture.state(Self.selectRPN(0, 0) + [Fixture.control(6, 1)] + Self.selectRPN(0, 1),
                                      policy: policy)
        for controller: UInt8 in [6, 38, 96, 97] {
            Fixture.expectRefused(Fixture.control(controller, 2), .parameterStoreFull(channel: 1), in: state)
        }
        _ = try state.apply(Fixture.control(100, 0))
        #expect(try state.apply(Fixture.control(6, 2)).effect == .parameter(Self.rpn(0, 0), value: 256))
    }

    @Test
    func delayedDataEntryThroughParserAndRunningStatus() throws {
        var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 8))
        var state = MIDI1PerformanceState()
        try Self.feed([0xB0, 0x65, 0x00, 0x64, 0x00], parser: &parser, state: &state)
        let filler: [UInt8] = [
            0xF8, 0xFE, 0xF0, 0x7D, 0x01, 0xF7, 0x91, 0x3C, 0x40, 0xB1, 0x07, 0x10,
            0xF2, 0x00, 0x00, 0x90, 0x3C, 0x40, 0x3C, 0x00, 0xE0, 0x00, 0x40
        ]
        for _ in 0..<1_000 { try Self.feed(filler, parser: &parser, state: &state) }
        try Self.feed([0xB0, 0x06, 0xF8, 0x05, 0x26, 0xFE, 0x01], parser: &parser, state: &state)
        #expect(try Fixture.first(state).parameterValue(Self.rpn(0, 0)) == 641)
        try Self.feed([0x60, 0x00], parser: &parser, state: &state)
        #expect(try Fixture.first(state).parameterValue(Self.rpn(0, 0)) == 642)
        try Self.feed([0xB0, 0x63, 0x01, 0x62, 0x02, 0x06, 0x40, 0x26, 0x05], parser: &parser, state: &state)
        #expect(try Fixture.first(state).parameterValue(Self.nrpn(1, 2)) == 8197)
        #expect(state.channel(2)?.controllers[7] == 0x10)
        #expect(state.channel(2)?.heldNotes.notes.map(\.note) == [0x3C])
        #expect(try Fixture.first(state).heldNotes.notes.isEmpty)
    }

    @Test
    func malformedFragmentsDoNotCorrupt() throws {
        var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 4))
        var state = try Fixture.state(Self.selectRPN(0, 0) + [Fixture.control(6, 1), Fixture.noteOn(60)])
        let before = state
        let fragments: [UInt8] = [
            0xB0, 0x65, 0x90, 0xF7, 0x01, 0x02, 0xB0, 0x06, 0xF2, 0x00, 0x00,
            0xF0, 0x01, 0x02, 0x03, 0x04, 0x05, 0xF7, 0xB0, 0x62, 0xF6, 0x7F
        ]
        try Self.feed(fragments, parser: &parser, state: &state)
        #expect(state == before)
        Fixture.expectRefused(.controlChange(channel: 1, controller: 38, value: 0x80), .malformedEvent, in: state)
        var copy = state
        #expect(throws: MIDI1StateRefusal.malformedEvent) {
            try copy.apply(MIDI1Event.channel(status: 0xB0, data1: 6, data2: nil))
        }
        #expect(copy == state)
        try Self.feed([0xB0, 0x26, 0x07], parser: &parser, state: &state)
        #expect(try Fixture.first(state).parameterValue(Self.rpn(0, 0)) == 135)
    }

    @Test
    func resetAllControllersNullsSelectionKeepsValues() throws {
        var state = try Fixture.state(Self.selectNRPN(3, 4) + [Fixture.control(6, 9), Fixture.control(121, 0)])
        let channel = try Fixture.first(state)
        #expect(channel.selectedParameter(policy: .standard) == nil)
        #expect(channel.parameterValue(Self.nrpn(3, 4)) == 9 << 7)
        let refusal = MIDI1StateRefusal.noParameterSelected(channel: 1, controller: 6)
        Fixture.expectRefused(Fixture.control(6, 1), refusal, in: state)
        _ = try state.apply(Fixture.control(99, 3))
        #expect(try state.apply(Fixture.control(98, 4)).effect == .parameterSelected(Self.nrpn(3, 4)))
    }
}
