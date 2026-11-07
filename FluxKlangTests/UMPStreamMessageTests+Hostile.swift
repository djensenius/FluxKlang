import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// A fixed-seed generator for the hostile sweeps; the values never depend on the machine or the clock.
private struct UMPStreamHostileGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

extension UMPStreamMessageTests {
    private static func hostileWords(_ generator: inout UMPStreamHostileGenerator) throws -> [UInt32] {
        let pool = try samples.flatMap { try encode($0) }
        switch generator.below(4) {
        case 0:
            return [UInt32(truncatingIfNeeded: generator.next()) | 0xF000_0000] + (0..<3).map { _ in
                generator.below(3) == 0 ? UInt32(truncatingIfNeeded: generator.next()) : 0
            }
        case 1:
            var words = pool[generator.below(pool.count)]
            for _ in 0..<(1 + generator.below(2)) {
                words[generator.below(4)] ^= UInt32(1) << UInt32(generator.below(32))
            }
            words[0] = (words[0] & 0x0FFF_FFFF) | 0xF000_0000
            return words
        default:
            return pool[generator.below(pool.count)]
        }
    }

    @Test func seededHostilePacketsDecodeOrRefuseAndEveryAcceptedPacketReEncodesToItself() throws {
        var generator = UMPStreamHostileGenerator(seed: 0x55AA_0F0F_1234_ABCD)
        var accepted = 0
        var refused = 0
        for _ in 0..<4_000 {
            let words = try Self.hostileWords(&generator)
            guard let refusal = try Self.decodeRefusal(words) else {
                accepted += 1
                let message = try Self.decode(words)
                #expect(try Self.encode(message) == [words], "\(words)")
                continue
            }
            refused += 1
            if case .notStream = refusal { Issue.record("a Message Type 0xF packet was refused as not stream") }
        }
        #expect(accepted > 200)
        #expect(refused > 200)
    }

    @Test func nonStreamPacketsOfEveryTypeAreRefusedAsNotStreamWithTheirType() throws {
        for type in UMPMessageType.allCases where type != .stream {
            let first = UInt32(type.rawValue) << 28
            let words = [first] + Array(repeating: UInt32(0), count: type.wordCount - 1)
            #expect(try Self.decodeRefusal(words) == .notStream(actual: type))
        }
    }

    @Test func seededTextPacketStreamsKeepTheAssemblerConsistentAndRefusalsNeverMutateIt() throws {
        var generator = UMPStreamHostileGenerator(seed: 0x0DDB_A11C_AFE5_1DE5)
        var assembler = try Self.hostileAssembler(60)
        var completed = 0
        var refused = 0
        for _ in 0..<6_000 {
            let status = [UInt32(0x003), 0x003, 0x004, 0x012, 0x003, 0x002][generator.below(6)]
            let bytes = (0..<generator.below(status == 0x012 ? 14 : 15)).map { _ in
                [UInt8(0x41), 0x42, 0x43, 0x44, 0x00, 0xFF][generator.below(6)]
            }
            let format = [0, 1, 1, 2, 3, 3][generator.below(6)]
            let words = Self.textWords(
                status: status, format: UInt32(format),
                index: status == 0x012 ? UInt8(generator.below(2)) : nil, bytes: bytes
            )
            let before = assembler
            do {
                switch try assembler.feed(UMPPacket(words: words)) {
                case .partial: #expect(assembler.isAssembling)
                case .complete:
                    completed += 1
                    #expect(!assembler.isAssembling)
                }
            } catch {
                refused += 1
                #expect(assembler == before, "\(error)")
            }
            #expect(assembler.pendingPacketCount <= 7)
            #expect(assembler.pendingByteCount <= 98)
            if generator.below(6) == 0 { assembler.reset() }
        }
        #expect(completed > 100)
        #expect(refused > 100)
    }

    @Test func seededTextsOfEveryKindRoundTripThroughTheirCanonicalPackets() throws {
        var generator = UMPStreamHostileGenerator(seed: 0x1357_9BDF_2468_ACE0)
        let alphabet = ["a", "Z", "7", " ", "\u{E9}", "\u{20AC}", "\u{1F3B9}", "e\u{301}", "\u{1}"]
        for round in 0..<600 {
            let kind = [UMPStreamTextKind.endpointName, .productInstanceID, .functionBlockName][round % 3]
            var value = ""
            let pool = kind == .productInstanceID ? Array(alphabet.prefix(4)) : alphabet
            while true {
                let piece = pool[generator.below(pool.count)]
                if value.utf8.count + piece.utf8.count > kind.specificationMaximumBytes { break }
                value += piece
                if generator.below(12) == 0 { break }
            }
            let message = Self.hostileName(kind, value, index: generator.below(32))
            let packets = try UMPStreamMessage.encode(message, limits: Self.limits())
            let size = kind.bytesPerPacket
            #expect(packets.count == max(1, (value.utf8.count + size - 1) / size), "\(round)")
            var assembler = UMPStreamTextAssembler(limits: try Self.limits())
            var last: UMPStreamTextEvent?
            for packet in packets { last = try assembler.feed(packet) }
            #expect(last == .complete(message), "round \(round)")
        }
    }

    private static func hostileName(_ kind: UMPStreamTextKind, _ value: String, index: Int) -> UMPStreamMessage {
        switch kind {
        case .endpointName: return .endpointName(UMPStreamString(value))
        case .productInstanceID: return .productInstanceID(UMPStreamString(value))
        case .functionBlockName: return .functionBlockName(index: index, name: UMPStreamString(value))
        }
    }

    private static func hostileAssembler(_ limit: Int) throws -> UMPStreamTextAssembler {
        UMPStreamTextAssembler(limits: try limits(limit))
    }
}
