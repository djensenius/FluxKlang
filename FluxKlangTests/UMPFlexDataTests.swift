import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private struct FlexDataVector {
    let words: [UInt32]
    let group: UInt8
    let address: UMPFlexDataAddress
    let content: UMPFlexDataContent
}

/// UMP Flex Data (MT 0xD), status bank 0x00: Set Tempo, Set Time Signature and Set Key Signature. Every golden word
/// was written by hand from the published test vectors of bl-midi2-rs (`midi2/src/flex_data/set_*.rs`) and
/// ni-midi2 (`tests/flex_data_message_tests.cpp`), not computed by the production code.
@Suite("UMP Flex Data", .productionAccessAudit)
struct UMPFlexDataTests {
    static func decode(_ words: [UInt32]) throws -> UMPFlexDataMessage {
        try UMPFlexDataMessage(decoding: UMPPacket(words: words))
    }

    static func key(_ sharpsOrFlats: Int8, _ tonic: UMPFlexDataTonic) throws -> UMPFlexDataContent {
        .setKeySignature(try UMPFlexDataKeySignature(sharpsOrFlats: sharpsOrFlats, tonic: tonic))
    }

    static func time(_ numerator: UInt8, _ exponent: UInt8, _ notes: UInt8) -> UMPFlexDataContent {
        .setTimeSignature(UMPFlexDataTimeSignature(
            numerator: numerator, denominatorExponent: exponent, thirtySecondNotes: notes
        ))
    }

    private static func vectors() throws -> [FlexDataVector] {
        let thirteen = UMPFlexDataAddress.channel(try UMPChannel(13))
        let five = UMPFlexDataAddress.channel(try UMPChannel(5))
        return [
            // bl-midi2-rs set_tempo.rs `builder`.
            FlexDataVector(words: [0xD710_0000, 0xF751_FE05, 0, 0], group: 7, address: .group,
                           content: .setTempo(tenNanosecondsPerQuarterNote: 0xF751_FE05)),
            // ni-midi2 `make_set_tempo_message(2, 500 ms)`: 120 bpm.
            FlexDataVector(words: [0xD210_0000, 0x02FA_F080, 0, 0], group: 2, address: .group,
                           content: .setTempo(tenNanosecondsPerQuarterNote: 50_000_000)),
            // bl-midi2-rs set_time_signature.rs `builder`.
            FlexDataVector(words: [0xDA10_0001, 0xCD90_7E00, 0, 0], group: 0xA, address: .group,
                           content: time(0xCD, 0x90, 0x7E)),
            // ni-midi2 `make_set_time_signature_message(7, 3, 4, 8)`: 3/16.
            FlexDataVector(words: [0xD710_0001, 0x0304_0800, 0, 0], group: 7, address: .group,
                           content: time(3, 4, 8)),
            // 4/4 with eight 1/32 notes.
            FlexDataVector(words: [0xD010_0001, 0x0402_0800, 0, 0], group: 0, address: .group,
                           content: time(4, 2, 8)),
            // bl-midi2-rs set_key_signature.rs `setters`, `set_flats`, `builder_channel`.
            FlexDataVector(words: [0xD410_0005, 0x5400_0000, 0, 0], group: 4, address: .group,
                           content: try key(5, .noteD)),
            FlexDataVector(words: [0xD410_0005, 0xB400_0000, 0, 0], group: 4, address: .group,
                           content: try key(-5, .noteD)),
            FlexDataVector(words: [0xD40D_0005, 0x8000_0000, 0, 0], group: 4, address: thirteen,
                           content: try key(-8, .nonStandard)),
            // ni-midi2 `make_set_key_signature_message` vectors.
            FlexDataVector(words: [0xD505_0005, 0xB300_0000, 0, 0], group: 5, address: five,
                           content: try key(-5, .noteC)),
            FlexDataVector(words: [0xDC10_0005, 0x7200_0000, 0, 0], group: 0xC, address: .group,
                           content: try key(7, .noteB))
        ]
    }

