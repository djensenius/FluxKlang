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
