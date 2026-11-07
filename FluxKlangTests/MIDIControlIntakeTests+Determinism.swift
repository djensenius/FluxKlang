import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIControlIntakeTests {
    struct IntakeCase {
        let effect: MIDI1StateEffect
        let channel: UInt8?
        let profile: EncoderProfile
        let dialect: ControlIntakeDialect
        let expected: ControlIntakeRefusal?
    }

    private func intakeCase(
        _ effect: MIDI1StateEffect, channel: UInt8? = 16, profile: EncoderProfile,
        dialect: ControlIntakeDialect = .pairedFourteenBit, expected: ControlIntakeRefusal? = nil
    ) -> IntakeCase {
        IntakeCase(effect: effect, channel: channel, profile: profile, dialect: dialect, expected: expected)
    }

    /// Every success and every refusal kind the other files pin, as one table.
    var intakeTable: [IntakeCase] {
        let wide = fourteenBit
        let narrow = sevenBit
        return [
            intakeCase(.controller(70, value: 127), profile: narrow),
            intakeCase(.controller14(5, value: 16_256), profile: wide),
            intakeCase(.controller14(5, value: 16_256), profile: narrow, dialect: .msbOnlySevenBit),
            intakeCase(.parameter(rpn(0, 2), value: 8_192), profile: .binaryOffset(width: .fourteen)),
            intakeCase(.pitchBend(8_192), profile: wide),
            intakeCase(.channelPressure(127), profile: narrow),
            intakeCase(.controller(70, value: 1), profile: wide,
                       expected: .widthMismatch(messageBits: 7, profileBits: 14)),
            intakeCase(.controller(70, value: 100), profile: .absolute(resolution: 100),
                       expected: .profileRange(raw: 100, upper: 99)),
            intakeCase(.controller(70, value: 1), profile: .absolute(resolution: 1),
                       expected: .invalidProfile(resolution: 1)),
            intakeCase(.controller(70, value: 1), channel: nil, profile: narrow, expected: .noChannel),
            intakeCase(.controller(70, value: 1), channel: 17, profile: narrow, expected: .invalidChannel(17)),
            intakeCase(.noteOn(note: 60, velocity: 1), profile: narrow, expected: .notControlInput),
            intakeCase(.controller(64, value: 1), profile: narrow, expected: .invalidNumber(64)),
            intakeCase(.pitchBend(16_384), profile: wide, expected: .rawOutOfRange(raw: 16_384, maximum: 16_383)),
            intakeCase(.controller14(5, value: 16_257), profile: narrow, dialect: .msbOnlySevenBit,
                       expected: .lsbPresent(raw: 1))
        ]
    }

    func run(_ entry: IntakeCase) -> Outcome {
        outcome(entry.effect, channel: entry.channel, profile: entry.profile, dialect: entry.dialect)
    }

    @Test func intakeTheTableResolvesToItsExpectedRefusalOrSuccess() throws {
        let table = intakeTable
        #expect(table.count == 15)
        for entry in table {
            switch run(entry) {
            case .success: #expect(entry.expected == nil)
            case .failure(let error): #expect(entry.expected == error)
            }
        }
        #expect(table.filter { $0.expected == nil }.count == 6)
    }

    @Test func intakeTheWholeTableTwiceAndInReverseGivesEqualResults() throws {
        let table = intakeTable
        let first = table.map(run)
        let second = table.map(run)
        let reversed = table.reversed().map(run).reversed()
        #expect(first == second)
        #expect(first == Array(reversed))
    }

    @Test func intakeARefusalLeavesTheUpdateOriginAndProfileUnchanged() throws {
        for entry in intakeTable where entry.expected != nil {
            let update = message(entry.effect, channel: entry.channel)
            let updateCopy = update
            let originCopy = origin
            let profileCopy = entry.profile
            do {
                _ = try MIDIControlIntake.resolve(
                    update, origin: origin, profile: entry.profile, dialect: entry.dialect)
                Issue.record("expected a refusal for \(entry.effect)")
            } catch {
                #expect(error == entry.expected)
            }
            #expect(update == updateCopy)
            #expect(origin == originCopy)
            #expect(entry.profile == profileCopy)
            #expect(run(entry) == run(entry))
        }
    }

    @Test func intakeTheSameUpdateFromTwoOriginsDiffersOnlyInTheSource() throws {
        let other = try ControlSourceOrigin("lcxl-2")
        for effect in everyControlEffect() {
            let isSevenBit = effect == .controller(70, value: 100) || effect == .channelPressure(64)
            let profile = isSevenBit ? sevenBit : fourteenBit
            let update = message(effect)
            let first = try MIDIControlIntake.resolve(update, origin: origin, profile: profile)
            let second = try MIDIControlIntake.resolve(update, origin: other, profile: profile)
            #expect(first.raw == second.raw)
            #expect(first.input == second.input)
            #expect(first.width == second.width)
            #expect(first.key.kind == second.key.kind)
            #expect(first.key.number == second.key.number)
            #expect(first.source != second.source)
            #expect(first.source.rawValue.replacingOccurrences(of: "lcxl-1", with: "lcxl-2") == second.source.rawValue)
        }
    }

    @Test func intakeEveryRefusalKindIsReachableAndIsAnIntegerOnlyValue() throws {
        let originRefusals: [ControlIntakeRefusal] = [
            originRefusal("") ?? .noChannel, originRefusal("A") ?? .noChannel
        ]
        let seen = Set(intakeTable.compactMap(\.expected) + originRefusals)
        #expect(seen.count == 11)
        #expect(seen.contains(.invalidOrigin(length: 0)))
        #expect(seen.contains(.invalidOriginByte(offset: 0)))
        #expect(!seen.contains(.invalidOriginByte(offset: 1)))
    }
}
