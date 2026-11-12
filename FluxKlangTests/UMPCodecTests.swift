import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private enum UMPFixture {
    /// Words of one packet of `type`, the first word carrying `low` under the MT nibble, the rest distinct fillers.
    static func packet(_ type: UMPMessageType, low: UInt32 = 0x0123_4567) -> [UInt32] {
        let first = UInt32(type.rawValue) << 28 | (low & 0x0FFF_FFFF)
        return [first] + (1..<type.wordCount).map { 0xA5A5_0000 | UInt32($0) }
    }

    static func split(_ words: [UInt32]) throws -> [UMPPacket] {
        try UMPStreamSplitter.standard.split(words)
    }
}

#if os(macOS)
@Suite("UMP packet framing", .productionAccessAudit)
#else
@Suite("UMP packet framing")
#endif
struct UMPPacketFramingTests {
    @Test func lengthTableCoversAllSixteenMessageTypes() {
        // M2-104-UM MT allocation: 0/1/2/6/7 = 1; 3/4/8/9/A = 2; B/C = 3; 5/D/E/F = 4 words.
        let expected = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
        #expect(UMPMessageType.allCases.count == 16)
        for (nibble, count) in expected.enumerated() {
            let type = UMPMessageType(firstWord: UInt32(nibble) << 28 | 0x0FFF_FFFF)
            #expect(type.rawValue == UInt8(nibble))
            #expect(type.wordCount == count, "MT \(nibble)")
        }
    }

    @Test func reservedAndGroupedTypes() {
        let reserved: Set<UInt8> = [0x6, 0x7, 0x8, 0x9, 0xA, 0xB, 0xC, 0xE]
        let grouped: Set<UInt8> = [0x1, 0x2, 0x3, 0x4, 0x5, 0xD]
        for type in UMPMessageType.allCases {
            #expect(type.isReserved == reserved.contains(type.rawValue), "MT \(type.rawValue)")
            #expect(type.carriesGroup == grouped.contains(type.rawValue), "MT \(type.rawValue)")
        }
    }

    @Test func everyTypeSplitsAsOnePacketWithExactWords() throws {
        for type in UMPMessageType.allCases {
            let words = UMPFixture.packet(type)
            let packets = try UMPFixture.split(words)
            #expect(packets.count == 1)
            #expect(packets.first?.words == words)
            #expect(packets.first?.messageType == type)
        }
    }

    @Test func mixedStreamKeepsOrderAndWords() throws {
        let stream = UMPMessageType.allCases.reversed().flatMap { UMPFixture.packet($0, low: UInt32($0.rawValue)) }
        let packets = try UMPFixture.split(stream)
        #expect(packets.map(\.messageType) == Array(UMPMessageType.allCases.reversed()))
        #expect(packets.flatMap(\.words) == stream)
    }

