import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private let realTimeBytes: [UInt8] = Array(0xF8...0xFF)

extension MIDIControlChangeDecodeTests {
    private static func inserting(_ byte: UInt8, at position: Int, into bytes: [UInt8]) -> [UInt8] {
        var copy = bytes
        copy.insert(byte, at: position)
        return copy
    }

    @Test func ccDecodeIgnoresEveryRealTimeByteAtEveryPositionOfARunningStatusInput() {
        let clean: [UInt8] = [0xBF, 5, 127, 6, 64]
        let expected = [Self.cc(16, 5, 127), Self.cc(16, 6, 64)]
        #expect(MIDIControlChange.decode(clean) == expected)
        var cases = 0
        for position in 0...clean.count {
            for byte in realTimeBytes {
                let input = Self.inserting(byte, at: position, into: clean)
                #expect(MIDIControlChange.decode(input) == expected, "byte \(byte) at \(position)")
                cases += 1
            }
        }
        #expect(cases == 48)
    }

    @Test func ccDecodeIgnoresEveryRealTimeByteAtEveryPositionOfATwoStatusInput() {
        let clean: [UInt8] = [0xB0, 5, 127, 0xB1, 6, 64]
        let expected = [Self.cc(1, 5, 127), Self.cc(2, 6, 64)]
        #expect(MIDIControlChange.decode(clean) == expected)
        var cases = 0
        for position in 0...clean.count {
            for byte in realTimeBytes {
                let input = Self.inserting(byte, at: position, into: clean)
                #expect(MIDIControlChange.decode(input) == expected, "byte \(byte) at \(position)")
                cases += 1
            }
        }
        #expect(cases == 56)
    }

    @Test func ccDecodeIgnoresRealTimeBytesBetweenEveryByteAtOnce() {
        let clean: [UInt8] = [0xBF, 5, 127, 6, 64]
        var interleaved: [UInt8] = []
        for (offset, byte) in clean.enumerated() {
            interleaved.append(realTimeBytes[offset % realTimeBytes.count])
            interleaved.append(byte)
        }
        interleaved.append(0xFF)
        #expect(interleaved.count == 11)
        #expect(MIDIControlChange.decode(interleaved) == [Self.cc(16, 5, 127), Self.cc(16, 6, 64)])
    }

    @Test func ccDecodeOfRealTimeBytesAloneAndOfTheByteBelowThemBehavesAsDocumented() {
        #expect(MIDIControlChange.decode(realTimeBytes).isEmpty)
        #expect(MIDIControlChange.decode([0xB0, 5] + realTimeBytes).isEmpty)
        #expect(MIDIControlChange.decode([0xB0, 5, 0xF7, 7]).isEmpty)
        #expect(MIDIControlChange.decode([0xB0, 5, 0xF7, 0xB0, 6, 7]) == [Self.cc(1, 6, 7)])
    }

    @Test func ccDecodeKeepsRunningStatusAcrossSkippedRealTimeBytes() {
        #expect(MIDIControlChange.decode([0xB3, 1, 2, 0xF8, 0xFE, 3, 4, 0xFF, 5, 6]) == [
            Self.cc(4, 1, 2), Self.cc(4, 3, 4), Self.cc(4, 5, 6)
        ])
        #expect(MIDIControlChange.decode([0xB0, 5, 7, 0xFA, 6, 8, 0xFC, 9, 10]) == [
            Self.cc(1, 5, 7), Self.cc(1, 6, 8), Self.cc(1, 9, 10)
        ])
    }

    @Test func ccDecodeIgnoresRealTimeBytesInsideASysExAndStillDecodesTheCCAfterIt() {
        let input: [UInt8] = [0xF0, 1, 0xF8, 2, 0xFF, 3, 0xF7, 0xB0, 5, 7]
        #expect(MIDIControlChange.decode(input) == [Self.cc(1, 5, 7)])
        #expect(MIDIControlChange.decode([0xF0, 1, 0xF8, 5, 7]).isEmpty)
    }

    @Test func ccDecodeSkipsRealTimeBytesInsideANonCCMessage() {
        let input: [UInt8] = [0x90, 0xF8, 0x3C, 0xF9, 0x40, 0xB0, 5, 0xFA, 7]
        #expect(MIDIControlChange.decode(input) == [Self.cc(1, 5, 7)])
        #expect(MIDIControlChange.decode([0xC0, 0xF8, 9, 0xB0, 5, 7]) == [Self.cc(1, 5, 7)])
    }

    @Test func ccDecodeTreatsEveryRealTimeByteTheSameAndNothingBelowF8AsRealTime() {
        for byte in realTimeBytes {
            #expect(MIDIControlChange.decode([0xB0, byte, 5, 7]) == [Self.cc(1, 5, 7)], "byte \(byte)")
        }
        #expect(MIDIControlChange.decode([0xB0, 0xF6, 5, 7]).isEmpty)
        #expect(MIDIControlChange.decode([0xB0, 0xF7, 5, 7]).isEmpty)
        #expect(MIDIControlChange.decode([0xB0, 0xF4, 5, 7]).isEmpty)
    }
}
