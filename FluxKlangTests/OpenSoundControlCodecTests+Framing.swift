import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Deterministic linear congruential generator for bounded fuzz-style inputs.
struct OpenSoundControlFuzzGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(bound, 1)))
    }

    mutating func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8(truncatingIfNeeded: next(256)) }
    }
}

@Suite("OpenSoundControl framing and malformed input")
struct OpenSoundControlFramingTests {
    typealias Fixture = OpenSoundControlFixture
    typealias CodecError = OpenSoundControl.CodecError
    typealias Framer = OpenSoundControl.StreamFramer
    typealias Limits = OpenSoundControl.Limits

    static let packets: [[UInt8]] = Fixture.corpus.compactMap { try? Fixture.encode($0) }

    static func frames(_ events: [OpenSoundControl.FrameEvent]) -> [[UInt8]] {
        events.compactMap { if case .frame(let bytes) = $0 { bytes } else { nil } }
    }

    /// Accepted input must be canonical: re-encoding reproduces it exactly.
    static func decodeNeverTraps(_ bytes: [UInt8], limits: Limits = .standard) -> Bool {
        guard let packet = try? Fixture.decode(bytes, limits: limits) else { return false }
        #expect((try? Fixture.encode(packet, limits: limits)) == bytes)
        return true
    }

    static func rawNested(depth: Int) -> [UInt8] {
        var bytes = Fixture.ascii("/leaf") + [0, 0, 0] + Fixture.ascii(",") + [0, 0, 0]
        for _ in 0..<depth {
            let header = OpenSoundControl.bundleHeader + [0, 0, 0, 0, 0, 0, 0, 1]
            bytes = header + Fixture.bigEndian(UInt32(bytes.count)) + bytes
        }
        return bytes
    }

    // MARK: - SLIP

    @Test func slipEscapesEndAndEscapeBetweenDoubleEnds() throws {
        let framed = try Framer.frame([0x2F, 0xC0, 0x00, 0xDB], framing: .slip)
        #expect(framed == [0xC0, 0x2F, 0xDB, 0xDC, 0x00, 0xDB, 0xDD, 0xC0])
        var framer = Framer(framing: .slip)
        #expect(framer.append(framed) == [.frame([0x2F, 0xC0, 0x00, 0xDB])])
    }

    @Test(arguments: 1...7)
    func slipReassemblesAcrossChunksAndIgnoresEmptyFrames(chunkSize: Int) throws {
        var stream: [UInt8] = [0xC0, 0xC0]
        for packet in Self.packets { stream += try Framer.frame(packet, framing: .slip) + [0xC0] }
        var framer = Framer(framing: .slip)
        var received: [[UInt8]] = []
        for start in stride(from: 0, to: stream.count, by: chunkSize) {
            received += Self.frames(framer.append(Array(stream[start..<min(start + chunkSize, stream.count)])))
        }
        #expect(received == Self.packets)
        #expect(try received.map { try Fixture.decode($0) } == Fixture.corpus)
        var bare = Framer(framing: .slip)
        #expect(bare.append([1, 2, 0xC0]) == [.frame([1, 2])])
    }

    @Test func slipRefusesInvalidEscapeThenResyncsAtEnd() {
        var framer = Framer(framing: .slip)
        let events = framer.append([0xC0, 0x41, 0xDB, 0x41, 0x42, 0xC0, 0x43, 0xC0])
        #expect(events == [.refused(.invalidSlipEscape(0x41)), .frame([0x43])])
        #expect(framer.append([0x44, 0xDB, 0xC0, 0x45, 0xC0]) == [.refused(.invalidSlipEscape(0xC0)), .frame([0x45])])
        #expect(framer.state == .ready)
    }