    @Test func contractExampleTenWords() throws {
        // media-contract example 10: MT4 note on, MT4 per-note pitch bend, MT2 note on, MT0 JR timestamp.
        let words: [UInt32] = [0x4190_3C03, 0xC925_1E00, 0x4160_3C00, 0x8040_0000, 0x2190_3C64, 0x0020_1F40]
        let packets = try UMPFixture.split(words)
        #expect(packets.map(\.words) == [[0x4190_3C03, 0xC925_1E00], [0x4160_3C00, 0x8040_0000], [0x2190_3C64],
                                          [0x0020_1F40]])
        #expect(packets.map(\.messageType) == [.midi2ChannelVoice, .midi2ChannelVoice, .midi1ChannelVoice, .utility])
        #expect(packets.map { $0.group?.value } == [1, 1, 1, nil])
    }

    @Test func reservedTypesPassThroughVerbatim() throws {
        for type in UMPMessageType.allCases where type.isReserved {
            let words = UMPFixture.packet(type, low: 0x0FFF_FFFF)
            let packets = try UMPFixture.split(words + [0x2090_3C64])
            #expect(packets.map(\.words) == [words, [0x2090_3C64]])
            #expect(packets.first?.group == nil)
        }
    }

    @Test func groupNibbleIsReadOnlyForGroupedTypes() throws {
        for type in UMPMessageType.allCases {
            for group in UInt32(0)...15 {
                let packet = try UMPPacket(words: UMPFixture.packet(type, low: group << 24 | 0x00AB_CDEF))
                #expect(packet.group?.value == (type.carriesGroup ? UInt8(group) : nil))
            }
        }
    }

    @Test func truncatedTailRefusesWholeBatch() throws {
        let lead = [UInt32(0x2090_3C64), 0x4090_3C00, 0xC924_0000]
        for type in UMPMessageType.allCases where type.wordCount > 1 {
            let full = UMPFixture.packet(type)
            for have in 1..<type.wordCount {
                let words = lead + full.prefix(have)
                #expect(throws: UMPRefusal.truncated(mt: type, have: have, need: type.wordCount)) {
                    try UMPFixture.split(words)
                }
            }
            #expect(try UMPFixture.split(lead + full).count == 3)
        }
    }

    @Test func truncationIsMeasuredFromThePacketStart() {
        // A 128-bit packet starting after two 32-bit packets with three words left.
        let words: [UInt32] = [0x1000_0000, 0x2090_3C64, 0xF000_0000, 0, 0]
        #expect(throws: UMPRefusal.truncated(mt: .stream, have: 3, need: 4)) { try UMPFixture.split(words) }
    }

    @Test func emptyBatchSplitsToNothing() throws {
        #expect(try UMPFixture.split([]).isEmpty)
    }

    @Test func batchBoundAcceptsNAndRefusesNPlusOne() throws {
        let splitter = try UMPStreamSplitter(maximumWords: 4)
        #expect(splitter.maximumWords == 4)
        let four = [UInt32](repeating: 0x2090_3C64, count: 4)
        #expect(try splitter.split(four).count == 4)
        #expect(throws: UMPRefusal.batchTooLarge(count: 5, limit: 4)) { try splitter.split(four + [0x2080_3C00]) }
    }

    @Test func standardBoundAcceptsNAndRefusesNPlusOne() throws {
        let limit = UMPStreamSplitter.defaultMaximumWords
        #expect(UMPStreamSplitter.standard.maximumWords == limit)
        let words = [UInt32](repeating: 0x1000_0000, count: limit)
        #expect(try UMPFixture.split(words).count == limit)
        #expect(throws: UMPRefusal.batchTooLarge(count: limit + 1, limit: limit)) {
            try UMPFixture.split(words + [0x1000_0000])
        }
    }

    @Test func splitterBoundIsChecked() throws {
        let limit = UMPStreamSplitter.maximumWordsLimit
        #expect(try UMPStreamSplitter(maximumWords: 1).maximumWords == 1)
        #expect(try UMPStreamSplitter(maximumWords: limit).maximumWords == limit)
        #expect(throws: UMPRefusal.valueOutOfRange(field: .batchLimit, value: 0)) {
            try UMPStreamSplitter(maximumWords: 0)
        }
        #expect(throws: UMPRefusal.valueOutOfRange(field: .batchLimit, value: limit + 1)) {
            try UMPStreamSplitter(maximumWords: limit + 1)
        }
    }

    @Test func packetFactoryChecksWordCount() throws {
        #expect(throws: UMPRefusal.emptyPacket) { try UMPPacket(words: []) }
        for type in UMPMessageType.allCases {
            let words = UMPFixture.packet(type)
            #expect(try UMPPacket(words: words).words == words)
            #expect(throws: UMPRefusal.wrongWordCount(mt: type, have: type.wordCount + 1, need: type.wordCount)) {
                try UMPPacket(words: words + [0])
            }
            if type.wordCount > 1 {
                #expect(throws: UMPRefusal.wrongWordCount(mt: type, have: 1, need: type.wordCount)) {
                    try UMPPacket(words: [words[0]])
                }
            }
        }
    }

    @Test func channelVoiceBuildersForceTheirMessageType() {
        #expect(UMPPacket.midi1ChannelVoice(0xF190_3C64).words == [0x2190_3C64])
        #expect(UMPPacket.midi2ChannelVoice(0x0190_3C00, 0xFFFF_FFFF).words == [0x4190_3C00, 0xFFFF_FFFF])
    }

    @Test func groupAndChannelAndSevenBitFieldsAreChecked() throws {
        #expect(try UMPGroup(15).value == 15)
        #expect(try UMPChannel(15).value == 15)
        #expect(try UMPSevenBit(127).value == 127)
        #expect(throws: UMPRefusal.valueOutOfRange(field: .group, value: 16)) { try UMPGroup(16) }
        #expect(throws: UMPRefusal.valueOutOfRange(field: .channel, value: 16)) { try UMPChannel(16) }
        #expect(throws: UMPRefusal.valueOutOfRange(field: .sevenBit, value: 128)) { try UMPSevenBit(128) }
    }
}

// MARK: - Utility messages (MT 0x0)

extension UMPPacketFramingTests {
    /// Hand-written MT 0x0 words (M2-104-UM v1.1, Utility Messages) and the message each must decode to.
    static let utilityGoldens: [(word: UInt32, message: UMPUtilityMessage)] = [
        (0x0000_0000, .noop),
        (0x0010_1234, .jrClock(senderTime: 0x1234)),
        (0x0010_FFFF, .jrClock(senderTime: 0xFFFF)),
        (0x0020_1F40, .jrTimestamp(0x1F40)), // media-contract example 10
        (0x0030_03C0, .deltaClockstampTicksPerQuarterNote(960)),
        (0x0040_0000, .deltaClockstamp(ticks: 0)),
        (0x004F_FFFF, .deltaClockstamp(ticks: 0xF_FFFF))
    ]

