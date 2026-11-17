//
//  MIDI1UMPInputDecoderTests.swift
//  FluxKlangTests
//
//  MIDI 1.0-protocol UMP words back to MIDI 1.0 bytes (#81, slice MP1): channel voice, system, order, skips,
//  malformed batches and a differential check through MIDI1Parser. SysEx7 is in
//  MIDI1UMPInputDecoderTests+SysEx.swift. Words are written by hand from the UMP packet layouts
//  (`[MT | group][status][data 1][data 2]`), never by the codec under test.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI 1.0 UMP input decoder", .productionAccessAudit)
struct MIDI1UMPInputDecoderTests {
    /// One 32-bit MT 0x1 or MT 0x2 word: `[MT | group][status][data 1][data 2]`.
    static func word(_ type: UInt32, group: UInt32, _ status: UInt8, _ data1: UInt8 = 0, _ data2: UInt8 = 0)
        -> UInt32 {
        type << 28 | group << 24 | UInt32(status) << 16 | UInt32(data1) << 8 | UInt32(data2)
    }

    static func channelWord(group: UInt32 = 0, _ status: UInt8, _ data1: UInt8, _ data2: UInt8 = 0) -> UInt32 {
        word(0x2, group: group, status, data1, data2)
    }

    static func systemWord(group: UInt32 = 0, _ status: UInt8, _ data1: UInt8 = 0, _ data2: UInt8 = 0) -> UInt32 {
        word(0x1, group: group, status, data1, data2)
    }

    /// Decodes one batch with a fresh decoder (no SysEx open).
    static func decodeOnce(_ words: [UInt32]) -> MIDI1UMPInputDecoding {
        var decoder = MIDI1UMPInputDecoder()
        return decoder.decode(words)
    }

