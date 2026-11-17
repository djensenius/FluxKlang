import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - SysEx7 (MT 0x3)

extension MIDI1UMPInputDecoderTests {
    /// Two MT 0x3 words: `[0x3 | group][status | number of bytes][byte 1][byte 2]`, `[byte 3][byte 4][byte 5][byte 6]`,
    /// unused slots zero. The group is 0 unless given.
    static func sysEx7Words(group: UInt32 = 0, status: UInt8, _ payload: [UInt8]) -> [UInt32] {
        var slots = [UInt32](repeating: 0, count: 6)
        for (index, byte) in payload.prefix(6).enumerated() { slots[index] = UInt32(byte) }
        let first = 0x3000_0000 | group << 24 | UInt32(status) << 20 | UInt32(payload.count) << 16
            | slots[0] << 8 | slots[1]
        let second = slots[2] << 24 | slots[3] << 16 | slots[4] << 8 | slots[5]
        return [first, second]
    }

    @Test func completeCarriesZeroToSixBytesBetweenF0AndF7() throws {
        let full: [UInt8] = [0x7E, 0x7F, 0x06, 0x01, 0x10, 0x20]
        for count in 0...6 {
            let payload = Array(full.prefix(count))
            let decoded = Self.decodeOnce(Self.sysEx7Words(status: 0x0, payload))
            #expect(decoded.bytes == [0xF0] + payload + [0xF7], "\(count) bytes")
            #expect(decoded.skipped.isEmpty)
            let parsed = try events(decoded.bytes)
            try #require(parsed.count == 1)
            #expect(parsed == [.sysEx(payload: payload)])
        }
    }

    @Test func startContinueAndEndFrameAnOpenSysEx() {
        var decoder = MIDI1UMPInputDecoder()
        let start = decoder.decode(Self.sysEx7Words(status: 0x1, [0x7D, 0x01]))
        let middle = decoder.decode(Self.sysEx7Words(status: 0x2, [0x02, 0x03, 0x04]))
        let end = decoder.decode(Self.sysEx7Words(status: 0x3, [0x05]))
        #expect(start.bytes == [0xF0, 0x7D, 0x01])
        #expect(middle.bytes == [0x02, 0x03, 0x04])
        #expect(end.bytes == [0x05, 0xF7])
        #expect(start.skipped.isEmpty && middle.skipped.isEmpty && end.skipped.isEmpty)
        #expect(decoder == MIDI1UMPInputDecoder())
    }

    @Test func emptyStartContinueAndEndCarryOnlyTheirFraming() {
        var decoder = MIDI1UMPInputDecoder()
        #expect(decoder.decode(Self.sysEx7Words(status: 0x1, [])).bytes == [0xF0])
        #expect(decoder.decode(Self.sysEx7Words(status: 0x2, [])).bytes.isEmpty)
        #expect(decoder.decode(Self.sysEx7Words(status: 0x3, [])).bytes == [0xF7])
    }