    @Test func utilityGoldensDecodeAndEncode() throws {
        for (word, message) in Self.utilityGoldens {
            let packet = try UMPPacket(words: [word])
            #expect(try UMPUtilityMessage(decoding: packet) == message, "\(word)")
            #expect(try message.packet().words == [word], "\(word)")
        }
    }

    @Test func utilityRoundTrips() throws {
        let messages: [UMPUtilityMessage] = [
            .noop, .jrClock(senderTime: 0), .jrClock(senderTime: 0xABCD), .jrTimestamp(0), .jrTimestamp(0xFFFF),
            .deltaClockstampTicksPerQuarterNote(0), .deltaClockstampTicksPerQuarterNote(0xFFFF),
            .deltaClockstamp(ticks: 1), .deltaClockstamp(ticks: 0x8_0001), .deltaClockstamp(ticks: 0xF_FFFF)
        ]
        for message in messages {
            let packet = try message.packet()
            let word = try #require(packet.words.first)
            #expect(packet.words.count == 1)
            #expect(word & 0x0F00_0000 == 0, "group nibble stays zero")
            #expect(packet.messageType == .utility)
            #expect(try UMPUtilityMessage(decoding: packet) == message)
        }
    }

    @Test func utilityRefusesOtherMessageTypes() throws {
        // A reserved status, group bits and data bits are all set, so the type check must come first.
        for type in UMPMessageType.allCases where type != .utility {
            let packet = try UMPPacket(words: UMPFixture.packet(type, low: 0x0F5F_FFFF))
            #expect(throws: UMPRefusal.wrongMessageType(expected: .utility, actual: type)) {
                try UMPUtilityMessage(decoding: packet)
            }
        }
    }

    @Test func utilityRefusesReservedStatuses() throws {
        for status in UInt32(0x5)...0xF {
            let packet = try UMPPacket(words: [status << 20])
            #expect(throws: UMPRefusal.reservedStatus(mt: .utility, status: UInt8(status))) {
                try UMPUtilityMessage(decoding: packet)
            }
        }
        // Status is checked before reserved bits.
        let both = try UMPPacket(words: [0x0F5F_FFFF])
        #expect(throws: UMPRefusal.reservedStatus(mt: .utility, status: 0x5)) {
            try UMPUtilityMessage(decoding: both)
        }
    }

    @Test func utilityRefusesReservedGroupNibble() throws {
        // MT 0x0 is groupless in UMP 1.1; a UMP 1.0 style group is refused, not ignored.
        for (word, _) in Self.utilityGoldens {
            for group in UInt32(1)...15 {
                let packet = try UMPPacket(words: [word | group << 24])
                let status = UInt8((word >> 20) & 0x0F)
                #expect(throws: UMPRefusal.reservedBitsSet(mt: .utility, status: status), "\(word) g\(group)") {
                    try UMPUtilityMessage(decoding: packet)
                }
            }
        }
    }

    @Test func utilityRefusesReservedDataBits() throws {
        for status in UInt32(0x1)...0x3 {
            for bit in UInt32(16)...19 {
                let packet = try UMPPacket(words: [status << 20 | 1 << bit | 0x1F40])
                #expect(throws: UMPRefusal.reservedBitsSet(mt: .utility, status: UInt8(status)), "\(status) \(bit)") {
                    try UMPUtilityMessage(decoding: packet)
                }
            }
        }
        for bit in UInt32(0)...19 {
            let packet = try UMPPacket(words: [1 << bit])
            #expect(throws: UMPRefusal.reservedBitsSet(mt: .utility, status: 0), "NOOP bit \(bit)") {
                try UMPUtilityMessage(decoding: packet)
            }
        }
    }

    @Test func utilityEncodeRefusesDeltaClockstampAboveTwentyBits() throws {
        #expect(UMPUtilityMessage.maximumDeltaClockstampTicks == 0xF_FFFF)
        #expect(try UMPUtilityMessage.deltaClockstamp(ticks: 0xF_FFFF).packet().words == [0x004F_FFFF])
        for ticks: UInt32 in [0x10_0000, 0xFFFF_FFFF] {
            #expect(throws: UMPRefusal.valueOutOfRange(field: .twentyBit, value: Int(ticks))) {
                try UMPUtilityMessage.deltaClockstamp(ticks: ticks).packet()
            }
        }
    }

    @Test func utilityPacketIsExactlyOneWord() {
        // `UMPPacket` cannot carry a multi-word MT 0x0 packet, so no decoder ever sees one.
        #expect(throws: UMPRefusal.wrongWordCount(mt: .utility, have: 2, need: 1)) {
            try UMPPacket(words: [0x0020_1F40, 0])
        }
    }
}
