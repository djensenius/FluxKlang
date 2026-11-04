//
//  PeerFrameDecoder.swift
//  FluxKlang
//
//  Incremental, bounded decoding of one inbound byte stream. Results are
//  independent of how the transport splits or coalesces deliveries: every
//  frame completed before a defect is delivered, then the defect is reported.
//  The magic is checked as soon as 4 bytes arrive and the header before any
//  payload is buffered, so an oversized length is refused without reading it.
//  The first error latches: the decoder never yields another frame. Idle and
//  partial-frame timeouts belong to a later transport slice.
//

import Foundation

/// Frames completed by one delivery, then the defect that stopped decoding, if any.
/// Callers must consume `frames` in order and then act on `failure`: a non-nil
/// failure ends the stream, and the decoder yields nothing further.
struct PeerFrameDelivery: Hashable, Sendable {
    let frames: [PeerFrame]
    let failure: PeerWireError?
}

struct PeerFrameDecoder: Sendable {
    let limits: PeerFrameLimits
    private(set) var failure: PeerWireError?
    private var buffer: [UInt8] = []
    private var header: Header?
    private var nextSequence: UInt32 = 1
    private var exhausted = false

    private struct Header: Sendable {
        let kind: PeerFrameKind
        let epoch: Generation?
        let sequence: UInt32
        let length: Int
    }

    init(limits: PeerFrameLimits = .standard) {
        self.limits = limits
        buffer.reserveCapacity(PeerWire.headerByteCount)
    }

    /// Bytes held for an incomplete frame; never above `limits.maximumFrameBytes`.
    var bufferedByteCount: Int { buffer.count + (header == nil ? 0 : PeerWire.headerByteCount) }

    /// Decodes every frame completed by `bytes`, in order, up to the first
    /// defect. A failure latches; later calls return no frames and that failure.
    mutating func feed(_ bytes: [UInt8]) -> PeerFrameDelivery {
        if let failure { return PeerFrameDelivery(frames: [], failure: failure) }
        var frames: [PeerFrame] = []
        var index = bytes.startIndex
        do throws(PeerWireError) {
            while index < bytes.endIndex {
                let target = header?.length ?? (buffer.count < PeerWire.magic.count
                    ? PeerWire.magic.count : PeerWire.headerByteCount)
                let take = min(target - buffer.count, bytes.endIndex - index)
                buffer.append(contentsOf: bytes[index..<(index + take)])
                index += take
                try completePending(into: &frames)
            }
        } catch {
            latch(error)
            return PeerFrameDelivery(frames: frames, failure: error)
        }
        return PeerFrameDelivery(frames: frames, failure: nil)
    }

    /// Call at end of stream; a partially received frame is refused.
    mutating func finish() throws(PeerWireError) {
        if let failure { throw failure }
        guard bufferedByteCount == 0 else {
            let error = PeerWireError.truncated(bufferedBytes: bufferedByteCount)
            latch(error)
            throw error
        }
    }

    private mutating func completePending(into frames: inout [PeerFrame]) throws(PeerWireError) {
        if header == nil, buffer.count == PeerWire.magic.count, !buffer.elementsEqual(PeerWire.magic) {
            throw .badMagic
        }
        if header == nil, buffer.count == PeerWire.headerByteCount {
            header = try parseHeader(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        guard let pending = header, buffer.count == pending.length else { return }
        frames.append(PeerFrame(
            kind: pending.kind, sequence: pending.sequence, connectionEpoch: pending.epoch, payload: buffer
        ))
        header = nil
        buffer.removeAll(keepingCapacity: true)
    }

    private mutating func parseHeader(_ bytes: [UInt8]) throws(PeerWireError) -> Header {
        var reader = PeerWireReader(bytes, kind: .hello)
        guard try reader.readBytes(count: PeerWire.magic.count) == PeerWire.magic else { throw .badMagic }
        let version = try reader.readUInt16()
        guard version == PeerWire.frameLayoutVersion else { throw .unsupportedFrameVersion(version) }
        let rawKind = try reader.readUInt8()
        guard let kind = PeerFrameKind(rawValue: rawKind) else { throw .unknownKind(rawKind) }
        let flags = try reader.readUInt8()
        guard flags == 0 else { throw .reservedFlags(flags) }
        let epoch = try PeerWireEpoch.decode(try reader.readUInt64())
        let sequence = try reader.readUInt32()
        guard !exhausted, sequence == nextSequence else {
            throw exhausted ? .sequenceExhausted : .outOfOrder(expected: nextSequence, found: sequence)
        }
        let length = try reader.readUInt32()
        guard length <= limits.maximumPayloadBytes else {
            throw .oversized(length: length, limit: limits.maximumPayloadBytes)
        }
        if nextSequence == .max { exhausted = true } else { nextSequence += 1 }
        return Header(kind: kind, epoch: epoch, sequence: sequence, length: Int(length))
    }

    private mutating func latch(_ error: PeerWireError) {
        failure = error
        header = nil
        buffer = []
    }
}