    @Test func partsAcrossSeparateCallsParseAsOneSysEx() throws {
        let payload = Array(UInt8(0x00)...UInt8(0x10))
        try #require(payload.count == 17)
        let calls = [
            Self.sysEx7Words(status: 0x1, Array(payload[0..<6])),
            Self.sysEx7Words(status: 0x2, Array(payload[6..<12])),
            Self.sysEx7Words(status: 0x3, Array(payload[12..<17]))
        ]
        var decoder = MIDI1UMPInputDecoder()
        var bytes: [UInt8] = []
        for words in calls {
            let decoded = decoder.decode(words)
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
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0xF0, 0x7D, 0x01, 0xF8, 0x02, 0xF7])
        let parsed = try events(decoded.bytes)
        try #require(parsed.count == 2)
        #expect(parsed == [.realTime(status: 0xF8), .sysEx(payload: [0x7D, 0x01, 0x02])])
    }

    @Test func refusedSysEx7PacketGivesNoBytes() {
        // A number of bytes of 7, then a reserved status 0x4; both refused, the Note On after them still decodes.
        let words: [UInt32] = [0x3007_0102, 0x0304_0506, 0x3041_0100, 0x0000_0000, Self.channelWord(0x90, 0x3C, 0x64)]
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0x90, 0x3C, 0x64])
        #expect(decoded.skipped == [
            .malformed(.valueOutOfRange(field: .sysEx7ByteCount, value: 7)),
            .malformed(.reservedStatus(mt: .data64, status: 0x4))
        ])
    }

    // MARK: Framing for one MIDI1Parser

    @Test func refusedContinuationClosesTheSysEx() throws {
        // Start [7D 01], a continue claiming 7 bytes (refused), then end [02].
        let words = Self.sysEx7Words(status: 0x1, [0x7D, 0x01]) + [0x3027_0203, 0x0405_0607]
            + Self.sysEx7Words(status: 0x3, [0x02])
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0xF0, 0x7D, 0x01])
        #expect(!decoded.bytes.contains(0xF7))
        #expect(try events(decoded.bytes).isEmpty)
        #expect(decoded.skipped == [
            .malformed(.valueOutOfRange(field: .sysEx7ByteCount, value: 7)), .orphanSysEx(.end)
        ])
    }

    @Test func orphanEndIsNotReadAsRunningStatusData() throws {
        let decoded = Self.decodeOnce([0x2090_3C64, 0x3032_3D40, 0x0000_0000])
        #expect(decoded.bytes == [0x90, 0x3C, 0x64])
        #expect(try events(decoded.bytes) == [.channel(status: 0x90, data1: 0x3C, data2: 0x64)])
        #expect(decoded.skipped == [.orphanSysEx(.end)])
    }

    @Test func orphanContinueIsNotReadAsRunningStatusData() throws {
        let decoded = Self.decodeOnce([0x2090_3C64, 0x3022_3D40, 0x0000_0000])
        #expect(decoded.bytes == [0x90, 0x3C, 0x64])
        let parsed = try events(decoded.bytes)
        try #require(parsed.count == 1)
        #expect(parsed == [.channel(status: 0x90, data1: 0x3C, data2: 0x64)])
        #expect(decoded.skipped == [.orphanSysEx(.continue)])
    }

    @Test func systemCommonInterruptsAnOpenSysEx() throws {
        let words = Self.sysEx7Words(status: 0x1, [0x7D, 0x01]) + [Self.systemWord(0xF6)]
            + Self.sysEx7Words(status: 0x3, [0x02])
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0xF0, 0x7D, 0x01, 0xF6])
        let parsed = try events(decoded.bytes)
        try #require(parsed.count == 1)
        #expect(parsed == [.systemCommon(status: 0xF6, data1: nil, data2: nil)])
        #expect(decoded.skipped == [.sysExInterrupted, .orphanSysEx(.end)])
    }

    @Test func openSysExCarriesAcrossCalls() throws {
        var decoder = MIDI1UMPInputDecoder()
        let first = decoder.decode(Self.sysEx7Words(status: 0x1, [0x7D, 0x01]))
        let second = decoder.decode(Self.sysEx7Words(status: 0x2, [0x02, 0x03]) + Self.sysEx7Words(status: 0x3, [0x04]))
        #expect(first.skipped.isEmpty && second.skipped.isEmpty)
        let parsed = try events(first.bytes + second.bytes)
        try #require(parsed.count == 1)
        #expect(parsed == [.sysEx(payload: [0x7D, 0x01, 0x02, 0x03, 0x04])])
    }

    @Test func channelMessageInterruptsAnOpenSysEx() throws {
        let words = Self.sysEx7Words(status: 0x1, [0x7D, 0x01]) + [Self.channelWord(0xB0, 0x07, 0x64)]
            + Self.sysEx7Words(status: 0x3, [0x02])
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0xF0, 0x7D, 0x01, 0xB0, 0x07, 0x64])
        #expect(try events(decoded.bytes) == [.channel(status: 0xB0, data1: 0x07, data2: 0x64)])
        #expect(decoded.skipped == [.sysExInterrupted, .orphanSysEx(.end)])
    }

    @Test func skippedTypesBetweenPartsLeaveTheSysExOpen() throws {
        let words = Self.sysEx7Words(status: 0x1, [0x7D]) + [0x0000_0000, 0x4091_3C00, 0xFFFF_0000]
            + Self.sysEx7Words(status: 0x3, [0x02])
        let decoded = Self.decodeOnce(words)
        #expect(try events(decoded.bytes) == [.sysEx(payload: [0x7D, 0x02])])
        #expect(decoded.skipped == [.notMIDI1(.utility), .protocolMismatch(.midi2ChannelVoice)])
    }

    @Test func refusedBatchClosesTheSysEx() throws {
        var decoder = MIDI1UMPInputDecoder()
        let start = decoder.decode(Self.sysEx7Words(status: 0x1, [0x7D, 0x01]))
        let refused = decoder.decode([0x3031_0200])
        let end = decoder.decode(Self.sysEx7Words(status: 0x3, [0x02]))
        #expect(refused.skipped == [.malformed(.truncated(mt: .data64, have: 1, need: 2))])
        #expect(end.bytes.isEmpty)
        #expect(end.skipped == [.orphanSysEx(.end)])
        #expect(try events(start.bytes + refused.bytes + end.bytes).isEmpty)
    }

    @Test func nestedStartDeliversOnlyTheSecondSysEx() throws {
        let words = Self.sysEx7Words(status: 0x1, [0x01]) + Self.sysEx7Words(status: 0x1, [0x02, 0x03])
            + Self.sysEx7Words(status: 0x3, [0x04])
        let decoded = Self.decodeOnce(words)
        #expect(try events(decoded.bytes) == [.sysEx(payload: [0x02, 0x03, 0x04])])
        #expect(decoded.skipped == [.sysExInterrupted])

        let complete = Self.decodeOnce(Self.sysEx7Words(status: 0x1, [0x01]) + Self.sysEx7Words(status: 0x0, [0x05]))
        #expect(try events(complete.bytes) == [.sysEx(payload: [0x05])])
        #expect(complete.skipped == [.sysExInterrupted])
    }

    @Test func resetClosesTheSysEx() {
        var decoder = MIDI1UMPInputDecoder()
        _ = decoder.decode(Self.sysEx7Words(status: 0x1, [0x7D]))
        #expect(decoder != MIDI1UMPInputDecoder())
        decoder.reset()
        #expect(decoder == MIDI1UMPInputDecoder())
        let end = decoder.decode(Self.sysEx7Words(status: 0x3, [0x02]))
        #expect(end.bytes.isEmpty)
        #expect(end.skipped == [.orphanSysEx(.end)])
    }

    // MARK: Groups

    @Test func sameGroupNonZeroStillDecodes() throws {
        for group: UInt32 in [0, 5, 15] {
            let words = Self.sysEx7Words(group: group, status: 0x1, [0x01, 0x02])
                + Self.sysEx7Words(group: group, status: 0x2, [0x03])
                + Self.sysEx7Words(group: group, status: 0x3, [0x04])
            var decoder = MIDI1UMPInputDecoder()
            let decoded = decoder.decode(words)
            #expect(decoded.bytes == [0xF0, 0x01, 0x02, 0x03, 0x04, 0xF7], "group \(group)")
            #expect(decoded.skipped.isEmpty, "group \(group)")
            #expect(decoder == MIDI1UMPInputDecoder(), "group \(group)")
            #expect(try events(decoded.bytes) == [.sysEx(payload: [0x01, 0x02, 0x03, 0x04])], "group \(group)")
        }
    }

    @Test func interleavedGroupContinueIsNotSplicedIntoOpenSysEx() throws {
        let words = Self.sysEx7Words(group: 0, status: 0x1, [0x01, 0x02])
            + Self.sysEx7Words(group: 1, status: 0x2, [0x03, 0x04])
            + Self.sysEx7Words(group: 0, status: 0x3, [0x07])
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0xF0, 0x01, 0x02, 0x07, 0xF7])
        #expect(decoded.skipped == [.foreignGroupSysEx(.continue)])
        #expect(try events(decoded.bytes) == [.sysEx(payload: [0x01, 0x02, 0x07])])
    }

    @Test func foreignGroupEndDoesNotCloseOpenSysEx() throws {
        var decoder = MIDI1UMPInputDecoder()
        let start = decoder.decode(Self.sysEx7Words(group: 0, status: 0x1, [0x01, 0x02]))
        let afterStart = decoder
        let foreign = decoder.decode(Self.sysEx7Words(group: 1, status: 0x3, [0x09]))
        #expect(foreign.bytes.isEmpty)
        #expect(foreign.skipped == [.foreignGroupSysEx(.end)])
        #expect(decoder == afterStart)
        let rest = decoder.decode(
            Self.sysEx7Words(group: 0, status: 0x2, [0x03]) + Self.sysEx7Words(group: 0, status: 0x3, [0x04])
        )
        #expect(rest.bytes == [0x03, 0x04, 0xF7])
        #expect(rest.skipped.isEmpty)
        #expect(decoder == MIDI1UMPInputDecoder())
        let bytes = start.bytes + foreign.bytes + rest.bytes
        #expect(bytes == [0xF0, 0x01, 0x02, 0x03, 0x04, 0xF7])
        #expect(try events(bytes) == [.sysEx(payload: [0x01, 0x02, 0x03, 0x04])])
    }

    @Test func interleavedStartsLetTheLaterGroupWin() throws {
        let words = Self.sysEx7Words(group: 0, status: 0x1, [0x01, 0x02])
            + Self.sysEx7Words(group: 1, status: 0x1, [0x11, 0x12])
            + Self.sysEx7Words(group: 0, status: 0x2, [0x03])
            + Self.sysEx7Words(group: 1, status: 0x2, [0x13, 0x14])
            + Self.sysEx7Words(group: 0, status: 0x3, [0x04])
            + Self.sysEx7Words(group: 1, status: 0x3, [0x15])
        var decoder = MIDI1UMPInputDecoder()
        let decoded = decoder.decode(words)
        #expect(decoded.bytes == [0xF0, 0x01, 0x02, 0xF0, 0x11, 0x12, 0x13, 0x14, 0x15, 0xF7])
        #expect(decoded.skipped == [.sysExInterrupted, .foreignGroupSysEx(.continue), .foreignGroupSysEx(.end)])
        #expect(decoder == MIDI1UMPInputDecoder())
        #expect(try events(decoded.bytes) == [.sysEx(payload: [0x11, 0x12, 0x13, 0x14, 0x15])])
    }

    @Test func completeFromAnotherGroupInterruptsAndLeavesNothingOpen() throws {
        let words = Self.sysEx7Words(group: 2, status: 0x1, [0x01]) + Self.sysEx7Words(group: 3, status: 0x0, [0x05])
            + Self.sysEx7Words(group: 2, status: 0x3, [0x02])
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0xF0, 0x01, 0xF0, 0x05, 0xF7])
        #expect(decoded.skipped == [.sysExInterrupted, .orphanSysEx(.end)])
        #expect(try events(decoded.bytes) == [.sysEx(payload: [0x05])])
    }

    @Test func orphanStaysAnOrphanWhenNoSysExIsOpenWhateverTheGroup() {
        for group: UInt32 in [0, 1, 3, 15] {
            let fresh = Self.decodeOnce(
                Self.sysEx7Words(group: group, status: 0x2, [0x01])
                    + Self.sysEx7Words(group: group, status: 0x3, [0x02])
            )
            #expect(fresh.bytes.isEmpty, "group \(group)")
            #expect(fresh.skipped == [.orphanSysEx(.continue), .orphanSysEx(.end)], "group \(group)")
        }
        // Closed by an end, then by a complete (which never opens): another group's tail is still an orphan.
        let words = Self.sysEx7Words(group: 0, status: 0x1, [0x01]) + Self.sysEx7Words(group: 0, status: 0x3, [0x02])
            + Self.sysEx7Words(group: 1, status: 0x2, [0x03]) + Self.sysEx7Words(group: 2, status: 0x0, [0x04])
            + Self.sysEx7Words(group: 1, status: 0x3, [0x05])
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0xF0, 0x01, 0x02, 0xF7, 0xF0, 0x04, 0xF7])
        #expect(decoded.skipped == [.orphanSysEx(.continue), .orphanSysEx(.end)])
    }

    @Test func nonSysExMessagesOfAnotherGroupStillInterruptAnOpenSysEx() throws {
        let words = Self.sysEx7Words(group: 0, status: 0x1, [0x01, 0x02]) + [Self.systemWord(group: 1, 0xF8)]
            + [Self.channelWord(group: 2, 0x90, 0x3C, 0x64)] + Self.sysEx7Words(group: 0, status: 0x3, [0x07])
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0xF0, 0x01, 0x02, 0xF8, 0x90, 0x3C, 0x64])
        #expect(decoded.skipped == [.sysExInterrupted, .orphanSysEx(.end)])
        let parsed = try events(decoded.bytes)
        #expect(parsed == [.realTime(status: 0xF8), .channel(status: 0x90, data1: 0x3C, data2: 0x64)])
    }
}
