import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum PeerWireTestSupport {
    static func generation(_ value: Int) -> Generation {
        do { return try Generation(value) } catch { preconditionFailure("invalid test generation \(value)") }
    }

    static func capability(_ raw: String) -> PeerCapability {
        guard let capability = PeerCapability(raw) else { preconditionFailure("invalid test capability \(raw)") }
        return capability
    }

    static func capabilities(_ raws: [String]) -> PeerCapabilitySet {
        guard let set = PeerCapabilitySet(raws.map(capability)) else { preconditionFailure("too many capabilities") }
        return set
    }

    static func message(
        _ kind: PeerFrameKind, epoch: Int? = nil, payload: [UInt8] = []
    ) -> PeerOutboundMessage {
        PeerOutboundMessage(kind: kind, connectionEpoch: epoch.map(generation), payload: payload)
    }

    /// Encodes `messages` as one stream with consecutive sequences from 1.
    static func stream(_ messages: [PeerOutboundMessage], limits: PeerFrameLimits = .standard) -> [UInt8] {
        var encoder = PeerFrameEncoder(limits: limits)
        return messages.flatMap { message in
            do { return try encoder.encode(message) } catch { preconditionFailure("encode failed: \(error)") }
        }
    }

    /// A header with arbitrary field values, for refusal cases.
    static func rawHeader(
        magic: [UInt8] = PeerWire.magic, version: UInt16 = 1, kind: UInt8 = 4, flags: UInt8 = 0,
        epoch: UInt64 = 0, sequence: UInt32 = 1, length: UInt32 = 0
    ) -> [UInt8] {
        var writer = PeerWireWriter()
        writer.append(magic)
        writer.append(version)
        writer.append(kind)
        writer.append(flags)
        writer.append(epoch)
        writer.append(sequence)
        writer.append(length)
        return writer.bytes
    }
}

extension PeerFrameDecoder {
    /// Test convenience: the delivered frames, or the delivery's failure.
    mutating func strictFeed(_ bytes: [UInt8]) throws(PeerWireError) -> [PeerFrame] {
        let delivery = feed(bytes)
        if let failure = delivery.failure { throw failure }
        return delivery.frames
    }
}

private typealias Support = PeerWireTestSupport

private let sampleMessages: [PeerOutboundMessage] = [
    Support.message(.hello, payload: [1, 2, 3]),
    Support.message(.control, epoch: 4, payload: []),
    Support.message(.control, epoch: Generation.maximumValue, payload: Array(repeating: 0xAB, count: 300)),
    Support.message(.close, epoch: 4)
]

private struct RefusalCase: Sendable, CustomTestStringConvertible {
    let name: String
    let bytes: [UInt8]
    let error: PeerWireError
    var testDescription: String { name }
}

