import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// One hostile Stream packet and the typed refusal its decode must give.
private struct HostileWords {
    let name: String
    let words: [UInt32]
    let refusal: UMPStreamRefusal
}

/// #83 "groups/function blocks": UMP Stream words → `UMPStreamMessage` → facts → resolver.
extension UMPCapabilityTests {
    private static let hostile: [HostileWords] = [
        HostileWords(
            name: "endpoint declares 33 blocks", words: [0xF001_0101, 0xA100_0300, 0, 0],
            refusal: .invalidField(.functionBlockCount, value: 33)),
        HostileWords(
            name: "endpoint reserved bit 16", words: [0xF001_0101, 0x8201_0302, 0, 0],
            refusal: .reservedBitsSet(status: 0x001)),
        HostileWords(
            name: "endpoint word 3 not zero", words: [0xF001_0101, 0x8200_0302, 0, 1],
            refusal: .reservedBitsSet(status: 0x001)),
        HostileWords(
            name: "endpoint as a start packet", words: [0xF401_0101, 0x8200_0302, 0, 0],
            refusal: .wrongFormat(status: 0x001, format: 1)),
        HostileWords(
            name: "block index 32", words: [0xF011_A033, 0x0002_0201, 0, 0],
            refusal: .functionBlockOutOfRange(32)),
        HostileWords(
            name: "block groups 15 + 2", words: [0xF011_8033, 0x0F02_0201, 0, 0],
            refusal: .invalidField(.groupCount, value: 2)),
        HostileWords(
            name: "block CI version 3", words: [0xF011_8033, 0x0002_0301, 0, 0],
            refusal: .invalidField(.midiCIVersion, value: 3)),
        HostileWords(
            name: "block direction 0", words: [0xF011_8030, 0x0002_0201, 0, 0],
            refusal: .invalidField(.direction, value: 0)),
        HostileWords(
            name: "block MIDI 1.0 mode 3", words: [0xF011_803F, 0x0002_0201, 0, 0],
            refusal: .invalidField(.midi1Mode, value: 3)),
        HostileWords(
            name: "unknown status 0x013", words: [0xF013_0000, 0, 0, 0],
            refusal: .unknownStatus(0x013)),
        HostileWords(
            name: "MIDI 2.0 Note On", words: [0x4090_3C00, 0x8000_0000],
            refusal: .notStream(actual: .midi2ChannelVoice))
    ]

