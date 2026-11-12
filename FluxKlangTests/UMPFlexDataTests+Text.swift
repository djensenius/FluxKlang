import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private struct FlexTextVector {
    let words: [UInt32]
    let group: UInt8
    let address: UMPFlexDataAddress
    let form: UMPFlexDataForm
    let kind: UMPFlexDataTextKind
    let bytes: [UInt8]
}

/// UMP Flex Data (MT 0xD) text packets, status banks 0x01 (Metadata Text) and 0x02 (Performance Text Events). Golden
/// words are written by hand from bl-midi2-rs (`midi2/src/flex_data.rs`, `flex_data/unknown_metadata_text.rs`) and
/// ni-midi2 (`tests/flex_data_message_tests.cpp`), or by hand with a distinct byte in every position.
extension UMPFlexDataTests {
    static func decodeText(_ words: [UInt32]) throws -> UMPFlexDataTextPacket {
        try UMPFlexDataTextPacket(decoding: UMPPacket(words: words))
    }

    static func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

    private static func textVectors() throws -> [FlexTextVector] {
        let twelve = UMPFlexDataAddress.channel(try UMPChannel(12))
        let ten = UMPFlexDataAddress.channel(try UMPChannel(10))
        let lyricist = UMPFlexDataTextKind.metadata(.lyricistName)
        let rubyLanguage = UMPFlexDataTextKind.performance(.rubyLanguage)
        return [
            // Distinct bytes: group 0xB, start, channel 10, bank 0x02, Ruby (0x03), text "ABCDEFGHIJKL".
            FlexTextVector(words: [0xDB4A_0203, 0x4142_4344, 0x4546_4748, 0x494A_4B4C], group: 0xB, address: ten,
                           form: .start, kind: .performance(.ruby), bytes: Array(0x41...0x4C)),
            // bl-midi2-rs flex_data.rs `try_from_text`: Lyricist Name "Gimme some signal!".
            FlexTextVector(words: [0xD050_0106, 0x4769_6D6D, 0x6520_736F, 0x6D65_2073], group: 0, address: .group,
                           form: .start, kind: lyricist, bytes: ascii("Gimme some s")),
            FlexTextVector(words: [0xD0D0_0106, 0x6967_6E61, 0x6C21_0000, 0], group: 0, address: .group,
                           form: .end, kind: lyricist, bytes: ascii("ignal!")),
            // bl-midi2-rs unknown_metadata_text.rs `new`: an empty complete packet.
            FlexTextVector(words: [0xD010_0100, 0, 0, 0], group: 0, address: .group, form: .complete,
                           kind: .metadata(.unknown), bytes: []),
            // ni-midi2 `make_flex_data_text_message`: channel 12, bank 0x01 status 0x07.
            FlexTextVector(words: [0xD10C_0107, 0x7465_7374, 0x7465_7874, 0], group: 1, address: twelve,
                           form: .complete, kind: .metadata(.arrangerName), bytes: ascii("testtext")),
            // ni-midi2: bank 0x02 status 0x04 in four packets, group 5.
            FlexTextVector(words: [0xD550_0204, 0x5468_6973, 0x2069_7320, 0x6120_6D75], group: 5, address: .group,
                           form: .start, kind: rubyLanguage, bytes: ascii("This is a mu")),
            FlexTextVector(words: [0xD590_0204, 0x6C74_692D, 0x7061_636B, 0x6574_2063], group: 5, address: .group,
                           form: .continuation, kind: rubyLanguage, bytes: ascii("lti-packet c")),
            FlexTextVector(words: [0xD590_0204, 0x6F70_7972, 0x6967_6874, 0x206E_6F74], group: 5, address: .group,
                           form: .continuation, kind: rubyLanguage, bytes: ascii("opyright not")),
            FlexTextVector(words: [0xD5D0_0204, 0x6963_6500, 0, 0], group: 5, address: .group,
                           form: .end, kind: rubyLanguage, bytes: ascii("ice"))
        ]
    }

    // MARK: Text goldens and round trips

