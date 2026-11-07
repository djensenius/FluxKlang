import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension OSCTransportFixture {
    static let framings: [OSC.StreamFraming] = [.slip, .lengthPrefixed]

    /// A `/go` message holding one blob. With `count` 52 it encodes to exactly 64 bytes.
    static func blobMessage(_ count: Int) throws -> OSC.Message {
        OSC.Message(address: try OSC.AddressPattern("/go"), arguments: [.blob([UInt8](repeating: 0x5A, count: count))])
    }

    static func blobDatagram(_ count: Int) throws -> [UInt8] {
        try OSC.Encoder().encode(blobMessage(count))
    }

    /// One packet as a stream frame: END-delimited SLIP, or a four-byte big-endian length header.
    static func frame(_ packet: [UInt8], _ framing: OSC.StreamFraming) throws -> [UInt8] {
        try OSC.StreamFramer.frame(packet, framing: framing)
    }

    /// The bytes of `/go` messages 0 up to `count`, each framed and concatenated.
    static func frames(_ count: Int, _ framing: OSC.StreamFraming) throws -> [UInt8] {
        try (0..<count).flatMap { try frame(datagram(Int32($0)), framing) }
    }

    /// A stream pipeline whose packets are at most 64 bytes, so a chunk is at most 68 bytes.
    static func stream(
        _ framing: OSC.StreamFraming, packets: Int = 4, malformed: Int = 2
    ) throws -> OSC.IntakePipeline {
        try pipeline(.stream(framing), packets: packets, malformed: malformed, packetBytes: 64)
    }

    /// Every result of a chunk that was consumed, or nothing.
    static func results(_ outcome: OSC.ChunkOutcome) -> [OSC.IntakeResult] {
        if case .consumed(let results) = outcome { results } else { [] }
    }

    /// Offers `prefix` to a stream pipeline, then refuses three calls on it: a chunk above the size limit, a regressed
    /// tick and a datagram on the wrong transport. Each refusal must leave it equal to an untouched twin, and `rest`
    /// must then complete the same single frame, with the same result, on both.
    static func expectRefusalsLeaveFramerAlone(
        _ framing: OSC.StreamFraming, prefix: [UInt8], rest: [UInt8], yields expected: OSC.IntakeResult,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        var touched = try stream(framing)
        chunk(&touched, prefix, at: 1, sourceLocation: sourceLocation)
        var twin = touched
        let oversize = [UInt8](repeating: 0x41, count: 69)
        let tooBig = chunk(&touched, oversize, at: 2, sourceLocation: sourceLocation)
        let regressed = chunk(&touched, rest, at: 0, sourceLocation: sourceLocation)
        let wrong = receive(&touched, rest, at: 2, sourceLocation: sourceLocation)
        #expect(tooBig == .refused(.chunkTooLarge(byteCount: 69, limit: 68)), sourceLocation: sourceLocation)
        #expect(regressed == .refused(.tickRegressed(previous: 1, now: 0)), sourceLocation: sourceLocation)
        #expect(wrong == .failure(.wrongTransport(expected: .stream(framing))), sourceLocation: sourceLocation)
        #expect(touched == twin, sourceLocation: sourceLocation)
        let touchedDone = chunk(&touched, rest, at: 3, sourceLocation: sourceLocation)
        let twinDone = chunk(&twin, rest, at: 3, sourceLocation: sourceLocation)
        #expect(touchedDone == .consumed([expected]), sourceLocation: sourceLocation)
        #expect(twinDone == touchedDone && touched == twin, sourceLocation: sourceLocation)
    }
}

/// Datagram size and depth bounds, the immediate stage's refusals, and stream framing (#89, O2b).
extension OSCTransportTests {
    // MARK: Datagrams: size and depth

