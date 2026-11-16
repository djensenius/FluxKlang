//
//  LaunchControlXLTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
struct LaunchControlXLTests {
    @Test func bundledMappingMatchesLaunchControlXL3DefaultMode16() throws {
        let configuration = try #require(LaunchControlXLConfiguration.bundled())

        #expect(configuration.mode == .monitor)
        #expect(configuration.mapping.channel == 16)
        #expect(configuration.mapping.faderCCs == Array(5...12))
        #expect(configuration.mapping.panOrBalanceCCs == Array(13...20))
        #expect(configuration.mapping.selectCCs == Array(37...44))
        #expect(configuration.mapping.muteCCs == Array(45...52))
        #expect(configuration.mapping.bankPreviousCC == 103)
        #expect(configuration.mapping.bankNextCC == 102)
    }

    @Test func mappingResolvesContinuousButtonsAndBanks() throws {
        let mapping = try #require(LaunchControlXLConfiguration.bundled()).mapping

        #expect(mapping.action(for: .init(channel: 16, controller: 5, value: 127)) == .fader(
            slot: 0,
            value: 1
        ))
        #expect(mapping.action(for: .init(channel: 16, controller: 20, value: 0)) == .panOrBalance(
            slot: 7,
            value: -1
        ))
        #expect(mapping.action(for: .init(channel: 16, controller: 45, value: 127)) == .toggleMute(slot: 0))
        #expect(mapping.action(for: .init(channel: 16, controller: 45, value: 0)) == nil)
        #expect(mapping.action(for: .init(channel: 16, controller: 102, value: 127)) == .moveBank(1))
        #expect(mapping.action(for: .init(channel: 1, controller: 5, value: 127)) == nil)
    }

    @Test func midiDecoderHandlesChannel16AndRunningStatus() {
        #expect(MIDIControlChange.decode([0xBF, 5, 127, 6, 64]) == [
            MIDIControlChange(channel: 16, controller: 5, value: 127),
            MIDIControlChange(channel: 16, controller: 6, value: 64)
        ])
    }

    @MainActor
    @Test func monitorModeNeverDispatchesControlActions() async throws {
        var configuration = try #require(LaunchControlXLConfiguration.bundled())
        configuration.mode = .monitor
        let controller = LaunchControlXLController(defaultConfiguration: configuration)
        var dispatched: [LaunchControlXLAction] = []
        controller.setActionHandler { dispatched.append($0) }

        await controller.receive([MIDIControlChange(channel: 16, controller: 5, value: 127)])

        #expect(controller.lastAction == .fader(slot: 0, value: 1))
        #expect(dispatched.isEmpty)
    }

    @MainActor
    @Test func controlModeDispatchesAndClampsBanks() async throws {
        var configuration = try #require(LaunchControlXLConfiguration.bundled())
        configuration.mode = .control
        let controller = LaunchControlXLController(defaultConfiguration: configuration)
        var dispatched: [LaunchControlXLAction] = []
        controller.setActionHandler { dispatched.append($0) }

        await controller.receive([MIDIControlChange(channel: 16, controller: 45, value: 127)])
        controller.moveBank(1, stripCount: 18)
        controller.moveBank(10, stripCount: 18)

        #expect(dispatched == [.toggleMute(slot: 0)])
        #expect(controller.bank == 2)
        #expect(controller.stripIndex(for: 3) == 19)
    }

    @MainActor
    @Test func appModelAppliesControlActionsThroughWingController() async throws {
        let wing = WingController.preview()
        let model = AppModel(wing: wing)
        let writesBefore = wing.transportWriteCount

        await model.handleLaunchControlXL(.fader(slot: 0, value: 0.25))

        #expect(wing.transportWriteCount == writesBefore + 2)
        let left = try #require(wing.faderPosition(.channel, 1))
        let right = try #require(wing.faderPosition(.channel, 2))
        #expect(abs((left + right) / 2 - 0.25) < 0.0001)
        #expect(abs((right - left) + 0.06) < 0.0001)
    }
}

/// The Launch Control XL through the MIDI 1 state layer with the `.unpaired` profile (#80, slice MU2).
extension LaunchControlXLTests {
    /// Faders on the CCs a standard receiver pairs or selects with, plus Sustain (64).
    static let pairedCCMapping = LaunchControlXLMapping(
        sourceNameContains: ["Launch Control XL"], channel: 16,
        faderCCs: [6, 38, 98, 99, 100, 101, 64, 5], panOrBalanceCCs: [], selectCCs: [], muteCCs: [],
        bankPreviousCC: 103, bankNextCC: 102
    )

    static func stateActions(
        _ bytes: [UInt8], mapping: LaunchControlXLMapping,
        profile: MIDISourceProfile = LaunchControlXLMapping.sourceProfile
    ) throws -> [LaunchControlXLAction] {
        var registry = try MIDISourceRegistry.make(maximumFeedBytes: MIDISourceRegistry.feedByteBounds.upperBound)
        try registry.register(MIDIInputID(1), key: MIDIEndpointKey(fingerprint: 1), profile: profile)
        return mapping.actions(for: try registry.feed(bytes, from: MIDIInputID(1)))
    }

