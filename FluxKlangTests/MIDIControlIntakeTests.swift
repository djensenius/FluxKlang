import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// MIDI control intake (#87, #88): origin and key validation, bounds, width checks, check precedence, golden vectors
/// and determinism. Fixtures are nested here so no name leaks into the shared test module.
#if os(macOS)
@Suite("MIDIControlIntakeTests", .productionAccessAudit)
#else
@Suite("MIDIControlIntakeTests")
#endif
struct MIDIControlIntakeTests {
    typealias Outcome = Result<ControlIntakeSample, ControlIntakeRefusal>

    /// Launch Control XL 3 default Mode 16 numbers, restated from `FluxKlangTests/LaunchControlXLTests.swift`.
    enum LaunchControl {
        static let channel: UInt8 = 16
        static let faders: ClosedRange<UInt8> = 5...12
        static let pans: ClosedRange<UInt8> = 13...20
        static let selects: ClosedRange<UInt8> = 37...44
        static let mutes: ClosedRange<UInt8> = 45...52
        static let bankPrevious: UInt8 = 103
        static let bankNext: UInt8 = 102
    }

    struct Expectation {
        let kind: ControlSourceKind
        let number: UInt16
        let raw: Int
        let width: EncoderBitWidth
    }

    let origin: ControlSourceOrigin
    let sevenBit = EncoderProfile.absolute(resolution: 128)
    let fourteenBit = EncoderProfile.absolute(resolution: 16_384)

    init() throws {
        origin = try ControlSourceOrigin("lcxl-1")
    }

    func message(_ effect: MIDI1StateEffect, channel: UInt8? = LaunchControl.channel) -> MIDI1StateUpdate {
        MIDI1StateUpdate(channel: channel, effect: effect)
    }

    func outcome(
        _ effect: MIDI1StateEffect,
        channel: UInt8? = LaunchControl.channel,
        profile: EncoderProfile? = nil,
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) -> Outcome {
        let update = message(effect, channel: channel)
        do {
            let resolved = try MIDIControlIntake.resolve(
                update, origin: origin, profile: profile ?? sevenBit, dialect: dialect)
            return .success(resolved)
        } catch {
            return .failure(error)
        }
    }

    func refusal(
        _ effect: MIDI1StateEffect,
        channel: UInt8? = LaunchControl.channel,
        profile: EncoderProfile? = nil,
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) -> ControlIntakeRefusal? {
        if case .failure(let error) = outcome(effect, channel: channel, profile: profile, dialect: dialect) {
            return error
        }
        return nil
    }

    func sample(
        _ effect: MIDI1StateEffect,
        channel: UInt8? = LaunchControl.channel,
        profile: EncoderProfile? = nil,
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) -> ControlIntakeSample? {
        if case .success(let resolved) = outcome(effect, channel: channel, profile: profile, dialect: dialect) {
            return resolved
        }
        return nil
    }

    func keyRefusal(_ effect: MIDI1StateEffect, channel: UInt8? = LaunchControl.channel) -> ControlIntakeRefusal? {
        do {
            _ = try MIDIControlIntake.key(for: message(effect, channel: channel), origin: origin)
            return nil
        } catch {
            return error
        }
    }

    func nrpn(_ msb: UInt8, _ lsb: UInt8) -> MIDI1ParameterNumber {
        MIDI1ParameterNumber(kind: .nonRegistered, msb: msb, lsb: lsb)
    }

    func rpn(_ msb: UInt8, _ lsb: UInt8) -> MIDI1ParameterNumber {
        MIDI1ParameterNumber(kind: .registered, msb: msb, lsb: lsb)
    }

    /// The update a real performance state reports after one control change on a fresh state.
    func performed(channel: UInt8, controller: UInt8, value: UInt8) throws -> MIDI1StateUpdate {
        var state = MIDI1PerformanceState()
        return try state.apply(.controlChange(channel: channel, controller: controller, value: value))
    }

    func key(_ kind: ControlSourceKind, channel: UInt8 = 1, number: UInt16 = 0) throws -> ControlSourceKey {
        try ControlSourceKey(origin: origin, channel: channel, kind: kind, number: number)
    }

    /// One effect of every control kind with a mid-range, valid, in-width raw value.
    func everyControlEffect() -> [MIDI1StateEffect] {
        [
            .controller(70, value: 100), .controller14(5, value: 8_192), .parameter(rpn(0, 2), value: 8_192),
            .parameter(nrpn(1, 2), value: 8_192), .pitchBend(8_192), .channelPressure(64)
        ]
    }

    /// One effect of every case that is not a control input.
    func everyNonControlEffect() -> [MIDI1StateEffect] {
        [
            .unchanged, .noteOn(note: 60, velocity: 100), .noteOff(note: 60, sustained: false),
            .polyPressure(note: 60, pressure: 1), .bankLatched(msb: 1, lsb: 2), .parameterSelected(nil),
            .parameterSelected(nrpn(1, 2)), .program(MIDI1ProgramSelection(bankMSB: 0, bankLSB: 0, program: 1)),
            .sustain(down: true, released: []), .allSoundOff(released: [60]), .allNotesOff(released: []),
            .controllersReset(released: []), .localControl(true), .mode(MIDI1ChannelMode(), released: [])
        ]
    }

    @Test func intakeEveryNonControlEffectIsRefusedNotControlInputInBothDialects() throws {
        let effects = everyNonControlEffect()
        #expect(effects.count == 14)
        for effect in effects {
            for dialect in ControlIntakeDialect.allCases {
                #expect(refusal(effect, dialect: dialect) == .notControlInput)
            }
        }
    }

    @Test func intakeEveryControlEffectMapsToItsKindNumberAndRaw() throws {
        let expected = [
            Expectation(kind: .controller, number: 70, raw: 100, width: .seven),
            Expectation(kind: .controller14, number: 5, raw: 8_192, width: .fourteen),
            Expectation(kind: .registeredParameter, number: 2, raw: 8_192, width: .fourteen),
            Expectation(kind: .nonRegisteredParameter, number: 130, raw: 8_192, width: .fourteen),
            Expectation(kind: .pitchBend, number: 0, raw: 8_192, width: .fourteen),
            Expectation(kind: .channelPressure, number: 0, raw: 64, width: .seven)
        ]
        let effects = everyControlEffect()
        try #require(effects.count == expected.count)
        for (effect, want) in zip(effects, expected) {
            let profile = EncoderProfile.absolute(resolution: want.width == .seven ? 128 : 16_384)
            let resolved = try #require(sample(effect, profile: profile))
            #expect(resolved.key.kind == want.kind)
            #expect(resolved.key.number == want.number)
            #expect(resolved.raw == want.raw)
            #expect(resolved.width == want.width)
            #expect(resolved.key.channel == 16)
            #expect(resolved.key.origin == origin)
            #expect(resolved.source == resolved.key.sourceID)
        }
    }
}
