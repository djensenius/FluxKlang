import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - System Common and System Real Time messages (MT 0x1)

extension UMPPacketFramingTests {
    /// One hand-written MT 0x1 word (M2-104-UM System Messages; Linux `snd_ump_system_msg`, CoreMIDI
    /// `MIDI1UPSystemCommon`) with the group, message and `MIDI1Parser`-shaped event it must match.
    struct SystemGolden {
        let word: UInt32
        let group: UInt8
        let message: UMPSystemMessage
        let event: MIDI1Event
    }

    static func systemGoldens() throws -> [SystemGolden] {
        [
            // MTC piece 3 (seconds high nibble), nibble 0x2: a valid quarter frame `0 011 0010`.
            SystemGolden(word: 0x10F1_3200, group: 0, message: .mtcQuarterFrame(try UMPSevenBit(0x32)),
                         event: .systemCommon(status: 0xF1, data1: 0x32, data2: nil)),
            // Song Position Pointer: LSB 0x01 in data byte 1, MSB 0x02 in data byte 2 → 0x02 << 7 | 0x01 = 257.
            SystemGolden(word: 0x13F2_0102, group: 3, message: .songPositionPointer(257),
                         event: .systemCommon(status: 0xF2, data1: 0x01, data2: 0x02)),
            SystemGolden(word: 0x10F2_7F7F, group: 0, message: .songPositionPointer(0x3FFF),
                         event: .systemCommon(status: 0xF2, data1: 0x7F, data2: 0x7F)),
            SystemGolden(word: 0x1FF3_0500, group: 15, message: .songSelect(try UMPSevenBit(5)),
                         event: .systemCommon(status: 0xF3, data1: 0x05, data2: nil)),
            SystemGolden(word: 0x10F6_0000, group: 0, message: .tuneRequest,
                         event: .systemCommon(status: 0xF6, data1: nil, data2: nil)),
            SystemGolden(word: 0x10F8_0000, group: 0, message: .timingClock, event: .realTime(status: 0xF8)),
            SystemGolden(word: 0x12FA_0000, group: 2, message: .start, event: .realTime(status: 0xFA)),
            SystemGolden(word: 0x10FB_0000, group: 0, message: .continue, event: .realTime(status: 0xFB)),
            SystemGolden(word: 0x17FC_0000, group: 7, message: .stop, event: .realTime(status: 0xFC)),
            SystemGolden(word: 0x10FE_0000, group: 0, message: .activeSensing, event: .realTime(status: 0xFE)),
            SystemGolden(word: 0x1EFF_0000, group: 14, message: .reset, event: .realTime(status: 0xFF))
        ]
    }

    static func system(_ word: UInt32) throws -> UMPSystemCommonRealTime {
        try UMPSystemCommonRealTime(decoding: UMPPacket(words: [word]))
    }

    @Test func systemGoldensDecodeAndEncode() throws {
        for golden in try Self.systemGoldens() {
            let decoded = try Self.system(golden.word)
            #expect(decoded.group.value == golden.group, "\(golden.word)")
            #expect(decoded.message == golden.message, "\(golden.word)")
            #expect(decoded.event == golden.event, "\(golden.word)")
            let built = try UMPSystemCommonRealTime(group: UMPGroup(golden.group), message: golden.message)
            #expect(built == decoded)
            #expect(built.packet.words == [golden.word], "\(golden.word)")
            #expect(built.packet.messageType == .system)
            #expect(built.packet.group == decoded.group)
        }
    }

    @Test func systemRoundTripsInEveryGroup() throws {
        let messages: [UMPSystemMessage] = try [
            .mtcQuarterFrame(UMPSevenBit(0)), .mtcQuarterFrame(UMPSevenBit(0x7F)), .songPositionPointer(0),
            .songPositionPointer(0x80), .songPositionPointer(0x3FFF), .songSelect(UMPSevenBit(0)),
            .songSelect(UMPSevenBit(0x7F)), .tuneRequest, .timingClock, .start, .continue, .stop, .activeSensing,
            .reset
        ]
        for groupValue in UInt8(0)...15 {
            let group = try UMPGroup(groupValue)
            for message in messages {
                let value = try UMPSystemCommonRealTime(group: group, message: message)
                let word = try #require(value.packet.words.first)
                #expect(value.packet.words.count == 1)
                #expect(word >> 28 == 0x1)
                #expect((word >> 24) & 0x0F == UInt32(groupValue), "group is preserved")
                #expect(try UMPSystemCommonRealTime(decoding: value.packet) == value)
                #expect(try UMPSystemCommonRealTime(group: group, event: value.event) == value)
            }
        }
    }

