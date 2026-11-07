import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIControlIntakeTests {
    struct RelativeCase {
        let profile: EncoderProfile
        let raw: Int
        let delta: Int
    }

    private func lastUpdate(_ semantics: [MIDI1Semantic]) throws -> MIDI1StateUpdate {
        var state = MIDI1PerformanceState()
        var last: MIDI1StateUpdate?
        for semantic in semantics { last = try state.apply(semantic) }
        return try #require(last)
    }

    @Test func intakeLaunchControlFaderThroughARealStateIsAFourteenBitPairUnlessTheDialectNarrowsIt() throws {
        let update = try performed(channel: 16, controller: 5, value: 127)
        #expect(update == MIDI1StateUpdate(channel: 16, effect: .controller14(5, value: 16_256)))
        let wide = try MIDIControlIntake.resolve(update, origin: origin, profile: fourteenBit)
        #expect(wide.raw == 16_256)
        #expect(wide.input == .absolute(normalized: 16_256.0 / 16_383.0))
        #expect(wide.source.rawValue == "midi.lcxl-1.16.cc14.5")
        #expect(wide.width == .fourteen)
        let narrow = try MIDIControlIntake.resolve(update, origin: origin, profile: sevenBit, dialect: .msbOnlySevenBit)
        #expect(narrow.raw == 127)
        #expect(narrow.input == .absolute(normalized: 1.0))
        #expect(narrow.source.rawValue == "midi.lcxl-1.16.cc.5")
        #expect(narrow.width == .seven)
        let zero = try performed(channel: 16, controller: 5, value: 0)
        let low = try MIDIControlIntake.resolve(zero, origin: origin, profile: sevenBit, dialect: .msbOnlySevenBit)
        #expect(low.input == .absolute(normalized: 0.0))
        #expect(low.raw == 0)
    }

    @Test func intakeLaunchControlPanThroughARealStateReadsHalfScaleAsSixtyFourOverOneTwentySeven() throws {
        let update = try performed(channel: 16, controller: 13, value: 64)
        #expect(update.effect == .controller14(13, value: 8_192))
        let narrow = try MIDIControlIntake.resolve(update, origin: origin, profile: sevenBit, dialect: .msbOnlySevenBit)
        #expect(narrow.raw == 64)
        #expect(narrow.input == .absolute(normalized: 64.0 / 127.0))
        #expect(narrow.source.rawValue == "midi.lcxl-1.16.cc.13")
    }

    @Test func intakeEveryLaunchControlFaderAndPanResolvesToItsOwnSevenBitSource() throws {
        var identifiers: [String] = []
        for number in LaunchControl.faders.lowerBound...LaunchControl.pans.upperBound where number != 6 {
            let update = try performed(channel: LaunchControl.channel, controller: number, value: 100)
            let resolved = try MIDIControlIntake.resolve(
                update, origin: origin, profile: sevenBit, dialect: .msbOnlySevenBit)
            #expect(resolved.raw == 100)
            identifiers.append(resolved.source.rawValue)
        }
        #expect(identifiers.count == 15)
        #expect(identifiers.first == "midi.lcxl-1.16.cc.5")
        #expect(identifiers.last == "midi.lcxl-1.16.cc.20")
        #expect(Set(identifiers).count == 15)
    }

    /// CC 6 and CC 38 are Data Entry MSB/LSB, which the performance state treats as parameter data, so a real state
    /// without a selected parameter refuses them before intake sees anything (a finding the lane sheet did not list).
    @Test func intakeLaunchControlNumbersSixAndThirtyEightNeverReachIntakeFromAFreshState() throws {
        for number: UInt8 in [6, 38] {
            var state = MIDI1PerformanceState()
            #expect(throws: MIDI1StateRefusal.noParameterSelected(channel: 16, controller: number)) {
                try state.apply(.controlChange(channel: 16, controller: number, value: 127))
            }
        }
    }

    @Test func intakeLaunchControlSelectAndMuteCCsArriveAsLowPartsOfThePairedControllers() throws {
        for number in Array(LaunchControl.selects) + Array(LaunchControl.mutes) where number != 38 {
            let update = try performed(channel: LaunchControl.channel, controller: number, value: 127)
            // A fresh state already holds default MSBs (CC 7, 10 and 11), so the pair value is not always 127.
            guard case .controller14(let msb, let combined) = update.effect else {
                Issue.record("expected a controller pair for CC \(number)")
                continue
            }
            #expect(msb == number - 32)
            #expect(combined & 127 == 127)
            #expect(refusal(update.effect, dialect: .msbOnlySevenBit) == .lsbPresent(raw: 127))
            let wide = try #require(sample(update.effect, profile: fourteenBit))
            #expect(wide.key.kind == .controller14)
            #expect(wide.key.number == UInt16(number - 32))
            #expect(wide.raw == Int(combined))
        }
        let mute = try performed(channel: 16, controller: 45, value: 127)
        #expect(mute.effect == .controller14(13, value: 127))
    }

    @Test func intakeLaunchControlBankButtonsAreSevenBitControllersOnChannelSixteen() throws {
        for (number, expected) in [(LaunchControl.bankNext, "cc.102"), (LaunchControl.bankPrevious, "cc.103")] {
            let update = try performed(channel: 16, controller: number, value: 127)
            #expect(update.effect == .controller(number, value: 127))
            for dialect in ControlIntakeDialect.allCases {
                let resolved = try MIDIControlIntake.resolve(
                    update, origin: origin, profile: sevenBit, dialect: dialect)
                #expect(resolved.source.rawValue == "midi.lcxl-1.16." + expected)
                #expect(resolved.raw == 127)
                #expect(resolved.input == .absolute(normalized: 1.0))
            }
        }
    }

    @Test func intakePitchBendAndChannelPressureThroughARealState() throws {
        var state = MIDI1PerformanceState()
        let bend = try state.apply(.pitchBend(channel: 16, value: 8_192))
        let bendSample = try MIDIControlIntake.resolve(bend, origin: origin, profile: fourteenBit)
        #expect(bendSample.input == .absolute(normalized: 8_192.0 / 16_383.0))
        #expect(bendSample.source.rawValue == "midi.lcxl-1.16.bend.0")
        let pressure = try state.apply(.channelPressure(channel: 16, pressure: 127))
        let pressureSample = try MIDIControlIntake.resolve(pressure, origin: origin, profile: sevenBit)
        #expect(pressureSample.raw == 127)
        #expect(pressureSample.input == .absolute(normalized: 1.0))
        #expect(pressureSample.source.rawValue == "midi.lcxl-1.16.press.0")
    }

    @Test func intakeANonRegisteredParameterAtHalfScaleIsARelativeZeroForBinaryOffset() throws {
        let update = try lastUpdate([
            .controlChange(channel: 16, controller: 99, value: 1),
            .controlChange(channel: 16, controller: 98, value: 2),
            .controlChange(channel: 16, controller: 6, value: 64)
        ])
        #expect(update.effect == .parameter(nrpn(1, 2), value: 8_192))
        let resolved = try MIDIControlIntake.resolve(update, origin: origin, profile: .binaryOffset(width: .fourteen))
        #expect(resolved.input == .relative(delta: 0))
        #expect(resolved.source.rawValue == "midi.lcxl-1.16.nrpn.130")
    }

    @Test func intakeARegisteredParameterThroughARealStateKeepsItsKind() throws {
        let update = try lastUpdate([
            .controlChange(channel: 3, controller: 101, value: 0),
            .controlChange(channel: 3, controller: 100, value: 2),
            .controlChange(channel: 3, controller: 6, value: 1)
        ])
        let resolved = try MIDIControlIntake.resolve(update, origin: origin, profile: fourteenBit)
        #expect(resolved.source.rawValue == "midi.lcxl-1.3.rpn.2")
        #expect(resolved.raw == 128)
    }

    @Test func intakeRelativeProfilesDecodeExactlyLikeTheProfileAtTheBoundaryRaws() throws {
        func item(_ profile: EncoderProfile, _ raw: Int, _ delta: Int) -> RelativeCase {
            RelativeCase(profile: profile, raw: raw, delta: delta)
        }
        let twos7 = EncoderProfile.twosComplement(width: .seven)
        let binary7 = EncoderProfile.binaryOffset(width: .seven)
        let sign7 = EncoderProfile.signMagnitude(width: .seven)
        let sevenBitCases = [
            item(twos7, 127, -1), item(twos7, 1, 1), item(twos7, 0, 0), item(twos7, 64, -64),
            item(binary7, 65, 1), item(binary7, 63, -1), item(binary7, 64, 0),
            item(sign7, 65, -1), item(sign7, 1, 1), item(sign7, 64, 0)
        ]
        for entry in sevenBitCases {
            let resolved = try #require(sample(.controller(70, value: UInt8(entry.raw)), profile: entry.profile))
            #expect(resolved.input == .relative(delta: entry.delta))
            #expect(resolved.input == (try entry.profile.decode(raw: entry.raw)))
        }
        let twos14 = EncoderProfile.twosComplement(width: .fourteen)
        let binary14 = EncoderProfile.binaryOffset(width: .fourteen)
        let sign14 = EncoderProfile.signMagnitude(width: .fourteen)
        let fourteenBitCases = [
            item(twos14, 16_383, -1), item(twos14, 1, 1), item(binary14, 8_193, 1),
            item(binary14, 8_191, -1), item(sign14, 8_193, -1), item(sign14, 1, 1)
        ]
        for entry in fourteenBitCases {
            let resolved = try #require(sample(.pitchBend(UInt16(entry.raw)), profile: entry.profile))
            #expect(resolved.input == .relative(delta: entry.delta))
            #expect(resolved.input == (try entry.profile.decode(raw: entry.raw)))
        }
    }

    @Test func intakeAnAbsoluteSampleCarriesEveryFieldOfItsKey() throws {
        let resolved = try #require(sample(.controller14(5, value: 16_256), profile: fourteenBit))
        let expected = ControlIntakeSample(
            key: try key(.controller14, channel: 16, number: 5), raw: 16_256, width: .fourteen,
            input: .absolute(normalized: 16_256.0 / 16_383.0))
        #expect(resolved == expected)
        #expect(resolved.source == ControlSourceID(validated: "midi.lcxl-1.16.cc14.5"))
    }

    @Test func intakeTheLaunchControlNumbersAreTheRuledOnes() throws {
        #expect(LaunchControl.channel == 16)
        #expect(Array(LaunchControl.faders) == Array(5...12))
        #expect(Array(LaunchControl.pans) == Array(13...20))
        #expect(Array(LaunchControl.selects) == Array(37...44))
        #expect(Array(LaunchControl.mutes) == Array(45...52))
        #expect(LaunchControl.bankPrevious == 103)
        #expect(LaunchControl.bankNext == 102)
    }
}
