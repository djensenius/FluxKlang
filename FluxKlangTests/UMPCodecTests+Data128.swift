import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - Data Messages (128-bit), SysEx8 and Mixed Data Set (MT 0x5)

extension UMPPacketFramingTests {
    /// Hand-written MT 0x5 words (M2-104-UM, Data Messages (128-bit); cmidi2 `cmidi2_ump_get_sysex8_*` and
    /// `cmidi2_ump_get_mds_*`; AM_MIDI2.0Lib `mt5MDSHeader`) and the message each must decode to.
    static func data128Goldens() throws -> [(words: [UInt32], message: UMPData128Message)] {
        func sysEx8(_ group: UInt8, _ status: UMPSysEx8Status, _ stream: UInt8, _ bytes: [UInt8]) throws
            -> UMPData128Message {
            .sysEx8(try UMPSysEx8Packet(group: UMPGroup(group), status: status, streamID: stream, bytes: bytes))
        }
        let header = UMPMixedDataSetHeader(
            group: try UMPGroup(3), mdsID: try UMPMixedDataSetID(4), validByteCount: 0x1234, chunkCount: 0x5678,
            chunkNumber: 0x9ABC, manufacturerID: 0xDEF0, deviceID: 0x0FED, subID1: 0xCBA9, subID2: 0x8765
        )
        let payload = try UMPMixedDataSetPayload(
            group: UMPGroup(2), mdsID: UMPMixedDataSetID(15), bytes: Array(UInt8(0x01)...0x0E)
        )
        return [
            ([0x5001_4200, 0, 0, 0], try sysEx8(0, .complete, 0x42, [])),
            ([0x570E_0A01, 0x0203_0405, 0x0607_0809, 0x0A0B_0C0D], try sysEx8(7, .complete, 0x0A, Array(1...13))),
            ([0x5013_FF80, 0xFE00_0000, 0, 0], try sysEx8(0, .start, 0xFF, [0x80, 0xFE])),
            ([0x5F22_00F7, 0, 0, 0], try sysEx8(15, .continue, 0x00, [0xF7])),
            ([0x5031_0500, 0, 0, 0], try sysEx8(0, .end, 0x05, [])),
            ([0x5384_1234, 0x5678_9ABC, 0xDEF0_0FED, 0xCBA9_8765], .mixedDataSetHeader(header)),
            ([0x529F_0102, 0x0304_0506, 0x0708_090A, 0x0B0C_0D0E], .mixedDataSetPayload(payload))
        ]
    }

    static func data128(_ words: [UInt32]) throws -> UMPData128Message {
        try UMPData128Message(decoding: UMPPacket(words: words))
    }

