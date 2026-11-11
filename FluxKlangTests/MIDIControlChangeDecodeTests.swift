import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// `MIDIControlChange.decode(_:)` on the MIDI 1 parser (#80, slice LD1). This file holds the basic contract and the
/// size bounds; `+Legacy` holds the frozen old decoder and the before/after tables, `+RealTime` the F8...FF cases and
/// `+Fragments` truncation, non-CC skipping, running status and SysEx.
#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct MIDIControlChangeDecodeTests {
    static func cc(_ channel: Int, _ controller: UInt8, _ value: UInt8) -> MIDIControlChange {
        MIDIControlChange(channel: channel, controller: controller, value: value)
    }

    /// Unit `index` is a complete three-byte CC whose channel, controller and value all depend on the index.
    static func unit(_ index: Int) -> [UInt8] {
        [0xB0 | UInt8(index & 0x0F), UInt8(index & 0x7F), UInt8((index >> 7) & 0x7F)]
    }

    @Test func ccDecodeKeepsTheLaunchControlXLRunningStatusFixture() {
        #expect(MIDIControlChange.decode([0xBF, 5, 127, 6, 64]) == [Self.cc(16, 5, 127), Self.cc(16, 6, 64)])
    }

    @Test func ccDecodeOfEmptyInputIsEmptyAndEverySingleByteYieldsNothing() {
        #expect(MIDIControlChange.decode([]).isEmpty)
        for byte in UInt8.min...UInt8.max {
            #expect(MIDIControlChange.decode([byte]).isEmpty, "byte \(byte)")
        }
    }

    @Test func ccDecodeReadsChannelsOneAndSixteenAndTheControllerAndValueExtremes() {
        #expect(MIDIControlChange.decode([0xB0, 0, 0]) == [Self.cc(1, 0, 0)])
        #expect(MIDIControlChange.decode([0xB0, 127, 127]) == [Self.cc(1, 127, 127)])
        #expect(MIDIControlChange.decode([0xBF, 0, 127]) == [Self.cc(16, 0, 127)])
        #expect(MIDIControlChange.decode([0xBF, 127, 0]) == [Self.cc(16, 127, 0)])
    }

    @Test func ccDecodeMapsEveryStatusNibbleToTheOneBasedChannel() {
        for channel in 0..<16 {
            let status = UInt8(0xB0 + channel)
            #expect(MIDIControlChange.decode([status, 9, 10]) == [Self.cc(channel + 1, 9, 10)])
        }
    }

    @Test func ccDecodeOnlyAcceptsTheControlChangeStatusNibble() {
        for status in [UInt8(0xAF), 0xC0] {
            #expect(MIDIControlChange.decode([status, 5, 7]).isEmpty, "status \(status)")
        }
        #expect(MIDIControlChange.decode([0xB0, 5, 7]) == [Self.cc(1, 5, 7)])
        #expect(MIDIControlChange.decode([0xBF, 5, 7]) == [Self.cc(16, 5, 7)])
        for status in UInt8(0x80)...UInt8(0xEF) where status & 0xF0 != 0xB0 {
            #expect(MIDIControlChange.decode([status, 5, 7, 5, 7]).isEmpty, "status \(status)")
        }
    }

    @Test func ccDecodeAcceptsDataByte7FAndAnyHighBitByteStartsANewStatus() {
        #expect(MIDIControlChange.decode([0xB0, 0x7F, 0x7F]) == [Self.cc(1, 0x7F, 0x7F)])
        #expect(MIDIControlChange.decode([0xB0, 0x05, 0x80]).isEmpty)
        #expect(MIDIControlChange.decode([0xB0, 0x80, 0x05, 0x06]).isEmpty)
        #expect(MIDIControlChange.decode([0xB0, 0x05, 0xB1, 0x06, 0x07]) == [Self.cc(2, 6, 7)])
        #expect(MIDIControlChange.decode([0xB0, 0xB1, 0x06, 0x07]) == [Self.cc(2, 6, 7)])
    }

    @Test func ccDecodeReturnsTheSameWholeResultOnEveryCall() {
        let inputs: [[UInt8]] = [
            [], [0xB0], [0xBF, 5, 127, 6, 64], [0xB0, 5, 0xF8, 7, 0x90, 1, 2, 0xB1, 3, 4],
            [0xF0, 0xB0, 5, 7], [0xB0, 5, 7, 0xF0, 6, 7]
        ]
        for input in inputs {
            let first = MIDIControlChange.decode(input)
            let second = MIDIControlChange.decode(input)
            #expect(first == second)
        }
        #expect(MIDIControlChange.decode([0xB0, 5, 7, 0xF0, 6, 7]) == [Self.cc(1, 5, 7)])
    }

    @Test func ccDecodeReturnsMessagesInInputByteOrderAcrossChannels() {
        let input: [UInt8] = [0xB2, 9, 1, 0xB0, 8, 2, 7, 3, 0xBF, 6, 4]
        #expect(MIDIControlChange.decode(input) == [
            Self.cc(3, 9, 1), Self.cc(1, 8, 2), Self.cc(1, 7, 3), Self.cc(16, 6, 4)
        ])
    }

    @Test func ccDecodeHandlesSixtyFiveThousandFiveHundredThirtySixBytesOfThreeByteUnits() throws {
        let units = 21_845
        var input: [UInt8] = []
        for index in 0..<units { input.append(contentsOf: Self.unit(index)) }
        input.append(0x00)
        #expect(input.count == 65_536)
        let result = MIDIControlChange.decode(input)
        #expect(result.count == 21_845)
        for index in [0, 1, 127, 128, 16_383, 16_384, units - 1] {
            let message = try #require(result.indices.contains(index) ? result[index] : nil)
            let bytes = Self.unit(index)
            #expect(message == Self.cc(Int(bytes[0] & 0x0F) + 1, bytes[1], bytes[2]), "unit \(index)")
        }
    }

    @Test func ccDecodeHandlesSixtyFiveThousandFiveHundredThirtySevenBytesWithoutTrapping() throws {
        var input: [UInt8] = []
        for index in 0..<21_845 { input.append(contentsOf: Self.unit(index)) }
        input.append(contentsOf: [0x11, 0x22])
        #expect(input.count == 65_537)
        let result = MIDIControlChange.decode(input)
        #expect(result.count == 21_846)
        let last = try #require(result.last)
        #expect(last == Self.cc(Int(Self.unit(21_844)[0] & 0x0F) + 1, 0x11, 0x22))
    }

    @Test func ccDecodeReadsALongRunningStatusRunOfDataPairs() throws {
        var input: [UInt8] = [0xB5]
        for index in 0..<32_767 { input.append(contentsOf: [UInt8(index & 0x7F), UInt8((index >> 7) & 0x7F)]) }
        input.append(0x01)
        #expect(input.count == 65_536)
        let result = MIDIControlChange.decode(input)
        #expect(result.count == 32_767)
        #expect(result.allSatisfy { $0.channel == 6 })
        let last = try #require(result.last)
        #expect(last == Self.cc(6, UInt8(32_766 & 0x7F), UInt8((32_766 >> 7) & 0x7F)))
    }
}
