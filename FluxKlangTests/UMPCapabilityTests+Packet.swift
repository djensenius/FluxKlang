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
        let result = try Self.negotiate(packets, answer: Self.ciAnswer(reply: Self.reply))
        #expect(result.level == .umpMIDI2)
        #expect(result.features == [.umpTransport, .midi2Protocol, .jitterReduction, .functionBlocks, .ciDiscovery])
        #expect(result.functionBlocks == [Self.expectedBlock0, Self.expectedBlock1])
        #expect(result.profiles.isEmpty)
        #expect(result.downgrades.isEmpty)
    }

    @Test func inactiveBlocksAreListedButGrantNoFunctionBlockFeature() throws {
        // Endpoint with one block (MIDI 2.0 only), block 0 with the active bit (word 0 bit 15) clear.
        let endpoint: [UInt32] = [0xF001_0101, 0x8100_0200, 0, 0]
        let inactive: [UInt32] = [0xF011_0033, 0x0002_0201, 0, 0]
        let result = try Self.negotiate([endpoint, inactive], answer: Self.ciAnswer(reply: Self.reply))
        #expect(result.level == .umpMIDI2)
        #expect(result.features == [.umpTransport, .midi2Protocol, .ciDiscovery])
        let block = try #require(result.functionBlocks.first)
        #expect(result.functionBlocks.count == 1)
        #expect(!block.isActive)
    }

    @Test func hostileStreamWordsAreRefusedAndContributeNothing() throws {
        let limits = try Self.limits()
        let good = [Self.endpointMIDI2, Self.block0, Self.block1]
        let answer = try Self.ciAnswer(reply: Self.reply)
        let baseline = try Self.negotiate(good, answer: answer)
        #expect(baseline.level == .umpMIDI2)
        #expect(baseline.functionBlocks == [Self.expectedBlock0, Self.expectedBlock1])
        for fixture in Self.hostile {
            let packet = try UMPPacket(words: fixture.words)
            #expect(throws: fixture.refusal, "\(fixture.name)") { try UMPStreamMessage.decode(packet, limits: limits) }
            // The pipeline yields no facts at all, wherever the hostile packet sits...
            for position in 0...good.count {
                var packets = good
                packets.insert(fixture.words, at: position)
                #expect(throws: fixture.refusal, "\(fixture.name)") { try Self.facts(packets, answer: answer) }
            }
            // ...and the good packets alone still negotiate exactly as before.
            #expect(try Self.negotiate(good, answer: answer) == baseline, "\(fixture.name)")
        }
    }

    @Test func inconsistentWireFactsAreRefusedByTheResolver() throws {
        let answer = try Self.ciAnswer(reply: Self.reply)
        // Block 1 moved to first group 1: it overlaps block 0 (groups 0-1).
        let overlapping: [UInt32] = [0xF011_8115, 0x0101_0100, 0, 0]
        let cases: [([[UInt32]], MIDICapabilityRefusal)] = [
            ([Self.endpointMIDI2, Self.block0], .functionBlockCountMismatch(declared: 2, supplied: 1)),
            ([Self.block0], .functionBlocksWithoutEndpoint(count: 1)),
            ([Self.endpointMIDI2, Self.block0, Self.block0], .duplicateFunctionBlockIndex(0)),
            ([Self.endpointMIDI2, overlapping, Self.block0], .overlappingFunctionBlockGroups(first: 0, second: 1))
        ]
        for (packets, expected) in cases {
            #expect(Self.refusal(try Self.facts(packets, answer: answer)) == expected)
        }
    }
}