    @Test("A datagram of exactly the largest packet size is decoded; one byte more is malformed")
    func largestDatagramIsAcceptedAndOneMoreIsMalformed() throws {
        var pipeline = try Fixture.pipeline(bytes: 1 << 20, packetBytes: 65_536)
        let blob = try Fixture.blobMessage(32_744)
        let packet = Fixture.bundle(.immediate, [.message(blob), .message(blob)])
        let largest = try Fixture.encode(packet)
        #expect(largest.count == 65_536)
        #expect(Fixture.receive(&pipeline, largest, at: 0) == .success([[blob, blob]]))
        let oversize = Refusal.malformed(.packetTooLarge(byteCount: 65_537, limit: 65_536))
        #expect(Fixture.receive(&pipeline, largest + [0], at: 1) == .failure(oversize))
        let ledger = try Fixture.ledger(pipeline)
        #expect(ledger.packets == 2 && ledger.bytes == 131_073 && ledger.malformed == 1)
    }

    @Test("The policy's packet size, not the codec default, bounds a datagram")
    func policyPacketSizeBoundsDatagrams() throws {
        var pipeline = try Fixture.pipeline(packetBytes: 64)
        let largest = try Fixture.blobDatagram(52)
        #expect(largest.count == 64)
        #expect(Fixture.receive(&pipeline, largest, at: 0) == .success([[try Fixture.blobMessage(52)]]))
        for count in [65, 68] {
            let refusal = Refusal.malformed(.packetTooLarge(byteCount: count, limit: 64))
            #expect(Fixture.receive(&pipeline, [UInt8](repeating: 0, count: count), at: 1) == .failure(refusal))
        }
        #expect(try Fixture.ledger(pipeline).malformed == 2)
    }