    @Test func streamWordsDecodeToTheHandWrittenValues() throws {
        #expect(try Self.stream(Self.endpointMIDI2) == .endpointInfo(UMPStreamEndpointInfo(
            version: UMPStreamVersion(major: 1, minor: 1), hasStaticFunctionBlocks: true, functionBlockCount: 2,
            supportsMIDI1: true, supportsMIDI2: true, receivesJitterReduction: true,
            transmitsJitterReduction: false)))
        #expect(try Self.stream(Self.block0) == .functionBlockInfo(Self.expectedBlock0))
        #expect(try Self.stream(Self.block1) == .functionBlockInfo(Self.expectedBlock1))
        #expect(try Self.stream(Self.block0Name) == .functionBlockName(index: 0, name: UMPStreamString("Synth")))
    }

    @Test func midi2EndpointWithBlocksNegotiatesUMPMIDI2() throws {
        // Wire order: block 1 before block 0, then a name. The result lists the blocks sorted by index.
        let packets = [Self.endpointMIDI2, Self.block1, Self.block0, Self.block0Name]
        let result = try Self.negotiate(packets, ci: [Self.reply])
        #expect(result.level == .umpMIDI2)
        #expect(result.features == [.umpTransport, .midi2Protocol, .jitterReduction, .functionBlocks, .ciDiscovery])
        #expect(result.functionBlocks == [Self.expectedBlock0, Self.expectedBlock1])
        #expect(result.profiles.isEmpty)
        // Block 1 is a MIDI 1.0 block on this MIDI 2.0 endpoint (#572 gap 3): recorded, the level is unchanged.
        #expect(result.downgrades == [Self.block1MIDI1Only])
    }

    @Test func inactiveBlocksAreListedButGrantNoFunctionBlockFeature() throws {
        // Endpoint with one block (MIDI 2.0 only), block 0 with the active bit (word 0 bit 15) clear.
        let endpoint: [UInt32] = [0xF001_0101, 0x8100_0200, 0, 0]
        let inactive: [UInt32] = [0xF011_0033, 0x0002_0201, 0, 0]
        let result = try Self.negotiate([endpoint, inactive], ci: [Self.reply])
        #expect(result.level == .umpMIDI2)
        #expect(result.features == [.umpTransport, .midi2Protocol, .ciDiscovery])
        let block = try #require(result.functionBlocks.first)
        #expect(result.functionBlocks.count == 1)
        #expect(!block.isActive)
    }

    @Test func hostileStreamWordsAreRefusedAndContributeNothing() throws {
        let limits = try Self.limits()
        let good = [Self.endpointMIDI2, Self.block0, Self.block1]
        let answer = [Self.reply]
        let baseline = try Self.negotiate(good, ci: answer)
        #expect(baseline.level == .umpMIDI2)
        #expect(baseline.functionBlocks == [Self.expectedBlock0, Self.expectedBlock1])
        for fixture in Self.hostile {
            let packet = try UMPPacket(words: fixture.words)
            #expect(throws: fixture.refusal, "\(fixture.name)") { try UMPStreamMessage.decode(packet, limits: limits) }
            // The pipeline yields no facts at all, wherever the hostile packet sits...
            for position in 0...good.count {
                var packets = good
                packets.insert(fixture.words, at: position)
                #expect(throws: fixture.refusal, "\(fixture.name)") { try Self.facts(packets, ci: answer) }
            }
            // ...and the good packets alone still negotiate exactly as before.
            #expect(try Self.negotiate(good, ci: answer) == baseline, "\(fixture.name)")
        }
    }

    @Test func inconsistentWireFactsAreRefusedByTheResolver() throws {
        let answer = [Self.reply]
        // Block 1 moved to first group 1: it overlaps block 0 (groups 0-1).
        let overlapping: [UInt32] = [0xF011_8115, 0x0101_0100, 0, 0]
        // The adapter keys blocks by index, so an identical repeat of block 0 is one block: the count is short.
        let cases: [([[UInt32]], MIDICapabilityRefusal)] = [
            ([Self.endpointMIDI2, Self.block0], .functionBlockCountMismatch(declared: 2, supplied: 1)),
            ([Self.block0], .functionBlocksWithoutEndpoint(count: 1)),
            ([Self.endpointMIDI2, Self.block0, Self.block0], .functionBlockCountMismatch(declared: 2, supplied: 1)),
            ([Self.endpointMIDI2, overlapping, Self.block0], .overlappingFunctionBlockGroups(first: 0, second: 1))
        ]
        for (packets, expected) in cases {
            #expect(Self.refusal(try Self.facts(packets, ci: answer)) == expected)
        }
        // Two different blocks with index 0 never reach the resolver: the adapter refuses the second one.
        let otherBlock0: [UInt32] = [0xF011_8033, 0x0202_0201, 0, 0]
        #expect(throws: MIDICapabilityDiscoveryRefusal.conflictingFunctionBlock(index: 0)) {
            try Self.facts([Self.endpointMIDI2, Self.block0, otherBlock0], ci: answer)
        }
    }
}

/// UPD1: `UMPPacketMessage` routes one checked packet by Message Type to the typed decoder.
extension UMPCapabilityTests {
    /// One hostile packet and the refusal the classifier must give for it.
    private struct HostilePacket {
        let name: String
        let words: [UInt32]
        let refusal: UMPPacketMessageRefusal
    }

