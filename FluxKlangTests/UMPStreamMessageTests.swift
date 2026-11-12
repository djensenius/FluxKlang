import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// UMP Stream messages (MT 0xF): golden words, limits and round trips. Refusals are in `+Decode`, text assembly in
/// `+Text`, seeded hostile input in `+Hostile`. Every golden word below was written by hand from the layout in
/// DESIGN.md section 2, not computed by the production code.
#if os(macOS)
@Suite("UMP Stream messages", .productionAccessAudit)
#else
@Suite("UMP Stream messages")
#endif
struct UMPStreamMessageTests {
    static func limits(_ bytes: Int = 255) throws -> UMPStreamLimits {
        try UMPStreamLimits.make(maximumTextBytes: bytes)
    }

    static func decode(_ words: [UInt32], limit: Int = 255) throws -> UMPStreamMessage {
        try UMPStreamMessage.decode(UMPPacket(words: words), limits: limits(limit))
    }

    static func decodeRefusal(_ words: [UInt32], limit: Int = 255) throws -> UMPStreamRefusal? {
        let packet = try UMPPacket(words: words)
        let limits = try limits(limit)
        do {
            _ = try UMPStreamMessage.decode(packet, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func encode(_ message: UMPStreamMessage, limit: Int = 255) throws -> [[UInt32]] {
        try UMPStreamMessage.encode(message, limits: limits(limit)).map(\.words)
    }

    static func encodeRefusal(_ message: UMPStreamMessage, limit: Int = 255) throws -> UMPStreamRefusal? {
        let limits = try limits(limit)
        do {
            _ = try UMPStreamMessage.encode(message, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    /// Hand-packed text packet: `bytes` follow the optional function block index in the 14-byte lane.
    static func textWords(status: UInt32, format: UInt32, index: UInt8? = nil, bytes: [UInt8]) -> [UInt32] {
        var lane = [UInt8](repeating: 0, count: 14)
        var cursor = 0
        if let index {
            lane[0] = index
            cursor = 1
        }
        for byte in bytes {
            lane[cursor] = byte
            cursor += 1
        }
        func word(_ offset: Int) -> UInt32 {
            UInt32(lane[offset]) << 24 | UInt32(lane[offset + 1]) << 16 | UInt32(lane[offset + 2]) << 8
                | UInt32(lane[offset + 3])
        }
        let first = 0xF000_0000 | format << 26 | status << 16 | UInt32(lane[0]) << 8 | UInt32(lane[1])
        return [first, word(2), word(6), word(10)]
    }

    static let zeroVersion = UMPStreamVersion(major: 0, minor: 0)

    static func text(_ count: Int) -> String {
        String((0..<count).map { Character(UnicodeScalar(UInt8(0x41 + $0 % 26))) })
    }

    static let allFilters = UMPStreamEndpointFilter(
        info: true, deviceIdentity: true, name: true, productInstanceID: true, streamConfiguration: true
    )
    static let infoOnlyFilter = UMPStreamEndpointFilter(
        info: true, deviceIdentity: false, name: false, productInstanceID: false, streamConfiguration: false
    )
    static let version11 = UMPStreamVersion(major: 1, minor: 1)

    static let endpointInfo = UMPStreamEndpointInfo(
        version: version11, hasStaticFunctionBlocks: true, functionBlockCount: 3, supportsMIDI1: true,
        supportsMIDI2: true, receivesJitterReduction: false, transmitsJitterReduction: true
    )
    static let identity = UMPStreamDeviceIdentity(
        manufacturer1: 0x11, manufacturer2: 0x22, manufacturer3: 0x33, familyLSB: 0x44, familyMSB: 0x55,
        modelLSB: 0x66, modelMSB: 0x77, revision1: 0x01, revision2: 0x02, revision3: 0x03, revision4: 0x04
    )
    static let blockInfo = UMPStreamFunctionBlockInfo(
        index: 3, isActive: true, uiHint: .both, midi1Mode: .restricted, direction: .bidirectional,
        firstGroup: 4, groupCount: 2, midiCIVersion: 2, maximumSysEx8Streams: 1
    )

    static var samples: [UMPStreamMessage] {
        [
            .endpointDiscovery(version: version11, filter: allFilters),
            .endpointInfo(endpointInfo),
            .deviceIdentity(identity),
            .endpointName(UMPStreamString("Rack")),
            .productInstanceID(UMPStreamString("SN-0042")),
            .streamConfigRequest(UMPStreamConfiguration(
                streamProtocol: .midi2, receivesJitterReduction: true, transmitsJitterReduction: false
            )),
            .streamConfigNotification(UMPStreamConfiguration(
                streamProtocol: .midi1, receivesJitterReduction: false, transmitsJitterReduction: true
            )),
            .functionBlockDiscovery(UMPStreamFunctionBlockQuery(target: .block(5), wantsInfo: true, wantsName: true)),
            .functionBlockInfo(blockInfo),
            .functionBlockName(index: 9, name: UMPStreamString("Lead")),
            .startOfClip,
            .endOfClip
        ]
    }

    private func expectGolden(
        _ message: UMPStreamMessage,
        _ words: [[UInt32]],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(try Self.encode(message) == words, sourceLocation: sourceLocation)
        let first = try #require(words.first, sourceLocation: sourceLocation)
        if words.count == 1 {
            #expect(try Self.decode(first) == message, sourceLocation: sourceLocation)
        }
    }

    @Test func limitsAcceptOneAndTwoFiftyFiveAndRefuseZeroTwoFiftySixAndNegative() throws {
        #expect(try UMPStreamLimits.make(maximumTextBytes: 1).maximumTextBytes == 1)
        #expect(try UMPStreamLimits.make(maximumTextBytes: 255).maximumTextBytes == 255)
        for bad in [0, 256, -1, Int.max, Int.min] {
            do {
                _ = try UMPStreamLimits.make(maximumTextBytes: bad)
                Issue.record("limit \(bad) was accepted")
            } catch {
                #expect(error == .invalidLimit(.maximumTextBytes, value: bad))
            }
        }
    }

    @Test func limitsNeverRaiseTheByteBoundAboveTheMessageMaximum() throws {
        let wide = try Self.limits(255)
        #expect(wide.maximumBytes(for: .endpointName) == 98)
        #expect(wide.maximumBytes(for: .productInstanceID) == 42)
        #expect(wide.maximumBytes(for: .functionBlockName) == 91)
        let narrow = try Self.limits(40)
        #expect(narrow.maximumBytes(for: .endpointName) == 40)
        #expect(narrow.maximumBytes(for: .productInstanceID) == 40)
        #expect(narrow.maximumBytes(for: .functionBlockName) == 40)
        #expect(try Self.limits(98).maximumBytes(for: .endpointName) == 98)
        #expect(try Self.limits(1).maximumBytes(for: .endpointName) == 1)
    }

    @Test func endpointDiscoveryGoldenWordsEncodeAndDecode() throws {
        try expectGolden(
            .endpointDiscovery(version: Self.version11, filter: Self.allFilters), [[0xF000_0101, 0x1F, 0, 0]]
        )
        try expectGolden(
            .endpointDiscovery(version: UMPStreamVersion(major: 0xFF, minor: 0), filter: Self.infoOnlyFilter),
            [[0xF000_FF00, 0x01, 0, 0]]
        )
    }

    @Test func endpointDiscoveryFiltersMapToBitsZeroThroughFourIndependently() throws {
        let none = UMPStreamEndpointFilter(
            info: false, deviceIdentity: false, name: false, productInstanceID: false, streamConfiguration: false
        )
        var single: [UMPStreamEndpointFilter] = []
        for position in 0..<5 {
            var filter = none
            switch position {
            case 0: filter.info = true
            case 1: filter.deviceIdentity = true
            case 2: filter.name = true
            case 3: filter.productInstanceID = true
            default: filter.streamConfiguration = true
            }
            single.append(filter)
        }
        for (position, filter) in single.enumerated() {
            let words = [0xF000_0000, UInt32(1) << UInt32(position), 0, 0]
            let message = UMPStreamMessage.endpointDiscovery(version: Self.zeroVersion, filter: filter)
            #expect(try Self.decode(words) == message)
            #expect(try Self.encode(message) == [words])
        }
        #expect(
            try Self.decode([0xF000_0000, 0, 0, 0]) == .endpointDiscovery(version: Self.zeroVersion, filter: none)
        )
    }

    @Test func endpointInfoGoldenWordsEncodeAndDecode() throws {
        try expectGolden(.endpointInfo(Self.endpointInfo), [[0xF001_0101, 0x8300_0301, 0, 0]])
        let bare = UMPStreamEndpointInfo(
            version: UMPStreamVersion(major: 1, minor: 2), hasStaticFunctionBlocks: false, functionBlockCount: 32,
            supportsMIDI1: false, supportsMIDI2: false, receivesJitterReduction: true, transmitsJitterReduction: false
        )
        try expectGolden(.endpointInfo(bare), [[0xF001_0102, 0x2000_0002, 0, 0]])
    }

    @Test func endpointInfoCapabilityAndJitterFlagsMapToTheirOwnBits() throws {
        func info(midi1: Bool, midi2: Bool, receive: Bool, transmit: Bool) -> UMPStreamEndpointInfo {
            UMPStreamEndpointInfo(
                version: UMPStreamVersion(major: 0, minor: 0), hasStaticFunctionBlocks: false, functionBlockCount: 0,
                supportsMIDI1: midi1, supportsMIDI2: midi2, receivesJitterReduction: receive,
                transmitsJitterReduction: transmit
            )
        }
        let cases: [(UMPStreamEndpointInfo, UInt32)] = [
            (info(midi1: true, midi2: false, receive: false, transmit: false), 0x0000_0100),
            (info(midi1: false, midi2: true, receive: false, transmit: false), 0x0000_0200),
            (info(midi1: false, midi2: false, receive: true, transmit: false), 0x0000_0002),
            (info(midi1: false, midi2: false, receive: false, transmit: true), 0x0000_0001)
        ]
        for (value, word) in cases {
            #expect(try Self.decode([0xF001_0000, word, 0, 0]) == .endpointInfo(value))
            #expect(try Self.encode(.endpointInfo(value)) == [[0xF001_0000, word, 0, 0]])
        }
    }

    @Test func deviceIdentityGoldenWordsEncodeAndDecode() throws {
        try expectGolden(.deviceIdentity(Self.identity), [[0xF002_0000, 0x0011_2233, 0x4455_6677, 0x0102_0304]])
        let maximum = UMPStreamDeviceIdentity(
            manufacturer1: 0x7F, manufacturer2: 0x7F, manufacturer3: 0x7F, familyLSB: 0x7F, familyMSB: 0x7F,
            modelLSB: 0x7F, modelMSB: 0x7F, revision1: 0x7F, revision2: 0x7F, revision3: 0x7F, revision4: 0x7F
        )
        try expectGolden(.deviceIdentity(maximum), [[0xF002_0000, 0x007F_7F7F, 0x7F7F_7F7F, 0x7F7F_7F7F]])
    }

    @Test func streamConfigurationGoldenWordsForRequestAndNotification() throws {
        let request = UMPStreamConfiguration(
            streamProtocol: .midi2, receivesJitterReduction: true, transmitsJitterReduction: false
        )
        let notification = UMPStreamConfiguration(
            streamProtocol: .midi1, receivesJitterReduction: false, transmitsJitterReduction: true
        )
        try expectGolden(.streamConfigRequest(request), [[0xF005_0202, 0, 0, 0]])
        try expectGolden(.streamConfigNotification(notification), [[0xF006_0101, 0, 0, 0]])
        try expectGolden(.streamConfigRequest(notification), [[0xF005_0101, 0, 0, 0]])
        try expectGolden(.streamConfigNotification(request), [[0xF006_0202, 0, 0, 0]])
    }

    @Test func functionBlockDiscoveryGoldenWordsForABlockAndForAll() throws {
        try expectGolden(
            .functionBlockDiscovery(UMPStreamFunctionBlockQuery(target: .block(5), wantsInfo: true, wantsName: true)),
            [[0xF010_0503, 0, 0, 0]]
        )
        try expectGolden(
            .functionBlockDiscovery(UMPStreamFunctionBlockQuery(target: .all, wantsInfo: true, wantsName: false)),
            [[0xF010_FF01, 0, 0, 0]]
        )
        try expectGolden(
            .functionBlockDiscovery(UMPStreamFunctionBlockQuery(target: .block(31), wantsInfo: false, wantsName: true)),
            [[0xF010_1F02, 0, 0, 0]]
        )
        try expectGolden(
            .functionBlockDiscovery(UMPStreamFunctionBlockQuery(target: .block(0), wantsInfo: false, wantsName: false)),
            [[0xF010_0000, 0, 0, 0]]
        )
    }

    @Test func functionBlockInfoGoldenWordsEncodeAndDecode() throws {
        try expectGolden(.functionBlockInfo(Self.blockInfo), [[0xF011_833B, 0x0402_0201, 0, 0]])
        let idle = UMPStreamFunctionBlockInfo(
            index: 31, isActive: false, uiHint: .receiver, midi1Mode: .notMIDI1, direction: .input,
            firstGroup: 0, groupCount: 16, midiCIVersion: 0, maximumSysEx8Streams: 255
        )
        try expectGolden(.functionBlockInfo(idle), [[0xF011_1F11, 0x0010_00FF, 0, 0]])
        let sender = UMPStreamFunctionBlockInfo(
            index: 0, isActive: true, uiHint: .sender, midi1Mode: .unrestricted, direction: .output,
            firstGroup: 15, groupCount: 1, midiCIVersion: 1, maximumSysEx8Streams: 0
        )
        try expectGolden(.functionBlockInfo(sender), [[0xF011_8026, 0x0F01_0100, 0, 0]])
    }

    @Test func startAndEndOfClipGoldenWordsEncodeAndDecode() throws {
        try expectGolden(.startOfClip, [[0xF020_0000, 0, 0, 0]])
        try expectGolden(.endOfClip, [[0xF021_0000, 0, 0, 0]])
    }

    @Test func startAndEndOfClipRefuseAnyNonZeroReservedBit() throws {
        for (first, status) in [(UInt32(0xF020_0000), UInt16(0x020)), (0xF021_0000, 0x021)] {
            for words in [
                [first | 0x0001, 0, 0, 0], [first | 0x8000, 0, 0, 0], [first | 0x00FF, 0, 0, 0],
                [first, 0x0000_0001, 0, 0], [first, 0x8000_0000, 0, 0],
                [first, 0, 0x0000_0001, 0], [first, 0, 0x8000_0000, 0],
                [first, 0, 0, 0x0000_0001], [first, 0, 0, 0x8000_0000]
            ] {
                #expect(try Self.decodeRefusal(words) == .reservedBitsSet(status: status), "\(words)")
            }
        }
    }

    @Test func shortTextGoldenWordsForEndpointProductAndFunctionBlockNames() throws {
        try expectGolden(.endpointName(UMPStreamString("Hi")), [[0xF003_4869, 0, 0, 0]])
        try expectGolden(.productInstanceID(UMPStreamString("Hi")), [[0xF004_4869, 0, 0, 0]])
        try expectGolden(.functionBlockName(index: 2, name: UMPStreamString("Hi")), [[0xF012_0248, 0x6900_0000, 0, 0]])
        try expectGolden(.endpointName(UMPStreamString("A")), [[0xF003_4100, 0, 0, 0]])
        try expectGolden(
            .endpointName(UMPStreamString("ABCDEFGHIJKLMN")),
            [[0xF003_4142, 0x4344_4546, 0x4748_494A, 0x4B4C_4D4E]]
        )
    }

    @Test func fifteenByteNameSplitsIntoAStartPacketAndAnEndPacket() throws {
        let name = UMPStreamString("ABCDEFGHIJKLMNO")
        let expected: [[UInt32]] = [
            [0xF403_4142, 0x4344_4546, 0x4748_494A, 0x4B4C_4D4E],
            [0xFC03_4F00, 0, 0, 0]
        ]
        #expect(try Self.encode(.endpointName(name)) == expected)
        var assembler = UMPStreamTextAssembler(limits: try Self.limits())
        #expect(try assembler.feed(UMPPacket(words: expected[0])) == .partial)
        #expect(try assembler.feed(UMPPacket(words: expected[1])) == .complete(.endpointName(name)))
    }

    @Test func everySampleMessageRoundTripsThroughEncodeAndDecodeAsAFourWordStreamPacket() throws {
        for message in Self.samples {
            let packets = try UMPStreamMessage.encode(message, limits: Self.limits())
            #expect(packets.count == 1, "\(message)")
            let packet = try #require(packets.first)
            #expect(packet.messageType == .stream)
            #expect(packet.words.count == 4)
            #expect(try UMPStreamMessage.decode(packet, limits: Self.limits()) == message)
        }
    }
}
