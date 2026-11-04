//
//  PeerWireBytes.swift
//  FluxKlang
//
//  Big-endian primitives for peer frames and handshake payloads. Reads are
//  bounds-checked and a payload must be consumed exactly.
//

import Foundation

struct PeerWireWriter: Sendable {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    mutating func append(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func append(_ value: UInt16) {
        appendBigEndian(UInt64(value), byteCount: 2)
    }

    mutating func append(_ value: UInt32) {
        appendBigEndian(UInt64(value), byteCount: 4)
    }

    mutating func append(_ value: UInt64) {
        appendBigEndian(value, byteCount: 8)
    }

    mutating func append(_ values: some Sequence<UInt8>) {
        bytes.append(contentsOf: values)
    }

    private mutating func appendBigEndian(_ value: UInt64, byteCount: Int) {
        for index in stride(from: byteCount - 1, through: 0, by: -1) {
            bytes.append(UInt8(truncatingIfNeeded: value >> (UInt64(index) * 8)))
        }
    }
}

/// Reads one payload of `kind`; every defect is `.malformedPayload(kind)`.
struct PeerWireReader: Sendable {
    let kind: PeerFrameKind
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8], kind: PeerFrameKind) {
        self.bytes = bytes
        self.kind = kind
    }

    mutating func readUInt8() throws(PeerWireError) -> UInt8 {
        UInt8(try readBigEndian(byteCount: 1))
    }

    mutating func readUInt16() throws(PeerWireError) -> UInt16 {
        UInt16(try readBigEndian(byteCount: 2))
    }

    mutating func readUInt32() throws(PeerWireError) -> UInt32 {
        UInt32(try readBigEndian(byteCount: 4))
    }

    mutating func readUInt64() throws(PeerWireError) -> UInt64 {
        try readBigEndian(byteCount: 8)
    }

    mutating func readBytes(count: Int) throws(PeerWireError) -> [UInt8] {
        guard count >= 0, count <= bytes.count - offset else { throw .malformedPayload(kind) }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    /// Refuses trailing bytes.
    func finish() throws(PeerWireError) {
        guard offset == bytes.count else { throw .malformedPayload(kind) }
    }

    private mutating func readBigEndian(byteCount: Int) throws(PeerWireError) -> UInt64 {
        guard byteCount <= bytes.count - offset else { throw .malformedPayload(kind) }
        var value: UInt64 = 0
        for byte in bytes[offset..<(offset + byteCount)] {
            value = value << 8 | UInt64(byte)
        }
        offset += byteCount
        return value
    }
}
