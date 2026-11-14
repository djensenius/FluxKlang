import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum OpenSoundControlFixture {
    typealias Packet = OpenSoundControl.Packet

    static func pattern(_ string: String) -> OpenSoundControl.AddressPattern {
        do { return try OpenSoundControl.AddressPattern(string) } catch {
            preconditionFailure("invalid pattern \(string)")
        }
    }

    static func address(_ string: String) -> OpenSoundControl.Address {
        do { return try OpenSoundControl.Address(string) } catch { preconditionFailure("invalid address \(string)") }
    }

    static func message(_ address: String, _ arguments: [OpenSoundControl.Argument] = []) -> Packet {
        .message(OpenSoundControl.Message(address: pattern(address), arguments: arguments))
    }

    static func bundle(_ elements: [Packet], timeTag: OpenSoundControl.TimeTag = .immediate) -> Packet {
        .bundle(OpenSoundControl.Bundle(timeTag: timeTag, elements: elements))
    }

    /// `depth` nested bundles around one message.
    static func nested(depth: Int) -> Packet {
        var packet = message("/leaf")
        for _ in 0..<depth { packet = bundle([packet]) }
        return packet
    }

    static func ascii(_ string: String) -> [UInt8] { Array(string.utf8) }

    static func hex(_ string: String) -> [UInt8] {
        let digits = Array(string.filter { !$0.isWhitespace })
        return stride(from: 0, to: digits.count, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> UInt32($0)) }
    }

    static let quietNaN = Float(bitPattern: 0x7FC0_1234)
    static let signallingNaN = Double(bitPattern: 0x7FF0_0000_0000_0BAD)

    /// Valid values covering every type tag, padding phase and nesting shape.
    static let corpus: [Packet] = [
        message("/a"),
        message("/oscillator/4/frequency", [.float32(440)]),
        message("/foo", [.int32(1_000), .int32(-1), .string("hello"), .float32(1.234), .float32(5.678)]),
        message("/types", [.int64(.min), .float64(-0.0), .timeTag(.immediate), .true, .false, .nil, .impulse]),
        message("/nan", [.float32(quietNaN), .float64(signallingNaN), .float32(-0.0), .float64(.infinity)]),
        message("/empty", [.string(""), .blob([])]),
        message("/pad", [.string("abc"), .string("abcd"), .blob([1]), .blob([1, 2, 3, 4, 5]), .string("é✓")]),
        message("/{a,b}/[!0-9]*", [.int32(.max), .int64(.max), .timeTag(.init(seconds: 7, fraction: 9))]),
        bundle([]),
        bundle([message("/x", [.int32(1)]), message("/y")], timeTag: .init(rawValue: 0xDEAD_BEEF_0000_0001)),
        bundle([bundle([message("/deep", [.blob([0xC0, 0xDB])])]), message("/z", [.string("s")])]),
        nested(depth: 8)
    ]

    static func encode(_ packet: Packet, limits: OpenSoundControl.Limits = .standard) throws -> [UInt8] {
        try OpenSoundControl.Encoder(limits: limits).encode(packet)
    }

    static func decode(_ bytes: [UInt8], limits: OpenSoundControl.Limits = .standard) throws -> Packet {
        try OpenSoundControl.Decoder(limits: limits).decode(bytes)
    }
}

@Suite("OpenSoundControl codec", .productionAccessAudit)
struct OpenSoundControlCodecTests {
    typealias Fixture = OpenSoundControlFixture
    typealias CodecError = OpenSoundControl.CodecError
    typealias Limits = OpenSoundControl.Limits

    @Test func encodesSpecificationExamples() throws {
        let frequency = Fixture.message("/oscillator/4/frequency", [.float32(440)])
        let frequencyBytes = Fixture.ascii("/oscillator/4/frequency") + Fixture.hex("00 2c660000 43dc0000")
        #expect(try Fixture.encode(frequency) == frequencyBytes)
        let foo = Fixture.corpus[2]
        let expected = Fixture.hex("""
            2f666f6f 00000000 2c696973 66660000 000003e8 ffffffff 68656c6c 6f000000 3f9df3b6 40b5b22d
            """)
        #expect(try Fixture.encode(foo) == expected)
        #expect(try Fixture.decode(expected) == foo)
    }

