import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - Data Messages (64-bit), SysEx7 (MT 0x3)

extension UMPPacketFramingTests {
    /// Hand-written MT 0x3 words (M2-104-UM, Data Messages (64-bit); Linux `cvt_legacy_sysex_to_ump`; CoreMIDI
    /// `MIDI1UPSysEx`) and the packet each must decode to.
    static func sysEx7Goldens() throws -> [(words: [UInt32], packet: UMPSysEx7Packet)] {
        func make(_ group: UInt8, _ status: UMPSysEx7Status, _ bytes: [UInt8]) throws -> UMPSysEx7Packet {
            try UMPSysEx7Packet(group: UMPGroup(group), status: status, bytes: bytes)
        }
        return [
            ([0x3000_0000, 0x0000_0000], try make(0, .complete, [])),
            ([0x3501_7E00, 0x0000_0000], try make(5, .complete, [0x7E])),
            // Universal Identity Request F0 7E 7F 06 01 F7, payload only.
            ([0x3004_7E7F, 0x0601_0000], try make(0, .complete, [0x7E, 0x7F, 0x06, 0x01])),
            ([0x3012_7E7F, 0x0000_0000], try make(0, .start, [0x7E, 0x7F])),
            ([0x3F23_0102, 0x0300_0000], try make(15, .continue, [0x01, 0x02, 0x03])),
            ([0x3336_1011, 0x1213_1415], try make(3, .end, [0x10, 0x11, 0x12, 0x13, 0x14, 0x15])),
            ([0x3030_0000, 0x0000_0000], try make(0, .end, []))
        ]
    }

    static func sysEx7(_ first: UInt32, _ second: UInt32 = 0) throws -> UMPSysEx7Packet {
        try UMPSysEx7Packet(decoding: UMPPacket(words: [first, second]))
    }

    @Test func sysEx7GoldensDecodeAndEncode() throws {
        for (words, expected) in try Self.sysEx7Goldens() {
            #expect(try UMPSysEx7Packet(decoding: UMPPacket(words: words)) == expected, "\(words)")
            #expect(expected.packet.words == words, "\(words)")
            #expect(expected.packet.messageType == .data64)
        }
        let identity = try #require(Self.sysEx7Goldens().dropFirst(2).first).packet
        #expect(identity.group.value == 0 && identity.status == .complete && identity.bytes == [0x7E, 0x7F, 0x06, 0x01])
    }

    @Test func sysEx7RoundTrips() throws {
        let source: [UInt8] = [0x00, 0x7F, 0x55, 0x2A, 0x01, 0x40]
        for status in UMPSysEx7Status.allCases {
            for count in 0...6 {
                for group: UInt8 in [0, 9, 15] {
                    let message = try UMPSysEx7Packet(
                        group: UMPGroup(group), status: status, bytes: Array(source.prefix(count))
                    )
                    let words = message.packet.words
                    let first = try #require(words.first)
                    #expect(words.count == 2)
                    #expect(first >> 16 == 0x3000 | UInt32(group) << 8 | UInt32(status.rawValue) << 4 | UInt32(count))
                    #expect(try UMPSysEx7Packet(decoding: message.packet) == message, "\(status) \(count)")
                }
            }
        }
    }