    @MainActor
    static func dispatched(
        _ messages: [MIDIControlChange], mapping: LaunchControlXLMapping
    ) async -> [LaunchControlXLAction] {
        let controller = LaunchControlXLController(
            defaultConfiguration: LaunchControlXLConfiguration(version: 1, mode: .control, mapping: mapping)
        )
        var dispatched: [LaunchControlXLAction] = []
        controller.setActionHandler { dispatched.append($0) }
        await controller.receive(messages)
        return dispatched
    }

    /// T1: every channel, CC 0...119 and edge value maps exactly as the raw mapping, via registry and controller.
    @MainActor
    @Test func everyControllerMapsAsTheRawMappingThroughTheState() async throws {
        let bundled = try #require(LaunchControlXLConfiguration.bundled()).mapping
        var messages: [MIDIControlChange] = []
        for channel in 1...16 {
            for controller in UInt8(0)...119 {
                for value: UInt8 in [0, 1, 63, 64, 127] {
                    messages.append(MIDIControlChange(channel: channel, controller: controller, value: value))
                }
            }
        }
        let bytes = messages.flatMap { [0xB0 | UInt8($0.channel - 1), $0.controller, $0.value] }
        for mapping in [bundled, Self.pairedCCMapping] {
            let expected = messages.compactMap(mapping.action(for:))
            #expect(!expected.isEmpty)
            #expect(try Self.stateActions(bytes, mapping: mapping) == expected)
            #expect(await Self.dispatched(messages, mapping: mapping) == expected)
        }
    }

    /// T2: a lone CC 6, 38 or 98...101 acts at once; a standard receiver would refuse or select a parameter.
    @Test func loneDataEntryAndParameterNumberCCsActImmediately() throws {
        let unpaired = try #require(MIDI1StatePolicy(controllerPairing: .unpaired))
        #expect(LaunchControlXLMapping.sourceProfile == (try MIDISourceProfile.make(statePolicy: unpaired)))
        for (slot, controller) in [UInt8(6), 38, 98, 99, 100, 101].enumerated() {
            let bytes: [UInt8] = [0xBF, controller, 127]
            #expect(try Self.stateActions(bytes, mapping: Self.pairedCCMapping) == [.fader(slot: slot, value: 1)])
            #expect(try Self.stateActions(bytes, mapping: Self.pairedCCMapping, profile: .standard).isEmpty)
        }
    }