    @Test func valuesRoundTripBitExactly() throws {
        for packet in Fixture.corpus {
            let bytes = try Fixture.encode(packet)
            #expect(bytes.count % 4 == 0)
            #expect(try Fixture.decode(bytes) == packet)
            #expect(try Fixture.encode(Fixture.decode(bytes)) == bytes)
        }
        guard case .message(let decoded) = try Fixture.decode(Fixture.encode(Fixture.corpus[4])),
              case .float32(let nan) = decoded.arguments[0], case .float64(let wide) = decoded.arguments[1],
              case .float32(let zero) = decoded.arguments[2] else {
            Issue.record("expected floats")
            return
        }
        #expect(nan.bitPattern == 0x7FC0_1234)
        #expect(wide.bitPattern == 0x7FF0_0000_0000_0BAD)
        #expect(zero.bitPattern == 0x8000_0000)
        #expect(OpenSoundControl.Argument.float32(0) != .float32(-0.0))
    }

    @Test func zeroArgumentMessageCarriesCommaTagString() throws {
        let expected = Fixture.ascii("/a") + [0, 0] + Fixture.ascii(",") + [0, 0, 0]
        #expect(try Fixture.encode(Fixture.message("/a")) == expected)
    }

    @Test(arguments: 0...8)
    func stringsAndBlobsPadToFourBytes(length: Int) throws {
        let content = String(repeating: "x", count: length)
        let blob = [UInt8](repeating: 7, count: length)
        let stringBytes = try Fixture.encode(Fixture.message("/s", [.string(content)]))
        let blobBytes = try Fixture.encode(Fixture.message("/b", [.blob(blob)]))
        #expect(stringBytes.count == 8 + (length / 4 + 1) * 4)
        #expect(blobBytes.count == 8 + 4 + (length + 3) / 4 * 4)
        #expect(stringBytes.dropFirst(8 + length).allSatisfy { $0 == 0 })
        #expect(Array(blobBytes[8..<12]) == Fixture.bigEndian(UInt32(length)))
        #expect(blobBytes.dropFirst(12 + length).allSatisfy { $0 == 0 })
    }

    @Test func refusesNonZeroPadding() throws {
        let canonical = Fixture.ascii("/ab") + [0] + Fixture.ascii(",sb") + [0] + Fixture.ascii("xy") + [0, 0]
            + Fixture.bigEndian(1) + [9, 0, 0, 0]
        for offset in [11, 17, 18, 19] {
            var bytes = canonical
            bytes[offset] = 1
            #expect(throws: CodecError.nonZeroPadding) { try Fixture.decode(bytes) }
        }
        let addressPadding = Fixture.ascii("/abcd") + [0, 1, 0] + Fixture.ascii(",") + [0, 0, 0]
        #expect(throws: CodecError.nonZeroPadding) { try Fixture.decode(addressPadding) }
        let tagPadding = Fixture.ascii("/a") + [0, 0] + Fixture.ascii(",") + [0, 0, 1]
        #expect(throws: CodecError.nonZeroPadding) { try Fixture.decode(tagPadding) }
        #expect(try Fixture.decode(canonical) == Fixture.message("/ab", [.string("xy"), .blob([9])]))
    }

    @Test func refusesWholePacketOnUnknownTypeTag() {
        for tag in Fixture.ascii("Scrm[]x") {
            let bytes = Fixture.ascii("/a") + [0, 0] + Fixture.ascii(",i") + [tag, 0]
            #expect(throws: CodecError.unknownTypeTag(tag)) { try Fixture.decode(bytes) }
        }
    }

    @Test func refusesMissingTypeTagString() {
        #expect(throws: CodecError.missingTypeTags) { try Fixture.decode(Fixture.ascii("/abc") + [0, 0, 0, 0]) }
        let legacy = Fixture.ascii("/a") + [0, 0] + Fixture.bigEndian(5)
        #expect(throws: CodecError.missingTypeTags) { try Fixture.decode(legacy) }
    }

