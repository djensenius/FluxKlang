import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIControlChangeDecodeTests {
    @Test func ccDecodeDropsATruncatedTrailingCCButKeepsTheCompleteOnesBeforeIt() {
        #expect(Self.ccs([0xB0, 5]).isEmpty)
        #expect(Self.ccs([0xB0, 5, 7, 0xB1, 6]) == [Self.cc(1, 5, 7)])
        #expect(Self.ccs([0xB0, 5, 7, 6]) == [Self.cc(1, 5, 7)])
    }

    @Test func ccDecodeIgnoresLeadingDataBytesThatHaveNoRunningStatus() {
        #expect(Self.ccs([1, 2, 3]).isEmpty)
        #expect(Self.ccs([1, 2, 0xB0, 5, 7]) == [Self.cc(1, 5, 7)])
        #expect(Self.ccs([0x7F, 0xB0, 5, 7]) == [Self.cc(1, 5, 7)])
    }

    @Test func ccDecodeSkipsEveryNonCCChannelStatusAndKeepsDecodingAfterIt() {
        for status in UInt8(0x80)...UInt8(0xEF) where status & 0xF0 != 0xB0 {
            let input: [UInt8] = [status, 1, 2, 0xB0, 3, 4]
            #expect(Self.ccs(input) == [Self.cc(1, 3, 4)], "status \(status)")
        }
    }

    @Test func ccDecodeLetsANonCCMessageConsumeItsDataBytesUnderRunningStatus() {
        #expect(Self.ccs([0xB0, 5, 7, 0x90, 0x3C, 0x40, 6, 8]) == [Self.cc(1, 5, 7)])
        #expect(Self.ccs([0xB0, 5, 7, 0xC0, 9, 6, 8]) == [Self.cc(1, 5, 7)])
        #expect(Self.ccs([0xB0, 5, 7, 0xE0, 1, 2, 3, 4]) == [Self.cc(1, 5, 7)])
        #expect(Self.ccs([0x90, 0x3C, 0x40, 6, 8]).isEmpty)
        #expect(Self.ccs([0xD0, 9, 6, 8]).isEmpty)
    }

    @Test func ccDecodeReturnsToControlChangeOnlyAfterANewControlChangeStatus() {
        let input: [UInt8] = [0xB0, 5, 7, 0x90, 0x3C, 0x40, 6, 8, 0xB2, 6, 8, 9, 10]
        #expect(Self.ccs(input) == [Self.cc(1, 5, 7), Self.cc(3, 6, 8), Self.cc(3, 9, 10)])
    }

    @Test func ccDecodeSkipsSystemCommonMessagesAndClearsRunningStatusAfterThem() {
        for status in UInt8(0xF1)...UInt8(0xF6) {
            let input: [UInt8] = [0xB0, 5, 7, status, 1, 2, 3, 4, 0xB1, 6, 8]
            #expect(Self.ccs(input) == [Self.cc(1, 5, 7), Self.cc(2, 6, 8)], "status \(status)")
        }
        #expect(Self.ccs([0xB0, 5, 7, 0xF2, 1, 2, 6, 8]) == [Self.cc(1, 5, 7)])
        #expect(Self.ccs([0xB0, 5, 7, 0xF6, 6, 8]) == [Self.cc(1, 5, 7)])
    }

    @Test func ccDecodeYieldsNothingForCCLookingDataInsideATerminatedSysEx() {
        #expect(Self.ccs([0xF0, 5, 7, 0xF7]).isEmpty)
        #expect(Self.ccs([0xB0, 5, 7, 0xF0, 6, 8, 0xF7]) == [Self.cc(1, 5, 7)])
        #expect(Self.ccs([0xB0, 5, 7, 0xF0, 6, 8, 0xF7, 9, 10]) == [Self.cc(1, 5, 7)])
        #expect(Self.ccs([0xF0, 5, 7, 0xF7, 0xB0, 6, 8]) == [Self.cc(1, 6, 8)])
    }

    @Test func ccDecodeLetsAnUnterminatedSysExSwallowFollowingDataBytesByParserPolicy() {
        #expect(Self.ccs([0xF0, 5, 7, 6, 8]).isEmpty)
        #expect(Self.ccs([0xB0, 5, 7, 0xF0, 6, 8, 9, 10]) == [Self.cc(1, 5, 7)])
        #expect(Self.ccs([0xB0, 5, 7, 0xF0, 6, 8, 0xB1, 9, 10]) == [
            Self.cc(1, 5, 7), Self.cc(2, 9, 10)
        ])
    }

    @Test func ccDecodeTreatsAStrayF7AsSystemCommonThatClearsRunningStatus() {
        #expect(Self.ccs([0xB0, 5, 7, 0xF7, 6, 8]) == [Self.cc(1, 5, 7)])
        #expect(Self.ccs([0xF7, 0xB0, 5, 7]) == [Self.cc(1, 5, 7)])
    }

    @Test func ccDecodeYieldsNothingFromLongSysExPayloadsAndRecoversAfterF7() {
        for payloadBytes in [256, 257, 300] {
            let payload = [UInt8](repeating: 0x05, count: payloadBytes)
            let terminated = [0xF0] + payload + [0xF7, 0xB0, 6, 8]
            #expect(Self.ccs(terminated) == [Self.cc(1, 6, 8)], "payload \(payloadBytes)")
            let unterminated = [0xB0, 5, 7, 0xF0] + payload + [6, 8]
            #expect(Self.ccs(unterminated) == [Self.cc(1, 5, 7)], "payload \(payloadBytes)")
        }
    }

    @Test func ccDecodeLetsAStatusByteInsideASysExInterruptItAndStartAMessage() {
        #expect(Self.ccs([0xF0, 1, 0xB0, 5, 7]) == [Self.cc(1, 5, 7)])
        #expect(Self.ccs([0xF0, 0xB0, 5, 7, 0xF7]) == [Self.cc(1, 5, 7)])
        #expect(Self.ccs([0xF0, 1, 0xF0, 2, 0xB0, 5, 7]) == [Self.cc(1, 5, 7)])
    }
}