    /// T3: Sustain (64) stays a `.sustain` update in the state but maps from its own value byte as before; channel
    /// mode CCs 120...127 are mode messages, not surface controls, and map to nothing even when configured.
    @MainActor
    @Test func sustainMapsFromItsValueAndChannelModeCCsDoNot() async throws {
        var registry = try MIDISourceRegistry.make()
        try registry.register(MIDIInputID(1), key: MIDIEndpointKey(fingerprint: 1), profile: .unpaired)
        let outputs = try registry.feed([0xBF, 64, 100, 64, 0], from: MIDIInputID(1))
        #expect(outputs.map(\.outcome) == [
            .applied(MIDI1StateUpdate(channel: 16, effect: .sustain(down: true, released: []))),
            .applied(MIDI1StateUpdate(channel: 16, effect: .sustain(down: false, released: [])))
        ])
        let sustain: [LaunchControlXLAction] = [.fader(slot: 6, value: 100 / 127), .fader(slot: 6, value: 0)]
        #expect(Self.pairedCCMapping.actions(for: outputs) == sustain)
        let messages = [UInt8(100), 0].map { MIDIControlChange(channel: 16, controller: 64, value: $0) }
        #expect(await Self.dispatched(messages, mapping: Self.pairedCCMapping) == sustain)

        var modeMapping = Self.pairedCCMapping
        modeMapping.faderCCs = Array(120...127)
        let modeBytes: [UInt8] = [0xBF, 120, 0, 121, 0, 122, 127, 122, 64, 123, 0, 124, 0, 125, 0, 126, 1, 127, 0]
        #expect(try Self.stateActions(modeBytes, mapping: modeMapping).isEmpty)
    }

    /// T4: data bytes 5/127 would be fader 1 at full if any non-controller message were read as a CC.
    @Test func nonControllerMessagesMapToNothing() throws {
        let mapping = try #require(LaunchControlXLConfiguration.bundled()).mapping
        let messages: [[UInt8]] = [
            [0x9F, 5, 127], [0x8F, 5, 127], [0xAF, 5, 127], [0xCF, 5], [0xDF, 5], [0xEF, 5, 127],
            [0xF0, 0x3F, 5, 127, 0xF7], [0xF1, 5], [0xF2, 5, 127], [0xF3, 5], [0xF6], [0xF8], [0xFA], [0xFE], [0xFF]
        ]
        for bytes in messages {
            #expect(try Self.stateActions(bytes, mapping: mapping).isEmpty, "bytes \(bytes)")
        }
        #expect(try Self.stateActions(messages.flatMap(\.self) + [0xBF, 5, 127], mapping: mapping) == [
            .fader(slot: 0, value: 1)
        ])
        let systemControl = MIDI1StateUpdate(channel: nil, effect: .controller(5, value: 127))
        #expect(mapping.action(for: systemControl) == nil)
        #expect(mapping.action(for: MIDI1StateUpdate(channel: 16, effect: .controller14(5, value: 127))) == nil)
        #expect(mapping.action(for: MIDI1StateUpdate(channel: 16, effect: .noteOn(note: 5, velocity: 127))) == nil)
        #expect(mapping.action(for: MIDI1StateUpdate(channel: 16, effect: .controller(5, value: 127))) == .fader(
            slot: 0, value: 1
        ))
    }

    /// T5: running status, also across interleaved real-time bytes, through the registry and the decoder path.
    @MainActor
    @Test func runningStatusStillMapsThroughTheState() async throws {
        let mapping = try #require(LaunchControlXLConfiguration.bundled()).mapping
        let bytes: [UInt8] = [0xBF, 5, 127, 6, 0xF8, 64, 38, 127, 0xFE, 37, 127, 102, 127]
        let expected: [LaunchControlXLAction] = [
            .fader(slot: 0, value: 1), .fader(slot: 1, value: 64 / 127), .select(slot: 1), .select(slot: 0),
            .moveBank(1)
        ]
        #expect(try Self.stateActions(bytes, mapping: mapping) == expected)
        #expect(await Self.dispatched(MIDIControlChange.decode(bytes), mapping: mapping) == expected)
    }

    /// T7: the controller itself goes through the state: channel mode CCs, out-of-range data and channels map to
    /// nothing even where the raw mapping would act, and an RPN selection does not capture the next CC 6.
    @MainActor
    @Test func controllerRoutesMessagesThroughTheState() async throws {
        var modeMapping = Self.pairedCCMapping
        modeMapping.faderCCs = Array(120...127)
        let modes = (UInt8(120)...127).map { MIDIControlChange(channel: 16, controller: $0, value: 0) }
        #expect(!modes.compactMap(modeMapping.action(for:)).isEmpty)
        #expect(await Self.dispatched(modes, mapping: modeMapping).isEmpty)

        let bundled = try #require(LaunchControlXLConfiguration.bundled()).mapping
        let wide = MIDIControlChange(channel: 16, controller: 5, value: 0x80)
        #expect(bundled.action(for: wide) != nil)
        #expect(await Self.dispatched([wide], mapping: bundled).isEmpty)
        for channel in [0, 17] {
            var outside = bundled
            outside.channel = channel
            let message = MIDIControlChange(channel: channel, controller: 5, value: 127)
            #expect(outside.action(for: message) != nil)
            #expect(await Self.dispatched([message], mapping: outside).isEmpty, "channel \(channel)")
        }

        let rpnThenDataEntry = MIDIControlChange.decode([0xBF, 101, 0, 100, 0, 6, 127])
        #expect(await Self.dispatched(rpnThenDataEntry, mapping: Self.pairedCCMapping) == [
            .fader(slot: 5, value: 0), .fader(slot: 4, value: 0), .fader(slot: 0, value: 1)
        ])
        #expect(await Self.dispatched(rpnThenDataEntry, mapping: bundled) == [.fader(slot: 1, value: 1)])
    }

    /// T6: only applied outputs map, in output order.
    @Test func actionsSkipNonAppliedOutputsInOrder() throws {
        let mapping = try #require(LaunchControlXLConfiguration.bundled()).mapping
        let input = MIDIInputID(1)
        func output(_ controller: UInt8, _ value: UInt8, _ outcome: MIDISourceOutcome) -> MIDISourceOutput {
            let event = MIDI1Event.channel(status: 0xBF, data1: controller, data2: value)
            return MIDISourceOutput(input: input, event: event, outcome: outcome)
        }
        func applied(_ controller: UInt8, _ value: UInt8) -> MIDISourceOutput {
            let update = MIDI1StateUpdate(channel: 16, effect: .controller(controller, value: value))
            return output(controller, value, .applied(update))
        }
        let outputs = [
            applied(45, 127),
            output(6, 127, .refused(.noParameterSelected(channel: 16, controller: 6))),
            MIDISourceOutput(input: input, event: .realTime(status: 0xFF), outcome: .systemReset(released: [])),
            output(5, 127, .refused(.malformedEvent)),
            applied(102, 127),
            MIDISourceOutput(
                input: input, event: .realTime(status: 0xF8),
                outcome: .applied(MIDI1StateUpdate(channel: nil, effect: .unchanged))
            ),
            applied(5, 0)
        ]
        #expect(mapping.actions(for: outputs) == [.toggleMute(slot: 0), .moveBank(1), .fader(slot: 0, value: 0)])
        #expect(mapping.actions(for: []).isEmpty)
    }
}
