import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIControlIntakeTests {
    struct WidthProfile {
        let profile: EncoderProfile
        let bits: Int
    }

    var widthProfiles: [WidthProfile] {
        [
            WidthProfile(profile: .absolute(resolution: 2), bits: 7),
            WidthProfile(profile: .absolute(resolution: 128), bits: 7),
            WidthProfile(profile: .absolute(resolution: 129), bits: 14),
            WidthProfile(profile: .absolute(resolution: 16_384), bits: 14),
            WidthProfile(profile: .binaryOffset(width: .seven), bits: 7),
            WidthProfile(profile: .binaryOffset(width: .fourteen), bits: 14),
            WidthProfile(profile: .twosComplement(width: .seven), bits: 7),
            WidthProfile(profile: .twosComplement(width: .fourteen), bits: 14),
            WidthProfile(profile: .signMagnitude(width: .seven), bits: 7),
            WidthProfile(profile: .signMagnitude(width: .fourteen), bits: 14)
        ]
    }

    @Test func intakeEveryProfileResolvesOnlyAgainstMessagesOfItsOwnWidth() throws {
        let effects = everyControlEffect().map { effect -> MIDI1StateEffect in
            switch effect {
            case .controller: .controller(70, value: 0)
            case .controller14: .controller14(5, value: 0)
            case .parameter(let number, _): .parameter(number, value: 0)
            case .pitchBend: .pitchBend(0)
            case .channelPressure: .channelPressure(0)
            default: effect
            }
        }
        let messageBits = [7, 14, 14, 14, 14, 7]
        try #require(effects.count == messageBits.count)
        var resolved = 0
        for entry in widthProfiles {
            for (effect, bits) in zip(effects, messageBits) {
                let result = outcome(effect, profile: entry.profile)
                if bits == entry.bits {
                    let value = try #require(try? result.get())
                    #expect(value.width.rawValue == bits)
                    resolved += 1
                } else {
                    #expect(refusal(effect, profile: entry.profile)
                            == .widthMismatch(messageBits: bits, profileBits: entry.bits))
                }
            }
        }
        #expect(resolved == 30)
    }

    @Test func intakeAbsoluteResolution128IsSevenBitAndRefusesFourteenBitMessages() throws {
        let top = try #require(sample(.controller(70, value: 127), profile: .absolute(resolution: 128)))
        #expect(top.input == .absolute(normalized: 1.0))
        #expect(top.width == .seven)
        #expect(refusal(.pitchBend(127), profile: .absolute(resolution: 128))
                == .widthMismatch(messageBits: 14, profileBits: 7))
        #expect(MIDIControlIntake.requiredWidth(of: .absolute(resolution: 128)) == .seven)
    }

    @Test func intakeAbsoluteResolution129IsFourteenBitAndRefusesSevenBitMessages() throws {
        let profile = EncoderProfile.absolute(resolution: 129)
        let resolved = try #require(sample(.pitchBend(128), profile: profile))
        #expect(resolved.input == .absolute(normalized: Double(128) / Double(128)))
        #expect(resolved.width == .fourteen)
        #expect(refusal(.controller(70, value: 1), profile: profile)
                == .widthMismatch(messageBits: 7, profileBits: 14))
        #expect(MIDIControlIntake.requiredWidth(of: profile) == .fourteen)
    }

    @Test func intakeAbsoluteResolutionBelowTheMessageMaximumRefusesTheProfileRange() throws {
        let profile = EncoderProfile.absolute(resolution: 100)
        let top = try #require(sample(.controller(70, value: 99), profile: profile))
        #expect(top.input == .absolute(normalized: 1.0))
        #expect(refusal(.controller(70, value: 100), profile: profile) == .profileRange(raw: 100, upper: 99))
        #expect(refusal(.controller(70, value: 127), profile: profile) == .profileRange(raw: 127, upper: 99))
        #expect(sample(.controller(70, value: 50), profile: profile)?.input == .absolute(normalized: 50.0 / 99.0))
    }

    @Test func intakeProfileResolutionAcceptsTwoAndSixteenThousandThreeHundredEightyFour() throws {
        #expect(sample(.controller(70, value: 1), profile: .absolute(resolution: 2))?.input
                == .absolute(normalized: 1.0))
        #expect(sample(.pitchBend(16_383), profile: .absolute(resolution: 16_384))?.input
                == .absolute(normalized: 1.0))
        for resolution in [1, 0, -1, 16_385, Int.max, Int.min] {
            #expect(refusal(.controller(70, value: 1), profile: .absolute(resolution: resolution))
                    == .invalidProfile(resolution: resolution))
        }
    }

    @Test func intakeMsbOnlyDialectReadsAZeroLowPartAsSevenBitController() throws {
        let resolved = try #require(sample(.controller14(5, value: 16_256), dialect: .msbOnlySevenBit))
        #expect(resolved.key.kind == .controller)
        #expect(resolved.key.number == 5)
        #expect(resolved.raw == 127)
        #expect(resolved.width == .seven)
        #expect(resolved.input == .absolute(normalized: 1.0))
        #expect(resolved.source.rawValue == "midi.lcxl-1.16.cc.5")
        #expect(sample(.controller14(5, value: 0), dialect: .msbOnlySevenBit)?.raw == 0)
        #expect(sample(.controller14(5, value: 128), dialect: .msbOnlySevenBit)?.raw == 1)
        #expect(sample(.controller14(5, value: 8_192), dialect: .msbOnlySevenBit)?.raw == 64)
    }

    @Test func intakeMsbOnlyDialectRefusesAnyNonZeroLowPartWithTheLowBits() throws {
        #expect(refusal(.controller14(5, value: 16_257), dialect: .msbOnlySevenBit) == .lsbPresent(raw: 1))
        #expect(refusal(.controller14(5, value: 127), dialect: .msbOnlySevenBit) == .lsbPresent(raw: 127))
        #expect(refusal(.controller14(5, value: 16_255), dialect: .msbOnlySevenBit) == .lsbPresent(raw: 127))
        #expect(refusal(.controller14(5, value: 8_256), dialect: .msbOnlySevenBit) == .lsbPresent(raw: 64))
        #expect(refusal(.controller14(5, value: 16_383), dialect: .msbOnlySevenBit) == .lsbPresent(raw: 127))
    }

    @Test func intakeMsbOnlyDialectKeepsTheFourteenBitRawBoundBeforeTheLowPartCheck() throws {
        #expect(refusal(.controller14(5, value: 16_384), dialect: .msbOnlySevenBit)
                == .rawOutOfRange(raw: 16_384, maximum: 16_383))
        #expect(refusal(.controller14(5, value: 16_385), dialect: .msbOnlySevenBit)
                == .rawOutOfRange(raw: 16_385, maximum: 16_383))
    }

    @Test func intakeMsbOnlyControllerPairNeedsASevenBitProfile() throws {
        #expect(refusal(.controller14(5, value: 16_256), profile: fourteenBit, dialect: .msbOnlySevenBit)
                == .widthMismatch(messageBits: 7, profileBits: 14))
        #expect(refusal(.controller14(5, value: 16_256), profile: sevenBit, dialect: .pairedFourteenBit)
                == .widthMismatch(messageBits: 14, profileBits: 7))
    }

    @Test func intakeTheDialectOnlyChangesControllerPairs() throws {
        let effects: [MIDI1StateEffect] = [
            .controller(70, value: 100), .parameter(rpn(0, 2), value: 8_192), .parameter(nrpn(1, 2), value: 1),
            .pitchBend(8_192), .channelPressure(64)
        ]
        for effect in effects {
            for profile in [sevenBit, fourteenBit] {
                let paired = outcome(effect, profile: profile, dialect: .pairedFourteenBit)
                let msbOnly = outcome(effect, profile: profile, dialect: .msbOnlySevenBit)
                #expect(paired == msbOnly)
            }
        }
        for effect in everyNonControlEffect() {
            #expect(outcome(effect, dialect: .pairedFourteenBit) == outcome(effect, dialect: .msbOnlySevenBit))
        }
    }
}
