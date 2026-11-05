import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum MIDI1SnapshotCorruption: CaseIterable, Sendable {
    case fifteenChannels, seventeenChannels, shortControllers, controllerValue, storedModeController
    case shortPolyPressure, polyPressureValue, pitchBend, channelPressure, program
    case parameterValue, parameterNumber, unsortedParameters, duplicateParameter, parametersOverBound
    case noteNumber, duplicateNote, unsortedNotes, zeroVelocity, notesOverBound, sustainedWithoutPedal, monoChannels
    case storedRPNNull, storedNRPNNull

    static let rpnNull = MIDI1ParameterNumber(kind: .registered, msb: 127, lsb: 127)
    static let nrpnNull = MIDI1ParameterNumber(kind: .nonRegistered, msb: 127, lsb: 127)

    var field: MIDI1SnapshotField {
        switch self {
        case .fifteenChannels, .seventeenChannels: .channelCount
        case .shortControllers, .controllerValue, .storedModeController: .controllers
        case .shortPolyPressure, .polyPressureValue: .polyPressure
        case .pitchBend: .pitchBend
        case .channelPressure: .channelPressure
        case .program: .program
        case .parameterValue, .parameterNumber, .unsortedParameters, .duplicateParameter, .parametersOverBound:
            .parameters
        case .monoChannels: .mode
        default: nullField ?? .heldNotes
        }
    }

    private var nullField: MIDI1SnapshotField? {
        switch self {
        case .storedRPNNull: .nullParameter(channel: 1, number: Self.rpnNull)
        case .storedNRPNNull: .nullParameter(channel: 16, number: Self.nrpnNull)
        default: nil
        }
    }

    func apply(to snapshot: inout MIDI1PerformanceSnapshot) {
        switch self {
        case .fifteenChannels: snapshot.channels.removeLast()
        case .seventeenChannels: snapshot.channels.append(snapshot.channels[0])
        case .notesOverBound: snapshot.policy = MIDI1StatePolicy(maximumHeldNotes: 2) ?? .standard
        case .storedNRPNNull: snapshot.channels[15].parameters = [MIDI1ParameterValue(number: Self.nrpnNull, value: 1)]
        case .parametersOverBound: snapshot.policy = MIDI1StatePolicy(maximumParameterValues: 2) ?? .standard
        default: corrupt(&snapshot.channels[0])
        }
    }

    private typealias ChannelEdit = @Sendable (inout MIDI1ChannelSnapshot) -> Void

    private static let invalidParameter = MIDI1ParameterValue(
        number: MIDI1ParameterNumber(kind: .nonRegistered, msb: 128, lsb: 0), value: 0
    )

    private static let channelEdits: [MIDI1SnapshotCorruption: ChannelEdit] = [
        .shortControllers: { $0.controllers.removeLast() },
        .controllerValue: { $0.controllers[3] = 128 },
        .storedModeController: { $0.controllers[120] = 1 },
        .shortPolyPressure: { $0.polyPressure.removeLast() },
        .polyPressureValue: { $0.polyPressure[5] = 128 },
        .pitchBend: { $0.pitchBend = 16_384 },
        .channelPressure: { $0.channelPressure = 128 },
        .program: { $0.program = MIDI1ProgramSelection(bankMSB: 0, bankLSB: 128, program: 0) },
        .parameterValue: { $0.parameters[0] = MIDI1ParameterValue(number: $0.parameters[0].number, value: 16_384) },
        .parameterNumber: { $0.parameters[2] = invalidParameter },
        .unsortedParameters: { $0.parameters.reverse() },
        .duplicateParameter: { $0.parameters[1] = $0.parameters[0] },
        .noteNumber: { $0.heldNotes[2] = MIDI1HeldNote(note: 128, velocity: 1, phase: .keyDown) },
        .duplicateNote: { $0.heldNotes[1] = $0.heldNotes[0] },
        .unsortedNotes: { $0.heldNotes.reverse() },
        .zeroVelocity: { $0.heldNotes[0] = MIDI1HeldNote(note: $0.heldNotes[0].note, velocity: 0, phase: .keyDown) },
        .sustainedWithoutPedal: { $0.controllers[64] = 63 },
        .monoChannels: { $0.mode.voices = .mono(channels: 17) },
        .storedRPNNull: { $0.parameters.insert(MIDI1ParameterValue(number: rpnNull, value: 0), at: 2) }
    ]

    private func corrupt(_ channel: inout MIDI1ChannelSnapshot) {
        Self.channelEdits[self]?(&channel)
    }
}

struct MIDI1PerformanceSnapshotTests {
    typealias Fixture = MIDI1StateFixture

    /// Channel 1 holds three notes (one sustained) and three parameters; channel 16 has non-default mode state.
    static func richState(policy: MIDI1StatePolicy = .standard) throws -> MIDI1PerformanceState {
        try Fixture.state([
            Fixture.control(99, 1), Fixture.control(98, 2), Fixture.control(6, 3),
            Fixture.control(101, 0), Fixture.control(100, 1), Fixture.control(6, 4), Fixture.control(38, 5),
            Fixture.control(100, 0), Fixture.control(96, 0),
            Fixture.control(0, 1), Fixture.control(32, 2), .programChange(channel: 1, program: 3),
            Fixture.control(1, 64), Fixture.control(33, 1), .pitchBend(channel: 1, value: 0),
            .channelPressure(channel: 1, pressure: 9), .polyphonicPressure(channel: 1, note: 7, pressure: 8),
            Fixture.noteOn(30, 1), Fixture.control(64, 127), Fixture.noteOn(60), Fixture.noteOff(30),
            Fixture.noteOn(90, 127),
            Fixture.control(124, 0, channel: 16), Fixture.control(126, 4, channel: 16),
            Fixture.control(122, 0, channel: 16), Fixture.noteOn(1, channel: 16)
        ], policy: policy)
    }