private let refusalCases: [RefusalCase] = [
    .init(name: "bad magic", bytes: Support.rawHeader(magic: [0x46, 0x4B, 0x50, 0x58]), error: .badMagic),
    .init(name: "bad magic alone", bytes: [0x46, 0x4B, 0x50, 0x00], error: .badMagic),
    .init(name: "plain garbage", bytes: Array("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8), error: .badMagic),
    .init(name: "unknown layout version", bytes: Support.rawHeader(version: 2), error: .unsupportedFrameVersion(2)),
    .init(name: "layout version zero", bytes: Support.rawHeader(version: 0), error: .unsupportedFrameVersion(0)),
    .init(name: "unknown kind", bytes: Support.rawHeader(kind: 9), error: .unknownKind(9)),
    .init(name: "kind zero", bytes: Support.rawHeader(kind: 0), error: .unknownKind(0)),
    .init(name: "reserved flags", bytes: Support.rawHeader(flags: 0x80), error: .reservedFlags(0x80)),
    .init(name: "epoch beyond JSON-safe range", bytes: Support.rawHeader(epoch: 1 << 53),
          error: .invalidEpoch(1 << 53)),
    .init(name: "first sequence zero", bytes: Support.rawHeader(sequence: 0),
          error: .outOfOrder(expected: 1, found: 0)),
    .init(name: "first sequence skipped", bytes: Support.rawHeader(sequence: 2),
          error: .outOfOrder(expected: 1, found: 2)),
    .init(name: "oversized by one", bytes: Support.rawHeader(length: 16_385),
          error: .oversized(length: 16_385, limit: 16_384)),
    .init(name: "maximal length", bytes: Support.rawHeader(length: .max),
          error: .oversized(length: .max, limit: 16_384))
]

@Suite("PeerTransportTests")
struct PeerTransportTests {
    private func frames(_ messages: [PeerOutboundMessage]) -> [PeerFrame] {
        var decoder = PeerFrameDecoder()
        return decoder.feed(Support.stream(messages)).frames
    }

    @Test("Frames round-trip with consecutive sequences")
    func roundTrip() throws {
        var decoder = PeerFrameDecoder()
        let frames = try decoder.strictFeed(Support.stream(sampleMessages))
        #expect(frames.map(\.sequence) == [1, 2, 3, 4])
        #expect(frames.map(\.kind) == sampleMessages.map(\.kind))
        #expect(frames.map(\.connectionEpoch) == sampleMessages.map(\.connectionEpoch))
        #expect(frames.map(\.payload) == sampleMessages.map(\.payload))
        #expect(decoder.bufferedByteCount == 0)
        try decoder.finish()
    }

    @Test("Every split of a stream decodes identically", arguments: [1, 2, 7, 23, 24, 25, 331, 4_096])
    func splitDelivery(chunkSize: Int) throws {
        let bytes = Support.stream(sampleMessages)
        var decoder = PeerFrameDecoder()
        var frames: [PeerFrame] = []
        for start in stride(from: 0, to: bytes.count, by: chunkSize) {
            frames += try decoder.strictFeed(Array(bytes[start..<min(start + chunkSize, bytes.count)]))
            #expect(decoder.bufferedByteCount <= decoder.limits.maximumFrameBytes)
        }
        #expect(frames.map(\.payload) == sampleMessages.map(\.payload))
        #expect(frames.map(\.sequence) == [1, 2, 3, 4])
    }

    @Test("Payload bound is exact for encoder and decoder")
    func payloadBoundary() throws {
        let limits = try #require(PeerFrameLimits(maximumPayloadBytes: 1_024))
        let atLimit = Support.message(.control, epoch: 1, payload: Array(repeating: 1, count: 1_024))
        var decoder = PeerFrameDecoder(limits: limits)
        #expect(try decoder.strictFeed(Support.stream([atLimit], limits: limits)).first?.payload.count == 1_024)
        let overHeader = Support.rawHeader(epoch: 1, sequence: 2, length: 1_025)
        #expect(throws: PeerWireError.oversized(length: 1_025, limit: 1_024)) { try decoder.strictFeed(overHeader) }

        var encoder = PeerFrameEncoder(limits: limits)
        let over = Support.message(.control, epoch: 1, payload: Array(repeating: 1, count: 1_025))
        #expect(throws: PeerWireError.oversized(length: 1_025, limit: 1_024)) { try encoder.encode(over) }
        #expect(PeerFrameLimits(maximumPayloadBytes: 1_023) == nil)
        #expect(PeerFrameLimits(maximumPayloadBytes: PeerFrameLimits.payloadCeiling + 1) == nil)
    }

    @Test("Malformed headers are refused before any payload", arguments: refusalCases)
    fileprivate func refusesHeader(_ refusal: RefusalCase) {
        var decoder = PeerFrameDecoder()
        #expect(throws: refusal.error) { try decoder.strictFeed(refusal.bytes) }
        #expect(decoder.failure == refusal.error)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("A refused stream never yields another frame")
    func refusalLatches() {
        var decoder = PeerFrameDecoder()
        let valid = Support.stream([Support.message(.hello)])
        let garbage = [UInt8](repeating: 0, count: 4)
        #expect(decoder.feed(garbage + valid) == PeerFrameDelivery(frames: [], failure: .badMagic))
        #expect(decoder.bufferedByteCount == 0)
        #expect(decoder.feed(valid) == PeerFrameDelivery(frames: [], failure: .badMagic))
        #expect(throws: PeerWireError.badMagic) { try decoder.finish() }
    }

    @Test("Frames before a defect are delivered whatever the chunking")
    func deliveryBeforeDefectIsChunkingIndependent() {
        let valid = [Support.message(.hello, payload: [9]), Support.message(.control, epoch: 4)]
        let bytes = Support.stream(valid) + Support.rawHeader(magic: [0, 0, 0, 0], sequence: 3) + Support.stream(valid)
        let expected = Array(frames(valid))
        for chunkSize in 1...bytes.count {
            var decoder = PeerFrameDecoder()
            var delivered: [PeerFrame] = []
            var failure: PeerWireError?
            for start in stride(from: 0, to: bytes.count, by: chunkSize) where failure == nil {
                let delivery = decoder.feed(Array(bytes[start..<min(start + chunkSize, bytes.count)]))
                delivered += delivery.frames
                failure = delivery.failure
            }
            #expect(delivered == expected, "chunk size \(chunkSize)")
            #expect(failure == .badMagic, "chunk size \(chunkSize)")
            #expect(decoder.feed(Support.stream(valid)).frames.isEmpty)
        }
    }

    @Test("A max-size frame leaves no large storage for later tiny frames to retain")
    func payloadStorageIsNotRetained() throws {
        let maximum = PeerFrameLimits.standard.maximumPayloadBytes
        let large = Support.message(.control, epoch: 4, payload: Array(repeating: 0xAB, count: maximum))
        let tiny = (0..<64).map { Support.message(.control, epoch: 4, payload: [UInt8($0)]) }
        let bytes = Support.stream([large] + tiny)
        let split = PeerWire.headerByteCount + maximum
        var decoder = PeerFrameDecoder()
        #expect(try decoder.strictFeed(Array(bytes.prefix(split))).map(\.payload.count) == [maximum])
        #expect(decoder.bufferCapacity < 256)
        let later = try decoder.strictFeed(Array(bytes.dropFirst(split)))
        #expect(later.map(\.payload) == tiny.map(\.payload))
        #expect(later.allSatisfy { $0.payload.capacity < 256 })
        #expect(decoder.bufferCapacity < 256)
    }

    @Test("A zero-length frame ending at a chunk boundary completes at once")
    func zeroLengthAtChunkBoundary() throws {
        let bytes = Support.stream([
            Support.message(.close, epoch: 4), Support.message(.control, epoch: 4, payload: [7])
        ])
        var decoder = PeerFrameDecoder()
        let first = try decoder.strictFeed(Array(bytes.prefix(PeerWire.headerByteCount)))
        #expect(first.map(\.kind) == [.close])
        #expect(first.first?.payload.isEmpty == true)
        #expect(decoder.bufferedByteCount == 0)
        try decoder.finish()
        var resumed = PeerFrameDecoder()
        _ = try resumed.strictFeed(Array(bytes.prefix(PeerWire.headerByteCount)))
        #expect(try resumed.strictFeed(Array(bytes.dropFirst(PeerWire.headerByteCount))).map(\.payload) == [[7]])
    }

    @Test("Golden bytes pin the provisional v1 layout")
    func goldenBytes() {
        let hello = Support.capabilities(["control", "status"])
        let payload = PeerHello(versions: 1...1, offered: hello, required: .empty)?.encoded() ?? []
        let bytes = Support.stream([
            Support.message(.hello, payload: payload), Support.message(.control, epoch: 4, payload: [0xC0, 0xDE])
        ])
        let golden: [UInt8] = [
            0x46, 0x4B, 0x50, 0x57, 0x00, 0x01, 0x01, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x16,
            0x00, 0x01, 0x00, 0x01, 0x02, 0x07, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C,
            0x06, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x00, 0x00,
            0x46, 0x4B, 0x50, 0x57, 0x00, 0x01, 0x04, 0x00, 0, 0, 0, 0, 0, 0, 0, 0x04, 0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x02, 0xC0, 0xDE
        ]
        #expect(bytes == golden)
    }

    @Test("Repeated, reordered and replayed sequences are refused")
    func outOfOrder() throws {
        let first = Support.stream([Support.message(.hello)])
        var decoder = PeerFrameDecoder()
        _ = try decoder.strictFeed(first)
        #expect(throws: PeerWireError.outOfOrder(expected: 2, found: 1)) { try decoder.strictFeed(first) }

        let three = Support.stream([Support.message(.hello), Support.message(.hello), Support.message(.hello)])
        var reordered = PeerFrameDecoder()
        let frameBytes = PeerWire.headerByteCount
        let swapped = Array(three[0..<frameBytes] + three[(2 * frameBytes)...] + three[frameBytes..<(2 * frameBytes)])
        #expect(throws: PeerWireError.outOfOrder(expected: 2, found: 3)) { try reordered.strictFeed(swapped) }
    }

    @Test("End of stream at every interior offset of a two-frame stream")
    func truncatedEverywhere() throws {
        let messages = [Support.message(.hello, payload: [1, 2]), Support.message(.control, epoch: 1, payload: [3])]
        let bytes = Support.stream(messages)
        let boundary = PeerWire.headerByteCount + 2
        for offset in 1..<bytes.count {
            var decoder = PeerFrameDecoder()
            let delivered = try decoder.strictFeed(Array(bytes.prefix(offset)))
            #expect(delivered.count == (offset >= boundary ? 1 : 0), "offset \(offset)")
            let buffered = offset >= boundary ? offset - boundary : offset
            #expect(decoder.bufferedByteCount == buffered, "offset \(offset)")
            if buffered == 0 {
                try decoder.finish()
            } else {
                #expect(throws: PeerWireError.truncated(bufferedBytes: buffered)) { try decoder.finish() }
                let rest = Array(bytes.dropFirst(offset))
                let latched = PeerFrameDelivery(frames: [], failure: .truncated(bufferedBytes: buffered))
                #expect(decoder.feed(rest) == latched)
            }
        }
    }

    @Test("Hello payloads have one canonical encoding")
    func helloCanonical() throws {
        let offered = Support.capabilities(["status", "control.live", "telemetry"])
        let hello = try #require(PeerHello(
            versions: 1...3, offered: offered, required: Support.capabilities(["status"])
        ))
        #expect(try PeerHello.decode(hello.encoded()) == hello)
        #expect(offered.members.map(\.rawValue) == ["control.live", "status", "telemetry"])

        var unsorted = PeerWireWriter()
        unsorted.append(UInt16(1))
        unsorted.append(UInt16(1))
        unsorted.append(UInt8(2))
        for token in ["status", "control"] {
            unsorted.append(UInt8(token.utf8.count))
            unsorted.append(Array(token.utf8))
        }
        unsorted.append(UInt16(0))
        #expect(throws: PeerWireError.malformedPayload(.hello)) { try PeerHello.decode(unsorted.bytes) }
        #expect(throws: PeerWireError.malformedPayload(.hello)) { try PeerHello.decode(hello.encoded() + [0]) }
        let short = Array(hello.encoded().dropLast())
        #expect(throws: PeerWireError.malformedPayload(.hello)) { try PeerHello.decode(short) }
    }

    @Test("Hello declarations refuse invalid shapes", arguments: [
        [0, 1, 0, 1, 0, 0, 0, 0], [0, 0, 0, 1, 0, 0, 0], [0, 2, 0, 1, 0, 0, 0], [0, 1, 0, 1, 17],
        [0, 1, 0, 1, 1, 0, 0, 0],
        [0, 1, 0, 1, 1, 1, 0x41, 0, 0], [0, 1, 0, 1, 1, 1, 0x61, 0, 2], [0, 1, 0, 1, 0, 0x80, 0]
    ] as [[UInt8]])
    func helloRefusesShape(payload: [UInt8]) {
        #expect(throws: PeerWireError.malformedPayload(.hello)) { try PeerHello.decode(payload) }
    }

    @Test("Capability tokens and sets are bounded")
    func capabilityBounds() {
        #expect(PeerCapability("") == nil)
        #expect(PeerCapability("Control") == nil)
        #expect(PeerCapability("1control") == nil)
        for malformed in ["control.", "status-", "a..b", "a.-b", "a--b"] { #expect(PeerCapability(malformed) == nil) }
        for wellFormed in ["a", "a1", "a.b-c", "control.v2"] { #expect(PeerCapability(wellFormed) != nil) }
        #expect(PeerCapability.initialVocabulary.map(\.rawValue) == ["control", "status", "telemetry"])
        #expect(PeerCapability.initialVocabulary.allSatisfy { PeerCapability($0.rawValue) == $0 })
        #expect(PeerCapability(String(repeating: "a", count: 33)) == nil)
        #expect(PeerCapability(String(repeating: "a", count: 32)) != nil)
        let seventeen = (0..<17).map { Support.capability("cap\($0)") }
        #expect(PeerCapabilitySet(seventeen) == nil)
        #expect(PeerCapabilitySet(seventeen.dropLast())?.members.count == 16)
        #expect(PeerHello(versions: 0...1, offered: .empty, required: .empty) == nil)
        #expect(PeerHello(
            versions: 1...1, offered: .empty, required: Support.capabilities(["status"])
        ) == nil)
    }
}