    @Test("A bundle nested to the policy's depth is admitted; one level deeper is malformed")
    func bundleDepthAcceptsNAndRefusesNPlusOne() throws {
        for depth in [1, 3, 8] {
            var pipeline = try Fixture.pipeline(malformed: 1, depth: depth)
            let message = try Fixture.message(1)
            #expect(Fixture.receive(&pipeline, try Fixture.encode(Fixture.nested(depth), depth: depth + 1), at: 0)
                == .success([[message]]))
            let deeper = try Fixture.encode(Fixture.nested(depth + 1), depth: depth + 1)
            #expect(Fixture.receive(&pipeline, deeper, at: 1) == .failure(.malformed(.bundleTooDeep(limit: depth))))
            #expect(try Fixture.ledger(pipeline).malformed == 1)
        }
    }

    @Test("The deepest allowed policy admits depth 64 and refuses depth 65")
    func bundleDepthAtItsCeiling() throws {
        let ceiling = OSC.EndpointPolicy.bundleDepthLimit
        var pipeline = try Fixture.pipeline(bytes: 8_192, packetBytes: 4_096, depth: ceiling)
        let message = try Fixture.message(1)
        let deepest = try Fixture.encode(Fixture.nested(64), depth: 65)
        #expect(Fixture.receive(&pipeline, deepest, at: 0) == .success([[message]]))
        let tooDeep = try Fixture.encode(Fixture.nested(65), depth: 65)
        #expect(Fixture.receive(&pipeline, tooDeep, at: 0) == .failure(.malformed(.bundleTooDeep(limit: 64))))
    }

    // MARK: Datagrams: what the immediate stage refuses

    @Test("Scheduled, reserved, wildcard and unlisted content emits no messages and is charged, not a strike")
    func stageRefusalsEmitNothingAtomically() throws {
        let goPacket = OSC.Packet.message(try Fixture.message(1))
        let scheduled = OSC.TimeTag(seconds: 1, fraction: 2)
        let reserved = OSC.TimeTag(rawValue: 0)
        let cases: [(OSC.Packet, OSC.SchedulingRefusal)] = [
            (Fixture.bundle(scheduled, [goPacket]), .unsupportedScheduling(scheduled)),
            (Fixture.bundle(reserved, [goPacket]), .reservedTimeTag(reserved)),
            (.message(try Fixture.message(1, "/nope")), .disallowedAddress("/nope")),
            (.message(try Fixture.message(1, "/fx/9/on")), .disallowedAddress("/fx/9/on")),
            (.message(try Fixture.message(1, "/mixer/*/fader")), .wildcardAddress("/mixer/*/fader")),
            (.message(try Fixture.message(1, "/{go}")), .wildcardAddress("/{go}")),
            // The listed message in the same bundle is not dispatched when a sibling is refused.
            (
                Fixture.bundle(.immediate, [goPacket, .message(try Fixture.message(2, "/nope"))]),
                .disallowedAddress("/nope")
            ),
            (
                Fixture.bundle(.immediate, [goPacket, Fixture.bundle(scheduled, [goPacket])]),
                .unsupportedScheduling(scheduled)
            )
        ]
        for (index, (packet, refusal)) in cases.enumerated() {
            var pipeline = try Fixture.pipeline(packets: 8, malformed: 0)
            let bytes = try Fixture.encode(packet)
            #expect(Fixture.receive(&pipeline, bytes, at: 0) == .failure(.notAdmitted(refusal)), "case \(index)")
            let ledger = try Fixture.ledger(pipeline)
            #expect(ledger.packets == 1 && ledger.bytes == bytes.count && ledger.malformed == 0, "case \(index)")
            #expect(ledger.quarantinedAt == nil, "case \(index)")
        }
    }

    @Test("Listed patterns admit only matching literal addresses and inbound wildcards stay refused (Q-OSC-NS)")
    func allowListIsNeverWidened() throws {
        let policy = try Fixture.policy()
        #expect(policy.allowList == (try Fixture.allowList()))
        let cases: [(String, OSC.SchedulingRefusal?)] = [
            ("/go", nil), ("/mixer/3/fader", nil), ("/fx/2/on", nil), ("/fx/4/on", nil),
            ("/fx/5/on", .disallowedAddress("/fx/5/on")), ("/mixer/*/fader", .wildcardAddress("/mixer/*/fader")),
            ("/mixer/3/fader/x", .disallowedAddress("/mixer/3/fader/x")), ("/g", .disallowedAddress("/g"))
        ]
        for (address, refusal) in cases {
            var pipeline = try Fixture.pipeline()
            let expected: OSC.IntakeResult
            if let refusal {
                expected = .failure(.notAdmitted(refusal))
            } else {
                expected = try Fixture.accepted(1, address)
            }
            #expect(Fixture.receive(&pipeline, try Fixture.datagram(1, address), at: 0) == expected, "\(address)")
        }
    }

    // MARK: Streams: chunk size and charging

    @Test("A chunk of one maximum frame and its header is consumed; one byte more is refused, then splits fine",
          arguments: Fixture.framings)
    func chunkLimitIsTheFrameSizePlusItsHeader(_ framing: OSC.StreamFraming) throws {
        var pipeline = try Fixture.stream(framing)
        let message = try Fixture.blobMessage(52)
        let framed = try Fixture.frame(Fixture.blobDatagram(52), framing)
        // SLIP adds two ENDs (empty frames are ignored); the length header already made 68 bytes.
        let full = framing == .slip ? framed + [0xC0, 0xC0] : framed
        let over = framing == .slip ? full + [0xC0] : full + [0x00]
        #expect(full.count == 68 && over.count == 69)
        let refused = Fixture.chunk(&pipeline, over, at: 0)
        #expect(refused == .refused(.chunkTooLarge(byteCount: 69, limit: 68)))
        #expect(pipeline.peerCount == 0)
        #expect(Fixture.chunk(&pipeline, Array(over[..<34]), at: 0) == .consumed([]))
        #expect(Fixture.chunk(&pipeline, Array(over[34...]), at: 0) == .consumed([.success([[message]])]))
        var whole = try Fixture.stream(framing)
        #expect(Fixture.chunk(&whole, full, at: 0) == .consumed([.success([[message]])]))
    }

    @Test("A chunk charges its bytes once and each completed frame one packet", arguments: Fixture.framings)
    func chunkBytesAndFramePacketsAreChargedSeparately(_ framing: OSC.StreamFraming) throws {
        var pipeline = try Fixture.stream(framing)
        let bytes = try Fixture.frames(3, framing)
        let expected = try (0..<3).map { try Fixture.accepted(Int32($0)) }
        #expect(Fixture.chunk(&pipeline, bytes, at: 2) == .consumed(expected))
        let ledger = try Fixture.ledger(pipeline)
        #expect(ledger.packets == 3 && ledger.bytes == bytes.count && ledger.malformed == 0)
        #expect(bytes.count == (framing == .slip ? 42 : 48))
    }

    @Test("Frames after the packet allowance runs out mid-chunk are refused one by one and not charged",
          arguments: Fixture.framings)
    func midChunkPacketExhaustion(_ framing: OSC.StreamFraming) throws {
        var pipeline = try Fixture.stream(framing, packets: 2)
        let bytes = try Fixture.frames(4, framing)
        let exhausted = Refusal.packetBudgetExceeded(limit: 2, retryAfterTicks: 10)
        let expected = [try Fixture.accepted(0), try Fixture.accepted(1), .failure(exhausted), .failure(exhausted)]
        #expect(Fixture.chunk(&pipeline, bytes, at: 0) == .consumed(expected))
        let ledger = try Fixture.ledger(pipeline)
        #expect(ledger.packets == 2 && ledger.bytes == bytes.count && ledger.malformed == 0)
        // The next chunk is a gate refusal, uncharged; once the window rolls the stream continues.
        let next = try Fixture.frames(1, framing)
        #expect(Fixture.chunk(&pipeline, next, at: 1) == .refused(.packetBudgetExceeded(limit: 2, retryAfterTicks: 9)))
        #expect(Fixture.chunk(&pipeline, next, at: 10) == .consumed([try Fixture.accepted(0)]))
    }

    @Test("A frame that quarantines the peer mid-chunk makes the rest of the chunk refused, uncharged",
          arguments: Fixture.framings)
    func midChunkQuarantine(_ framing: OSC.StreamFraming) throws {
        var pipeline = try Fixture.stream(framing, malformed: 0)
        let bytes = try Fixture.frame(Fixture.garbage, framing) + Fixture.frames(2, framing)
        let jailed = Refusal.peerQuarantined(retryAfterTicks: 20)
        let garbage = Refusal.malformed(.unrecognizedPacket)
        let expected: [OSC.IntakeResult] = [.failure(garbage), .failure(jailed), .failure(jailed)]
        #expect(Fixture.chunk(&pipeline, bytes, at: 0) == .consumed(expected))
        let ledger = try Fixture.ledger(pipeline)
        #expect(ledger.packets == 1 && ledger.malformed == 1 && ledger.quarantinedAt == 0)
        #expect(Fixture.chunk(&pipeline, [0xC0], at: 5) == .refused(.peerQuarantined(retryAfterTicks: 15)))
        #expect(Fixture.chunk(&pipeline, [0xC0], at: 20) == .consumed([]))
    }

    @Test("An empty chunk is consumed and creates a peer entry with a fresh ledger", arguments: Fixture.framings)
    func emptyChunkCreatesAPeer(_ framing: OSC.StreamFraming) throws {
        var pipeline = try Fixture.stream(framing)
        #expect(Fixture.chunk(&pipeline, [], at: 4) == .consumed([]))
        #expect(pipeline.peerKeys == [Fixture.alpha] && pipeline.latestTick == 4)
        let ledger = try Fixture.ledger(pipeline)
        #expect(ledger == .fresh(at: 4) && pipeline.framerState(for: Fixture.alpha) == .ready)
    }

    // MARK: Streams: SLIP

    @Test("An invalid SLIP escape is one strike; an escaped END is already resynchronised")
    func slipInvalidEscapes() throws {
        var pipeline = try Fixture.stream(.slip, malformed: 8)
        #expect(Fixture.chunk(&pipeline, [0xC0, 0xDB, 0x00], at: 0)
            == .consumed([.failure(.malformed(.invalidSlipEscape(0x00)))]))
        #expect(pipeline.framerState(for: Fixture.alpha) == .discarding)
        #expect(Fixture.chunk(&pipeline, [0x41, 0x42], at: 0) == .consumed([]))
        #expect(pipeline.framerState(for: Fixture.alpha) == .discarding && pipeline.bufferedByteCount == 0)
        #expect(Fixture.chunk(&pipeline, [0xC0], at: 0) == .consumed([]))
        #expect(pipeline.framerState(for: Fixture.alpha) == .ready)
        #expect(Fixture.chunk(&pipeline, [0xDB, 0xC0], at: 0)
            == .consumed([.failure(.malformed(.invalidSlipEscape(0xC0)))]))
        #expect(pipeline.framerState(for: Fixture.alpha) == .ready)
        #expect(try Fixture.ledger(pipeline).malformed == 2)
    }

    @Test("A SLIP frame of 64 bytes is admitted and 65 is one strike that resynchronises at the next END")
    func slipFrameSizeBound() throws {
        var pipeline = try Fixture.stream(.slip)
        let message = try Fixture.blobMessage(52)
        #expect(Fixture.chunk(&pipeline, try Fixture.frame(Fixture.blobDatagram(52), .slip), at: 0)
            == .consumed([.success([[message]])]))
        let oversize: [UInt8] = [0xC0] + [UInt8](repeating: 0x41, count: 65) + [0xC0]
        let refusal = Refusal.malformed(.frameTooLarge(byteCount: 65, limit: 64))
        #expect(Fixture.chunk(&pipeline, oversize, at: 0) == .consumed([.failure(refusal)]))
        #expect(pipeline.framerState(for: Fixture.alpha) == .ready)
        #expect(try Fixture.ledger(pipeline).malformed == 1)
    }

    @Test("A long run of garbage without an END stays bounded, costs one strike, and resynchronises")
    func slipGarbageIsBoundedAndResynchronises() throws {
        var pipeline = try Fixture.stream(.slip)
        let junk = [UInt8](repeating: 0x41, count: 68)
        #expect(Fixture.chunk(&pipeline, junk, at: 3)
            == .consumed([.failure(.malformed(.frameTooLarge(byteCount: 65, limit: 64)))]))
        for _ in 0..<9 {
            #expect(Fixture.chunk(&pipeline, junk, at: 3) == .consumed([]))
            #expect(pipeline.bufferedByteCount == 0 && pipeline.framerState(for: Fixture.alpha) == .discarding)
        }
        let strikes = try Fixture.ledger(pipeline)
        #expect(strikes.malformed == 1 && strikes.bytes == 680 && strikes.packets == 0 && strikes.quarantinedAt == nil)
        let resync: [UInt8] = try [0xC0] + Fixture.frame(Fixture.datagram(5), .slip)
        #expect(Fixture.chunk(&pipeline, resync, at: 3) == .consumed([try Fixture.accepted(5)]))
        #expect(pipeline.framerState(for: Fixture.alpha) == .ready)
    }

    // MARK: Streams: length prefix

    @Test("A length-prefix failure is permanent for that stream, charged on every later chunk")
    func lengthPrefixFailureIsPermanent() throws {
        var pipeline = try Fixture.stream(.lengthPrefixed)
        let failed = Refusal.malformed(.framerFailed)
        #expect(Fixture.chunk(&pipeline, [0, 0, 0, 0], at: 0) == .consumed([.failure(.malformed(.emptyFrame))]))
        #expect(pipeline.framerState(for: Fixture.alpha) == .failed)
        // Even an empty chunk, and a perfectly valid frame, only report that the framer failed.
        #expect(Fixture.chunk(&pipeline, [], at: 1) == .consumed([.failure(failed)]))
        let valid = try Fixture.frames(1, .lengthPrefixed)
        #expect(Fixture.chunk(&pipeline, valid, at: 2) == .consumed([.failure(failed)]))
        #expect(try Fixture.ledger(pipeline).quarantinedAt == 2)
        // A released quarantine does not revive the stream; another peer is untouched.
        #expect(Fixture.chunk(&pipeline, [], at: 21) == .refused(.peerQuarantined(retryAfterTicks: 1)))
        #expect(Fixture.chunk(&pipeline, [], at: 22) == .consumed([.failure(failed)]))
        #expect(pipeline.framerState(for: Fixture.alpha) == .failed)
        let other = Fixture.chunk(&pipeline, try Fixture.frames(1, .lengthPrefixed), from: Fixture.bravo, at: 22)
        #expect(other == .consumed([try Fixture.accepted(0)]))
        #expect(pipeline.framerState(for: Fixture.bravo) == .ready)
    }

    @Test("A length header of 64 is admitted and 65 fails the stream; frames before it are still processed")
    func lengthPrefixSizeBound() throws {
        var pipeline = try Fixture.stream(.lengthPrefixed)
        let largest = try Fixture.frame(Fixture.blobDatagram(52), .lengthPrefixed)
        #expect(largest.prefix(4) == [0, 0, 0, 64])
        #expect(Fixture.chunk(&pipeline, largest, at: 0) == .consumed([.success([[try Fixture.blobMessage(52)]])]))
        let refusal = Refusal.malformed(.frameTooLarge(byteCount: 65, limit: 64))
        let bytes = try Fixture.frames(2, .lengthPrefixed) + [0, 0, 0, 65]
        #expect(Fixture.chunk(&pipeline, bytes, at: 0)
            == .consumed([try Fixture.accepted(0), try Fixture.accepted(1), .failure(refusal)]))
        #expect(pipeline.framerState(for: Fixture.alpha) == .failed && pipeline.bufferedByteCount == 0)
    }

    @Test("The most a stream holds is one frame body or a partial header, never above the buffered bound")
    func heldBytesReachTheirDocumentedMaximum() throws {
        var slip = try Fixture.stream(.slip)
        Fixture.chunk(&slip, [UInt8](repeating: 0x41, count: 64), at: 0)
        #expect(slip.bufferedByteCount == 64)
        Fixture.chunk(&slip, [0x41], at: 0)
        #expect(slip.bufferedByteCount == 0)
        var header = try Fixture.stream(.lengthPrefixed)
        Fixture.chunk(&header, [0, 0, 0], at: 0)
        #expect(header.bufferedByteCount == 3)
        Fixture.chunk(&header, [64], at: 0)
        #expect(header.bufferedByteCount == 0)
        Fixture.chunk(&header, [UInt8](repeating: 0x2F, count: 63), at: 0)
        #expect(header.bufferedByteCount == 63)
        let policy = try #require(header.endpoint.policy)
        #expect(policy.bufferedByteBound == 4 * 68)
        #expect(header.bufferedByteCount <= policy.bufferedByteBound)
    }

    // MARK: Streams: isolation and expiry

    @Test("Every peer has its own framer: interleaved halves of two frames never mix", arguments: Fixture.framings)
    func framersArePerPeer(_ framing: OSC.StreamFraming) throws {
        var pipeline = try Fixture.stream(framing)
        let first = try Fixture.frame(Fixture.datagram(1), framing)
        let second = try Fixture.frame(Fixture.datagram(2), framing)
        let cut = first.count / 2
        // SLIP does not hold its leading END; a length prefix does not hold its header.
        let held = framing == .slip ? cut - 1 : cut - 4
        #expect(Fixture.chunk(&pipeline, Array(first[..<cut]), from: Fixture.alpha, at: 0) == .consumed([]))
        #expect(Fixture.chunk(&pipeline, Array(second[..<cut]), from: Fixture.bravo, at: 0) == .consumed([]))
        #expect(pipeline.bufferedByteCount == 2 * held)
        #expect(Fixture.chunk(&pipeline, Array(second[cut...]), from: Fixture.bravo, at: 0)
            == .consumed([try Fixture.accepted(2)]))
        #expect(Fixture.chunk(&pipeline, Array(first[cut...]), from: Fixture.alpha, at: 0)
            == .consumed([try Fixture.accepted(1)]))
        #expect(pipeline.bufferedByteCount == 0)
    }

    @Test("Expiring a stream peer drops its framer and its partial frame, and a returning key starts fresh")
    func streamExpiryDropsTheFramer() throws {
        var pipeline = try Fixture.stream(.lengthPrefixed)
        Fixture.chunk(&pipeline, [0, 0, 0], at: 0)
        #expect(pipeline.bufferedByteCount == 3 && pipeline.framerState(for: Fixture.alpha) == .ready)
        #expect(Fixture.expire(&pipeline, at: 10) == .success([Fixture.alpha]))
        #expect(pipeline.bufferedByteCount == 0 && pipeline.framerState(for: Fixture.alpha) == nil)
        #expect(pipeline.peerCount == 0)
        #expect(Fixture.chunk(&pipeline, try Fixture.frames(1, .lengthPrefixed), at: 10)
            == .consumed([try Fixture.accepted(0)]))
    }

    @Test("A refused chunk is the same as one never sent")
    func refusedChunkEqualsAnUntouchedTwin() throws {
        var touched = try Fixture.stream(.slip)
        Fixture.chunk(&touched, [0xC0, 0x2F], at: 1)
        var twin = touched
        let oversize = [UInt8](repeating: 0, count: 69)
        #expect(Fixture.chunk(&touched, oversize, at: 2) == .refused(.chunkTooLarge(byteCount: 69, limit: 68)))
        #expect(Fixture.chunk(&touched, [0xC0], at: 0) == .refused(.tickRegressed(previous: 1, now: 0)))
        #expect(touched == twin)
        let rest: [UInt8] = try Array(Fixture.datagram(3).dropFirst()) + [0xC0]
        #expect(Fixture.chunk(&touched, rest, at: 3) == .consumed([try Fixture.accepted(3)]))
        #expect(Fixture.chunk(&twin, rest, at: 3) == .consumed([try Fixture.accepted(3)]))
        #expect(touched == twin)
    }

    @Test("A refused call never touches a length-prefix framer that holds its header but no body yet")
    func refusedCallsLeaveALengthPrefixFramerAlone() throws {
        let frame = try Fixture.frame(Fixture.datagram(3), .lengthPrefixed)
        #expect(frame.prefix(4) == [0, 0, 0, 12])
        // The framer has swallowed the header into a hidden expected length: it holds no byte at all.
        try Fixture.expectRefusalsLeaveFramerAlone(
            .lengthPrefixed, prefix: Array(frame.prefix(4)), rest: Array(frame.dropFirst(4)),
            yields: Fixture.accepted(3)
        )
    }

    @Test("A refused call never touches a SLIP framer that is waiting for the second byte of an escape")
    func refusedCallsLeaveAPendingSlipEscapeAlone() throws {
        // The int32 0x00C0DB01 holds the two bytes SLIP escapes, END (0xC0) and ESC (0xDB). The cut is just after
        // the first ESC, so the framer holds nine body bytes and a pending escape that nothing else can show.
        let prefix: [UInt8] = [0xC0, 0x2F, 0x67, 0x6F, 0x00, 0x2C, 0x69, 0x00, 0x00, 0x00, 0xDB]
        let rest: [UInt8] = [0xDC, 0xDB, 0xDD, 0x01, 0xC0]
        #expect(try Fixture.frame(Fixture.datagram(0x00C0_DB01), .slip) == prefix + rest)
        try Fixture.expectRefusalsLeaveFramerAlone(
            .slip, prefix: prefix, rest: rest, yields: Fixture.accepted(0x00C0_DB01)
        )
    }

    @Test("Two pipelines fed different bytes differ even when everything a caller can read agrees")
    func offeredBytesSeparateOtherwiseIdenticalPeers() throws {
        var longer = try Fixture.stream(.slip)
        Fixture.chunk(&longer, [0xC0, 0xC0, 0xC0], at: 0)
        // The window has rolled by now, so this chunk charges the same single byte as the one below.
        Fixture.chunk(&longer, [0xC0], at: 10)
        var shorter = try Fixture.stream(.slip)
        Fixture.chunk(&shorter, [0xC0], at: 10)
        #expect(try Fixture.ledger(longer) == Fixture.ledger(shorter))
        #expect(longer.framerState(for: Fixture.alpha) == shorter.framerState(for: Fixture.alpha))
        #expect(longer.bufferedByteCount == 0 && shorter.bufferedByteCount == 0)
        #expect(longer.latestTick == 10 && shorter.latestTick == 10 && longer.peerKeys == shorter.peerKeys)
        #expect(longer != shorter)
    }

    @Test("Length-prefix pipelines fed different bytes differ even when everything a caller can read agrees")
    func offeredBytesSeparateLengthPrefixPeers() throws {
        let frame = try Fixture.frames(1, .lengthPrefixed)
        var longer = try Fixture.stream(.lengthPrefixed)
        Fixture.chunk(&longer, frame, at: 0)
        // The window has rolled by now, so this chunk is charged exactly like the single one below.
        Fixture.chunk(&longer, frame, at: 10)
        var shorter = try Fixture.stream(.lengthPrefixed)
        Fixture.chunk(&shorter, frame, at: 10)
        #expect(try Fixture.ledger(longer) == Fixture.ledger(shorter))
        #expect(longer.framerState(for: Fixture.alpha) == shorter.framerState(for: Fixture.alpha))
        #expect(longer.bufferedByteCount == 0 && shorter.bufferedByteCount == 0)
        #expect(longer.latestTick == 10 && shorter.latestTick == 10 && longer.peerKeys == shorter.peerKeys)
        #expect(longer != shorter)
    }

    @Test("A stream allowance of exactly one chunk takes a full chunk per window, and a refusal's hint comes true")
    func fullChunkFitsTheSmallestStreamAllowance() throws {
        for framing in Fixture.framings {
            var pipeline = try Fixture.pipeline(.stream(framing), bytes: 68, packetBytes: 64)
            let framed = try Fixture.frame(Fixture.blobDatagram(52), framing)
            // A SLIP frame is two bytes short of a full chunk here; ignored empty frames fill it up.
            let padding: [UInt8] = framing == .slip ? [0xC0, 0xC0] : []
            let full = framed + padding
            #expect(full.count == 68)
            let done = OSC.ChunkOutcome.consumed([.success([[try Fixture.blobMessage(52)]])])
            #expect(Fixture.chunk(&pipeline, full, at: 0) == done)
            #expect(try Fixture.ledger(pipeline).bytes == 68)
            let first = Refusal.byteBudgetExceeded(limit: 68, retryAfterTicks: 9)
            let last = Refusal.byteBudgetExceeded(limit: 68, retryAfterTicks: 1)
            #expect(Fixture.chunk(&pipeline, full, at: 1) == .refused(first))
            #expect(Fixture.chunk(&pipeline, full, at: 9) == .refused(last))
            #expect(Fixture.chunk(&pipeline, full, at: 10) == done)
        }
    }
}
