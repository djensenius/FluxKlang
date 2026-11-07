import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIControlIntakeTests {
    @Test func intakeSevenBitControllerRawAcceptsZeroAndMaximumAndRefusesOneBeyond() throws {
        #expect(sample(.controller(70, value: 0))?.raw == 0)
        let top = try #require(sample(.controller(70, value: 127)))
        #expect(top.raw == 127)
        #expect(top.input == .absolute(normalized: 1.0))
        #expect(refusal(.controller(70, value: 128)) == .rawOutOfRange(raw: 128, maximum: 127))
        #expect(refusal(.controller(70, value: UInt8.max)) == .rawOutOfRange(raw: 255, maximum: 127))
    }

    @Test func intakeFourteenBitControllerRawAcceptsZeroAndMaximumAndRefusesOneBeyond() throws {
        #expect(sample(.controller14(5, value: 0), profile: fourteenBit)?.raw == 0)
        let top = try #require(sample(.controller14(5, value: 16_383), profile: fourteenBit))
        #expect(top.raw == 16_383)
        #expect(top.input == .absolute(normalized: 1.0))
        #expect(refusal(.controller14(5, value: 16_384), profile: fourteenBit)
                == .rawOutOfRange(raw: 16_384, maximum: 16_383))
        #expect(refusal(.controller14(5, value: UInt16.max), profile: fourteenBit)
                == .rawOutOfRange(raw: 65_535, maximum: 16_383))
    }

    @Test func intakeParameterRawAcceptsZeroAndMaximumAndRefusesOneBeyond() throws {
        for parameter in [rpn(0, 2), nrpn(1, 2)] {
            #expect(sample(.parameter(parameter, value: 0), profile: fourteenBit)?.raw == 0)
            #expect(sample(.parameter(parameter, value: 16_383), profile: fourteenBit)?.raw == 16_383)
            #expect(refusal(.parameter(parameter, value: 16_384), profile: fourteenBit)
                    == .rawOutOfRange(raw: 16_384, maximum: 16_383))
            #expect(refusal(.parameter(parameter, value: UInt16.max), profile: fourteenBit)
                    == .rawOutOfRange(raw: 65_535, maximum: 16_383))
        }
    }

    @Test func intakePitchBendRawAcceptsZeroAndMaximumAndRefusesOneBeyond() throws {
        #expect(sample(.pitchBend(0), profile: fourteenBit)?.raw == 0)
        #expect(sample(.pitchBend(16_383), profile: fourteenBit)?.raw == 16_383)
        #expect(refusal(.pitchBend(16_384), profile: fourteenBit) == .rawOutOfRange(raw: 16_384, maximum: 16_383))
        #expect(refusal(.pitchBend(UInt16.max), profile: fourteenBit) == .rawOutOfRange(raw: 65_535, maximum: 16_383))
    }

    @Test func intakeChannelPressureRawAcceptsZeroAndMaximumAndRefusesOneBeyond() throws {
        #expect(sample(.channelPressure(0))?.raw == 0)
        #expect(sample(.channelPressure(127))?.raw == 127)
        #expect(refusal(.channelPressure(128)) == .rawOutOfRange(raw: 128, maximum: 127))
        #expect(refusal(.channelPressure(UInt8.max)) == .rawOutOfRange(raw: 255, maximum: 127))
    }

    @Test func intakeOnlyTheReachableControllerNumbersAreControlInput() throws {
        for number: UInt8 in [65, 66, 94, 95, 102, 103, 118, 119] {
            let resolved = try #require(sample(.controller(number, value: 1)))
            #expect(resolved.key.kind == .controller)
            #expect(resolved.key.number == UInt16(number))
        }
        for number: UInt8 in [0, 1, 7, 31, 32, 33, 63, 64, 96, 97, 100, 101, 120, 127, 128, 200, 255] {
            #expect(refusal(.controller(number, value: 1)) == .invalidNumber(Int(number)))
        }
        #expect(ControlIntakeBounds.reachableControllerRanges == [65...95, 102...119])
    }

    @Test func intakePairedControllerNumbersAcceptOneAndThirtyOneAndRefuseZeroAndThirtyTwo() throws {
        #expect(sample(.controller14(1, value: 0), profile: fourteenBit)?.key.number == 1)
        #expect(sample(.controller14(31, value: 0), profile: fourteenBit)?.key.number == 31)
        #expect(refusal(.controller14(0, value: 0), profile: fourteenBit) == .invalidNumber(0))
        #expect(refusal(.controller14(32, value: 0), profile: fourteenBit) == .invalidNumber(32))
        #expect(refusal(.controller14(UInt8.max, value: 0), profile: fourteenBit) == .invalidNumber(255))
    }

    @Test func intakeParameterBytesAcceptOneHundredTwentySevenAndRefuseOneHundredTwentyEight() throws {
        let corner = try #require(sample(.parameter(nrpn(127, 127), value: 0), profile: fourteenBit))
        #expect(corner.key.number == 16_383)
        #expect(sample(.parameter(rpn(127, 0), value: 0), profile: fourteenBit)?.key.number == 16_256)
        #expect(sample(.parameter(rpn(0, 127), value: 0), profile: fourteenBit)?.key.number == 127)
        #expect(refusal(.parameter(nrpn(128, 0), value: 0), profile: fourteenBit) == .invalidNumber(16_384))
        #expect(refusal(.parameter(nrpn(0, 128), value: 0), profile: fourteenBit) == .invalidNumber(128))
        #expect(refusal(.parameter(rpn(1, 128), value: 0), profile: fourteenBit) == .invalidNumber(256))
        #expect(refusal(.parameter(rpn(255, 255), value: 0), profile: fourteenBit) == .invalidNumber(32_895))
    }

    @Test func intakeParameterNumberIsMsbTimesOneHundredTwentyEightPlusLsb() throws {
        let cases: [(MIDI1ParameterNumber, UInt16)] = [
            (nrpn(1, 2), 130), (rpn(0, 2), 2), (nrpn(2, 1), 257), (rpn(100, 100), 12_900), (nrpn(0, 0), 0)
        ]
        for (parameter, number) in cases {
            let resolved = try #require(sample(.parameter(parameter, value: 7), profile: fourteenBit))
            #expect(resolved.key.number == number)
        }
    }

    @Test func intakeRegisteredAndNonRegisteredParametersKeepTheirKind() throws {
        let registered = try #require(sample(.parameter(rpn(0, 2), value: 1), profile: fourteenBit))
        let nonRegistered = try #require(sample(.parameter(nrpn(0, 2), value: 1), profile: fourteenBit))
        #expect(registered.key.kind == .registeredParameter)
        #expect(nonRegistered.key.kind == .nonRegisteredParameter)
        #expect(registered.source.rawValue == "midi.lcxl-1.16.rpn.2")
        #expect(nonRegistered.source.rawValue == "midi.lcxl-1.16.nrpn.2")
        #expect(registered.source != nonRegistered.source)
    }

    @Test func intakeMsbOnlyControllerPairRawBoundsAreFourteenBitInBothDialects() throws {
        #expect(sample(.controller14(5, value: 16_256), dialect: .msbOnlySevenBit)?.raw == 127)
        #expect(refusal(.controller14(5, value: 16_384), dialect: .msbOnlySevenBit)
                == .rawOutOfRange(raw: 16_384, maximum: 16_383))
        #expect(refusal(.controller14(5, value: 16_384), profile: fourteenBit)
                == .rawOutOfRange(raw: 16_384, maximum: 16_383))
    }

    @Test func intakeBoundsHoldTheRuledConstantsInOnePlace() throws {
        #expect(ControlIntakeBounds.originByteRange == 1...32)
        #expect(ControlIntakeBounds.channelRange == 1...16)
        #expect(ControlIntakeBounds.sevenBitMaximum == 127)
        #expect(ControlIntakeBounds.fourteenBitMaximum == 16_383)
        #expect(ControlIntakeBounds.pairedControllerRange == 1...31)
        #expect(ControlIntakeBounds.plainControllerRange == 0...127)
        #expect(ControlIntakeBounds.parameterByteMaximum == 127)
        #expect(ControlIntakeBounds.sourceIDPrefix == "midi.")
        #expect(ControlIntakeBounds.parameterNumberRange == 0...16_383)
        #expect(ControlIntakeBounds.singletonNumberRange == 0...0)
        #expect(ControlIntakeBounds.maximum(for: .seven) == 127)
        #expect(ControlIntakeBounds.maximum(for: .fourteen) == 16_383)
    }
}