    // MARK: Goldens and round trips

    @Test func goldensDecodeAndEncode() throws {
        for vector in try Self.vectors() {
            let decoded = try Self.decode(vector.words)
            #expect(decoded.group.value == vector.group, "\(vector.words)")
            #expect(decoded.address == vector.address, "\(vector.words)")
            #expect(decoded.content == vector.content, "\(vector.words)")
            #expect(decoded.packet.words == vector.words)
            let built = try UMPFlexDataMessage(
                group: try UMPGroup(vector.group), address: vector.address, content: vector.content
            )
            #expect(built.packet.words == vector.words)
            #expect(built.packet.messageType == .flexData)
            #expect(built == decoded)
        }
    }

    @Test func tempoBoundariesRoundTripInEveryGroup() throws {
        for group in UInt8(0)...15 {
            for (units, data) in [(UInt32(0), UInt32(0)), (0xFFFF_FFFF, 0xFFFF_FFFF), (1, 1)] {
                let words: [UInt32] = [0xD010_0000 | UInt32(group) << 24, data, 0, 0]
                let decoded = try Self.decode(words)
                #expect(decoded.content == .setTempo(tenNanosecondsPerQuarterNote: units))
                #expect(decoded.group.value == group)
                #expect(decoded.address == .group)
                let built = try UMPFlexDataMessage(
                    group: try UMPGroup(group), address: .group, content: .setTempo(tenNanosecondsPerQuarterNote: units)
                )
                #expect(built.packet.words == words)
            }
        }
    }

    @Test func timeSignatureByteBoundariesRoundTrip() throws {
        let cases: [(UInt32, UMPFlexDataContent)] = [
            (0x0000_0000, Self.time(0, 0, 0)),
            (0xFFFF_FF00, Self.time(0xFF, 0xFF, 0xFF)),
            (0x0603_0C00, Self.time(6, 3, 12))
        ]
        for (data, content) in cases {
            let words: [UInt32] = [0xD310_0001, data, 0, 0]
            #expect(try Self.decode(words).content == content)
            let built = try UMPFlexDataMessage(group: try UMPGroup(3), address: .group, content: content)
            #expect(built.packet.words == words)
        }
    }

    @Test func keySignatureEverySharpsFlatsAndTonic() throws {
        // Signed nibble, hand-written: 0...7 sharps, 0x8 = -8, 0x9...0xF = -7...-1.
        let nibbles: [(Int8, UInt32)] = [
            (-8, 0x8), (-7, 0x9), (-6, 0xA), (-5, 0xB), (-4, 0xC), (-3, 0xD), (-2, 0xE), (-1, 0xF),
            (0, 0x0), (1, 0x1), (2, 0x2), (3, 0x3), (4, 0x4), (5, 0x5), (6, 0x6), (7, 0x7)
        ]
        #expect(Set(nibbles.map(\.1)) == Set(UInt32(0)...15))
        let tonics: [UMPFlexDataTonic] = [.nonStandard, .noteA, .noteB, .noteC, .noteD, .noteE, .noteF, .noteG]
        #expect(tonics.map(\.rawValue) == Array(0...7))
        #expect(UMPFlexDataTonic.allCases == tonics)
        for (sharpsOrFlats, nibble) in nibbles {
            for tonic in tonics {
                let words: [UInt32] = [0xD010_0005, nibble << 28 | UInt32(tonic.rawValue) << 24, 0, 0]
                let decoded = try Self.decode(words)
                guard case .setKeySignature(let key) = decoded.content else {
                    Issue.record("not a key signature: \(words)")
                    continue
                }
                #expect(key.sharpsOrFlats == sharpsOrFlats)
                #expect(key.tonic == tonic)
                let built = try UMPFlexDataMessage(
                    group: try UMPGroup(0), address: .group, content: try Self.key(sharpsOrFlats, tonic)
                )
                #expect(built.packet.words == words)
            }
        }
    }