    private static let hostilePackets: [HostilePacket] = [
        HostilePacket(
            name: "utility status 5", words: [0x0050_0000],
            refusal: .packet(.reservedStatus(mt: .utility, status: 0x5))),
        HostilePacket(
            name: "system status 0xF4", words: [0x11F4_0000],
            refusal: .packet(.reservedStatus(mt: .system, status: 0xF4))),
        HostilePacket(
            name: "MIDI 1.0 status below 0x80", words: [0x2240_3C40],
            refusal: .packet(.reservedStatus(mt: .midi1ChannelVoice, status: 0x40))),
        HostilePacket(
            name: "SysEx7 status 4", words: [0x3340_0000, 0],
            refusal: .packet(.reservedStatus(mt: .data64, status: 0x4))),
        HostilePacket(
            name: "MIDI 2.0 status 0x7", words: [0x4470_0000, 0],
            refusal: .packet(.reservedStatus(mt: .midi2ChannelVoice, status: 0x7))),
        HostilePacket(
            name: "Data 128 status 4", words: [0x5540_0000, 0, 0, 0],
            refusal: .packet(.reservedStatus(mt: .data128, status: 0x4))),
        HostilePacket(
            name: "Flex Data Set Metronome", words: [0xD010_0002, 0, 0, 0],
            refusal: .flexData(.unknownStatus(bank: 0x00, status: 0x02))),
        HostilePacket(
            name: "Flex Data text with address 3", words: [0xD030_0101, 0, 0, 0],
            refusal: .flexData(.reservedAddress(status: 0x01, address: 3))),
        HostilePacket(
            name: "Flex Data tempo as a start packet", words: [0xD050_0000, 0, 0, 0],
            refusal: .flexData(.wrongFormat(status: 0x00, format: 1))),
        HostilePacket(
            name: "Stream unknown status 0x013", words: [0xF013_0000, 0, 0, 0],
            refusal: .stream(.unknownStatus(0x013))),
        HostilePacket(
            name: "Stream endpoint with 33 blocks", words: [0xF001_0101, 0xA100_0300, 0, 0],
            refusal: .stream(.invalidField(.functionBlockCount, value: 33)))
    ]

    /// One valid packet per Message Type; the group (where there is one) is 5, so a group mix-up shows.
    private static func validWords(for type: UMPMessageType) -> [UInt32] {
        switch type {
        case .utility: return [0x0000_0000]
        case .system: return [0x15FA_0000]
        case .midi1ChannelVoice: return [0x2593_3C40]
        case .data64: return [0x3500_0000, 0]
        case .midi2ChannelVoice: return [0x4590_3C00, 0x8000_0000]
        case .data128: return [0x5501_0000, 0, 0, 0]
        case .flexData: return [0xD510_0000, 0x0000_1234, 0, 0]
        case .stream: return endpointMIDI2
        case .reserved6, .reserved7, .reserved8, .reserved9, .reservedA, .reservedB, .reservedC, .reservedE:
            return reservedWords(for: type)
        }
    }

    /// Every bit below the type nibble set, at the type's own word count.
    private static func reservedWords(for type: UMPMessageType) -> [UInt32] {
        [UInt32(type.rawValue) << 28 | 0x0FFF_FFFF] + [UInt32](repeating: 0xFFFF_FFFF, count: type.wordCount - 1)
    }

    private static func classify(_ words: [UInt32], limit: Int = 255) throws -> UMPPacketMessage {
        try classify(UMPPacket(words: words), limit: limit)
    }

    private static func classify(_ packet: UMPPacket, limit: Int = 255) throws -> UMPPacketMessage {
        try UMPPacketMessage(decoding: packet, streamLimits: UMPStreamLimits.make(maximumTextBytes: limit))
    }

    /// The Message Type a classified value came from. No `default`: a new case must be placed here.
    private static func origin(of message: UMPPacketMessage) -> UMPMessageType {
        switch message {
        case .utility: return .utility
        case .system: return .system
        case .midi1ChannelVoice: return .midi1ChannelVoice
        case .sysEx7: return .data64
        case .midi2ChannelVoice: return .midi2ChannelVoice
        case .data128: return .data128
        case .flexData, .flexDataText: return .flexData
        case .stream: return .stream
        case .reserved(let packet): return packet.messageType
        }
    }

    /// The group the decoded value itself exposes, nil where the value has none. No `default`.
    private static func exposedGroup(of message: UMPPacketMessage) -> UMPGroup? {
        switch message {
        case .utility, .stream, .reserved: return nil
        case .system(let value): return value.group
        case .midi1ChannelVoice(let value): return value.group
        case .sysEx7(let value): return value.group
        case .midi2ChannelVoice(let value): return value.group
        case .flexData(let value): return value.group
        case .flexDataText(let value): return value.group
        case .data128(let value): return data128Group(of: value)
        }
    }