    @Test func data128GoldensDecodeAndEncode() throws {
        for (words, expected) in try Self.data128Goldens() {
            #expect(try Self.data128(words) == expected, "\(words)")
            #expect(expected.packet.words == words, "\(words)")
            #expect(expected.packet.messageType == .data128)
        }
        let header = try #require(Self.data128Goldens().first { golden in
            if case .mixedDataSetHeader = golden.message { return true }
            return false
        })
        guard case .mixedDataSetHeader(let decoded) = try Self.data128(header.words) else {
            Issue.record("not a Mixed Data Set Header")
            return
        }
        #expect(decoded.group.value == 3 && decoded.mdsID.value == 4)
        #expect([decoded.validByteCount, decoded.chunkCount, decoded.chunkNumber, decoded.manufacturerID]
            == [0x1234, 0x5678, 0x9ABC, 0xDEF0])
        #expect([decoded.deviceID, decoded.subID1, decoded.subID2] == [0x0FED, 0xCBA9, 0x8765])
    }

    @Test func sysEx8RoundTripsEveryStatusAndCount() throws {
        let source: [UInt8] = [0x00, 0xFF, 0x80, 0x7F, 0x01, 0xF0, 0xF7, 0x55, 0xAA, 0x10, 0x20, 0x30, 0x40]
        for status in UMPSysEx8Status.allCases {
            for count in 0...13 {
                for (group, stream) in [(UInt8(0), UInt8(0)), (9, 0x7F), (15, 0xFF)] {
                    let message = try UMPSysEx8Packet(
                        group: UMPGroup(group), status: status, streamID: stream, bytes: Array(source.prefix(count))
                    )
                    let words = message.packet.words
                    let first = try #require(words.first)
                    #expect(words.count == 4)
                    #expect(first >> 8 == 0x50_0000 | UInt32(group) << 16 | UInt32(status.rawValue) << 12
                        | UInt32(count + 1) << 8 | UInt32(stream))
                    #expect(try UMPData128Message(decoding: message.packet) == .sysEx8(message), "\(status) \(count)")
                    #expect(UMPData128Message.sysEx8(message).packet == message.packet)
                }
            }
        }
    }

    @Test func mixedDataSetHeaderFieldPositions() throws {
        // One field at a time holds a sentinel; its 16 bits must land in exactly one half-word, in spec order.
        let sentinels: [UInt16] = [0xA001, 0xB002, 0xC003, 0xD004, 0xE005, 0xF006, 0x9007]
        for (index, sentinel) in sentinels.enumerated() {
            var fields = [UInt16](repeating: 0, count: 7)
            fields[index] = sentinel
            let header = UMPMixedDataSetHeader(
                group: try UMPGroup(1), mdsID: try UMPMixedDataSetID(0xA), validByteCount: fields[0],
                chunkCount: fields[1], chunkNumber: fields[2], manufacturerID: fields[3], deviceID: fields[4],
                subID1: fields[5], subID2: fields[6]
            )
            // Field k sits in half-word k + 1 of the packet: word (k + 1) / 2, high half when k + 1 is even.
            var expected: [UInt32] = [0x518A_0000, 0, 0, 0]
            let halfWord = index + 1
            expected[halfWord / 2] |= UInt32(sentinel) << (halfWord.isMultiple(of: 2) ? 16 : 0)
            #expect(header.packet.words == expected, "field \(index)")
            #expect(try Self.data128(expected) == .mixedDataSetHeader(header), "field \(index)")
        }
    }

    @Test func mixedDataSetIDRoundTripsInHeaderAndPayload() throws {
        for mdsID in UInt8(0)...15 {
            let identifier = try UMPMixedDataSetID(mdsID)
            let header = UMPMixedDataSetHeader(
                group: try UMPGroup(6), mdsID: identifier, validByteCount: 0xFFFF, chunkCount: 0xFFFF,
                chunkNumber: 0, manufacturerID: 0xFFFF, deviceID: 0, subID1: 0xFFFF, subID2: 0
            )
            let payload = try UMPMixedDataSetPayload(
                group: UMPGroup(6), mdsID: identifier, bytes: Array(repeating: 0xFF, count: 14)
            )
            let headerFirst = try #require(header.packet.words.first)
            let payloadFirst = try #require(payload.packet.words.first)
            #expect(headerFirst == 0x5680_FFFF | UInt32(mdsID) << 16)
            #expect(payloadFirst == 0x5690_FFFF | UInt32(mdsID) << 16)
            #expect(try UMPData128Message(decoding: header.packet) == .mixedDataSetHeader(header))
            #expect(try UMPData128Message(decoding: payload.packet) == .mixedDataSetPayload(payload))
        }
    }

    @Test func mixedDataSetPayloadBytePositions() throws {
        // Payload byte k (0-based) is packet byte k + 2, most significant first.
        for index in 0..<14 {
            var bytes = [UInt8](repeating: 0, count: 14)
            bytes[index] = 0xFF
            let payload = try UMPMixedDataSetPayload(group: UMPGroup(0), mdsID: UMPMixedDataSetID(1), bytes: bytes)
            var expected: [UInt32] = [0x5091_0000, 0, 0, 0]
            let slot = index + 2
            expected[slot / 4] |= 0xFF << UInt32(8 * (3 - slot % 4))
            #expect(payload.packet.words == expected, "byte \(index)")
            #expect(try Self.data128(expected) == .mixedDataSetPayload(payload), "byte \(index)")
        }
    }

    @Test func data128RefusesOtherMessageTypes() throws {
        // A reserved status and set padding bits are present, so the type check must come first.
        for type in UMPMessageType.allCases where type != .data128 {
            let first = UInt32(type.rawValue) << 28 | 0x0FFF_FFFF
            let packet = try UMPPacket(words: [first] + Array(repeating: 0xFFFF_FFFF, count: type.wordCount - 1))
            #expect(throws: UMPRefusal.wrongMessageType(expected: .data128, actual: type)) {
                try UMPData128Message(decoding: packet)
            }
        }
    }

    @Test func data128RefusesReservedStatuses() throws {
        for status in [UInt32(0x4), 0x5, 0x6, 0x7, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF] {
            #expect(throws: UMPRefusal.reservedStatus(mt: .data128, status: UInt8(status))) {
                try Self.data128([0x5000_0000 | status << 20, 0, 0, 0])
            }
            // Status is checked before any count or padding.
            #expect(throws: UMPRefusal.reservedStatus(mt: .data128, status: UInt8(status))) {
                try Self.data128([0x500F_FFFF | status << 20, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF])
            }
        }
    }

    @Test func sysEx8RefusesByteCountZeroAndFifteen() throws {
        for status in UInt32(0)...3 {
            for count in [UInt32(0), 15] {
                #expect(throws: UMPRefusal.valueOutOfRange(field: .sysEx8ByteCount, value: Int(count))) {
                    try Self.data128([0x5000_0000 | status << 20 | count << 16, 0, 0, 0])
                }
                // The count is checked before the padding bits.
                #expect(throws: UMPRefusal.valueOutOfRange(field: .sysEx8ByteCount, value: Int(count))) {
                    try Self.data128([0x5000_FFFF | status << 20 | count << 16, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF])
                }
            }
        }
    }

    @Test func sysEx8AcceptsBoundaryCounts() throws {
        let one = try Self.data128([0x5031_7700, 0, 0, 0])
        #expect(one == .sysEx8(try UMPSysEx8Packet(group: UMPGroup(0), status: .end, streamID: 0x77, bytes: [])))
        let words: [UInt32] = [0x500E_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF]
        let full = try UMPSysEx8Packet(
            group: UMPGroup(0), status: .complete, streamID: 0xFF, bytes: Array(repeating: 0xFF, count: 13)
        )
        #expect(try Self.data128(words) == .sysEx8(full))
        #expect(full.packet.words == words)
    }

    @Test(arguments: UMPSysEx8Status.allCases)
    func sysEx8RefusesNonZeroUnusedBytes(status: UMPSysEx8Status) throws {
        // Every bit of every data slot past the count must be zero. Data slot k (0-based) is packet byte k + 3.
        let refusal = UMPRefusal.reservedBitsSet(mt: .data128, status: status.rawValue)
        for count in 1...13 {
            for bit in 0..<104 {
                let slot = bit / 8 + 3
                guard slot - 3 >= count - 1 else { continue }
                var words: [UInt32] = [0x5000_AB00 | UInt32(status.rawValue) << 20 | UInt32(count) << 16, 0, 0, 0]
                words[slot / 4] |= 1 << UInt32(8 * (3 - slot % 4) + bit % 8)
                #expect(throws: refusal, "\(status) count \(count) bit \(bit)") {
                    try Self.data128(words)
                }
            }
        }
    }

    @Test func data128InitsRefuseInvalidValues() throws {
        let group = try UMPGroup(2)
        #expect(throws: UMPRefusal.valueOutOfRange(field: .sysEx8ByteCount, value: 15)) {
            try UMPSysEx8Packet(group: group, status: .complete, streamID: 0, bytes: Array(repeating: 0, count: 14))
        }
        for value: UInt8 in [16, 0x80, 0xFF] {
            #expect(throws: UMPRefusal.valueOutOfRange(field: .mixedDataSetID, value: Int(value))) {
                try UMPMixedDataSetID(value)
            }
        }
        let mdsID = try UMPMixedDataSetID(3)
        for count in [0, 13, 15] {
            #expect(throws: UMPRefusal.valueOutOfRange(field: .mixedDataSetPayloadByteCount, value: count)) {
                try UMPMixedDataSetPayload(group: group, mdsID: mdsID, bytes: Array(repeating: 0, count: count))
            }
        }
    }

    @Test(arguments: [
        (0, [UMPSysEx8Status.complete], [0]),
        (1, [.complete], [1]),
        (13, [.complete], [13]),
        (14, [.start, .end], [13, 1]),
        (26, [.start, .end], [13, 13]),
        (27, [.start, .continue, .end], [13, 13, 1])
    ])
    func sysEx8SplitterBoundaries(length: Int, statuses: [UMPSysEx8Status], counts: [Int]) throws {
        let payload = (0..<length).map { UInt8(truncatingIfNeeded: 0xF0 + $0) }
        let group = try UMPGroup(7)
        let packets = UMPSysEx8Packet.packets(group: group, streamID: 0x5A, payload: payload)
        #expect(packets.map(\.status) == statuses)
        #expect(packets.map(\.bytes.count) == counts)
        #expect(packets.allSatisfy { $0.group == group && $0.streamID == 0x5A })
        #expect(packets.flatMap(\.bytes) == payload)
    }

    @Test func sysEx8SplitterEmptyPayloadIsCountOne() throws {
        let packets = UMPSysEx8Packet.packets(group: try UMPGroup(4), streamID: 0x09, payload: [])
        #expect(packets.map(\.packet.words) == [[0x5401_0900, 0, 0, 0]])
    }

    @Test func sysEx8SplitterStatusPatternForLengthsUpToForty() throws {
        let group = try UMPGroup(0)
        for length in 0...40 {
            let payload = (0..<length).map { UInt8($0) }
            let packets = UMPSysEx8Packet.packets(group: group, streamID: 1, payload: payload)
            let expectedCount = max(1, (length + 12) / 13)
            #expect(packets.count == expectedCount, "length \(length)")
            let statuses: [UMPSysEx8Status] = expectedCount == 1
                ? [.complete]
                : [.start] + Array(repeating: .continue, count: expectedCount - 2) + [.end]
            #expect(packets.map(\.status) == statuses, "length \(length)")
            let last = try #require(packets.last)
            #expect(packets.dropLast().allSatisfy { $0.bytes.count == 13 }, "length \(length)")
            #expect(last.bytes.count == length - 13 * (expectedCount - 1), "length \(length)")
            #expect(packets.flatMap(\.bytes) == payload, "length \(length)")
        }
    }

    @Test func sysEx8SplitterExactWords() throws {
        let payload = Array(UInt8(0x81)...0x8E)
        let packets = UMPSysEx8Packet.packets(group: try UMPGroup(1), streamID: 0xEE, payload: payload)
        #expect(packets.map(\.packet.words) == [
            [0x511E_EE81, 0x8283_8485, 0x8687_8889, 0x8A8B_8C8D],
            [0x5132_EE8E, 0, 0, 0]
        ])
    }

    @Test func data128PacketHelperForcesMessageType() {
        let packet = UMPPacket.data128(0xF123_4567, 1, 2, 3)
        #expect(packet.words == [0x5123_4567, 1, 2, 3])
        #expect(packet.messageType == .data128)
        #expect(throws: UMPRefusal.wrongWordCount(mt: .data128, have: 2, need: 4)) {
            try UMPPacket(words: [0x5000_0000, 0])
        }
    }
}