    @Test func keySignatureKeepsEveryGroupAndChannel() throws {
        for group in UInt8(0)...15 {
            for channel in UInt8(0)...15 {
                let words: [UInt32] = [0xD000_0005 | UInt32(group) << 24 | UInt32(channel) << 16, 0x2600_0000, 0, 0]
                let decoded = try Self.decode(words)
                #expect(decoded.group.value == group)
                #expect(decoded.address == .channel(try UMPChannel(channel)))
                #expect(decoded.content == (try Self.key(2, .noteF)))
                #expect(decoded.packet.words == words)
            }
        }
    }

    // MARK: Refusals

    @Test func refusesOtherMessageTypes() throws {
        for type in UMPMessageType.allCases where type != .flexData {
            let first = UInt32(type.rawValue) << 28 | 0x0010_0000
            let words = [first] + Array(repeating: UInt32(0), count: type.wordCount - 1)
            #expect(throws: UMPFlexDataRefusal.notFlexData(actual: type)) { try Self.decode(words) }
        }
    }

    @Test func refusesOtherStatusesAndBanks() throws {
        // Sampled: every other status of bank 0x00, and the decoded statuses 0x00/0x01/0x05 in banks 0x01...0xFF.
        var pairs = (UInt32(0)...0xFF).filter { ![0x00, 0x01, 0x05].contains($0) }.map { (UInt32(0), $0) }
        for bank in UInt32(1)...0xFF {
            pairs += [(bank, 0x00), (bank, 0x01), (bank, 0x05)]
        }
        #expect(pairs.count == 253 + 255 * 3)
        for (bank, status) in pairs {
            let words: [UInt32] = [0xD010_0000 | bank << 8 | status, 0, 0, 0]
            #expect(throws: UMPFlexDataRefusal.unknownStatus(bank: UInt8(bank), status: UInt8(status))) {
                try Self.decode(words)
            }
        }
        // Set Metronome and Set Chord Name are known but not decoded; text start packets are refused before form.
        #expect(throws: UMPFlexDataRefusal.unknownStatus(bank: 0, status: 2)) {
            try Self.decode([0xD010_0002, 0x1803_0000, 0x0200_0000, 0])
        }
        #expect(throws: UMPFlexDataRefusal.unknownStatus(bank: 0, status: 6)) {
            try Self.decode([0xD70B_0006, 0xF703_3519, 0x4B00_0000, 0x110A_0020])
        }
        #expect(throws: UMPFlexDataRefusal.unknownStatus(bank: 1, status: 1)) {
            try Self.decode([0xD050_0101, 0x4142_4344, 0x4546_4748, 0x494A_4B4C])
        }
    }

    @Test func refusesEveryFormButComplete() throws {
        for status in [UInt32(0), 1, 5] {
            for format in UInt32(1)...3 {
                let words: [UInt32] = [0xD010_0000 | format << 22 | status, 0, 0, 0]
                #expect(throws: UMPFlexDataRefusal.wrongFormat(status: UInt8(status), format: UInt8(format))) {
                    try Self.decode(words)
                }
            }
        }
    }

    @Test func refusesReservedAddresses() throws {
        for status in [UInt32(0), 1, 5] {
            for address in UInt32(2)...3 {
                let words: [UInt32] = [0xD000_0000 | address << 20 | status, 0, 0, 0]
                #expect(throws: UMPFlexDataRefusal.reservedAddress(status: UInt8(status), address: UInt8(address))) {
                    try Self.decode(words)
                }
            }
        }
    }

    @Test func decodesChannelAddressForTempoAndTimeSignature() throws {
        // Lenient receive: ni-midi2, AM_MIDI2.0Lib, midi2.0lib and the Workbench accept address 0 for every status.
        // Status to (word 1, content).
        let cases: [UInt32: (UInt32, UMPFlexDataContent)] = [
            0: (0x02FA_F080, .setTempo(tenNanosecondsPerQuarterNote: 50_000_000)),
            1: (0x0402_0800, Self.time(4, 2, 8))
        ]
        for (status, (data, content)) in cases {
            for group in [UInt32(0), 9] {
                for channel in [UInt32(0), 1, 7, 15] {
                    let words: [UInt32] = [0xD000_0000 | group << 24 | channel << 16 | status, data, 0, 0]
                    let decoded = try Self.decode(words)
                    #expect(decoded.group.value == UInt8(group))
                    #expect(decoded.address == .channel(try UMPChannel(UInt8(channel))))
                    #expect(decoded.content == content)
                    #expect(decoded.packet.words == words)
                    // The address is part of equality: the group-addressed decode of the same data differs.
                    let grouped = try Self.decode([0xD010_0000 | group << 24 | status, data, 0, 0])
                    #expect(grouped.content == content)
                    #expect(decoded != grouped)
                }
            }
        }
    }

    @Test func refusesBuildingChannelAddressForTempoAndTimeSignature() throws {
        // Strict send: bl-midi2-rs writes address 1 for these.
        for group in [UInt8(0), 9] {
            for channel in [UInt8(0), 1, 7, 15] {
                let address = UMPFlexDataAddress.channel(try UMPChannel(channel))
                #expect(throws: UMPFlexDataRefusal.channelAddressNotAllowed(status: 0)) {
                    try UMPFlexDataMessage(
                        group: try UMPGroup(group), address: address,
                        content: .setTempo(tenNanosecondsPerQuarterNote: 50_000_000)
                    )
                }
                #expect(throws: UMPFlexDataRefusal.channelAddressNotAllowed(status: 1)) {
                    try UMPFlexDataMessage(group: try UMPGroup(group), address: address, content: Self.time(4, 2, 8))
                }
            }
        }
    }

    @Test func ignoresChannelNibbleWhenGroupAddressed() throws {
        // Status to (word 1, content).
        let cases: [UInt32: (UInt32, UMPFlexDataContent)] = [
            0: (0x02FA_F080, .setTempo(tenNanosecondsPerQuarterNote: 50_000_000)),
            1: (0x0402_0800, Self.time(4, 2, 8)),
            5: (0xB300_0000, try Self.key(-5, .noteC))
        ]
        for (status, (data, content)) in cases {
            for channel in UInt32(1)...15 {
                let words: [UInt32] = [0xD610_0000 | channel << 16 | status, data, 0, 0]
                let decoded = try Self.decode(words)
                #expect(decoded.group.value == 6)
                #expect(decoded.address == .group)
                #expect(decoded.content == content)
                #expect(decoded.packet.words == [0xD610_0000 | status, data, 0, 0])
                #expect(decoded == (try Self.decode([0xD610_0000 | status, data, 0, 0])))
            }
        }
    }

    @Test func refusesEveryReservedDataBit() throws {
        // Reserved masks per status for words 1, 2, 3.
        let reserved: [(UInt32, [UInt32])] = [
            (0x00, [0, 0xFFFF_FFFF, 0xFFFF_FFFF]),
            (0x01, [0x0000_00FF, 0xFFFF_FFFF, 0xFFFF_FFFF]),
            (0x05, [0x00FF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF])
        ]
        for (status, masks) in reserved {
            for (offset, mask) in masks.enumerated() {
                for bit in UInt32(0)..<32 where mask & (1 << bit) != 0 {
                    var words: [UInt32] = [0xD010_0000 | status, 0, 0, 0]
                    words[offset + 1] = 1 << bit
                    #expect(throws: UMPFlexDataRefusal.reservedBitsSet(status: UInt8(status))) {
                        try Self.decode(words)
                    }
                }
            }
        }
    }

    @Test func refusesReservedTonics() throws {
        for tonic in UInt32(8)...15 {
            let words: [UInt32] = [0xD010_0005, 0x3000_0000 | tonic << 24, 0, 0]
            #expect(throws: UMPFlexDataRefusal.invalidField(.tonic, value: Int(tonic))) { try Self.decode(words) }
        }
    }

    @Test func keySignatureByteLayoutIsNotTheNibbleLayout() throws {
        // AM_MIDI2.0Lib / cmidi2 write sharps/flats as a byte at 31...24 and the tonic as a byte at 23...16. Under the
        // nibble layout (Workbench, ALSA, bl-midi2-rs, ni-midi2) "5 sharps, tonic 0" reads as 0 sharps, tonic E;
        // "5 sharps, tonic 3" is refused for its reserved bits; and "3 flats, tonic 0" (byte 0xFD) puts 13 in the
        // tonic nibble and is refused. All three expectations flip if M2-104-UM uses bytes.
        let misread = try Self.decode([0xD010_0005, 0x0500_0000, 0, 0])
        #expect(misread.content == (try Self.key(0, .noteE)))
        #expect(throws: UMPFlexDataRefusal.reservedBitsSet(status: 5)) {
            try Self.decode([0xD010_0005, 0x0503_0000, 0, 0])
        }
        #expect(throws: UMPFlexDataRefusal.invalidField(.tonic, value: 13)) {
            try Self.decode([0xD010_0005, 0xFD00_0000, 0, 0])
        }
        #expect(UMPFlexDataKeySignature.reservedWord1Mask == 0x00FF_FFFF)
        let fromWord = try UMPFlexDataKeySignature(word1: 0xB300_0000)
        #expect(fromWord == (try UMPFlexDataKeySignature(sharpsOrFlats: -5, tonic: .noteC)))
        #expect(fromWord.word1 == 0xB300_0000)
    }

    @Test func keySignatureRefusesSharpsOrFlatsOutsideSignedNibble() throws {
        for value in [Int8.min, -9, 8, Int8.max] {
            #expect(throws: UMPFlexDataRefusal.invalidField(.sharpsOrFlats, value: Int(value))) {
                try UMPFlexDataKeySignature(sharpsOrFlats: value, tonic: .noteC)
            }
        }
        #expect(try UMPFlexDataKeySignature(sharpsOrFlats: -8, tonic: .noteC).sharpsOrFlats == -8)
        #expect(try UMPFlexDataKeySignature(sharpsOrFlats: 7, tonic: .noteC).sharpsOrFlats == 7)
    }

    @Test func refusalOrderFollowsTheDocumentedSequence() throws {
        // Unknown status beats form; form beats address; address beats data bits; data bits beat the tonic. A
        // channel address or an ignored channel nibble never pre-empts the data-bit refusal.
        #expect(throws: UMPFlexDataRefusal.unknownStatus(bank: 0, status: 2)) {
            try Self.decode([0xD0F0_0002, 0xFFFF_FFFF, 1, 1])
        }
        #expect(throws: UMPFlexDataRefusal.wrongFormat(status: 0, format: 3)) {
            try Self.decode([0xD0FF_0000, 0, 1, 1])
        }
        #expect(throws: UMPFlexDataRefusal.reservedAddress(status: 1, address: 3)) {
            try Self.decode([0xD03F_0001, 0xFF, 1, 1])
        }
        #expect(throws: UMPFlexDataRefusal.reservedBitsSet(status: 0)) {
            try Self.decode([0xD00F_0000, 0, 1, 1])
        }
        #expect(throws: UMPFlexDataRefusal.reservedBitsSet(status: 1)) {
            try Self.decode([0xD01F_0001, 0xFF, 0, 0])
        }
        #expect(throws: UMPFlexDataRefusal.reservedBitsSet(status: 5)) {
            try Self.decode([0xD010_0005, 0x0F00_0001, 0, 0])
        }
    }

    @Test func flexDataPacketIsExactlyFourWords() throws {
        #expect(throws: UMPRefusal.wrongWordCount(mt: .flexData, have: 3, need: 4)) {
            try UMPPacket(words: [0xD010_0000, 0, 0])
        }
        let built = try UMPFlexDataMessage(
            group: try UMPGroup(0), address: .group, content: .setTempo(tenNanosecondsPerQuarterNote: 0)
        )
        let first = try #require(built.packet.words.first)
        #expect(built.packet.words.count == 4)
        #expect(first == 0xD010_0000)
    }
}