    private static func data128Group(of message: UMPData128Message) -> UMPGroup {
        switch message {
        case .sysEx8(let packet): return packet.group
        case .sysEx8Abort(let packet): return packet.group
        case .mixedDataSetHeader(let header): return header.group
        case .mixedDataSetPayload(let payload): return payload.group
        }
    }

    @Test func everyMessageTypeIsRoutedToItsOwnCase() throws {
        #expect(UMPMessageType.allCases.count == 16)
        for type in UMPMessageType.allCases {
            let words = Self.validWords(for: type)
            let message = try Self.classify(words)
            #expect(Self.origin(of: message) == type, "\(type)")
            if case .reserved(let packet) = message {
                #expect(type.isReserved, "\(type)")
                #expect(packet.words == words, "\(type)")
            } else {
                #expect(!type.isReserved, "\(type)")
            }
        }
        #expect(try Self.classify(Self.validWords(for: .utility)) == .utility(.noop))
        #expect(try Self.classify(Self.validWords(for: .system))
            == .system(UMPSystemCommonRealTime(group: UMPGroup(5), message: .start)))
        guard case .sysEx7(let sysEx) = try Self.classify(Self.validWords(for: .data64)) else {
            Issue.record("MT 0x3 did not give sysEx7")
            return
        }
        #expect(sysEx.status == .complete)
        guard case .stream(.endpointInfo) = try Self.classify(Self.endpointMIDI2) else {
            Issue.record("MT 0xF did not give a Stream endpoint info")
            return
        }
    }

    @Test func reservedTypesKeepTheirWordsAndAreNeverRefused() throws {
        let reserved = UMPMessageType.allCases.filter(\.isReserved)
        #expect(reserved.map(\.rawValue) == [0x6, 0x7, 0x8, 0x9, 0xA, 0xB, 0xC, 0xE])
        #expect(reserved.map(\.wordCount) == [1, 1, 2, 2, 2, 3, 3, 4])
        for type in reserved {
            for words in [Self.reservedWords(for: type), [UInt32(type.rawValue) << 28]
                + [UInt32](repeating: 0, count: type.wordCount - 1)] {
                let packet = try UMPPacket(words: words)
                let message = try Self.classify(packet, limit: 1)
                #expect(message == .reserved(packet), "\(type)")
                guard case .reserved(let kept) = message else {
                    Issue.record("\(type) was not reserved")
                    continue
                }
                #expect(kept.words == words, "\(type)")
            }
        }
    }

    @Test func eachDecoderRefusalIsWrappedWithItsPayload() throws {
        for fixture in Self.hostilePackets {
            #expect(throws: fixture.refusal, "\(fixture.name)") { try Self.classify(fixture.words) }
        }
        let families = Set(Self.hostilePackets.map { fixture -> String in
            switch fixture.refusal {
            case .packet: return "packet"
            case .flexData: return "flexData"
            case .stream: return "stream"
            }
        })
        #expect(families == ["packet", "flexData", "stream"])
    }

    @Test func theStreamLimitIsARealParameter() throws {
        // "Synth" is five bytes.
        #expect(try Self.classify(Self.block0Name, limit: 5)
            == .stream(.functionBlockName(index: 0, name: UMPStreamString("Synth"))))
        #expect(try Self.classify(Self.block0Name, limit: 255)
            == .stream(.functionBlockName(index: 0, name: UMPStreamString("Synth"))))
        let tooLong = UMPPacketMessageRefusal.stream(.textTooLong(5))
        #expect(throws: tooLong) { try Self.classify(Self.block0Name, limit: 4) }
        // 5 is the text length after the block index byte and trailing zeros are dropped, so the smallest limit
        // reports it too.
        #expect(throws: tooLong) { try Self.classify(Self.block0Name, limit: 1) }
    }

    @Test func theStreamLimitBoundsAreChecked() throws {
        #expect(try UMPStreamLimits.make(maximumTextBytes: 1).maximumTextBytes == 1)
        #expect(try UMPStreamLimits.make(maximumTextBytes: 255).maximumTextBytes == 255)
        for value in [0, 256] {
            #expect(throws: UMPStreamRefusal.invalidLimit(.maximumTextBytes, value: value)) {
                try UMPStreamLimits.make(maximumTextBytes: value)
            }
        }
    }

    @Test func flexDataIsSplitOnBankAndStatus() throws {
        let setup: [[UInt32]] = [
            [0xD610_0000, 0x0000_1234, 0, 0],
            [0xD610_0001, 0x0402_0800, 0, 0],
            [0xD610_0005, 0x2300_0000, 0, 0]
        ]
        for words in setup {
            guard case .flexData(let message) = try Self.classify(words) else {
                Issue.record("\(words) did not give flexData")
                continue
            }
            #expect(message.group == (try UMPGroup(6)))
        }
        var textCount = 0
        for kind in UMPFlexDataMetadataText.allCases.map(UMPFlexDataTextKind.metadata)
            + UMPFlexDataPerformanceText.allCases.map(UMPFlexDataTextKind.performance) {
            for form in UMPFlexDataForm.allCases {
                let first = UInt32(0xD710_0000) | UInt32(form.rawValue) << 22 | UInt32(kind.bank) << 8
                    | UInt32(kind.status)
                let words = [first, 0x4142_4344, 0x4546_4748, 0x494A_4B4C]
                guard case .flexDataText(let text) = try Self.classify(words) else {
                    Issue.record("\(kind) \(form) did not give flexDataText")
                    continue
                }
                #expect(text.kind == kind)
                #expect(text.form == form)
                #expect(text.bytes.count == 12)
                textCount += 1
            }
        }
        #expect(textCount == 4 * (13 + 5))
        let unknown: [([UInt32], UMPPacketMessageRefusal)] = [
            ([0xD010_0301, 0, 0, 0], .flexData(.unknownStatus(bank: 0x03, status: 0x01))),
            ([0xD010_0007, 0, 0, 0], .flexData(.unknownStatus(bank: 0x00, status: 0x07))),
            ([0xD010_0205, 0, 0, 0], .flexData(.unknownStatus(bank: 0x02, status: 0x05))),
            ([0xD010_010D, 0, 0, 0], .flexData(.unknownStatus(bank: 0x01, status: 0x0D)))
        ]
        for (words, refusal) in unknown {
            #expect(throws: refusal) { try Self.classify(words) }
        }
        // Metadata status 0x00 is a defined text kind ("unknown" text), so it is text, not an unknown status.
        guard case .flexDataText(let text) = try Self.classify([0xD010_0100, 0, 0, 0]) else {
            Issue.record("bank 1 status 0 did not give flexDataText")
            return
        }
        #expect(text.kind == .metadata(.unknown))
    }

    @Test func groupMatchesThePacketAndTheDecodedValue() throws {
        for type in UMPMessageType.allCases {
            let packet = try UMPPacket(words: Self.validWords(for: type))
            let message = try Self.classify(packet)
            #expect((packet.group != nil) == type.carriesGroup, "\(type)")
            if type.carriesGroup {
                #expect(packet.group == (try UMPGroup(5)), "\(type)")
                #expect(Self.exposedGroup(of: message) == packet.group, "\(type)")
            } else {
                #expect(Self.exposedGroup(of: message) == nil, "\(type)")
            }
        }
        #expect(!UMPMessageType.utility.carriesGroup)
        #expect(!UMPMessageType.stream.carriesGroup)
    }

    @Test func aWrongWordCountNeverReachesTheClassifier() throws {
        for type in UMPMessageType.allCases {
            let first = UInt32(type.rawValue) << 28
            let tooLong = [first] + [UInt32](repeating: 0, count: type.wordCount)
            #expect(throws: UMPRefusal.wrongWordCount(mt: type, have: type.wordCount + 1, need: type.wordCount)) {
                try UMPPacket(words: tooLong)
            }
        }
        #expect(throws: UMPRefusal.wrongWordCount(mt: .midi2ChannelVoice, have: 1, need: 2)) {
            try UMPPacket(words: [0x4090_3C00])
        }
        #expect(throws: UMPRefusal.emptyPacket) { try UMPPacket(words: []) }
    }
}