    @Test func slipFrameLimitAtNAndNPlusOneThenResync() {
        var framer = Framer(framing: .slip, limits: Limits(maximumPacketBytes: 8))
        let atLimit = [UInt8](repeating: 0xC0, count: 8)
        let escaped = (try? Framer.frame(atLimit, framing: .slip, limits: Limits(maximumPacketBytes: 8))) ?? []
        #expect(escaped.count == 18)
        #expect(framer.append(escaped) == [.frame(atLimit)])
        #expect(framer.append([UInt8](repeating: 1, count: 9)) == [.refused(.frameTooLarge(byteCount: 9, limit: 8))])
        #expect(framer.state == .discarding)
        #expect(framer.append([UInt8](repeating: 1, count: 100)).isEmpty)
        #expect(framer.bufferedByteCount == 0)
        #expect(framer.append([0xC0, 7, 0xC0]) == [.frame([7])])
        #expect(framer.state == .ready)
    }

    // MARK: - Length prefix

    @Test(arguments: [1, 3, 5, 64])
    func lengthPrefixIsBigEndianAndReassembles(chunkSize: Int) throws {
        let framed = try Framer.frame([9, 8, 7, 6, 5], framing: .lengthPrefixed)
        #expect(framed == [0, 0, 0, 5, 9, 8, 7, 6, 5])
        let stream = try Self.packets.flatMap { try Framer.frame($0, framing: .lengthPrefixed) }
        var framer = Framer(framing: .lengthPrefixed)
        var received: [[UInt8]] = []
        for start in stride(from: 0, to: stream.count, by: chunkSize) {
            received += Self.frames(framer.append(Array(stream[start..<min(start + chunkSize, stream.count)])))
        }
        #expect(received == Self.packets)
        #expect(framer.bufferedByteCount == 0)
    }

    @Test func lengthPrefixLittleEndianHeaderIsRefused() {
        var framer = Framer(framing: .lengthPrefixed)
        #expect(framer.append([12, 0, 0, 0]) == [.refused(.frameTooLarge(byteCount: 0x0C00_0000, limit: 65_536))])
    }