    @Test func refusesStructuralDefects() {
        let message = Fixture.ascii("/a") + [0, 0] + Fixture.ascii(",") + [0, 0, 0]
        #expect(throws: CodecError.emptyPacket) { try Fixture.decode([]) }
        #expect(throws: CodecError.packetNotAligned(byteCount: 9)) { try Fixture.decode(message + [0]) }
        #expect(throws: CodecError.trailingBytes) { try Fixture.decode(message + [0, 0, 0, 0]) }
        #expect(throws: CodecError.unrecognizedPacket) { try Fixture.decode(Fixture.ascii("abcd")) }
        #expect(throws: CodecError.unrecognizedPacket) {
            try Fixture.decode(Fixture.ascii("#bundlx") + [0] + [UInt8](repeating: 0, count: 8))
        }
        #expect(throws: CodecError.unterminatedString) { try Fixture.decode(Fixture.ascii("/abc")) }
        let badUTF8 = Fixture.ascii("/a") + [0, 0] + Fixture.ascii(",s") + [0, 0, 0xFF, 0, 0, 0]
        #expect(throws: CodecError.invalidUTF8) { try Fixture.decode(badUTF8) }
        let bundle = OpenSoundControl.bundleHeader + [UInt8](repeating: 0, count: 8)
        for size: UInt32 in [0, 2, 0xFFFF_FFFC] {
            #expect(throws: CodecError.invalidElementSize(Int32(bitPattern: size))) {
                try Fixture.decode(bundle + Fixture.bigEndian(size) + message)
            }
        }
        #expect(throws: CodecError.truncated) { try Fixture.decode(bundle + Fixture.bigEndian(16) + message) }
        #expect(throws: CodecError.trailingBytes) {
            try Fixture.decode(bundle + Fixture.bigEndian(12) + message + [0, 0, 0, 0])
        }
        #expect(throws: CodecError.unrecognizedPacket) {
            try Fixture.decode(bundle + Fixture.bigEndian(4) + Fixture.ascii("abcd"))
        }
    }

    @Test func timeTagIsRawSixtyFourBitNTP() throws {
        let immediate = OpenSoundControl.TimeTag.immediate
        #expect(immediate.rawValue == 1)
        #expect(immediate.isImmediate)
        #expect(!OpenSoundControl.TimeTag(rawValue: 0).isImmediate)
        let tag = OpenSoundControl.TimeTag(seconds: 0x0102_0304, fraction: 0x0506_0708)
        #expect(tag.rawValue == 0x0102_0304_0506_0708)
        #expect(tag.seconds == 0x0102_0304 && tag.fraction == 0x0506_0708)
        let bytes = try Fixture.encode(Fixture.bundle([]))
        #expect(bytes == OpenSoundControl.bundleHeader + [0, 0, 0, 0, 0, 0, 0, 1])
        #expect(try Fixture.decode(bytes) == .bundle(OpenSoundControl.Bundle()))
        let argument = try Fixture.encode(Fixture.message("/t", [.timeTag(tag)]))
        #expect(Array(argument.suffix(8)) == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func encoderRefusesInvalidValues() {
        let nul = Fixture.message("/s", [.string("a\u{0}b")])
        #expect(throws: CodecError.stringContainsNul) { try Fixture.encode(nul) }
        let longAddress = Fixture.message("/abcdefgh")
        let short = Limits(maximumStringBytes: 8)
        #expect(throws: CodecError.invalidAddress(.tooLong(byteCount: 9, limit: 8))) {
            try Fixture.encode(longAddress, limits: short)
        }
        let complex = Fixture.message("/*?")
        #expect(throws: CodecError.invalidAddress(.tooComplex(complexity: 2, limit: 1))) {
            try Fixture.encode(complex, limits: Limits(maximumPatternComplexity: 1))
        }
    }

    // MARK: - Limits at N and N+1

    @Test func packetBytesLimit() throws {
        let packet = Fixture.message("/p", [.int32(1)])
        let bytes = try Fixture.encode(packet)
        let atLimit = Limits(maximumPacketBytes: bytes.count)
        let below = Limits(maximumPacketBytes: bytes.count - 1)
        #expect(try Fixture.encode(packet, limits: atLimit) == bytes)
        #expect(try Fixture.decode(bytes, limits: atLimit) == packet)
        #expect(throws: CodecError.packetTooLarge(byteCount: 12, limit: 11)) {
            try Fixture.encode(packet, limits: below)
        }
        #expect(throws: CodecError.packetTooLarge(byteCount: 12, limit: 11)) {
            try Fixture.decode(bytes, limits: below)
        }
    }

    @Test func argumentCountLimit() throws {
        let limits = Limits(maximumArguments: 3)
        let atLimit = Fixture.message("/n", [.true, .false, .nil])
        let over = Fixture.message("/n", [.true, .false, .nil, .impulse])
        #expect(try Fixture.decode(Fixture.encode(atLimit), limits: limits) == atLimit)
        #expect(try Fixture.encode(atLimit, limits: limits).count == 12)
        #expect(throws: CodecError.tooManyArguments(limit: 3)) { try Fixture.encode(over, limits: limits) }
        #expect(throws: CodecError.tooManyArguments(limit: 3)) {
            try Fixture.decode(Fixture.encode(over), limits: limits)
        }
    }

    @Test func bundleDepthLimit() throws {
        let limits = Limits(maximumBundleDepth: 3)
        let atLimit = Fixture.nested(depth: 3)
        let over = Fixture.nested(depth: 4)
        #expect(try Fixture.decode(Fixture.encode(atLimit, limits: limits), limits: limits) == atLimit)
        #expect(throws: CodecError.bundleTooDeep(limit: 3)) { try Fixture.encode(over, limits: limits) }
        #expect(throws: CodecError.bundleTooDeep(limit: 3)) { try Fixture.decode(Fixture.encode(over), limits: limits) }
        let flat = Limits(maximumBundleDepth: 0)
        #expect(try Fixture.decode(Fixture.encode(Fixture.message("/m")), limits: flat) == Fixture.message("/m"))
        #expect(throws: CodecError.bundleTooDeep(limit: 0)) {
            try Fixture.decode(Fixture.encode(Fixture.bundle([])), limits: flat)
        }
    }

    @Test func bundleElementLimitCountsEveryDepth() throws {
        let limits = Limits(maximumBundleElements: 3)
        let atLimit = Fixture.bundle([Fixture.bundle([Fixture.message("/a"), Fixture.message("/b")])])
        let pair = Fixture.bundle([Fixture.message("/a"), Fixture.message("/b")])
        let over = Fixture.bundle([pair, Fixture.message("/c")])
        #expect(try Fixture.decode(Fixture.encode(atLimit, limits: limits), limits: limits) == atLimit)
        #expect(throws: CodecError.tooManyElements(limit: 3)) { try Fixture.encode(over, limits: limits) }
        #expect(throws: CodecError.tooManyElements(limit: 3)) {
            try Fixture.decode(Fixture.encode(over), limits: limits)
        }
    }

    @Test func stringByteLimit() throws {
        let limits = Limits(maximumStringBytes: 4)
        let atLimit = Fixture.message("/abc", [.string("éxy")])
        let over = Fixture.message("/abc", [.string("abcde")])
        #expect(try Fixture.decode(Fixture.encode(atLimit, limits: limits), limits: limits) == atLimit)
        #expect(throws: CodecError.stringTooLong(limit: 4)) { try Fixture.encode(over, limits: limits) }
        #expect(throws: CodecError.stringTooLong(limit: 4)) { try Fixture.decode(Fixture.encode(over), limits: limits) }
        let longAddress = try Fixture.encode(Fixture.message("/abcd"))
        #expect(throws: CodecError.stringTooLong(limit: 4)) { try Fixture.decode(longAddress, limits: limits) }
        #expect(throws: CodecError.invalidAddress(.tooLong(byteCount: 5, limit: 4))) {
            try OpenSoundControl.AddressPattern("/abcd", limits: limits)
        }
    }

    @Test func blobByteLimit() throws {
        let limits = Limits(maximumBlobBytes: 5)
        let atLimit = Fixture.message("/b", [.blob([1, 2, 3, 4, 5])])
        let over = Fixture.message("/b", [.blob([1, 2, 3, 4, 5, 6])])
        #expect(try Fixture.decode(Fixture.encode(atLimit, limits: limits), limits: limits) == atLimit)
        #expect(throws: CodecError.blobTooLarge(byteCount: 6, limit: 5)) { try Fixture.encode(over, limits: limits) }
        #expect(throws: CodecError.blobTooLarge(byteCount: 6, limit: 5)) {
            try Fixture.decode(Fixture.encode(over), limits: limits)
        }
    }

    @Test func patternComplexityLimit() throws {
        let limits = Limits(maximumPatternComplexity: 4)
        let atLimit = try OpenSoundControl.AddressPattern("/*/[ab]{x,y}", limits: limits)
        #expect(atLimit.complexity == 4)
        #expect(throws: CodecError.invalidAddress(.tooComplex(complexity: 5, limit: 4))) {
            try OpenSoundControl.AddressPattern("/*/[ab]{x,y}?", limits: limits)
        }
        let over = try Fixture.encode(Fixture.message("/*/[ab]{x,y,z}"))
        #expect(throws: CodecError.invalidAddress(.tooComplex(complexity: 5, limit: 4))) {
            try Fixture.decode(over, limits: limits)
        }
        let packet = OpenSoundControl.Packet.message(.init(address: atLimit))
        #expect(try Fixture.decode(Fixture.encode(packet), limits: limits) == packet)
    }
    // MARK: - Addresses and patterns

    @Test func validatesAddresses() {
        for valid in ["/a", "/a/b", "/mixer/ch-1/fader_2.x~", "/!-"] {
            #expect((try? OpenSoundControl.Address(valid)) != nil, "\(valid)")
        }
        let refusals: [(String, OpenSoundControl.AddressRefusal)] = [
            ("", .missingLeadingSlash), ("a", .missingLeadingSlash), ("/", .emptyPart), ("//a", .emptyPart),
            ("/a/", .emptyPart), ("/a b", .invalidCharacter(0x20)), ("/a#b", .invalidCharacter(0x23)),
            ("/é", .invalidCharacter(0xC3)), ("/a\u{7F}", .invalidCharacter(0x7F)),
            ("/a*", .wildcardInAddress(0x2A)), ("/a?", .wildcardInAddress(0x3F)), ("/[a]", .wildcardInAddress(0x5B)),
            ("/{a}", .wildcardInAddress(0x7B)), ("/a,b", .wildcardInAddress(0x2C))
        ]
        for (string, refusal) in refusals {
            #expect(throws: CodecError.invalidAddress(refusal)) { try OpenSoundControl.Address(string) }
        }
    }

    @Test func validatesPatterns() {
        let refusals: [(String, OpenSoundControl.AddressRefusal)] = [
            ("/[a", .unbalancedBracket), ("/a]", .unbalancedBracket), ("/[a/b]", .unbalancedBracket),
            ("/[a[b]]", .unbalancedBracket), ("/{a", .unbalancedBrace), ("/a}", .unbalancedBrace),
            ("/{a,b/c}", .unbalancedBrace), ("/{a{b}}", .unbalancedBrace), ("/[]", .emptyGroup), ("/[!]", .emptyGroup),
            ("/{}", .emptyGroup), ("/[z-a]", .invalidRange), ("/a,b", .invalidCharacter(0x2C)),
            ("/[a,b]", .invalidCharacter(0x2C)), ("/{a*}", .invalidCharacter(0x2A)),
            ("/[a b]", .invalidCharacter(0x20))
        ]
        for (string, refusal) in refusals {
            #expect(throws: CodecError.invalidAddress(refusal)) { try OpenSoundControl.AddressPattern(string) }
        }
        #expect(Fixture.pattern("/a/b").complexity == 0 && !Fixture.pattern("/a/b").hasWildcards)
    }

    @Test(arguments: [
        ("/a/b", "/a/b", true), ("/a/b", "/a/bc", false), ("/a/*", "/a/xyz", true), ("/a/*", "/a/b/c", false),
        ("/*/*", "/a/b", true), ("/*", "/a/b", false), ("/a*c", "/abbbc", true), ("/a*c", "/ac", true),
        ("/a*c", "/abbb", false), ("/a?c", "/abc", true), ("/a?c", "/ac", false), ("/a?c", "/a/c", false),
        ("/[abc]x", "/bx", true), ("/[abc]x", "/dx", false), ("/[!abc]x", "/dx", true), ("/[!abc]x", "/ax", false),
        ("/[a-c]", "/b", true), ("/[a-c]", "/c", true), ("/[a-c]", "/d", false), ("/[!a-c]", "/d", true),
        ("/[!a-c]", "/b", false),
        ("/[a-]", "/-", true), ("/[-a]", "/-", true), ("/[a!]", "/!", true), ("/[a-]", "/b", false),
        ("/{foo,bar}/x", "/bar/x", true), ("/{foo,bar}/x", "/foo/x", true), ("/{foo,bar}/x", "/baz/x", false),
        ("/{foo,bar}", "/foobar", false), ("/{a,}b", "/b", true), ("/{a,}b", "/ab", true), ("/x*{1,2}", "/xab2", true),
        ("/x*{1,2}", "/xab3", false), ("/a-b!", "/a-b!", true)
    ])
    func matchesPatterns(pattern: String, address: String, expected: Bool) {
        #expect(Fixture.pattern(pattern).matches(Fixture.address(address)) == expected)
    }

    @Test func adversarialPatternWorkIsBounded() {
        let pattern = Fixture.pattern("/" + String(repeating: "*a", count: 31) + "b")
        let address = Fixture.address("/" + String(repeating: "a", count: 1_000))
        #expect(!pattern.matches(address))
        #expect(pattern.matches(Fixture.address("/" + String(repeating: "a", count: 31) + "b")))
    }
}

