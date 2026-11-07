import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIControlIntakeTests {
    private var note: MIDI1StateEffect { .noteOn(note: 60, velocity: 100) }
    private var invalidProfile: EncoderProfile { .absolute(resolution: 1) }

    @Test func intakeAnInvalidProfileWinsOverAMissingChannel() throws {
        #expect(refusal(.controller(70, value: 1), channel: nil, profile: invalidProfile)
                == .invalidProfile(resolution: 1))
    }

    @Test func intakeAnInvalidProfileWinsOverEveryOtherFault() throws {
        let profile = EncoderProfile.absolute(resolution: 16_385)
        #expect(refusal(note, channel: nil, profile: profile) == .invalidProfile(resolution: 16_385))
        #expect(refusal(.controller(64, value: 200), channel: 17, profile: profile)
                == .invalidProfile(resolution: 16_385))
        #expect(refusal(.controller14(5, value: 16_257), profile: profile, dialect: .msbOnlySevenBit)
                == .invalidProfile(resolution: 16_385))
        #expect(refusal(.pitchBend(16_384), profile: profile) == .invalidProfile(resolution: 16_385))
    }

    @Test func intakeAMissingChannelWinsOverAnEffectThatIsNotControl() throws {
        #expect(refusal(note, channel: nil) == .noChannel)
        #expect(refusal(.controller(64, value: 200), channel: nil) == .noChannel)
    }

    @Test func intakeAnInvalidChannelWinsOverAnEffectThatIsNotControl() throws {
        #expect(refusal(note, channel: 0) == .invalidChannel(0))
        #expect(refusal(note, channel: 17) == .invalidChannel(17))
    }

    @Test func intakeAnInvalidChannelWinsOverAnInvalidNumber() throws {
        #expect(refusal(.controller(64, value: 1), channel: 17) == .invalidChannel(17))
        #expect(refusal(.controller(64, value: 1), channel: 0) == .invalidChannel(0))
    }

    @Test func intakeAnInvalidNumberWinsOverAnOutOfRangeRaw() throws {
        #expect(refusal(.controller(64, value: 200)) == .invalidNumber(64))
        #expect(refusal(.controller14(32, value: 20_000), profile: fourteenBit) == .invalidNumber(32))
        #expect(refusal(.parameter(nrpn(128, 0), value: 20_000), profile: fourteenBit) == .invalidNumber(16_384))
    }

    @Test func intakeAnOutOfRangeRawWinsOverTheLowPartCheck() throws {
        #expect(refusal(.controller14(5, value: 16_385), dialect: .msbOnlySevenBit)
                == .rawOutOfRange(raw: 16_385, maximum: 16_383))
    }

    @Test func intakeAnInvalidNumberWinsOverAWidthMismatch() throws {
        #expect(refusal(.controller(64, value: 1), profile: fourteenBit) == .invalidNumber(64))
        #expect(refusal(.controller14(0, value: 1), profile: sevenBit) == .invalidNumber(0))
    }

    @Test func intakeAnOutOfRangeRawWinsOverAWidthMismatch() throws {
        #expect(refusal(.controller(70, value: 128), profile: fourteenBit)
                == .rawOutOfRange(raw: 128, maximum: 127))
        #expect(refusal(.pitchBend(16_384), profile: sevenBit) == .rawOutOfRange(raw: 16_384, maximum: 16_383))
    }

    @Test func intakeTheLowPartCheckWinsOverAWidthMismatch() throws {
        let profile = EncoderProfile.twosComplement(width: .fourteen)
        #expect(refusal(.controller14(5, value: 16_257), profile: profile, dialect: .msbOnlySevenBit)
                == .lsbPresent(raw: 1))
        #expect(refusal(.controller14(5, value: 16_256), profile: profile, dialect: .msbOnlySevenBit)
                == .widthMismatch(messageBits: 7, profileBits: 14))
    }

    @Test func intakeAWidthMismatchWinsOverAProfileRangeFailure() throws {
        let profile = EncoderProfile.absolute(resolution: 100)
        #expect(refusal(.pitchBend(5_000), profile: profile) == .widthMismatch(messageBits: 14, profileBits: 7))
        #expect(refusal(.controller(70, value: 100), profile: .absolute(resolution: 2))
                == .profileRange(raw: 100, upper: 1))
    }

    @Test func intakeKeyForRunsChecksTwoToSevenOnlyAndNeedsNoProfile() throws {
        #expect(keyRefusal(note, channel: nil) == .noChannel)
        #expect(keyRefusal(note, channel: 0) == .invalidChannel(0))
        #expect(keyRefusal(note) == .notControlInput)
        #expect(keyRefusal(.controller(64, value: 200)) == .invalidNumber(64))
        #expect(keyRefusal(.controller(70, value: 200)) == .rawOutOfRange(raw: 200, maximum: 127))
        let built = try MIDIControlIntake.key(for: message(.controller14(5, value: 16_256)), origin: origin)
        #expect(built.key.kind == .controller14)
        #expect(built.raw == 16_256)
        let narrow = try MIDIControlIntake.key(
            for: message(.controller14(5, value: 16_256)), origin: origin, dialect: .msbOnlySevenBit)
        #expect(narrow.key.kind == .controller)
        #expect(narrow.raw == 127)
    }
}
