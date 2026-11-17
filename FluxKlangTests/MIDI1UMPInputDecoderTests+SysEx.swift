import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - SysEx7 (MT 0x3)

extension MIDI1UMPInputDecoderTests {
    /// Two MT 0x3 words, group 0: `[0x3 | group][status | number of bytes][byte 1][byte 2]`,
    /// `[byte 3][byte 4][byte 5][byte 6]`, unused slots zero.
    static func sysEx7Words(status: UInt8, _ payload: [UInt8]) -> [UInt32] {
        var slots = [UInt32](repeating: 0, count: 6)
        for (index, byte) in payload.prefix(6).enumerated() { slots[index] = UInt32(byte) }
        let first = 0x3000_0000 | UInt32(status) << 20 | UInt32(payload.count) << 16 | slots[0] << 8 | slots[1]
        let second = slots[2] << 24 | slots[3] << 16 | slots[4] << 8 | slots[5]
        return [first, second]
    }

    @Test func completeCarriesZeroToSixBytesBetweenF0AndF7() throws {
        let full: [UInt8] = [0x7E, 0x7F, 0x06, 0x01, 0x10, 0x20]
        for count in 0...6 {
            let payload = Array(full.prefix(count))
            let decoded = MIDI1UMPInputDecoder.decode(Self.sysEx7Words(status: 0x0, payload))
            #expect(decoded.bytes == [0xF0] + payload + [0xF7], "\(count) bytes")
            #expect(decoded.skipped.isEmpty)
            let parsed = try events(decoded.bytes)
            try #require(parsed.count == 1)
            #expect(parsed == [.sysEx(payload: payload)])
        }
    }

    @Test func startContinueAndEndMapByStatusAlone() {
        let start = MIDI1UMPInputDecoder.decode(Self.sysEx7Words(status: 0x1, [0x7D, 0x01]))
        let middle = MIDI1UMPInputDecoder.decode(Self.sysEx7Words(status: 0x2, [0x02, 0x03, 0x04]))
        let end = MIDI1UMPInputDecoder.decode(Self.sysEx7Words(status: 0x3, [0x05]))
        #expect(start.bytes == [0xF0, 0x7D, 0x01])
        #expect(middle.bytes == [0x02, 0x03, 0x04])
        #expect(end.bytes == [0x05, 0xF7])
        #expect(start.skipped.isEmpty && middle.skipped.isEmpty && end.skipped.isEmpty)
    }

    @Test func emptyStartContinueAndEndCarryOnlyTheirFraming() {
        #expect(MIDI1UMPInputDecoder.decode(Self.sysEx7Words(status: 0x1, [])).bytes == [0xF0])
        #expect(MIDI1UMPInputDecoder.decode(Self.sysEx7Words(status: 0x2, [])).bytes.isEmpty)
        #expect(MIDI1UMPInputDecoder.decode(Self.sysEx7Words(status: 0x3, [])).bytes == [0xF7])
    }

    @Test func partsAcrossSeparateCallsParseAsOneSysEx() throws {
        let payload = Array(UInt8(0x00)...UInt8(0x10))
        try #require(payload.count == 17)
        let calls = [
            Self.sysEx7Words(status: 0x1, Array(payload[0..<6])),
            Self.sysEx7Words(status: 0x2, Array(payload[6..<12])),
            Self.sysEx7Words(status: 0x3, Array(payload[12..<17]))
        ]
        var bytes: [UInt8] = []
        for words in calls {
            let decoded = MIDI1UMPInputDecoder.decode(words)
            #expect(decoded.skipped.isEmpty)
            bytes += decoded.bytes
        }
        #expect(bytes == [0xF0] + payload + [0xF7])
        let parsed = try events(bytes)
        try #require(parsed.count == 1)
        #expect(parsed == [.sysEx(payload: payload)])
    }

    @Test func realTimeBetweenSysExPartsKeepsItsPlace() throws {
        let words = Self.sysEx7Words(status: 0x1, [0x7D, 0x01]) + [Self.systemWord(0xF8)]
            + Self.sysEx7Words(status: 0x3, [0x02])
        let decoded = MIDI1UMPInputDecoder.decode(words)
        #expect(decoded.bytes == [0xF0, 0x7D, 0x01, 0xF8, 0x02, 0xF7])
        let parsed = try events(decoded.bytes)
        try #require(parsed.count == 2)
        #expect(parsed == [.realTime(status: 0xF8), .sysEx(payload: [0x7D, 0x01, 0x02])])
    }

    @Test func refusedSysEx7PacketGivesNoBytes() {
        // A number of bytes of 7, then a reserved status 0x4; both refused, the Note On after them still decodes.
        let words: [UInt32] = [0x3007_0102, 0x0304_0506, 0x3041_0100, 0x0000_0000, Self.channelWord(0x90, 0x3C, 0x64)]
        let decoded = MIDI1UMPInputDecoder.decode(words)
        #expect(decoded.bytes == [0x90, 0x3C, 0x64])
        #expect(decoded.skipped == [
            .malformed(.valueOutOfRange(field: .sysEx7ByteCount, value: 7)),
            .malformed(.reservedStatus(mt: .data64, status: 0x4))
        ])
    }
}