    @Test func systemBridgesMIDI1ParserEvents() throws {
        var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 16))
        let bytes: [UInt8] = [0xF1, 0x32, 0xF2, 0x01, 0x02, 0xF2, 0x7F, 0x7F, 0xF3, 0x05, 0xF6, 0xF8, 0xFA, 0xFB,
                              0xFC, 0xFE, 0xFF]
        let events = bytes.compactMap { parser.consume($0) }
        let goldens = try Self.systemGoldens()
        try #require(events.count == goldens.count)
        for (event, golden) in zip(events, goldens) {
            #expect(event == golden.event)
            let group = try UMPGroup(golden.group)
            let bridged = try UMPSystemCommonRealTime(group: group, event: event)
            #expect(bridged.message == golden.message)
            #expect(bridged.packet.words == [golden.word])
        }
    }

    @Test func systemQuarterFrameBridgesToMTCQuarterFrame() throws {
        // 0x32 = piece 3 (seconds high nibble), nibble 0x2: a valid quarter frame.
        let decoded = try Self.system(0x10F1_3200)
        let frame = try MTCQuarterFrame(event: decoded.event)
        #expect(frame.piece == 3)
        #expect(frame.nibble == 0x2)
        #expect(frame.dataByte == 0x32)
        #expect(try UMPSystemCommonRealTime(group: decoded.group, event: frame.event) == decoded)
        // The codec carries the raw 7-bit byte; piece checks stay with MTCQuarterFrame (piece 3 allows only 0x03).
        let raw = try Self.system(0x10F1_3500)
        #expect(raw.message == .mtcQuarterFrame(try UMPSevenBit(0x35)))
        #expect(throws: TimecodeError.reservedBitsSet(piece: 3, nibble: 5)) { try MTCQuarterFrame(event: raw.event) }
    }

    @Test func systemRefusesOtherMessageTypes() throws {
        // An undefined status and reserved data bits are set too, so the type check must come first.
        for type in UMPMessageType.allCases where type != .system {
            let first = UInt32(type.rawValue) << 28 | 0x0FF4_FFFF
            let packet = try UMPPacket(words: [first] + Array(repeating: 0, count: type.wordCount - 1))
            #expect(throws: UMPRefusal.wrongMessageType(expected: .system, actual: type)) {
                try UMPSystemCommonRealTime(decoding: packet)
            }
        }
    }

    @Test func systemRefusesSysExAndUndefinedStatuses() throws {
        for status: UInt32 in [0xF0, 0xF7, 0xF4, 0xF5, 0xF9, 0xFD] {
            #expect(throws: UMPRefusal.reservedStatus(mt: .system, status: UInt8(status)), "\(status)") {
                try Self.system(0x1000_0000 | status << 16)
            }
            // Status is checked before reserved bits.
            #expect(throws: UMPRefusal.reservedStatus(mt: .system, status: UInt8(status)), "\(status)") {
                try Self.system(0x1500_FFFF | status << 16)
            }
        }
    }

    @Test func systemRefusesChannelStatuses() throws {
        for status in UInt32(0x00)...0xEF {
            #expect(throws: UMPRefusal.reservedStatus(mt: .system, status: UInt8(status)), "\(status)") {
                try Self.system(0x1000_0000 | status << 16)
            }
        }
    }

    @Test func systemRefusesDataHighBit() throws {
        let words: [(UInt32, UInt8)] = [
            (0x10F1_8000, 0xF1), (0x10F1_FF00, 0xF1), (0x10F2_8000, 0xF2), (0x10F2_0080, 0xF2),
            (0x10F2_FFFF, 0xF2), (0x10F3_8000, 0xF3)
        ]
        for (word, status) in words {
            #expect(throws: UMPRefusal.reservedBitsSet(mt: .system, status: status), "\(word)") {
                try Self.system(word)
            }
        }
    }

    @Test func systemRefusesNonZeroUnusedDataBytes() throws {
        for status: UInt32 in [0xF1, 0xF3] {
            for bit in UInt32(0)...7 {
                #expect(throws: UMPRefusal.reservedBitsSet(mt: .system, status: UInt8(status)), "\(status) \(bit)") {
                    try Self.system(0x1000_0000 | status << 16 | 0x0500 | 1 << bit)
                }
            }
        }
        for status: UInt32 in [0xF6, 0xF8, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF] {
            for bit in UInt32(0)...15 {
                #expect(throws: UMPRefusal.reservedBitsSet(mt: .system, status: UInt8(status)), "\(status) \(bit)") {
                    try Self.system(0x1000_0000 | status << 16 | 1 << bit)
                }
            }
        }
    }

    @Test func systemRefusesSongPositionAboveFourteenBits() throws {
        #expect(UMPSystemMessage.maximumSongPosition == 0x3FFF)
        let group = try UMPGroup(0)
        for beats: UInt16 in [0x4000, 0xFFFF] {
            #expect(throws: UMPRefusal.valueOutOfRange(field: .fourteenBit, value: Int(beats))) {
                try UMPSystemCommonRealTime(group: group, message: .songPositionPointer(beats))
            }
        }
    }

    @Test func systemEventBridgeRefusals() throws {
        let group = try UMPGroup(4)
        let notSystem: [MIDI1Event] = [
            .channel(status: 0x90, data1: 60, data2: 100), .channel(status: 0xF8, data1: 0, data2: nil),
            .sysEx(payload: [0x7E]), .realTime(status: 0xF1), .realTime(status: 0xF6),
            .systemCommon(status: 0xF8, data1: nil, data2: nil), .systemCommon(status: 0xF1, data1: nil, data2: nil),
            .systemCommon(status: 0xF1, data1: 1, data2: 0), .systemCommon(status: 0xF2, data1: 1, data2: nil),
            .systemCommon(status: 0xF6, data1: 0, data2: nil), .systemCommon(status: 0xF3, data1: nil, data2: 1),
            .systemCommon(status: 0x90, data1: 1, data2: 2), .systemCommon(status: 0x00, data1: nil, data2: nil),
            .realTime(status: 0xF0), .realTime(status: 0x80), .realTime(status: 0xF4)
        ]
        for event in notSystem {
            #expect(throws: UMPRefusal.notSystemMessage, "\(event)") {
                try UMPSystemCommonRealTime(group: group, event: event)
            }
        }
        let undefined: [(MIDI1Event, UInt8)] = [
            (.systemCommon(status: 0xF7, data1: nil, data2: nil), 0xF7),
            (.systemCommon(status: 0xF4, data1: nil, data2: nil), 0xF4),
            (.systemCommon(status: 0xF5, data1: nil, data2: nil), 0xF5),
            (.systemCommon(status: 0xF9, data1: nil, data2: nil), 0xF9),
            (.realTime(status: 0xF9), 0xF9), (.realTime(status: 0xFD), 0xFD)
        ]
        for (event, status) in undefined {
            #expect(throws: UMPRefusal.reservedStatus(mt: .system, status: status), "\(event)") {
                try UMPSystemCommonRealTime(group: group, event: event)
            }
        }
        let highBit: [(MIDI1Event, Int)] = [
            (.systemCommon(status: 0xF1, data1: 0x80, data2: nil), 0x80),
            (.systemCommon(status: 0xF2, data1: 0, data2: 0xFF), 0xFF),
            (.systemCommon(status: 0xF3, data1: 0x81, data2: nil), 0x81)
        ]
        for (event, value) in highBit {
            #expect(throws: UMPRefusal.valueOutOfRange(field: .sevenBit, value: value), "\(event)") {
                try UMPSystemCommonRealTime(group: group, event: event)
            }
        }
    }

    @Test func systemPacketIsExactlyOneWord() {
        #expect(throws: UMPRefusal.wrongWordCount(mt: .system, have: 2, need: 1)) {
            try UMPPacket(words: [0x10F8_0000, 0])
        }
        // The factory forces the MT nibble, as `midi1ChannelVoice(_:)` does.
        #expect(UMPPacket.system(0xF3F8_0000).words == [0x13F8_0000])
    }
}