    @Test func lengthPrefixLimitAtNAndNPlusOneFailsPermanently() {
        var framer = Framer(framing: .lengthPrefixed, limits: Limits(maximumPacketBytes: 8))
        let atLimit: [UInt8] = [0, 0, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8]
        #expect(framer.append(atLimit + [0, 0, 0, 9, 1]) == [.frame([1, 2, 3, 4, 5, 6, 7, 8]),
                                                             .refused(.frameTooLarge(byteCount: 9, limit: 8))])
        #expect(framer.state == .failed)
        #expect(framer.bufferedByteCount == 0)
        #expect(framer.append(atLimit) == [.refused(.framerFailed)])
        var empty = Framer(framing: .lengthPrefixed)
        #expect(empty.append([0, 0, 0, 0, 0, 0, 0, 4]) == [.refused(.emptyFrame)])
        #expect(empty.state == .failed)
    }

    @Test func framingRefusesEmptyAndOversizePackets() {
        for framing in [OpenSoundControl.StreamFraming.slip, .lengthPrefixed] {
            #expect(throws: CodecError.emptyFrame) { try Framer.frame([], framing: framing) }
            #expect(throws: CodecError.frameTooLarge(byteCount: 5, limit: 4)) {
                try Framer.frame([1, 2, 3, 4, 5], framing: framing, limits: Limits(maximumPacketBytes: 4))
            }
            #expect((try? Framer.frame([1, 2, 3, 4], framing: framing, limits: Limits(maximumPacketBytes: 4))) != nil)
        }
    }

    // MARK: - Malformed input

    @Test func truncationsAtEveryOffsetNeverTrap() {
        for packet in Self.packets {
            for length in 0..<packet.count {
                let accepted = Self.decodeNeverTraps(Array(packet.prefix(length)))
                if packet.first == UInt8(ascii: "/") { #expect(!accepted) }
            }
        }
    }

    @Test func singleByteMutationsNeverTrap() {
        var refused = 0
        for packet in Self.packets {
            for offset in packet.indices {
                for flip: UInt8 in [0x01, 0x20, 0x80, 0xFF] {
                    var bytes = packet
                    bytes[offset] ^= flip
                    if !Self.decodeNeverTraps(bytes) { refused += 1 }
                }
            }
        }
        #expect(refused > 0)
    }

    @Test func hostileLengthsAreRefused() {
        let blobPrefix = Fixture.ascii("/b") + [0, 0] + Fixture.ascii(",b") + [0, 0]
        #expect(throws: CodecError.blobTooLarge(byteCount: Int(Int32.max), limit: 32_768)) {
            try Fixture.decode(blobPrefix + Fixture.bigEndian(0x7FFF_FFFF) + [0, 0, 0, 0])
        }
        #expect(throws: CodecError.negativeLength(.min)) {
            try Fixture.decode(blobPrefix + Fixture.bigEndian(0x8000_0000))
        }
        #expect(throws: CodecError.negativeLength(-1)) {
            try Fixture.decode(blobPrefix + Fixture.bigEndian(0xFFFF_FFFF))
        }
        #expect(throws: CodecError.truncated) {
            try Fixture.decode(blobPrefix + Fixture.bigEndian(0x7FFF_FFFC), limits: Limits(maximumBlobBytes: .max))
        }
        let unbounded = Limits(maximumArguments: .max, maximumStringBytes: .max)
        #expect(throws: CodecError.unterminatedString) { try Fixture.decode(Fixture.ascii("/abc"), limits: unbounded) }
        let tags = Fixture.ascii(",") + [UInt8](repeating: UInt8(ascii: "T"), count: 198) + [0]
        let manyTags = Fixture.ascii("/a") + [0, 0] + tags
        #expect(throws: CodecError.tooManyArguments(limit: 128)) { try Fixture.decode(manyTags) }
        #expect(throws: CodecError.truncated) { try Fixture.decode(OpenSoundControl.bundleHeader) }
        #expect(throws: CodecError.truncated) { try Fixture.decode(OpenSoundControl.bundleHeader + [0, 0, 0, 1]) }
    }

    @Test func nestingBeyondLimitIsRefusedWithoutRecursingFurther() throws {
        #expect(try Fixture.decode(Self.rawNested(depth: 8)) == Fixture.nested(depth: 8))
        #expect(throws: CodecError.bundleTooDeep(limit: 8)) { try Fixture.decode(Self.rawNested(depth: 9)) }
        #expect(throws: CodecError.bundleTooDeep(limit: 8)) { try Fixture.decode(Self.rawNested(depth: 2_000)) }
        #expect(throws: CodecError.bundleTooDeep(limit: 8)) { try Fixture.encode(Fixture.nested(depth: 64)) }
    }

    @Test func randomInputsNeverTrap() {
        var generator = OpenSoundControlFuzzGenerator(seed: 0x0589)
        let prefixes: [[UInt8]] = [Fixture.ascii("/a") + [0, 0, 0x2C], OpenSoundControl.bundleHeader, []]
        var accepted = 0
        for _ in 0..<3_000 {
            var bytes = prefixes[generator.next(prefixes.count)] + generator.bytes(generator.next(48))
            bytes += [UInt8](repeating: 0, count: OpenSoundControl.padding(after: bytes.count))
            let limits = Limits(maximumBundleDepth: 2, maximumStringBytes: 16)
            if Self.decodeNeverTraps(bytes, limits: limits) { accepted += 1 }
        }
        #expect(accepted < 3_000)
    }

    @Test(arguments: [OpenSoundControl.StreamFraming.slip, .lengthPrefixed])
    func randomStreamsStayWithinBufferBounds(framing: OpenSoundControl.StreamFraming) {
        var generator = OpenSoundControlFuzzGenerator(seed: framing == .slip ? 11 : 13)
        var framer = Framer(framing: framing, limits: Limits(maximumPacketBytes: 32))
        for _ in 0..<2_000 {
            var chunk = generator.bytes(generator.next(40))
            if framing == .slip, !chunk.isEmpty, generator.next(3) == 0 { chunk[generator.next(chunk.count)] = 0xC0 }
            for event in framer.append(chunk) {
                if case .frame(let frame) = event { #expect(!frame.isEmpty && frame.count <= 32) }
            }
            #expect(framer.bufferedByteCount <= 36)
            if framing == .slip { #expect(framer.state != .failed) }
        }
    }
}
