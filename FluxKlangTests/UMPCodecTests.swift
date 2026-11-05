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

@Suite("UMP packet framing")
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