extension OpenSoundControlCodecTests {
    // MARK: - Review pins

    @Test func negatedSetNeverMatchesSlash() {
        #expect(!Fixture.pattern("/a[!b]c").matches(Fixture.address("/a/c")))
        #expect(Fixture.pattern("/a[!b]c").matches(Fixture.address("/axc")))
    }

    @Test func singleCharacterRangeIsValid() throws {
        let pattern = try OpenSoundControl.AddressPattern("/[a-a]")
        #expect(pattern.matches(Fixture.address("/a")))
        #expect(!pattern.matches(Fixture.address("/b")))
        #expect(!pattern.matches(Fixture.address("/-")))
    }

    @Test func stringsCompareByBytesNotCanonicalEquivalence() throws {
        let composed = "\u{E9}", decomposed = "e\u{301}"
        #expect(composed == decomposed)
        let nfc = OpenSoundControl.Argument.string(composed), nfd = OpenSoundControl.Argument.string(decomposed)
        #expect(nfc != nfd)
        #expect(Set([nfc, nfd]).count == 2)
        let nfcBytes = try Fixture.encode(Fixture.message("/s", [nfc]))
        let nfdBytes = try Fixture.encode(Fixture.message("/s", [nfd]))
        #expect(nfcBytes != nfdBytes)
        #expect(try Fixture.decode(nfdBytes) == Fixture.message("/s", [nfd]))
        #expect(try Fixture.decode(nfdBytes) != Fixture.message("/s", [nfc]))
    }