    @Test func sysEx7RefusesOtherMessageTypes() throws {
        // A reserved status, an over-long count and high data bits are all set, so the type check must come first.
        for type in UMPMessageType.allCases where type != .data64 {
            let first = UInt32(type.rawValue) << 28 | 0x0FFF_FFFF
            let packet = try UMPPacket(words: [first] + Array(repeating: 0xFFFF_FFFF, count: type.wordCount - 1))
            #expect(throws: UMPRefusal.wrongMessageType(expected: .data64, actual: type)) {
                try UMPSysEx7Packet(decoding: packet)
            }
        }
    }

    @Test func sysEx7RefusesReservedStatuses() throws {
        for status in UInt32(0x4)...0xF {
            #expect(throws: UMPRefusal.reservedStatus(mt: .data64, status: UInt8(status))) {
                try Self.sysEx7(0x3000_0000 | status << 20)
            }
        }
        // Status is checked before the count and the data bits.
        #expect(throws: UMPRefusal.reservedStatus(mt: .data64, status: 0x8)) {
            try Self.sysEx7(0x308F_FFFF, 0xFFFF_FFFF)
        }
    }

    @Test func sysEx7RefusesByteCountAboveSix() throws {
        for count in UInt32(7)...15 {
            #expect(throws: UMPRefusal.valueOutOfRange(field: .sysEx7ByteCount, value: Int(count))) {
                try Self.sysEx7(0x3000_0000 | count << 16)
            }
        }
        // The count is checked before the data bits.
        #expect(throws: UMPRefusal.valueOutOfRange(field: .sysEx7ByteCount, value: 15)) {
            try Self.sysEx7(0x301F_FFFF, 0xFFFF_FFFF)
        }
    }

    @Test func sysEx7RefusesHighBitInUsedBytes() throws {
        // Byte slots 1...6 in wire order: word 0 bits 15...8 and 7...0, then word 1 from the top.
        let highBits: [(UInt32, UInt32)] = [
            (0x8000, 0), (0x0080, 0), (0, 0x8000_0000), (0, 0x0080_0000), (0, 0x0000_8000), (0, 0x0000_0080)
        ]
        for (slot, bits) in highBits.enumerated() {
            for count in (slot + 1)...6 {
                for status in UInt32(0)...3 {
                    let first = 0x3000_0000 | status << 20 | UInt32(count) << 16 | bits.0
                    let refusal = UMPRefusal.reservedBitsSet(mt: .data64, status: UInt8(status))
                    #expect(throws: refusal, "\(slot) \(count)") {
                        try Self.sysEx7(first, bits.1)
                    }
                }
            }
        }
    }

    @Test func sysEx7RefusesNonZeroUnusedBytes() throws {
        // Every bit of every slot past the count must be zero; slot k (0-based) is bits 15...0 of word 0 for k < 2.
        for count in 0...5 {
            for bit in 0..<48 {
                let slot = bit / 8
                guard slot >= count else { continue }
                let shift = UInt32(slot < 2 ? 8 * (1 - slot) : 8 * (5 - slot)) + UInt32(bit % 8)
                let first = 0x3020_0000 | UInt32(count) << 16 | (slot < 2 ? 1 << shift : 0)
                let second: UInt32 = slot < 2 ? 0 : 1 << shift
                #expect(throws: UMPRefusal.reservedBitsSet(mt: .data64, status: 0x2), "count \(count) bit \(bit)") {
                    try Self.sysEx7(first, second)
                }
            }
        }
    }

    @Test func sysEx7InitRefusesInvalidBytes() throws {
        let group = try UMPGroup(2)
        #expect(throws: UMPRefusal.valueOutOfRange(field: .sysEx7ByteCount, value: 7)) {
            try UMPSysEx7Packet(group: group, status: .complete, bytes: Array(repeating: 0, count: 7))
        }
        for byte: UInt8 in [0x80, 0xF7, 0xFF] {
            #expect(throws: UMPRefusal.valueOutOfRange(field: .sevenBit, value: Int(byte))) {
                try UMPSysEx7Packet(group: group, status: .start, bytes: [0x01, byte])
            }
        }
    }

    @Test(arguments: [
        (0, [UMPSysEx7Status.complete], [0]),
        (1, [.complete], [1]),
        (6, [.complete], [6]),
        (7, [.start, .end], [6, 1]),
        (12, [.start, .end], [6, 6]),
        (13, [.start, .continue, .end], [6, 6, 1])
    ])
    func sysEx7SplitterBoundaries(length: Int, statuses: [UMPSysEx7Status], counts: [Int]) throws {
        let payload = (0..<length).map { UInt8($0 % 0x80) }
        let group = try UMPGroup(7)
        let packets = try UMPSysEx7Packet.packets(group: group, payload: payload)
        #expect(packets.map(\.status) == statuses)
        #expect(packets.map(\.bytes.count) == counts)
        #expect(packets.allSatisfy { $0.group == group })
        #expect(packets.flatMap(\.bytes) == payload)
    }

    @Test func sysEx7SplitterNineteenBytesUsesTwoContinues() throws {
        let payload = Array(UInt8(0x01)...0x13)
        let packets = try UMPSysEx7Packet.packets(group: UMPGroup(4), payload: payload)
        #expect(packets.map(\.status) == [.start, .continue, .continue, .end])
        #expect(packets.map(\.bytes) == [
            [0x01, 0x02, 0x03, 0x04, 0x05, 0x06], [0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C],
            [0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12], [0x13]
        ])
        let last = try #require(packets.last)
        #expect(last.packet.words == [0x3431_1300, 0x0000_0000])
    }

    @Test func sysEx7SplitterStatusPatternForLengthsUpToThirty() throws {
        let group = try UMPGroup(0)
        for length in 0...30 {
            let payload = (0..<length).map { UInt8($0) }
            let packets = try UMPSysEx7Packet.packets(group: group, payload: payload)
            let expectedCount = max(1, (length + 5) / 6)
            #expect(packets.count == expectedCount, "length \(length)")
            let statuses: [UMPSysEx7Status] = expectedCount == 1
                ? [.complete]
                : [.start] + Array(repeating: .continue, count: expectedCount - 2) + [.end]
            #expect(packets.map(\.status) == statuses, "length \(length)")
            let last = try #require(packets.last)
            #expect(packets.dropLast().allSatisfy { $0.bytes.count == 6 }, "length \(length)")
            #expect(last.bytes.count == length - 6 * (expectedCount - 1), "length \(length)")
            #expect(packets.flatMap(\.bytes) == payload, "length \(length)")
        }
    }

    @Test func sysEx7SplitterExactWords() throws {
        let payload: [UInt8] = [0x7E, 0x7F, 0x0D, 0x70, 0x02, 0x01, 0x02]
        let packets = try UMPSysEx7Packet.packets(group: UMPGroup(1), payload: payload)
        #expect(packets.map(\.packet.words) == [[0x3116_7E7F, 0x0D70_0201], [0x3131_0200, 0x0000_0000]])
    }

    @Test func sysEx7SplitterRefusesHighBit() throws {
        let group = try UMPGroup(0)
        for payload: [UInt8] in [[0xF0], [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0xF7]] {
            let byte = try #require(payload.last)
            #expect(throws: UMPRefusal.valueOutOfRange(field: .sevenBit, value: Int(byte))) {
                try UMPSysEx7Packet.packets(group: group, payload: payload)
            }
        }
    }

    @Test func sysEx7PacketIsExactlyTwoWords() {
        #expect(throws: UMPRefusal.wrongWordCount(mt: .data64, have: 1, need: 2)) {
            try UMPPacket(words: [0x3000_0000])
        }
    }
}
