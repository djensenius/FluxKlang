import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private struct GroupProbe {
    let first: Int
    let count: Int
    let expected: UMPStreamRefusal?
}

extension UMPStreamMessageTests {
    /// A valid single-packet message per non-text status, used as the base for refusal fixtures.
    private static let bases: [(status: UInt16, words: [UInt32])] = [
        (0x000, [0xF000_0101, 0x1F, 0, 0]),
        (0x001, [0xF001_0101, 0x8300_0301, 0, 0]),
        (0x002, [0xF002_0000, 0x0011_2233, 0x4455_6677, 0x0102_0304]),
        (0x005, [0xF005_0202, 0, 0, 0]),
        (0x006, [0xF006_0101, 0, 0, 0]),
        (0x010, [0xF010_0503, 0, 0, 0]),
        (0x011, [0xF011_833B, 0x0402_0201, 0, 0]),
        (0x020, [0xF020_0000, 0, 0, 0]),
        (0x021, [0xF021_0000, 0, 0, 0])
    ]

    private static func setting(_ word: Int, _ bit: Int, in words: [UInt32]) -> [UInt32] {
        var result = words
        result[word] |= UInt32(1) << UInt32(bit)
        return result
    }

    /// The reserved bits of each non-text status as (word index, bit) pairs, from DESIGN.md section 2.
    private static func reservedBits(of status: UInt16) -> [(word: Int, bit: Int)] {
        var pairs: [(word: Int, bit: Int)] = []
        func add(_ word: Int, _ bits: [Int]) { pairs += bits.map { (word: word, bit: $0) } }
        let all = Array(0..<32)
        switch status {
        case 0x000: add(1, Array(5..<32)); add(2, all); add(3, all)
        case 0x001: add(1, Array(16..<24) + Array(10..<16) + Array(2..<8)); add(2, all); add(3, all)
        case 0x002:
            add(0, Array(0..<16)); add(1, Array(24..<32) + [7, 15, 23]); add(2, [7, 15, 23, 31])
            add(3, [7, 15, 23, 31])
        case 0x005, 0x006, 0x010: add(0, Array(2..<8)); add(1, all); add(2, all); add(3, all)
        case 0x020, 0x021: add(0, Array(0..<16)); add(1, all); add(2, all); add(3, all)
        default: add(0, [6, 7]); add(2, all); add(3, all)
        }
        return pairs
    }

    @Test func decodeRefusesPacketsOfOtherMessageTypesWithTheirType() throws {
        let utility = try UMPPacket(words: [0x0000_0000])
        let voice = try UMPPacket(words: [0x4090_3C00, 0x8000_0000])
        let flex = try UMPPacket(words: [0xD000_0000, 0, 0, 0])
        let limits = try Self.limits()
        for (packet, type) in [(utility, UMPMessageType.utility), (voice, .midi2ChannelVoice), (flex, .flexData)] {
            do {
                _ = try UMPStreamMessage.decode(packet, limits: limits)
                Issue.record("\(type) was decoded")
            } catch {
                #expect(error == .notStream(actual: type))
            }
        }
    }

    @Test func everyUnassignedOrUnsupportedStatusIsRefusedWithItsValue() throws {
        for status in [UInt32(0x007), 0x00F, 0x013, 0x01F, 0x022, 0x030, 0x100, 0x3FF] {
            #expect(try Self.decodeRefusal([0xF000_0000 | status << 16, 0, 0, 0]) == .unknownStatus(UInt16(status)))
        }
    }

    @Test func everyTenBitStatusIsKnownOrRefusedAsUnknownExactlyOnce() throws {
        let known: Set<UInt16> = [
            0x000, 0x001, 0x002, 0x003, 0x004, 0x005, 0x006, 0x010, 0x011, 0x012, 0x020, 0x021
        ]
        for status in 0..<UInt32(1024) {
            let outcome = try Self.decodeRefusal([0xF000_0000 | status << 16, 0, 0, 0])
            if known.contains(UInt16(status)) {
                #expect(outcome != .unknownStatus(UInt16(status)), "status \(status)")
            } else {
                #expect(outcome == .unknownStatus(UInt16(status)), "status \(status)")
            }
        }
    }