    @Test func textGoldensDecodeAndEncode() throws {
        for vector in try Self.textVectors() {
            let decoded = try Self.decodeText(vector.words)
            #expect(decoded.group.value == vector.group, "\(vector.words)")
            #expect(decoded.address == vector.address, "\(vector.words)")
            #expect(decoded.form == vector.form, "\(vector.words)")
            #expect(decoded.kind == vector.kind, "\(vector.words)")
            #expect(decoded.bytes == vector.bytes, "\(vector.words)")
            #expect(decoded.packet.words == vector.words)
            let built = try UMPFlexDataTextPacket(
                group: try UMPGroup(vector.group), address: vector.address, form: vector.form, kind: vector.kind,
                bytes: vector.bytes
            )
            #expect(built.packet.words == vector.words)
            #expect(built.packet.messageType == .flexData)
            #expect(built == decoded)
        }
    }

    @Test func textWireValuesArePinned() {
        #expect(UMPFlexDataMetadataText.allCases.map(\.rawValue) == Array(0x00...0x0C))
        #expect(UMPFlexDataPerformanceText.allCases.map(\.rawValue) == Array(0x00...0x04))
        #expect(UMPFlexDataTextKind(bank: 0x01, status: 0x0C) == .metadata(.recordingLocation))
        #expect(UMPFlexDataTextKind(bank: 0x02, status: 0x04) == .performance(.rubyLanguage))
        #expect(UMPFlexDataForm.allCases.map(\.rawValue) == [0, 1, 2, 3])
        #expect((UInt32(0)...7).map { UMPFlexDataForm(bits: $0) }
            == [.complete, .start, .continuation, .end, .complete, .start, .continuation, .end])
    }

    @Test func everyTextStatusRoundTripsInEveryFormAndAddress() throws {
        let kinds = UMPFlexDataMetadataText.allCases.map(UMPFlexDataTextKind.metadata)
            + UMPFlexDataPerformanceText.allCases.map(UMPFlexDataTextKind.performance)
        #expect(kinds.count == 18)
        let addresses: [(UMPFlexDataAddress, UInt32)] = [
            (.group, 0x0010_0000), (.channel(try UMPChannel(0)), 0), (.channel(try UMPChannel(15)), 0x000F_0000)
        ]
        for kind in kinds {
            for form in UMPFlexDataForm.allCases {
                for (address, addressBits) in addresses {
                    let first = 0xD300_0000 | UInt32(form.rawValue) << 22 | addressBits | UInt32(kind.bank) << 8
                        | UInt32(kind.status)
                    // An interior 0x00 is kept; trailing 0x00 bytes are padding only for complete and end.
                    let words: [UInt32] = [first, 0xE282_AC00, 0x32F0_9F8E, 0xB531_0000]
                    let text: [UInt8] = [0xE2, 0x82, 0xAC, 0x00, 0x32, 0xF0, 0x9F, 0x8E, 0xB5, 0x31]
                    let full = form == .start || form == .continuation
                    let decoded = try Self.decodeText(words)
                    #expect(decoded.kind == kind)
                    #expect(decoded.form == form)
                    #expect(decoded.address == address)
                    #expect(decoded.group.value == 3)
                    #expect(decoded.bytes == (full ? text + [0, 0] : text))
                    #expect(decoded.packet.words == words)
                }
            }
        }
    }

    @Test func textKeepsEveryLengthAndGroup() throws {
        for length in 0...12 {
            let bytes = (0..<length).map { UInt8(0x61 + $0) }
            var words: [UInt32] = [0xD010_0201 | UInt32(length) << 24, 0, 0, 0]
            for (offset, byte) in bytes.enumerated() {
                words[1 + offset / 4] |= UInt32(byte) << (24 - 8 * UInt32(offset % 4))
            }
            let decoded = try Self.decodeText(words)
            #expect(decoded.bytes == bytes)
            #expect(decoded.group.value == UInt8(length))
            #expect(decoded.packet.words == words)
        }
    }

    // MARK: Splitter

    @Test func splitterEdgesGiveFormsAndChunks() throws {
        // Group 9, channel 3, Lyrics: word 0 is 0xD9 | form << 6 | 0x03, then 0x0201.
        // Text length, then each packet's (word 0, byte count).
        let cases: [(Int, [(UInt32, Int)])] = [
            (0, [(0xD903_0201, 0)]),
            (1, [(0xD903_0201, 1)]),
            (12, [(0xD903_0201, 12)]),
            (13, [(0xD943_0201, 12), (0xD9C3_0201, 1)]),
            (24, [(0xD943_0201, 12), (0xD9C3_0201, 12)]),
            (25, [(0xD943_0201, 12), (0xD983_0201, 12), (0xD9C3_0201, 1)])
        ]
        let channel = UMPFlexDataAddress.channel(try UMPChannel(3))
        for (length, expected) in cases {
            let firstWords = expected.map(\.0)
            let sizes = expected.map(\.1)
            let text = (0..<length).map { UInt8(0x30 + $0) }
            let packets = try UMPFlexDataTextPacket.packets(
                group: try UMPGroup(9), address: channel, kind: .performance(.lyrics), text: text
            )
            #expect(packets.compactMap { $0.packet.words.first } == firstWords, "\(length)")
            #expect(packets.map(\.bytes.count) == sizes, "\(length)")
            #expect(packets.flatMap(\.bytes) == text)
            for packet in packets {
                #expect(try Self.decodeText(packet.packet.words) == packet)
            }
        }
    }

    @Test func splitterMatchesBlMidi2Goldens() throws {
        let daw = try UMPFlexDataTextPacket.packets(
            group: try UMPGroup(0), address: .group, kind: .metadata(.unknown),
            text: Self.ascii("Digital Audio Workstation - DAW36-16")
        )
        #expect(daw.flatMap(\.packet.words) == [
            0xD050_0100, 0x4469_6769, 0x7461_6C20, 0x4175_6469,
            0xD090_0100, 0x6F20_576F, 0x726B_7374, 0x6174_696F,
            0xD0D0_0100, 0x6E20_2D20, 0x4441_5733, 0x362D_3136
        ])
        // set_long_text: the last three emoji (4 UTF-8 bytes each) straddle the last two packets byte-wise.
        let text = Self.ascii("Synth wizardry: turning knobs and flipping switches until it sounds like a laser battle "
            + "in space! \u{1F4AB}\u{1F50A}\u{1F680}")
        #expect(text.count == 110)
        let packets = try UMPFlexDataTextPacket.packets(
            group: try UMPGroup(0), address: .group, kind: .metadata(.unknown), text: text
        )
        #expect(packets.map(\.form) == [.start] + Array(repeating: .continuation, count: 8) + [.end])
        #expect(packets.flatMap(\.packet.words) == [
            0xD050_0100, 0x5379_6E74, 0x6820_7769, 0x7A61_7264,
            0xD090_0100, 0x7279_3A20, 0x7475_726E, 0x696E_6720,
            0xD090_0100, 0x6B6E_6F62, 0x7320_616E, 0x6420_666C,
            0xD090_0100, 0x6970_7069, 0x6E67_2073, 0x7769_7463,
            0xD090_0100, 0x6865_7320, 0x756E_7469, 0x6C20_6974,
            0xD090_0100, 0x2073_6F75, 0x6E64_7320, 0x6C69_6B65,
            0xD090_0100, 0x2061_206C, 0x6173_6572, 0x2062_6174,
            0xD090_0100, 0x746C_6520, 0x696E_2073, 0x7061_6365,
            0xD090_0100, 0x2120_F09F, 0x92AB_F09F, 0x948A_F09F,
            0xD0D0_0100, 0x9A80_0000, 0x0000_0000, 0x0000_0000
        ])
        let last = try #require(packets.last)
        #expect(last.bytes == [0x9A, 0x80])
    }

    @Test func splitterKeepsInteriorZerosAndRefusesATrailingZero() throws {
        // A 0x00 at the end of the start packet (offset 11) and at the start of the next (offset 12), as a melisma.
        for offset in [0, 11, 12, 23, 24] {
            var text = [UInt8](repeating: 0x7A, count: 26)
            text[offset] = 0
            let packets = try UMPFlexDataTextPacket.packets(
                group: try UMPGroup(0), address: .group, kind: .performance(.lyrics), text: text
            )
            #expect(packets.map(\.form) == [.start, .continuation, .end], "\(offset)")
            #expect(packets.flatMap(\.bytes) == text, "\(offset)")
            for packet in packets {
                #expect(try Self.decodeText(packet.packet.words) == packet, "\(offset)")
            }
        }
        let boundary = try UMPFlexDataTextPacket.packets(
            group: try UMPGroup(0), address: .group, kind: .performance(.lyrics),
            text: Self.ascii("la-la-la-la") + [0, 0] + Self.ascii("ah")
        )
        #expect(boundary.flatMap(\.packet.words) == [
            0xD050_0201, 0x6C61_2D6C, 0x612D_6C61, 0x2D6C_6100,
            0xD0D0_0201, 0x0061_6800, 0, 0
        ])
        for text: [UInt8] in [[0], [0x41, 0], Array(repeating: 0x41, count: 12) + [0], [0x41, 0, 0]] {
            #expect(throws: UMPFlexDataRefusal.trailingZeroByte, "\(text)") {
                try UMPFlexDataTextPacket.packets(
                    group: try UMPGroup(0), address: .group, kind: .metadata(.copyrightNotice), text: text
                )
            }
        }
    }

    // MARK: Text refusals

    @Test func textRefusesOtherMessageTypes() throws {
        for type in UMPMessageType.allCases where type != .flexData {
            let first = UInt32(type.rawValue) << 28 | 0x0010_0101
            let words = [first] + Array(repeating: UInt32(0), count: type.wordCount - 1)
            #expect(throws: UMPFlexDataRefusal.notFlexData(actual: type)) { try Self.decodeText(words) }
        }
    }

    @Test func textRefusesUnknownStatusesAndOtherBanks() throws {
        // Every undefined status of banks 0x01 and 0x02 (including Workbench-only 0x01/0x0D), the bank 0x00 messages,
        // and status 0x00 and 0x01 of banks 0x03...0xFF.
        var pairs = (UInt32(0x0D)...0xFF).map { (UInt32(1), $0) } + (UInt32(0x05)...0xFF).map { (UInt32(2), $0) }
        pairs += [(0, 0x00), (0, 0x01), (0, 0x02), (0, 0x05), (0, 0x06)]
        for bank in UInt32(3)...0xFF {
            pairs += [(bank, 0x00), (bank, 0x01)]
        }
        #expect(pairs.count == 243 + 251 + 5 + 253 * 2)
        for (bank, status) in pairs {
            let words: [UInt32] = [0xD050_0000 | bank << 8 | status, 0x4100_0000, 0, 0]
            #expect(throws: UMPFlexDataRefusal.unknownStatus(bank: UInt8(bank), status: UInt8(status))) {
                try Self.decodeText(words)
            }
        }
    }

    @Test func textRefusesReservedAddressesAndIgnoresChannelNibbleWhenGroupAddressed() throws {
        // "ABCDEFGHIJKL": 12 bytes, valid in every form.
        let data: [UInt32] = [0x4142_4344, 0x4546_4748, 0x494A_4B4C]
        for form in UInt32(0)...3 {
            for address in UInt32(2)...3 {
                let words: [UInt32] = [0xD000_0201 | form << 22 | address << 20, 0, 0, 0]
                #expect(throws: UMPFlexDataRefusal.reservedAddress(status: 1, address: UInt8(address))) {
                    try Self.decodeText(words)
                }
            }
            // Bank 0x01 (metadata) status 0x0C and bank 0x02 (performance) status 0x01.
            for (bank, status) in [(UInt32(0x01), UInt32(0x0C)), (0x02, 0x01)] {
                let kind = UMPFlexDataTextKind(bank: UInt8(bank), status: UInt8(status))
                #expect(kind != nil)
                let cleared: [UInt32] = [0xD310_0000 | form << 22 | bank << 8 | status] + data
                for channel in UInt32(1)...15 {
                    let words: [UInt32] = [0xD310_0000 | form << 22 | channel << 16 | bank << 8 | status] + data
                    let decoded = try Self.decodeText(words)
                    #expect(decoded.group.value == 3)
                    #expect(decoded.address == .group)
                    #expect(decoded.form.rawValue == UInt8(form))
                    #expect(decoded.kind == kind)
                    #expect(decoded.bytes == Self.ascii("ABCDEFGHIJKL"))
                    #expect(decoded.packet.words == cleared)
                    #expect(decoded == (try Self.decodeText(cleared)))
                }
            }
        }
    }

    @Test func textDecodeKeepsInteriorZerosAndDropsOnlyTrailingPadding() throws {
        // A cmidi2-style melisma "la\0a" in every form: start and continuation keep all 12 bytes.
        let words: [UInt32] = [0, 0x6C61_0061, 0, 0]
        let melisma: [UInt8] = [0x6C, 0x61, 0x00, 0x61]
        for form in UMPFlexDataForm.allCases {
            let packet = [0xD010_0201 | UInt32(form.rawValue) << 22] + words[1...]
            let decoded = try Self.decodeText(packet)
            let full = form == .start || form == .continuation
            #expect(decoded.bytes == (full ? melisma + Array(repeating: 0, count: 8) : melisma))
            #expect(decoded.packet.words == packet)
        }
        // Every single interior 0x00 position of a complete packet round-trips.
        for zero in 0..<11 {
            var bytes = [UInt8](repeating: 0x42, count: 12)
            bytes[zero] = 0
            let built = try UMPFlexDataTextPacket(
                group: try UMPGroup(0), address: .group, form: .complete, kind: .metadata(.projectName), bytes: bytes
            )
            #expect(try Self.decodeText(built.packet.words) == built, "\(zero)")
        }
        // An all-zero end packet is an empty end.
        #expect(try Self.decodeText([0xD0D0_0101, 0, 0, 0]).bytes.isEmpty)
    }

    @Test func textInitRefusesLongShortAndTrailingZeroText() throws {
        let group = try UMPGroup(0)
        let kind = UMPFlexDataTextKind.performance(.lyrics)
        #expect(throws: UMPFlexDataRefusal.textTooLong(byteCount: 13)) {
            try UMPFlexDataTextPacket(group: group, address: .group, form: .complete, kind: kind,
                                      bytes: Array(repeating: 0, count: 13))
        }
        for form in [UMPFlexDataForm.start, .continuation] {
            for count in [0, 1, 11] {
                #expect(throws: UMPFlexDataRefusal.notFullPacket(byteCount: count)) {
                    try UMPFlexDataTextPacket(group: group, address: .group, form: form, kind: kind,
                                              bytes: Array(repeating: 0x41, count: count))
                }
            }
        }
        for form in [UMPFlexDataForm.complete, .end] {
            for bytes: [UInt8] in [[0], [0x41, 0], Array(repeating: 0x41, count: 11) + [0]] {
                #expect(throws: UMPFlexDataRefusal.trailingZeroByte) {
                    try UMPFlexDataTextPacket(group: group, address: .group, form: form, kind: kind, bytes: bytes)
                }
            }
        }
        let trailingZero = try UMPFlexDataTextPacket(
            group: group, address: .group, form: .start, kind: kind, bytes: Array(repeating: 0x41, count: 11) + [0]
        )
        #expect(trailingZero.packet.words == [0xD050_0201, 0x4141_4141, 0x4141_4141, 0x4141_4100])
        let full = try UMPFlexDataTextPacket(
            group: group, address: .group, form: .continuation, kind: kind, bytes: Array(repeating: 0xFF, count: 12)
        )
        #expect(full.packet.words == [0xD090_0201, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF])
    }

    @Test func bankZeroStatusesStillRefuseLaterFormsAndText() throws {
        for status in [UInt32(0), 1, 5] {
            for form in UInt32(1)...3 {
                let words: [UInt32] = [0xD010_0000 | form << 22 | status, 0x0402_0800 * (status & 1), 0, 0]
                #expect(throws: UMPFlexDataRefusal.wrongFormat(status: UInt8(status), format: UInt8(form))) {
                    try Self.decode(words)
                }
            }
        }
        for vector in try Self.textVectors() {
            let first = try #require(vector.words.first)
            #expect(throws: UMPFlexDataRefusal.unknownStatus(bank: UInt8((first >> 8) & 0xFF),
                                                             status: UInt8(first & 0xFF))) {
                try Self.decode(vector.words)
            }
        }
    }

    @Test func textRefusalOrderFollowsTheDocumentedSequence() throws {
        // Unknown status beats address. A reserved address is refused even with a channel nibble set.
        #expect(throws: UMPFlexDataRefusal.unknownStatus(bank: 1, status: 0x0D)) {
            try Self.decodeText([0xD0FF_010D, 0x0041_0000, 0, 0])
        }
        #expect(throws: UMPFlexDataRefusal.reservedAddress(status: 4, address: 3)) {
            try Self.decodeText([0xD03F_0204, 0x0041_0000, 0, 0])
        }
    }
}