    @Test(arguments: [MIDI1StatePolicy.standard, MIDI1StatePolicy(lsbReset: .retainLSB, nrpnNullDeselects: false)])
    func richStateRoundTrips(policy: MIDI1StatePolicy?) throws {
        let policy = try #require(policy)
        let state = try Self.richState(policy: policy)
        let snapshot = state.snapshot
        let restored = try MIDI1PerformanceState(snapshot: snapshot)
        #expect(restored == state)
        #expect(restored.snapshot == snapshot)
        #expect(restored.policy == policy)
        let first = try #require(snapshot.channels.first)
        #expect(first.parameters.map(\.number) == [
            MIDI1ParameterNumber(kind: .registered, msb: 0, lsb: 0),
            MIDI1ParameterNumber(kind: .registered, msb: 0, lsb: 1),
            MIDI1ParameterNumber(kind: .nonRegistered, msb: 1, lsb: 2)
        ])
        #expect(first.heldNotes.map(\.note) == [30, 60, 90])
        #expect(first.heldNotes.map(\.phase) == [.sustained, .keyDown, .keyDown])
        #expect(snapshot.channels[15].mode == MIDI1ChannelMode(omni: false, voices: .mono(channels: 4)))
    }

    @Test
    func defaultAndBoundaryRoundTrips() throws {
        let fresh = MIDI1PerformanceState()
        #expect(try MIDI1PerformanceState(snapshot: fresh.snapshot) == fresh)
        let full = try Fixture.state((0...127).map { Fixture.noteOn($0, 127) } + [
            .pitchBend(channel: 1, value: 16_383), Fixture.control(126, 16)
        ])
        #expect(try MIDI1PerformanceState(snapshot: full.snapshot) == full)
        let bounded = try #require(MIDI1StatePolicy(maximumHeldNotes: 3, maximumParameterValues: 3))
        let atBounds = try Self.richState(policy: bounded)
        #expect(try MIDI1PerformanceState(snapshot: atBounds.snapshot) == atBounds)
    }

    @Test
    func nullParameterKeysOnlyRestoreWhenOrdinary() throws {
        let open = try #require(MIDI1StatePolicy(nrpnNullDeselects: false))
        let ordinary = try Fixture.state([Fixture.control(99, 127), Fixture.control(98, 127), Fixture.control(6, 1)],
                                         policy: open)
        #expect(try Fixture.first(ordinary).parameterValue(MIDI1SnapshotCorruption.nrpnNull) == 128)
        #expect(try MIDI1PerformanceState(snapshot: ordinary.snapshot) == ordinary)
        var deselecting = ordinary.snapshot
        deselecting.policy = .standard
        let nrpnNull = MIDI1SnapshotCorruption.nrpnNull
        let refusal = MIDI1StateRefusal.invalidSnapshot(.nullParameter(channel: 1, number: nrpnNull))
        #expect(throws: refusal) { try MIDI1PerformanceState(snapshot: deselecting) }
    }

    @Test
    func nullParameterCannotFillTheStore() throws {
        let single = try #require(MIDI1StatePolicy(maximumParameterValues: 1))
        var snapshot = MIDI1PerformanceState(policy: single).snapshot
        let rpnNull = MIDI1SnapshotCorruption.rpnNull
        snapshot.channels[0].parameters = [MIDI1ParameterValue(number: rpnNull, value: 0)]
        let refusal = MIDI1StateRefusal.invalidSnapshot(.nullParameter(channel: 1, number: rpnNull))
        #expect(throws: refusal) { try MIDI1PerformanceState(snapshot: snapshot) }
        let fineTuning = MIDI1ParameterNumber(kind: .registered, msb: 0, lsb: 1)
        snapshot.channels[0].parameters = [MIDI1ParameterValue(number: fineTuning, value: 5)]
        var restored = try MIDI1PerformanceState(snapshot: snapshot)
        _ = try restored.apply(Fixture.control(101, 0))
        #expect(try restored.apply(Fixture.control(100, 1)).effect == .parameterSelected(fineTuning))
        #expect(try restored.apply(Fixture.control(6, 2)).effect == .parameter(fineTuning, value: 256))
        var empty = try MIDI1PerformanceState(snapshot: MIDI1PerformanceState(policy: single).snapshot)
        _ = try empty.apply(Fixture.control(101, 0))
        _ = try empty.apply(Fixture.control(100, 0))
        #expect(try empty.apply(Fixture.control(6, 3)).effect
            == .parameter(MIDI1ParameterNumber(kind: .registered, msb: 0, lsb: 0), value: 384))
    }

    @Test(arguments: MIDI1SnapshotCorruption.allCases)
    func corruptSnapshotsRefused(corruption: MIDI1SnapshotCorruption) throws {
        var snapshot = try Self.richState().snapshot
        corruption.apply(to: &snapshot)
        #expect(throws: MIDI1StateRefusal.invalidSnapshot(corruption.field)) {
            try MIDI1PerformanceState(snapshot: snapshot)
        }
    }
}