    @Test func singlePacketDecodeRefusesEveryNonCompleteFormatWithNonDefaultValues() throws {
        for (status, words) in Self.bases + [(0x003, [0xF003_0000, 0, 0, 0]), (0x004, [0xF004_0000, 0, 0, 0]),
                                             (0x012, [0xF012_0000, 0, 0, 0])] {
            for format in UInt32(1)...3 {
                var changed = words
                changed[0] |= format << 26
                #expect(
                    try Self.decodeRefusal(changed) == .wrongFormat(status: status, format: UInt8(format)),
                    "status \(status) format \(format)"
                )
            }
        }
    }

    @Test func everyReservedBitIsRefusedOnItsOwnForEveryNonTextStatus() throws {
        for (status, words) in Self.bases {
            #expect(try Self.decodeRefusal(words) == nil, "base \(status)")
            let pairs = Self.reservedBits(of: status)
            #expect(!pairs.isEmpty)
            for pair in pairs {
                let hostile = Self.setting(pair.word, pair.bit, in: words)
                #expect(
                    try Self.decodeRefusal(hostile) == .reservedBitsSet(status: status),
                    "status \(status) word \(pair.word) bit \(pair.bit)"
                )
            }
        }
    }

    @Test func everyDefinedBitOfEachNonTextStatusIsAcceptedNotTreatedAsReserved() throws {
        let defined: [(UInt16, [(Int, Int)])] = [
            (0x000, (0..<5).map { (1, $0) } + (0..<16).map { (0, $0) }),
            (
                0x001,
                [(1, 31), (1, 9), (1, 8), (1, 1), (1, 0)] + (24..<31).map { (1, $0) } + (0..<16).map { (0, $0) }
            ),
            (0x005, [(0, 8), (0, 1), (0, 0)]),
            (0x010, [(0, 8), (0, 9), (0, 10), (0, 11), (0, 12), (0, 0), (0, 1)]),
            (
                0x011,
                [(0, 15), (0, 14), (0, 8), (0, 5), (0, 4), (0, 3), (0, 2), (0, 1), (0, 0)]
                    + (0..<32).map { (1, $0) }
            )
        ]
        for (status, positions) in defined {
            let blank: [UInt32] = status == 0x005
                ? [0xF005_0100, 0, 0, 0]
                : [0xF000_0000 | UInt32(status) << 16, 0, 0, 0]
            for (word, bit) in positions {
                let refusal = try Self.decodeRefusal(Self.setting(word, bit, in: blank))
                if case .reservedBitsSet = refusal { Issue.record("status \(status) word \(word) bit \(bit) refused") }
            }
        }
    }

    @Test func deviceIdentityByteWithBitSevenSetIsReservedOnDecodeAndInvalidOnEncode() throws {
        let words: [UInt32] = [0xF002_0000, 0x0011_2233, 0x4455_6677, 0x0102_0304]
        #expect(try Self.decodeRefusal(words) == nil)
        let badByte: [UInt32] = [0xF002_0000, 0x0011_2280, 0x4455_6677, 0x0102_0304]
        #expect(try Self.decodeRefusal(badByte) == .reservedBitsSet(status: 2))
        let badRevision: [UInt32] = [0xF002_0000, 0x0011_2233, 0x4455_6677, 0x8102_0304]
        #expect(try Self.decodeRefusal(badRevision) == .reservedBitsSet(status: 2))
        var identity = Self.identity
        identity.revision4 = 0x80
        #expect(try Self.encodeRefusal(.deviceIdentity(identity)) == .invalidField(.deviceIdentityByte, value: 0x80))
        identity.revision4 = 0x7F
        #expect(try Self.encodeRefusal(.deviceIdentity(identity)) == nil)
        identity.manufacturer1 = 0xFF
        #expect(try Self.encodeRefusal(.deviceIdentity(identity)) == .invalidField(.deviceIdentityByte, value: 0xFF))
    }

    @Test func endpointInfoBlockCountAcceptsThirtyTwoAndRefusesThirtyThreeOnBothSides() throws {
        #expect(try Self.decodeRefusal([0xF001_0000, 0x2000_0000, 0, 0]) == nil)
        let thirtyThree = UMPStreamRefusal.invalidField(.functionBlockCount, value: 33)
        #expect(try Self.decodeRefusal([0xF001_0000, 0x2100_0000, 0, 0]) == thirtyThree)
        let huge = UMPStreamRefusal.invalidField(.functionBlockCount, value: 127)
        #expect(try Self.decodeRefusal([0xF001_0000, 0x7F00_0000, 0, 0]) == huge)
        #expect(try Self.decodeRefusal([0xF001_0000, 0, 0, 0]) == nil)
        var info = Self.endpointInfo
        info.functionBlockCount = 32
        #expect(try Self.encodeRefusal(.endpointInfo(info)) == nil)
        info.functionBlockCount = 33
        #expect(try Self.encodeRefusal(.endpointInfo(info)) == .invalidField(.functionBlockCount, value: 33))
        info.functionBlockCount = -1
        #expect(try Self.encodeRefusal(.endpointInfo(info)) == .invalidField(.functionBlockCount, value: -1))
        info.functionBlockCount = 0
        #expect(try Self.encodeRefusal(.endpointInfo(info)) == nil)
    }

    @Test func functionBlockIndexAcceptsThirtyOneAndRefusesThirtyTwoInEveryMessage() throws {
        #expect(try Self.decodeRefusal([0xF011_9F3B, 0x0402_0201, 0, 0]) == nil)
        #expect(try Self.decodeRefusal([0xF011_A03B, 0x0402_0201, 0, 0]) == .functionBlockOutOfRange(32))
        #expect(try Self.decodeRefusal([0xF011_FF3B, 0x0402_0201, 0, 0]) == .functionBlockOutOfRange(127))
        #expect(try Self.decodeRefusal([0xF010_1F03, 0, 0, 0]) == nil)
        #expect(try Self.decodeRefusal([0xF010_2003, 0, 0, 0]) == .functionBlockOutOfRange(32))
        #expect(try Self.decodeRefusal([0xF010_FE03, 0, 0, 0]) == .functionBlockOutOfRange(254))
        #expect(try Self.decodeRefusal([0xF010_FF03, 0, 0, 0]) == nil)
        var info = Self.blockInfo
        info.index = 32
        #expect(try Self.encodeRefusal(.functionBlockInfo(info)) == .functionBlockOutOfRange(32))
        info.index = -1
        #expect(try Self.encodeRefusal(.functionBlockInfo(info)) == .functionBlockOutOfRange(-1))
        info.index = 31
        #expect(try Self.encodeRefusal(.functionBlockInfo(info)) == nil)
        let query = UMPStreamFunctionBlockQuery(target: .block(32), wantsInfo: true, wantsName: false)
        #expect(try Self.encodeRefusal(.functionBlockDiscovery(query)) == .functionBlockOutOfRange(32))
        let longName = UMPStreamMessage.functionBlockName(index: 32, name: UMPStreamString("x"))
        #expect(try Self.encodeRefusal(longName) == .functionBlockOutOfRange(32))
        #expect(try Self.encodeRefusal(.functionBlockName(index: 31, name: UMPStreamString("x"))) == nil)
    }

    @Test func streamProtocolAcceptsOneAndTwoAndRefusesEveryOtherValue() throws {
        for status in [UInt32(0x005), 0x006] {
            let base = 0xF000_0000 | status << 16
            #expect(try Self.decodeRefusal([base | 0x0100, 0, 0, 0]) == nil)
            #expect(try Self.decodeRefusal([base | 0x0200, 0, 0, 0]) == nil)
            for wire in [UInt32(0), 3, 4, 0x7F, 0xFF] {
                #expect(try Self.decodeRefusal([base | wire << 8, 0, 0, 0]) == .invalidProtocol(UInt8(wire)))
            }
        }
    }

    @Test func functionBlockInfoRefusesReservedModeAndDirectionValues() throws {
        #expect(try Self.decodeRefusal([0xF011_800C, 0x0001_0000, 0, 0]) == .invalidField(.midi1Mode, value: 3))
        #expect(try Self.decodeRefusal([0xF011_8008, 0x0001_0001, 0, 0]) == .invalidField(.direction, value: 0))
        #expect(try Self.decodeRefusal([0xF011_8009, 0x0001_0000, 0, 0]) == nil)
        for hint in UInt32(0)...3 {
            #expect(try Self.decodeRefusal([0xF011_8001 | hint << 4, 0x0001_0000, 0, 0]) == nil)
        }
    }

    @Test func functionBlockInfoGroupAndVersionBoundsAreCheckedOnDecodeAndEncode() throws {
        let cases: [(UInt32, UMPStreamRefusal?)] = [
            (0x0F01_0000, nil), (0x0010_0000, nil), (0x0F02_0000, .invalidField(.groupCount, value: 2)),
            (0x1001_0000, .invalidField(.firstGroup, value: 16)), (0x0000_0000, .invalidField(.groupCount, value: 0)),
            (0x0011_0000, .invalidField(.groupCount, value: 17)), (0x0802_0000, nil),
            (0x0F01_0200, nil), (0x0F01_0300, .invalidField(.midiCIVersion, value: 3)),
            (0x0F01_FF00, .invalidField(.midiCIVersion, value: 255))
        ]
        for (word, expected) in cases {
            #expect(try Self.decodeRefusal([0xF011_8001, word, 0, 0]) == expected, "word \(String(word, radix: 16))")
        }
        var info = Self.blockInfo
        for probe in [
            GroupProbe(first: 15, count: 1, expected: nil),
            GroupProbe(first: 15, count: 2, expected: .invalidField(.groupCount, value: 2)),
            GroupProbe(first: 16, count: 1, expected: .invalidField(.firstGroup, value: 16)),
            GroupProbe(first: -1, count: 1, expected: .invalidField(.firstGroup, value: -1)),
            GroupProbe(first: 0, count: 16, expected: nil),
            GroupProbe(first: 0, count: 17, expected: .invalidField(.groupCount, value: 17)),
            GroupProbe(first: 0, count: 0, expected: .invalidField(.groupCount, value: 0)),
            GroupProbe(first: 0, count: -1, expected: .invalidField(.groupCount, value: -1))
        ] {
            info.firstGroup = probe.first
            info.groupCount = probe.count
            #expect(try Self.encodeRefusal(.functionBlockInfo(info)) == probe.expected, "\(probe)")
        }
        info.firstGroup = 0
        info.groupCount = 1
        info.midiCIVersion = 3
        #expect(try Self.encodeRefusal(.functionBlockInfo(info)) == .invalidField(.midiCIVersion, value: 3))
        let query = UMPStreamFunctionBlockQuery(target: .block(-1), wantsInfo: true, wantsName: true)
        #expect(try Self.encodeRefusal(.functionBlockDiscovery(query)) == .functionBlockOutOfRange(-1))
    }

    @Test func versionBytesAndSysEx8StreamCountAcceptEveryValue() throws {
        for version in [UInt32(0x0000), 0x00FF, 0xFF00, 0xFFFF] {
            let expected = UMPStreamVersion(major: UInt8(version >> 8), minor: UInt8(version & 0xFF))
            #expect(try Self.decode([0xF000_0000 | version, 0, 0, 0])
                == .endpointDiscovery(version: expected, filter: UMPStreamEndpointFilter(
                    info: false, deviceIdentity: false, name: false, productInstanceID: false,
                    streamConfiguration: false
                )))
        }
    }

    @Test func notStreamIsReportedBeforeAnUnknownStatusCanBeLookedAt() throws {
        #expect(try Self.decodeRefusal([0xD007_0000, 0, 0, 0]) == .notStream(actual: .flexData))
    }

    @Test func unknownStatusIsReportedBeforeAWrongFormat() throws {
        #expect(try Self.decodeRefusal([0xF407_0000, 0, 0, 0]) == .unknownStatus(7))
        #expect(try Self.decodeRefusal([0xFC22_0000, 0x1, 0, 0]) == .unknownStatus(0x22))
    }

    @Test func wrongFormatIsReportedBeforeReservedBitsAndFieldRanges() throws {
        #expect(try Self.decodeRefusal([0xF400_0000, 0, 0, 1]) == .wrongFormat(status: 0, format: 1))
        #expect(try Self.decodeRefusal([0xF801_0000, 0x7F00_0000, 0, 1]) == .wrongFormat(status: 1, format: 2))
        #expect(try Self.decodeRefusal([0xFC11_FF00, 0, 1, 0]) == .wrongFormat(status: 0x11, format: 3))
        #expect(try Self.decodeRefusal([0xF420_FFFF, 1, 0, 0]) == .wrongFormat(status: 0x20, format: 1))
        #expect(try Self.decodeRefusal([0xFC21_0001, 0, 0, 1]) == .wrongFormat(status: 0x21, format: 3))
    }

    @Test func reservedBitsAreReportedBeforeFieldRangeErrors() throws {
        #expect(try Self.decodeRefusal([0xF011_A00C, 0, 1, 0]) == .reservedBitsSet(status: 0x11))
        #expect(try Self.decodeRefusal([0xF001_0000, 0x7F00_0004, 0, 0]) == .reservedBitsSet(status: 1))
        #expect(try Self.decodeRefusal([0xF005_0300, 0, 0, 1]) == .reservedBitsSet(status: 5))
        #expect(try Self.decodeRefusal([0xF010_2003, 1, 0, 0]) == .reservedBitsSet(status: 0x10))
    }

    @Test func functionBlockInfoChecksIndexThenModeThenDirectionThenGroups() throws {
        #expect(try Self.decodeRefusal([0xF011_A00C, 0x1001_0000, 0, 0]) == .functionBlockOutOfRange(32))
        #expect(try Self.decodeRefusal([0xF011_800C, 0x1001_0000, 0, 0]) == .invalidField(.midi1Mode, value: 3))
        #expect(try Self.decodeRefusal([0xF011_8008, 0x1001_0000, 0, 0]) == .invalidField(.direction, value: 0))
        #expect(try Self.decodeRefusal([0xF011_8001, 0x1001_0300, 0, 0]) == .invalidField(.firstGroup, value: 16))
        #expect(try Self.decodeRefusal([0xF011_8001, 0x0F00_0300, 0, 0]) == .invalidField(.groupCount, value: 0))
    }
}
