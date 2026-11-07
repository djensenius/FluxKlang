import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIControlIntakeTests {
    func originRefusal(_ token: String) -> ControlIntakeRefusal? {
        do {
            _ = try ControlSourceOrigin(token)
            return nil
        } catch {
            return error
        }
    }

    func keyError(channel: UInt8, kind: ControlSourceKind, number: UInt16) -> ControlIntakeRefusal? {
        do {
            _ = try ControlSourceKey(origin: origin, channel: channel, kind: kind, number: number)
            return nil
        } catch {
            return error
        }
    }

    @Test func intakeOriginLengthAcceptsOneAndThirtyTwoAndRefusesZeroAndThirtyThree() throws {
        #expect(try ControlSourceOrigin("a").token == "a")
        #expect(try ControlSourceOrigin(String(repeating: "b", count: 32)).token.utf8.count == 32)
        #expect(originRefusal("") == .invalidOrigin(length: 0))
        #expect(originRefusal(String(repeating: "b", count: 33)) == .invalidOrigin(length: 33))
    }

    @Test func intakeOriginRefusesTheFirstBadByteAtItsUtf8Offset() throws {
        #expect(originRefusal("A") == .invalidOriginByte(offset: 0))
        #expect(originRefusal("a_b") == .invalidOriginByte(offset: 1))
        #expect(originRefusal("ab.c") == .invalidOriginByte(offset: 2))
        #expect(originRefusal("a c") == .invalidOriginByte(offset: 1))
        #expect(originRefusal("aé") == .invalidOriginByte(offset: 1))
        #expect(originRefusal("éa") == .invalidOriginByte(offset: 0))
        #expect(originRefusal("ab/cd:ef") == .invalidOriginByte(offset: 2))
        #expect(originRefusal("a`") == .invalidOriginByte(offset: 1))
        #expect(originRefusal("a{") == .invalidOriginByte(offset: 1))
        #expect(originRefusal("a@") == .invalidOriginByte(offset: 1))
        #expect(originRefusal("a[") == .invalidOriginByte(offset: 1))
        #expect(originRefusal("a/") == .invalidOriginByte(offset: 1))
        #expect(originRefusal("a:") == .invalidOriginByte(offset: 1))
        #expect(originRefusal("A.b.C") == .invalidOriginByte(offset: 0))
    }

    @Test func intakeOriginLengthIsCheckedBeforeTheBytes() throws {
        #expect(originRefusal("A" + String(repeating: "b", count: 32)) == .invalidOrigin(length: 33))
        #expect(originRefusal(String(repeating: "é", count: 17)) == .invalidOrigin(length: 34))
        #expect(originRefusal(String(repeating: "é", count: 16)) == .invalidOriginByte(offset: 0))
    }

    @Test func intakeOriginAcceptsEveryByteOfItsCharset() throws {
        let letters = "abcdefghijklmnopqrstuvwxyz"
        let digits = "0123456789"
        for character in letters + digits + "-" {
            #expect(originRefusal(String(character)) == nil)
        }
        #expect(try ControlSourceOrigin(digits + "-" + letters.prefix(21)).token.utf8.count == 32)
        #expect(try ControlSourceOrigin(String(letters.suffix(21)) + digits + "-").token.utf8.count == 32)
    }

    @Test func intakeOriginsCompareByUtf8Bytes() throws {
        let ordered = try ["", "9", "a", "a-", "a0", "a9", "aa", "b"].dropFirst().map { try ControlSourceOrigin($0) }
        for (low, high) in zip(ordered, ordered.dropFirst()) {
            #expect(low < high)
            #expect(!(high < low))
        }
        #expect(try ControlSourceOrigin("lcxl-1") == ControlSourceOrigin("lcxl-1"))
        #expect(try ControlSourceOrigin("lcxl-1") != ControlSourceOrigin("lcxl-2"))
    }

    @Test func intakeKeyChannelAcceptsOneAndSixteenAndRefusesZeroAndSeventeen() throws {
        #expect(keyError(channel: 1, kind: .controller, number: 0) == nil)
        #expect(keyError(channel: 16, kind: .controller, number: 0) == nil)
        #expect(keyError(channel: 0, kind: .controller, number: 0) == .invalidChannel(0))
        #expect(keyError(channel: 17, kind: .controller, number: 0) == .invalidChannel(17))
        #expect(keyError(channel: 255, kind: .controller, number: 0) == .invalidChannel(255))
    }

    @Test func intakeKeyNumberAcceptsItsLowestAndHighestAndRefusesOneBeyondPerKind() throws {
        let limits: [ControlSourceKind: (low: UInt16, high: UInt16)] = [
            .controller: (0, 127), .controller14: (1, 31), .registeredParameter: (0, 16_383),
            .nonRegisteredParameter: (0, 16_383), .pitchBend: (0, 0), .channelPressure: (0, 0)
        ]
        #expect(limits.count == ControlSourceKind.allCases.count)
        for kind in ControlSourceKind.allCases {
            let range = try #require(limits[kind])
            #expect(kind.numberRange == range.low...range.high)
            #expect(keyError(channel: 1, kind: kind, number: range.low) == nil)
            #expect(keyError(channel: 1, kind: kind, number: range.high) == nil)
            #expect(keyError(channel: 1, kind: kind, number: range.high + 1) == .invalidNumber(Int(range.high) + 1))
            if range.low > 0 {
                #expect(keyError(channel: 1, kind: kind, number: range.low - 1) == .invalidNumber(Int(range.low) - 1))
            }
        }
        #expect(keyError(channel: 1, kind: .controller, number: UInt16.max) == .invalidNumber(65_535))
    }

    @Test func intakeKindWidthIsSevenForControllerAndPressureAndFourteenForTheRest() throws {
        #expect(ControlSourceKind.controller.width == .seven)
        #expect(ControlSourceKind.channelPressure.width == .seven)
        #expect(ControlSourceKind.controller14.width == .fourteen)
        #expect(ControlSourceKind.registeredParameter.width == .fourteen)
        #expect(ControlSourceKind.nonRegisteredParameter.width == .fourteen)
        #expect(ControlSourceKind.pitchBend.width == .fourteen)
    }

    @Test func intakeKindRawValuesAndOrderAreStable() throws {
        let raws = ControlSourceKind.allCases.map(\.rawValue)
        #expect(raws == ["cc", "cc14", "rpn", "nrpn", "bend", "press"])
        let kinds = ControlSourceKind.allCases
        for (low, high) in zip(kinds, kinds.dropFirst()) {
            #expect(low < high)
            #expect(!(high < low))
        }
        #expect(ControlIntakeDialect.allCases.map(\.rawValue) == ["paired14", "msb7"])
    }

    @Test func intakeKeyChecksTheChannelBeforeTheNumber() throws {
        #expect(keyError(channel: 0, kind: .controller, number: 128) == .invalidChannel(0))
        #expect(keyError(channel: 17, kind: .pitchBend, number: 1) == .invalidChannel(17))
    }

    @Test func intakeKeySourceIDsHaveTheExactText() throws {
        #expect(try key(.controller14, channel: 16, number: 5).sourceID.rawValue == "midi.lcxl-1.16.cc14.5")
        #expect(try key(.controller, channel: 16, number: 102).sourceID.rawValue == "midi.lcxl-1.16.cc.102")
        #expect(try key(.registeredParameter, channel: 1, number: 2).sourceID.rawValue == "midi.lcxl-1.1.rpn.2")
        #expect(try key(.nonRegisteredParameter, channel: 9, number: 16_383).sourceID.rawValue
                == "midi.lcxl-1.9.nrpn.16383")
        #expect(try key(.pitchBend, channel: 3).sourceID.rawValue == "midi.lcxl-1.3.bend.0")
        #expect(try key(.channelPressure, channel: 12).sourceID.rawValue == "midi.lcxl-1.12.press.0")
        let short = try ControlSourceKey(origin: ControlSourceOrigin("a"), channel: 9, kind: .pitchBend, number: 0)
        #expect(short.sourceID.rawValue == "midi.a.9.bend.0")
        #expect(short.sourceID == ControlSourceID(validated: "midi.a.9.bend.0"))
    }

    @Test func intakeLongestSourceIDIsFiftyOneBytesWellBelowTheContractIDLimit() throws {
        let longest = try ControlSourceKey(
            origin: ControlSourceOrigin(String(repeating: "z", count: 32)), channel: 16,
            kind: .nonRegisteredParameter, number: 16_383)
        #expect(longest.sourceID.rawValue.utf8.count == 51)
        var maximum = 0
        for kind in ControlSourceKind.allCases {
            let top = try ControlSourceKey(
                origin: ControlSourceOrigin(String(repeating: "z", count: 32)), channel: 16,
                kind: kind, number: kind.numberRange.upperBound)
            maximum = max(maximum, top.sourceID.rawValue.utf8.count)
        }
        #expect(maximum == 51)
        #expect(maximum < ControlSourceID.maximumLength)
    }

    @Test func intakeKeyKeepsItsFieldsAndRoundTripsThroughItsSourceID() throws {
        let built = try key(.controller14, channel: 16, number: 5)
        #expect(built.origin == origin)
        #expect(built.channel == 16)
        #expect(built.kind == .controller14)
        #expect(built.number == 5)
        #expect(ControlSourceID(rawValue: built.sourceID.rawValue) == built.sourceID)
    }

    @Test func intakeKeySourceIDsArePairwiseDistinctAcrossKindsChannelsAndBoundaryNumbers() throws {
        var identifiers: [ControlSourceID] = []
        for kind in ControlSourceKind.allCases {
            for channel: UInt8 in [1, 16] {
                for number in Set([kind.numberRange.lowerBound, kind.numberRange.upperBound]).sorted() {
                    identifiers.append(try key(kind, channel: channel, number: number).sourceID)
                }
            }
        }
        // Per kind and channel: controller 2, controller14 2, rpn 2, nrpn 2, bend 1, press 1 numbers; times 2 channels.
        #expect(identifiers.count == 20)
        #expect(Set(identifiers).count == 20)
        #expect(try key(.registeredParameter, number: 2).sourceID != key(.nonRegisteredParameter, number: 2).sourceID)
        let other = try ControlSourceOrigin("lcxl-2")
        let moved = try ControlSourceKey(origin: other, channel: 1, kind: .controller, number: 0)
        #expect(moved.sourceID != (try key(.controller)).sourceID)
    }

    @Test func intakeKeysOrderByOriginThenChannelThenKindThenNumber() throws {
        let low = try ControlSourceOrigin("a")
        let high = try ControlSourceOrigin("b")
        let ascending = try [
            ControlSourceKey(origin: low, channel: 16, kind: .channelPressure, number: 0),
            ControlSourceKey(origin: high, channel: 1, kind: .controller, number: 0),
            ControlSourceKey(origin: high, channel: 1, kind: .channelPressure, number: 0),
            ControlSourceKey(origin: high, channel: 2, kind: .controller, number: 0),
            ControlSourceKey(origin: high, channel: 2, kind: .controller14, number: 1),
            ControlSourceKey(origin: high, channel: 2, kind: .controller14, number: 2)
        ]
        for (first, second) in zip(ascending, ascending.dropFirst()) {
            #expect(first < second)
            #expect(!(second < first))
        }
        try #require(ascending.count == 6)
        let shuffled = [ascending[3], ascending[0], ascending[4], ascending[2], ascending[1], ascending[5]]
        #expect(shuffled.sorted() == ascending)
        #expect(try ControlSourceKey(origin: low, channel: 1, kind: .controller, number: 5)
                == ControlSourceKey(origin: low, channel: 1, kind: .controller, number: 5))
    }
}