    @Test func distinguishesUnterminatedFromTooLong() {
        let limits = Limits(maximumStringBytes: 8)
        #expect(throws: CodecError.unterminatedString) {
            try Fixture.decode(Fixture.ascii("/abcdefg"), limits: limits)
        }
        #expect(throws: CodecError.stringTooLong(limit: 8)) {
            try Fixture.decode(Fixture.ascii("/abcdefghijk"), limits: limits)
        }
        #expect(throws: CodecError.unterminatedString) { try Fixture.decode(Fixture.ascii("/abc")) }
        let argument = Fixture.ascii("/s") + [0, 0] + Fixture.ascii(",s") + [0, 0]
        let small = Limits(maximumStringBytes: 4)
        #expect(throws: CodecError.unterminatedString) {
            try Fixture.decode(argument + Fixture.ascii("abcd"), limits: small)
        }
        #expect(throws: CodecError.stringTooLong(limit: 4)) {
            try Fixture.decode(argument + Fixture.ascii("abcdefgh"), limits: small)
        }
    }

    @Test func decodeMessageAcceptsOnlyOneCanonicalMessage() throws {
        let message = OpenSoundControl.Message(address: Fixture.pattern("/m"), arguments: [.int32(7), .string("x")])
        let bytes = try Fixture.encode(.message(message))
        #expect(try OpenSoundControl.Decoder().decodeMessage(bytes) == message)
        #expect(throws: CodecError.unrecognizedPacket) {
            try OpenSoundControl.Decoder().decodeMessage(Fixture.encode(Fixture.bundle([.message(message)])))
        }
        #expect(throws: CodecError.trailingBytes) { try OpenSoundControl.Decoder().decodeMessage(bytes + [0, 0, 0, 0]) }
        #expect(throws: CodecError.emptyPacket) { try OpenSoundControl.Decoder().decodeMessage([]) }
        #expect(throws: CodecError.tooManyArguments(limit: 1)) {
            try OpenSoundControl.Decoder(limits: Limits(maximumArguments: 1)).decodeMessage(bytes)
        }
    }

    @Test func nestedBundleWithEarlierTimeTagRoundTripsUnchanged() throws {
        let outer = OpenSoundControl.TimeTag(rawValue: 0x0000_0064_0000_0000)
        let inner = OpenSoundControl.TimeTag(rawValue: 0x0000_0032_8000_0000)
        let packet = Fixture.bundle(
            [Fixture.bundle([Fixture.message("/in")], timeTag: inner), Fixture.message("/after")], timeTag: outer
        )
        let bytes = try Fixture.encode(packet)
        #expect(Array(bytes[8..<16]) == Fixture.hex("00000064 00000000"))
        #expect(Array(bytes[28..<36]) == Fixture.hex("00000032 80000000"))
        let decoded = try Fixture.decode(bytes)
        #expect(decoded == packet)
        #expect(try Fixture.encode(decoded) == bytes)
        guard case .bundle(let top) = decoded, case .bundle(let first) = top.elements.first else {
            Issue.record("expected nested bundle first")
            return
        }
        #expect(top.timeTag == outer && first.timeTag == inner)
        #expect(top.elements.last == Fixture.message("/after"))
    }

    @Test func defaultElementLimitFitsConsoleSnapshot() throws {
        #expect(Limits.standard.maximumBundleElements == 1_024)
        let snapshot = Fixture.bundle((1...48).flatMap { channel in
            (1...6).map { Fixture.message("/ch/\(channel)/p\($0)", [.float32(Float($0))]) }
        })
        #expect(try Fixture.decode(Fixture.encode(snapshot)) == snapshot)
        let atLimit = Fixture.bundle(Array(repeating: Fixture.message("/a"), count: 1_024))
        let over = Fixture.bundle(Array(repeating: Fixture.message("/a"), count: 1_025))
        #expect(try Fixture.decode(Fixture.encode(atLimit)) == atLimit)
        #expect(throws: CodecError.tooManyElements(limit: 1_024)) { try Fixture.encode(over) }
        let overBytes = try Fixture.encode(over, limits: Limits(maximumBundleElements: 2_048))
        #expect(throws: CodecError.tooManyElements(limit: 1_024)) { try Fixture.decode(overBytes) }
    }
}
