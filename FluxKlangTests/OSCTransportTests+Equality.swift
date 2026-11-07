import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Whole-value equality of stream pipelines and framers (#89, O2b). Every refusal is checked against a copy taken
/// before the call, so equality has to see everything a framer holds, not only what a caller can read: a decoded
/// length it is waiting for, a partial header, the buffered bytes and a pending SLIP escape.
extension OSCTransportFixture {
    /// Everything a caller can read from two pipelines agrees: the ledger, the held bytes, the framer state, the
    /// latest tick and the keys. What is left to tell them apart is what a framer holds inside.
    static func expectReadablyEqual(
        _ left: OSC.IntakePipeline, _ right: OSC.IntakePipeline, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(try ledger(left) == ledger(right), sourceLocation: sourceLocation)
        #expect(left.bufferedByteCount == right.bufferedByteCount, sourceLocation: sourceLocation)
        #expect(left.framerState(for: alpha) == right.framerState(for: alpha), sourceLocation: sourceLocation)
        #expect(left.latestTick == right.latestTick, sourceLocation: sourceLocation)
        #expect(left.peerKeys == right.peerKeys, sourceLocation: sourceLocation)
    }

    /// Two fresh stream pipelines on one policy, key and tick, offered `first` and `second`: chunks of one size that
    /// complete nothing. Everything a caller can read from the two then agrees, and so does the offered byte count.
    /// Only what a framer holds inside can tell them apart.
    static func readablyEqualPair(
        _ framing: OSC.StreamFraming, _ first: [UInt8], _ second: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (first: OSC.IntakePipeline, second: OSC.IntakePipeline) {
        #expect(first.count == second.count, sourceLocation: sourceLocation)
        var left = try stream(framing)
        var right = try stream(framing)
        let outcomes = [
            chunk(&left, first, at: 0, sourceLocation: sourceLocation),
            chunk(&right, second, at: 0, sourceLocation: sourceLocation)
        ]
        #expect(outcomes == [.consumed([]), .consumed([])], sourceLocation: sourceLocation)
        try expectReadablyEqual(left, right, sourceLocation: sourceLocation)
        return (left, right)
    }

    /// A fresh stream pipeline offered `wire` in chunks of at most `size` bytes, all at tick 0.
    static func fed(
        _ wire: [UInt8], inPiecesOf size: Int, _ framing: OSC.StreamFraming
    ) throws -> OSC.IntakePipeline {
        var pipeline = try stream(framing)
        for start in Swift.stride(from: 0, to: wire.count, by: size) {
            chunk(&pipeline, Array(wire[start..<Swift.min(start + size, wire.count)]), at: 0)
        }
        return pipeline
    }

    /// A framer (packet limit 64 unless `packetBytes` says otherwise) offered each of `pieces` in turn.
    static func framer(
        _ framing: OSC.StreamFraming, packetBytes: Int = 64, _ pieces: [UInt8]...
    ) -> OSC.StreamFramer {
        var result = OSC.StreamFramer(framing: framing, limits: OSC.Limits(maximumPacketBytes: packetBytes))
        for piece in pieces { _ = result.append(piece) }
        return result
    }

    /// Two framers and the one thing about them that `part` names.
    struct FramerPair: Sendable {
        let part: String
        let left: OSC.StreamFramer
        let right: OSC.StreamFramer
    }

    /// Framers that differ in exactly one stored part and hold the same number of bytes.
    static func separatedFramers() -> [FramerPair] {
        let slip = OSC.StreamFraming.slip
        let prefixed = OSC.StreamFraming.lengthPrefixed
        return [
            FramerPair(part: "framing", left: framer(slip), right: framer(prefixed)),
            FramerPair(part: "packet limit", left: framer(slip), right: framer(slip, packetBytes: 65)),
            FramerPair(part: "state", left: framer(slip, [0xC0, 0xDB, 0x00]), right: framer(slip, [0xC0, 0xDB, 0xC0])),
            FramerPair(part: "buffered bytes", left: framer(slip, [0xC0, 0x41]), right: framer(slip, [0xC0, 0x42])),
            FramerPair(part: "pending escape", left: framer(slip, [0xC0, 0xDB]), right: framer(slip, [0xC0, 0xC0])),
            FramerPair(part: "partial header", left: framer(prefixed, [0, 0]), right: framer(prefixed, [0, 1])),
            FramerPair(
                part: "expected length", left: framer(prefixed, [0, 0, 0, 12]), right: framer(prefixed, [0, 0, 0, 16])
            ),
            FramerPair(part: "expected length or none", left: framer(prefixed, [0, 0, 0, 12]), right: framer(prefixed))
        ]
    }

    /// Framers reached by different routes that hold the same state.
    static func sameStateFramers() -> [FramerPair] {
        let slip = OSC.StreamFraming.slip
        let prefixed = OSC.StreamFraming.lengthPrefixed
        return [
            FramerPair(part: "a leading END", left: framer(slip, [0xC0, 0x41]), right: framer(slip, [0x41])),
            FramerPair(part: "a finished SLIP frame", left: framer(slip, [0xC0, 0x41, 0xC0]), right: framer(slip)),
            FramerPair(part: "a resynchronised escape", left: framer(slip, [0xC0, 0xDB, 0xC0]), right: framer(slip)),
            FramerPair(
                part: "a finished length-prefix frame", left: framer(prefixed, [0, 0, 0, 1, 0x41]),
                right: framer(prefixed)
            ),
            FramerPair(
                part: "one chunk or two", left: framer(prefixed, [0, 0, 0, 12, 0x2F]),
                right: framer(prefixed, [0, 0, 0], [12, 0x2F])
            )
        ]
    }
}

/// Pipelines and framers that only their hidden state tells apart (#89, O2b).
extension OSCTransportTests {
    // MARK: Pipelines

    @Test("Length-prefix pipelines waiting for 12 and for 16 body bytes are not equal, and only one completes a frame")
    func expectedLengthSeparatesLengthPrefixPipelines() throws {
        // Each has swallowed its header into a hidden expected length and holds no byte at all.
        var (twelve, sixteen) = try Fixture.readablyEqualPair(.lengthPrefixed, [0, 0, 0, 12], [0, 0, 0, 16])
        let ledger = try Fixture.ledger(twelve)
        #expect(ledger.bytes == 4 && ledger.packets == 0 && ledger.malformed == 0)
        #expect(twelve.bufferedByteCount == 0 && twelve.framerState(for: Fixture.alpha) == .ready)
        #expect(twelve != sixteen)
        // The same twelve bytes, one whole `/go` packet, finish the first frame and only begin the second.
        let body = try Fixture.datagram(3)
        #expect(body.count == 12)
        #expect(Fixture.chunk(&twelve, body, at: 1) == .consumed([try Fixture.accepted(3)]))
        #expect(Fixture.chunk(&sixteen, body, at: 1) == .consumed([]))
        #expect(twelve.bufferedByteCount == 0 && sixteen.bufferedByteCount == 12)
    }

    @Test("Length-prefix pipelines holding different partial headers are not equal, and the same bytes split them")
    func partialHeaderSeparatesLengthPrefixPipelines() throws {
        var (zero, one) = try Fixture.readablyEqualPair(.lengthPrefixed, [0, 0], [0, 1])
        #expect(zero.bufferedByteCount == 2 && zero.framerState(for: Fixture.alpha) == .ready)
        #expect(zero != one)
        // The same next bytes complete a header of 12 on the first and one of 65 548 on the second.
        let rest: [UInt8] = try [0, 12] + Fixture.datagram(3)
        #expect(Fixture.chunk(&zero, rest, at: 1) == .consumed([try Fixture.accepted(3)]))
        let refusal = Refusal.malformed(.frameTooLarge(byteCount: 65_548, limit: 64))
        #expect(Fixture.chunk(&one, rest, at: 1) == .consumed([.failure(refusal)]))
        #expect(one.framerState(for: Fixture.alpha) == .failed && one.bufferedByteCount == 0)
    }

    @Test("SLIP pipelines holding different bytes of one count are not equal, and the same bytes split them")
    func bufferedContentSeparatesSlipPipelines() throws {
        // Both hold two bytes of an address after the opening END: "/g" on the first and "/h" on the second.
        var (listed, unlisted) = try Fixture.readablyEqualPair(.slip, [0xC0, 0x2F, 0x67], [0xC0, 0x2F, 0x68])
        #expect(listed.bufferedByteCount == 2 && listed.framerState(for: Fixture.alpha) == .ready)
        #expect(listed != unlisted)
        // The rest of one `/go` packet completes "/go" on the first and "/ho", which is not listed, on the second.
        let rest: [UInt8] = try Array(Fixture.datagram(3).dropFirst(2)) + [0xC0]
        #expect(Fixture.chunk(&listed, rest, at: 1) == .consumed([try Fixture.accepted(3)]))
        let refusal = Refusal.notAdmitted(.disallowedAddress("/ho"))
        #expect(Fixture.chunk(&unlisted, rest, at: 1) == .consumed([.failure(refusal)]))
    }

    @Test("A SLIP pipeline waiting for the byte after an ESC is not equal to one holding the same bytes without it")
    func pendingEscapeSeparatesSlipPipelines() throws {
        // Eleven bytes offered and nine held by each. Only the first ends on an ESC that the byte count cannot show.
        let pending: [UInt8] = [0xC0, 0x2F, 0x67, 0x6F, 0x00, 0x2C, 0x69, 0x00, 0x00, 0x00, 0xDB]
        let settled: [UInt8] = [0xC0, 0xC0, 0x2F, 0x67, 0x6F, 0x00, 0x2C, 0x69, 0x00, 0x00, 0x00]
        var (waiting, plain) = try Fixture.readablyEqualPair(.slip, pending, settled)
        #expect(waiting.bufferedByteCount == 9 && waiting.framerState(for: Fixture.alpha) == .ready)
        #expect(try Fixture.ledger(waiting).bytes == 11)
        #expect(waiting != plain)
        // The same five bytes read DC as an escaped END after the ESC (0x00C0DB01) and as a plain byte without it.
        let rest: [UInt8] = [0xDC, 0xDB, 0xDD, 0x01, 0xC0]
        #expect(Fixture.chunk(&waiting, rest, at: 1) == .consumed([try Fixture.accepted(0x00C0_DB01)]))
        #expect(Fixture.chunk(&plain, rest, at: 1) == .consumed([try Fixture.accepted(0x00DC_DB01)]))
    }

    @Test("Pipelines fed one stream in any pieces are equal and hash alike; one changed held byte tells them apart",
          arguments: Fixture.framings)
    func equalFeedsGiveEqualPipelinesAndHashes(_ framing: OSC.StreamFraming) throws {
        // Two whole frames, then the start of a third: after a SLIP END seven body bytes, or a header and six.
        let held = framing == .slip ? 7 : 6
        let third = try Fixture.frame(Fixture.datagram(2), framing).prefix(framing == .slip ? 8 : 10)
        let wire: [UInt8] = try Fixture.frames(2, framing) + third
        let pipelines = try [wire.count, 1, 5, wire.count / 2].map { try Fixture.fed(wire, inPiecesOf: $0, framing) }
        let whole = try #require(pipelines.first)
        let ledger = try Fixture.ledger(whole)
        #expect(ledger.packets == 2 && ledger.bytes == wire.count && ledger.malformed == 0)
        #expect(whole.bufferedByteCount == held)
        for other in pipelines {
            #expect(other == whole)
            #expect(other.hashValue == whole.hashValue)
        }
        #expect(Set(pipelines).count == 1)
        // The same stream with its last held byte changed, offered in pieces of five like one of the pipelines above.
        var changed = wire
        changed[changed.count - 1] ^= 1
        let edited = try Fixture.fed(changed, inPiecesOf: 5, framing)
        // The same number of bytes went in, so the offered counts agree, and everything a caller can read agrees:
        // the ledger (packets 2, bytes `wire.count`), the held count, the state, the tick and the keys. The one
        // buffered byte is all that is left to tell the two pipelines apart.
        try Fixture.expectReadablyEqual(edited, whole)
        #expect(edited != whole)
    }

    // MARK: Framers

    @Test("Framers are equal exactly when every part of their state is, and equal framers hash alike")
    func framerEqualityCoversEveryPartOfItsState() {
        for pair in Fixture.separatedFramers() {
            #expect(pair.left != pair.right, "\(pair.part) must tell two framers apart")
            #expect(pair.left.bufferedByteCount == pair.right.bufferedByteCount, "\(pair.part) changes the held count")
        }
        let states = Fixture.separatedFramers().filter { $0.part == "state" }.map { [$0.left.state, $0.right.state] }
        #expect(states == [[.discarding, .ready]])
        for pair in Fixture.sameStateFramers() {
            #expect(pair.left == pair.right, "\(pair.part) leaves the same state")
            #expect(pair.left.hashValue == pair.right.hashValue, "\(pair.part) must hash alike")
        }
    }
}

/// Allow-list entries beyond the codec limits (#89, O2b). `AllowList` checks only its entry count, and an
/// `AddressPattern` can be built under raised limits, so a policy holds every entry to the codec's string and
/// complexity limits itself. Each oversized pattern below is built under `raisedLimits`, so it exists before the
/// policy sees it, and its size is asserted, so that no test can pass vacuously.
extension OSCTransportFixture {
    /// Limits far above the standard ones (1,024 string bytes and 32 wildcard constructs).
    static let raisedLimits = OSC.Limits(maximumStringBytes: 200_000, maximumPatternComplexity: 200_000)

    /// The three ways an endpoint can receive: datagrams, SLIP frames and length-prefixed frames.
    static let transports: [OSC.EndpointTransport] = [.datagram, .stream(.slip), .stream(.lengthPrefixed)]

    /// A pattern built under `raisedLimits`.
    static func raised(_ text: String) throws -> OSC.AddressPattern {
        try OSC.AddressPattern(text, limits: raisedLimits)
    }

    /// A literal address of exactly `count` bytes: a slash and `count - 1` letters.
    static func literal(bytes count: Int) -> String { "/" + String(repeating: "a", count: count - 1) }

    /// A pattern of a slash and `count` stars: `count` wildcard constructs in `count + 1` bytes.
    static func wildcards(_ count: Int) -> String { "/" + String(repeating: "*", count: count) }

    /// A policy over `entries`. Its byte allowance holds a whole stream chunk. Throws what the list or the policy
    /// refuses.
    static func policy(
        allowing entries: [OSC.AddressPattern], on transport: OSC.EndpointTransport = .datagram,
        budget: OSC.IntakeBudget? = nil, idle: UInt64 = 10, packetBytes: Int = 1_024, depth: Int = 8
    ) throws -> OSC.EndpointPolicy {
        try OSC.EndpointPolicy(
            transport: transport, allowList: OSC.AllowList(entries), budget: budget ?? Self.budget(bytes: 2_048),
            maximumPeers: 4, idleTicks: idle, maximumPacketBytes: packetBytes, maximumBundleDepth: depth
        )
    }
}

/// A policy refuses an allow-list entry beyond the codec limits, and names the first one by its index.
extension OSCTransportTests {
    // MARK: Allow-list entries against the codec limits

    @Test("An allow-list entry of exactly the string limit is accepted and one byte more is refused, by index")
    func entryByteCountIsBoundedByTheStringLimit() throws {
        let known = try Fixture.raised("/go")
        let widest = try Fixture.raised(Fixture.literal(bytes: 1_024))
        let over = try Fixture.raised(Fixture.literal(bytes: 1_025))
        #expect(widest.bytes.count == 1_024 && widest.complexity == 0)
        #expect(over.bytes.count == 1_025 && over.complexity == 0)
        // The standard limits refuse the larger pattern; only the raised ones let it exist.
        #expect(throws: OSC.CodecError.invalidAddress(.tooLong(byteCount: 1_025, limit: 1_024))) {
            try OSC.AddressPattern(Fixture.literal(bytes: 1_025))
        }
        let accepted = try Fixture.policy(allowing: [known, widest])
        #expect(accepted.allowList.entries == [known, widest] && accepted.limits.maximumStringBytes == 1_024)
        #expect(throws: Config.allowListEntryExceedsCodecLimits(index: 1)) {
            try Fixture.policy(allowing: [known, over])
        }
        #expect(throws: Config.allowListEntryExceedsCodecLimits(index: 0)) { try Fixture.policy(allowing: [over]) }
        // The bound is the codec's string limit, which a smaller packet size does not lower: the same two lists on
        // 64 byte packets. The wide entry could never match an address of such a packet, and holding it is harmless.
        let small = try Fixture.policy(allowing: [known, widest], packetBytes: 64)
        #expect(small.maximumPacketBytes == 64 && small.allowList.entries == [known, widest])
        #expect(throws: Config.allowListEntryExceedsCodecLimits(index: 1)) {
            try Fixture.policy(allowing: [known, over], packetBytes: 64)
        }
    }

    @Test("An allow-list entry of exactly 32 wildcard constructs is accepted and 33 are refused, by index")
    func entryComplexityIsBoundedByThePatternLimit() throws {
        let known = try Fixture.raised("/go")
        let busiest = try Fixture.raised(Fixture.wildcards(32))
        let over = try Fixture.raised(Fixture.wildcards(33))
        // A few bytes each, so the complexity alone can be the reason.
        #expect(busiest.complexity == 32 && busiest.bytes.count == 33)
        #expect(over.complexity == 33 && over.bytes.count == 34)
        #expect(throws: OSC.CodecError.invalidAddress(.tooComplex(complexity: 33, limit: 32))) {
            try OSC.AddressPattern(Fixture.wildcards(33))
        }
        let accepted = try Fixture.policy(allowing: [known, busiest])
        #expect(accepted.allowList.entries == [known, busiest] && accepted.limits.maximumPatternComplexity == 32)
        #expect(throws: Config.allowListEntryExceedsCodecLimits(index: 1)) {
            try Fixture.policy(allowing: [known, over])
        }
        #expect(throws: Config.allowListEntryExceedsCodecLimits(index: 0)) { try Fixture.policy(allowing: [over]) }
    }

    @Test("An allow-list entry of a slash and 100 000 stars is refused, though the allow-list itself accepts it")
    func aWildcardFloodEntryIsRefusedAtConstruction() throws {
        // The review's example: matching it would walk 100 001 tokens for every message of every packet.
        let flood = try Fixture.raised(Fixture.wildcards(100_000))
        #expect(flood.bytes.count == 100_001 && flood.complexity == 100_000)
        #expect(throws: OSC.CodecError.invalidAddress(.tooLong(byteCount: 100_001, limit: 1_024))) {
            try OSC.AddressPattern(Fixture.wildcards(100_000))
        }
        // `AllowList` checks only how many entries it holds, so it keeps the flood without complaint.
        #expect(try OSC.AllowList([flood]).entries == [flood])
        #expect(throws: Config.allowListEntryExceedsCodecLimits(index: 0)) { try Fixture.policy(allowing: [flood]) }
        let known = try Fixture.raised("/go")
        #expect(throws: Config.allowListEntryExceedsCodecLimits(index: 1)) {
            try Fixture.policy(allowing: [known, flood], on: .stream(.slip))
        }
    }

    @Test("The first allow-list entry beyond a limit is reported, and 256 entries at the limits are accepted")
    func firstOffendingEntryIsReported() throws {
        let known = try Fixture.raised("/go")
        let widest = try Fixture.raised(Fixture.literal(bytes: 1_024))
        let busiest = try Fixture.raised(Fixture.wildcards(32))
        let long = try Fixture.raised(Fixture.literal(bytes: 1_025))
        let busy = try Fixture.raised(Fixture.wildcards(33))
        // Either reason counts, and the earlier of two offenders wins whichever way round they come.
        let second = Config.allowListEntryExceedsCodecLimits(index: 1)
        #expect(throws: second) { try Fixture.policy(allowing: [known, long, busy]) }
        #expect(throws: second) { try Fixture.policy(allowing: [known, busy, long]) }
        #expect(throws: Config.allowListEntryExceedsCodecLimits(index: 2)) {
            try Fixture.policy(allowing: [known, widest, busy, long])
        }
        // The longest list, every entry at a limit, is accepted; a bad entry at its very end is still found.
        let full = (0..<OSC.AllowList.maximumEntries).map { $0.isMultiple(of: 2) ? widest : busiest }
        let accepted = try Fixture.policy(allowing: full)
        #expect(accepted.allowList.entries.count == 256 && accepted.allowList.entries == full)
        let flawed = Array(full.dropLast()) + [long]
        #expect(flawed.count == 256)
        #expect(throws: Config.allowListEntryExceedsCodecLimits(index: 255)) { try Fixture.policy(allowing: flawed) }
    }

    @Test("Datagram, SLIP and length-prefix endpoints hold an allow-list to the same codec limits",
          arguments: Fixture.transports)
    func bothTransportsCheckTheAllowList(_ transport: OSC.EndpointTransport) throws {
        let known = try Fixture.raised("/go")
        let widest = try Fixture.raised(Fixture.literal(bytes: 1_024))
        let busiest = try Fixture.raised(Fixture.wildcards(32))
        let accepted = try Fixture.policy(allowing: [known, widest, busiest], on: transport)
        #expect(accepted.transport == transport && accepted.allowList.entries == [known, widest, busiest])
        let long = try Fixture.raised(Fixture.literal(bytes: 1_025))
        let busy = try Fixture.raised(Fixture.wildcards(33))
        #expect(throws: Config.allowListEntryExceedsCodecLimits(index: 2)) {
            try Fixture.policy(allowing: [known, widest, long], on: transport)
        }
        #expect(throws: Config.allowListEntryExceedsCodecLimits(index: 1)) {
            try Fixture.policy(allowing: [known, busy, busiest], on: transport)
        }
    }

    @Test("A bad allow-list entry is reported after the knob checks and before the budget and idle checks")
    func entryCheckHasItsPlaceInTheValidationOrder() throws {
        let known = try Fixture.raised("/go")
        let over = try Fixture.raised(Fixture.literal(bytes: 1_025))
        let badEntry = Config.allowListEntryExceedsCodecLimits(index: 1)
        // Before it: a bad knob is reported even when the list is bad too.
        #expect(throws: Config.invalidCount(.bundleDepth, 0)) {
            try Fixture.policy(allowing: [known, over], depth: 0)
        }
        // After it: each rule is reported for a good list, but not for a bad one.
        let small = try Fixture.budget(bytes: 8)
        #expect(throws: badEntry) { try Fixture.policy(allowing: [known, over], budget: small) }
        #expect(throws: Config.budgetCannotFitPacket(maximumBytes: 8, maximumPacketBytes: 1_024)) {
            try Fixture.policy(allowing: [known], budget: small)
        }
        let tight = try Fixture.budget(bytes: 1_024)
        #expect(throws: badEntry) { try Fixture.policy(allowing: [known, over], on: .stream(.slip), budget: tight) }
        #expect(throws: Config.budgetCannotFitChunk(maximumBytes: 1_024, maximumChunkBytes: 1_028)) {
            try Fixture.policy(allowing: [known], on: .stream(.slip), budget: tight)
        }
        #expect(throws: badEntry) { try Fixture.policy(allowing: [known, over], idle: 5) }
        #expect(throws: Config.idleBeforeWindowEnds(idleTicks: 5, windowTicks: 10)) {
            try Fixture.policy(allowing: [known], idle: 5)
        }
    }
}