    func events(_ bytes: [UInt8]) throws -> [MIDI1Event] {
        var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 64))
        return bytes.compactMap { parser.consume($0) }
    }

    // MARK: Channel voice and system

    @Test func everyChannelVoiceTypeOnSeveralChannels() {
        // Status family then data bytes; Cn and Dn carry one data byte.
        let families: [[UInt8]] = [
            [0x80, 0x3C, 0x40], [0x90, 0x3C, 0x64], [0xA0, 0x3C, 0x22], [0xB0, 0x07, 0x7F],
            [0xC0, 0x05], [0xD0, 0x33], [0xE0, 0x00, 0x40]
        ]
        for message in families {
            let family = message.first ?? 0
            let data = Array(message.dropFirst())
            for channel: UInt8 in [0x0, 0x5, 0x9, 0xF] {
                let status = family | channel
                let word = Self.channelWord(status, data.first ?? 0, data.dropFirst().first ?? 0)
                let expected = [status] + data
                let decoded = Self.decodeOnce([word])
                #expect(decoded.bytes == expected, "\(String(word, radix: 16))")
                #expect(decoded.skipped.isEmpty)
            }
        }
    }

    @Test func twoByteMessagesEmitNoThirdByte() throws {
        let decoded = Self.decodeOnce([Self.channelWord(0xC3, 0x10), Self.channelWord(0xDA, 0x7F)])
        try #require(decoded.bytes.count == 4)
        #expect(decoded.bytes == [0xC3, 0x10, 0xDA, 0x7F])
    }

    @Test func systemRealTimeAndCommon() {
        let cases: [(UInt32, [UInt8])] = [
            (Self.systemWord(0xF8), [0xF8]), (Self.systemWord(0xFA), [0xFA]), (Self.systemWord(0xFB), [0xFB]),
            (Self.systemWord(0xFC), [0xFC]), (Self.systemWord(0xFE), [0xFE]), (Self.systemWord(0xFF), [0xFF]),
            (Self.systemWord(0xF1, 0x35), [0xF1, 0x35]),
            // Song Position Pointer: LSB in data 1, MSB in data 2, as on the MIDI 1.0 wire.
            (Self.systemWord(0xF2, 0x10, 0x20), [0xF2, 0x10, 0x20]),
            (Self.systemWord(0xF3, 0x07), [0xF3, 0x07]), (Self.systemWord(0xF6), [0xF6])
        ]
        for (word, expected) in cases {
            let decoded = Self.decodeOnce([word])
            #expect(decoded.bytes == expected, "\(String(word, radix: 16))")
            #expect(decoded.skipped.isEmpty)
        }
    }

    @Test func messagesKeepInputOrder() {
        let words: [UInt32] = [
            Self.channelWord(0x91, 0x3C, 0x64), Self.systemWord(0xF8), 0x3002_7E01, 0x0000_0000,
            Self.channelWord(0xB2, 0x07, 0x50), Self.channelWord(0x81, 0x3C, 0x00)
        ]
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0x91, 0x3C, 0x64, 0xF8, 0xF0, 0x7E, 0x01, 0xF7, 0xB2, 0x07, 0x50, 0x81, 0x3C, 0x00])
        #expect(decoded.skipped.isEmpty)
    }

    @Test func everyGroupMergesIntoOneStream() {
        let words = [
            Self.channelWord(group: 0, 0x90, 0x3C, 0x64), Self.channelWord(group: 3, 0x91, 0x3D, 0x65),
            Self.systemWord(group: 7, 0xF8), Self.channelWord(group: 15, 0xC2, 0x09), 0x3A01_2200, 0x0000_0000
        ]
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0x90, 0x3C, 0x64, 0x91, 0x3D, 0x65, 0xF8, 0xC2, 0x09, 0xF0, 0x22, 0xF7])
        #expect(decoded.skipped.isEmpty)
    }

    // MARK: Skips

    @Test func midi2ChannelVoiceIsAProtocolMismatch() {
        // MT 0x4 Note On, channel 1, note 0x3C, velocity 0xFFFF, no attribute; then MT 0x4 Control Change.
        let words: [UInt32] = [
            Self.channelWord(0x90, 0x3C, 0x64), 0x4091_3C00, 0xFFFF_0000, Self.systemWord(0xFA),
            0x40B2_0700, 0x8000_0000, Self.channelWord(0x80, 0x3C, 0x00)
        ]
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0x90, 0x3C, 0x64, 0xFA, 0x80, 0x3C, 0x00])
        #expect(decoded.skipped == [.protocolMismatch(.midi2ChannelVoice), .protocolMismatch(.midi2ChannelVoice)])
    }

    @Test func typesWithNoMIDI1FormAreSkipped() {
        let words: [UInt32] = [
            0x0000_0000,             // MT 0x0 utility (NOOP)
            0x5001_7E00, 0, 0, 0,    // MT 0x5 Data 128-bit
            0xD010_0000, 0, 0, 0,    // MT 0xD Flex Data
            0xF000_0000, 0, 0, 0,    // MT 0xF Stream
            0x6000_0000,             // MT 0x6 reserved
            Self.channelWord(0xB0, 0x40, 0x7F)
        ]
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0xB0, 0x40, 0x7F])
        #expect(decoded.skipped == [
            .notMIDI1(.utility), .notMIDI1(.data128), .notMIDI1(.flexData), .notMIDI1(.stream), .notMIDI1(.reserved6)
        ])
    }

    @Test func truncatedBatchGivesNoBytes() {
        let lone64 = Self.decodeOnce([Self.channelWord(0x90, 0x3C, 0x64), 0x3001_7E00])
        #expect(lone64.bytes.isEmpty)
        #expect(lone64.skipped == [.malformed(.truncated(mt: .data64, have: 1, need: 2))])

        let lone128 = Self.decodeOnce([Self.systemWord(0xF8), 0x5000_0000, 0, 0])
        #expect(lone128.bytes.isEmpty)
        #expect(lone128.skipped == [.malformed(.truncated(mt: .data128, have: 3, need: 4))])
    }

    @Test func batchAboveTheSplitterBoundIsRefusedWhole() {
        let atBound = Self.decodeOnce(Array(repeating: Self.systemWord(0xF8), count: 4096))
        #expect(atBound.bytes == Array(repeating: 0xF8, count: 4096))
        #expect(atBound.skipped.isEmpty)

        let aboveBound = Self.decodeOnce(Array(repeating: Self.systemWord(0xF8), count: 4097))
        #expect(aboveBound.bytes.isEmpty)
        #expect(aboveBound.skipped == [.malformed(.batchTooLarge(count: 4097, limit: 4096))])
    }

    @Test func refusedPacketGivesNoBytesAndDecodingContinues() throws {
        let words: [UInt32] = [
            Self.channelWord(0x90, 0x3C, 0x64),
            Self.channelWord(0x95, 0x80, 0x10),   // data byte with bit 7 set
            Self.systemWord(0xF4),                // undefined System Common
            Self.channelWord(0xC0, 0x05, 0x01),   // Program Change with a non-zero unused byte
            Self.channelWord(0x80, 0x3C, 0x00)
        ]
        let decoded = Self.decodeOnce(words)
        #expect(decoded.bytes == [0x90, 0x3C, 0x64, 0x80, 0x3C, 0x00])
        try #require(decoded.skipped.count == 3)
        #expect(decoded.skipped == [
            .malformed(.invalidMIDI1Message(status: 0x95, data1: 0x80, data2: 0x10)),
            .malformed(.reservedStatus(mt: .system, status: 0xF4)),
            .malformed(.reservedBitsSet(mt: .midi1ChannelVoice, status: 0xC0))
        ])
    }

    @Test func emptyBatchGivesNothing() {
        #expect(Self.decodeOnce([]) == MIDI1UMPInputDecoding(bytes: [], skipped: []))
    }

    // MARK: Differential

    @Test func decodedBytesParseLikeTheOriginalBytes() throws {
        let messages: [[UInt8]] = [
            [0x90, 0x3C, 0x64], [0x9F, 0x00, 0x00], [0x84, 0x40, 0x7F], [0xA2, 0x30, 0x10], [0xB9, 0x01, 0x00],
            [0xCE, 0x7F], [0xD1, 0x00], [0xE7, 0x7F, 0x7F], [0xF1, 0x71], [0xF2, 0x7F, 0x7F], [0xF3, 0x00],
            [0xF6], [0xF8], [0xFA], [0xFB], [0xFC], [0xFE], [0xFF]
        ]
        var words: [UInt32] = []
        for message in messages {
            let status = try #require(message.first)
            let data = Array(message.dropFirst())
            let type: UInt32 = status >= 0xF0 ? 0x1 : 0x2
            words.append(Self.word(type, group: 0, status, data.first ?? 0, data.dropFirst().first ?? 0))
        }
        let original = messages.flatMap { $0 }
        let decoded = Self.decodeOnce(words)
        #expect(decoded.skipped.isEmpty)
        let expected = try events(original)
        try #require(expected.count == messages.count)
        #expect(try events(decoded.bytes) == expected)
    }
}
