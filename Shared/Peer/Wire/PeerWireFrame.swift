//
//  PeerWireFrame.swift
//  FluxKlang
//
//  Provisional v1 peer frame layout (#93). Every frame is a fixed 24-byte
//  big-endian header followed by a bounded payload:
//
//    magic "FKPW" (4) | layout version (2) | kind (1) | flags (1)
//    connection epoch (8, 0 = none) | sequence (4) | payload length (4)
//
//  Framing is structure only. A decoded frame is never an authorization;
//  pairing/trust is #94 and command freshness/authority is #95/#62.
//

import Foundation

enum PeerWire {
    static let magic: [UInt8] = [0x46, 0x4B, 0x50, 0x57]
    static let frameLayoutVersion: UInt16 = 1
    static let headerByteCount = 24
    /// Protocol versions this build can negotiate in a hello.
    static let supportedProtocolVersions: ClosedRange<UInt16> = 1...1
}

/// Why bytes could not become a frame. Every case is terminal for the stream.
enum PeerWireError: Error, Hashable, Sendable {
    case badMagic
    case unsupportedFrameVersion(UInt16)
    case unknownKind(UInt8)
    case reservedFlags(UInt8)
    case oversized(length: UInt32, limit: Int)
    case outOfOrder(expected: UInt32, found: UInt32)
    case invalidEpoch(UInt64)
    /// The stream ended inside a frame.
    case truncated(bufferedBytes: Int)
    case malformedPayload(PeerFrameKind)
    case sequenceExhausted
}

enum PeerFrameKind: UInt8, Hashable, Sendable, CaseIterable {
    case hello = 1
    case helloAccept = 2
    case helloReject = 3
    /// Opaque control payload for #95; admitted only after negotiation.
    case control = 4
    case close = 5
}

/// Explicit per-connection payload bound. The decoder never buffers more than
/// `PeerWire.headerByteCount + maximumPayloadBytes` bytes.
struct PeerFrameLimits: Hashable, Sendable {
    /// Large enough for the largest hello or accept payload.
    static let minimumPayloadBytes = 1_024
    static let payloadCeiling = 1 << 20
    static let standard = PeerFrameLimits(uncheckedMaximumPayloadBytes: 16_384)

    let maximumPayloadBytes: Int

    var maximumFrameBytes: Int { PeerWire.headerByteCount + maximumPayloadBytes }

    init?(maximumPayloadBytes: Int) {
        guard (Self.minimumPayloadBytes...Self.payloadCeiling).contains(maximumPayloadBytes) else { return nil }
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    private init(uncheckedMaximumPayloadBytes: Int) {
        maximumPayloadBytes = uncheckedMaximumPayloadBytes
    }
}

struct PeerFrame: Hashable, Sendable {
    let kind: PeerFrameKind
    let sequence: UInt32
    let connectionEpoch: Generation?
    let payload: [UInt8]
}

/// A frame the session wants sent; the encoder assigns its sequence.
struct PeerOutboundMessage: Hashable, Sendable {
    let kind: PeerFrameKind
    let connectionEpoch: Generation?
    let payload: [UInt8]
}

/// Serializes outbound frames with a strictly consecutive sequence from 1.
struct PeerFrameEncoder: Sendable {
    let limits: PeerFrameLimits
    private var nextSequence: UInt32 = 1
    private var exhausted = false

    init(limits: PeerFrameLimits = .standard) {
        self.limits = limits
    }

    mutating func encode(_ message: PeerOutboundMessage) throws(PeerWireError) -> [UInt8] {
        guard !exhausted else { throw .sequenceExhausted }
        guard message.payload.count <= limits.maximumPayloadBytes else {
            throw .oversized(length: UInt32(clamping: message.payload.count), limit: limits.maximumPayloadBytes)
        }
        var writer = PeerWireWriter(capacity: PeerWire.headerByteCount + message.payload.count)
        writer.append(PeerWire.magic)
        writer.append(PeerWire.frameLayoutVersion)
        writer.append(message.kind.rawValue)
        writer.append(UInt8(0))
        writer.append(PeerWireEpoch.encode(message.connectionEpoch))
        writer.append(nextSequence)
        writer.append(UInt32(message.payload.count))
        writer.append(message.payload)
        if nextSequence == .max { exhausted = true } else { nextSequence += 1 }
        return writer.bytes
    }
}

enum PeerWireEpoch {
    static func encode(_ epoch: Generation?) -> UInt64 {
        epoch.map { UInt64($0.value) } ?? 0
    }

    /// 0 means no epoch; anything above `Generation.maximumValue` is refused.
    static func decode(_ raw: UInt64) throws(PeerWireError) -> Generation? {
        guard raw != 0 else { return nil }
        guard raw <= UInt64(Generation.maximumValue), let generation = try? Generation(Int(raw)) else {
            throw .invalidEpoch(raw)
        }
        return generation
    }
}
