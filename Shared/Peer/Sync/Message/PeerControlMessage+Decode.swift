//
//  PeerControlMessage+Decode.swift
//  FluxKlang
//
//  Total decoding of control payloads (#95, slice S2): a value, or one typed
//  refusal. Nothing is allocated from an untrusted count before it has passed
//  both the limit check and the remaining-bytes check.
//

import Foundation

extension PeerControlMessage {
    /// Decodes one control payload received for `session`. Snapshots, deltas and
    /// resync requests must carry exactly `session`; commands and results carry
    /// their own epochs and are judged by the command processor, not here.
    /// Refusal order: payload size, tag, session, sequence and revisions, entry
    /// counts against `limits`, entry counts against the remaining bytes, the
    /// entries, then trailing bytes. `limits` and `frameLimits` are required.
    static func decode(
        _ bytes: [UInt8],
        expecting session: PeerSyncSession,
        limits: PeerSyncLimits,
        frameLimits: PeerFrameLimits
    ) throws(PeerControlMessageError) -> PeerControlMessage {
        guard bytes.count <= frameLimits.maximumPayloadBytes else { throw .payloadTooLarge(bytes.count) }
        var cursor = PeerControlCursor(bytes)
        let code = try cursor.readUInt8()
        guard let tag = Tag(rawValue: code) else { throw .unknownTag(code) }
        let message: PeerControlMessage
        switch tag {
        case .snapshot: message = .snapshot(try readSnapshot(&cursor, session: session, limits: limits))
        case .delta: message = .delta(try readDelta(&cursor, session: session, limits: limits))
        case .resync: message = .resync(try readResync(&cursor, session: session))
        case .command: message = .command(try readCommand(&cursor))
        case .result: message = .result(try readResult(&cursor))
        }
        try cursor.finish()
        return message
    }

    private static func readSnapshot(
        _ cursor: inout PeerControlCursor,
        session: PeerSyncSession,
        limits: PeerSyncLimits
    ) throws(PeerControlMessageError) -> PeerSyncSnapshot {
        try readSession(&cursor, expecting: session)
        let sequence = try cursor.readSequence()
        let revisions = try cursor.readRevisions()
        let count = Int(try cursor.readUInt32())
        guard count <= limits.maximumSnapshotValues else { throw .tooManyEntries(count) }
        try cursor.requireRoom(for: count * Wire.minimumValueEntryBytes)
        let values = try readEntries(&cursor, count: count)
        return PeerSyncSnapshot(session: session, sequence: sequence, revisions: revisions, values: values)
    }

    private static func readDelta(
        _ cursor: inout PeerControlCursor,
        session: PeerSyncSession,
        limits: PeerSyncLimits
    ) throws(PeerControlMessageError) -> PeerSyncDelta {
        try readSession(&cursor, expecting: session)
        let sequence = try cursor.readSequence()
        let revisions = try cursor.readRevisions()
        let updateCount = Int(try cursor.readUInt32())
        let removalCount = Int(try cursor.readUInt32())
        guard updateCount + removalCount <= limits.maximumDeltaChanges else {
            throw .tooManyEntries(updateCount + removalCount)
        }
        try cursor.requireRoom(for: updateCount * Wire.minimumValueEntryBytes
            + removalCount * Wire.minimumRemovalBytes)
        let updates = try readEntries(&cursor, count: updateCount)
        var removals = Set<ParameterID>()
        removals.reserveCapacity(removalCount)
        var previous: ParameterID?
        for _ in 0..<removalCount {
            let id = try cursor.readID(ParameterID.self)
            try requireAscending(previous, id)
            guard updates[id] == nil else { throw .notCanonical }
            removals.insert(id)
            previous = id
        }
        return PeerSyncDelta(session: session, sequence: sequence, revisions: revisions,
                             updates: updates, removals: removals)
    }

    private static func readResync(
        _ cursor: inout PeerControlCursor,
        session: PeerSyncSession
    ) throws(PeerControlMessageError) -> PeerResyncWireRequest {
        try readSession(&cursor, expecting: session)
        let lastApplied = try cursor.readSequence()
        let start = cursor.offset
        let reason: PeerResyncWireReason
        switch try cursor.readUInt8() {
        case 1: reason = .gap(expected: try cursor.readSequence(), found: try cursor.readSequence())
        case 2: reason = .repeated(try cursor.readSequence())
        case 3: reason = .unappliable
        case 4: reason = .snapshotRefused
        default: throw .malformed(offset: start)
        }
        return PeerResyncWireRequest(session: session, lastApplied: lastApplied, reason: reason)
    }

    /// Parses the wire session, then compares it with the expected one. Both
    /// generations and both ids are validated first; a defect there is `malformed`.
    private static func readSession(
        _ cursor: inout PeerControlCursor,
        expecting session: PeerSyncSession
    ) throws(PeerControlMessageError) {
        let host = try cursor.readID(HostID.self)
        let hostGeneration = try cursor.readGeneration()
        let connection = try cursor.readID(ConnectionID.self)
        let connectionGeneration = try cursor.readGeneration()
        guard host == session.hostEpoch.host, hostGeneration == session.hostEpoch.generation,
              connection == session.connectionEpoch.connection,
              connectionGeneration == session.connectionEpoch.generation else { throw .sessionMismatch }
    }

    private static func readEntries(
        _ cursor: inout PeerControlCursor,
        count: Int
    ) throws(PeerControlMessageError) -> [ParameterID: ParameterValue] {
        var values: [ParameterID: ParameterValue] = [:]
        values.reserveCapacity(count)
        var previous: ParameterID?
        for _ in 0..<count {
            let id = try cursor.readID(ParameterID.self)
            let value = try cursor.readValue()
            try requireAscending(previous, id)
            values[id] = value
            previous = id
        }
        return values
    }

    /// Strictly ascending by UTF-8 bytes; an equal or lower id is not canonical.
    private static func requireAscending(
        _ previous: ParameterID?,
        _ next: ParameterID
    ) throws(PeerControlMessageError) {
        guard let previous else { return }
        guard previous.rawValue.utf8.lexicographicallyPrecedes(next.rawValue.utf8) else { throw .notCanonical }
    }
}

/// A bounds-checked reader over one payload. Every defect is `malformed(offset:)`
/// with the offset of the first byte of the field that failed, except a non-finite
/// double. It never reads past the end and never allocates from a count.
struct PeerControlCursor: Sendable {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }

    mutating func readUInt8() throws(PeerControlMessageError) -> UInt8 {
        UInt8(truncatingIfNeeded: try readBigEndian(byteCount: 1))
    }

    mutating func readUInt16() throws(PeerControlMessageError) -> UInt16 {
        UInt16(truncatingIfNeeded: try readBigEndian(byteCount: 2))
    }

    mutating func readUInt32() throws(PeerControlMessageError) -> UInt32 {
        UInt32(truncatingIfNeeded: try readBigEndian(byteCount: 4))
    }

    mutating func readUInt64() throws(PeerControlMessageError) -> UInt64 {
        try readBigEndian(byteCount: 8)
    }

    /// Refuses trailing bytes.
    func finish() throws(PeerControlMessageError) {
        guard remaining == 0 else { throw .malformed(offset: offset) }
    }

    /// Refuses a count whose entries cannot fit in the bytes that are left.
    func requireRoom(for byteCount: Int) throws(PeerControlMessageError) {
        guard byteCount <= remaining else { throw .malformed(offset: offset) }
    }

    /// A UTF-8 string with a one-byte (or, when `wide`, two-byte) length. Invalid
    /// UTF-8 is refused, never repaired.
    mutating func readText(bounds: ClosedRange<Int>, wide: Bool) throws(PeerControlMessageError) -> String {
        let start = offset
        let length = wide ? Int(try readUInt16()) : Int(try readUInt8())
        guard bounds.contains(length), length <= remaining else { throw .malformed(offset: start) }
        guard let text = String(validating: bytes[offset..<(offset + length)], as: UTF8.self) else {
            throw .malformed(offset: offset)
        }
        offset += length
        return text
    }

    mutating func readID<Tag: ContractIDTag>(
        _ type: ContractID<Tag>.Type
    ) throws(PeerControlMessageError) -> ContractID<Tag> {
        let start = offset
        let text = try readText(bounds: PeerControlMessage.Wire.idBytes, wide: false)
        guard let id = ContractID<Tag>(rawValue: text) else { throw .malformed(offset: start) }
        return id
    }

    mutating func readFingerprint() throws(PeerControlMessageError) -> PermissionFingerprint {
        PermissionFingerprint(rawValue: try readText(bounds: PermissionFingerprint.utf8Bounds, wide: true))
    }

    mutating func readSequence() throws(PeerControlMessageError) -> PeerSequence {
        let start = offset
        guard let value = Int(exactly: try readUInt64()), let sequence = try? PeerSequence(value) else {
            throw .malformed(offset: start)
        }
        return sequence
    }

    mutating func readGeneration() throws(PeerControlMessageError) -> Generation {
        let start = offset
        guard let value = Int(exactly: try readUInt64()), let generation = try? Generation(value) else {
            throw .malformed(offset: start)
        }
        return generation
    }

    mutating func readRevision() throws(PeerControlMessageError) -> ContractRevision {
        let start = offset
        guard let value = Int(exactly: try readUInt64()), let revision = try? ContractRevision(value) else {
            throw .malformed(offset: start)
        }
        return revision
    }

    mutating func readRevisions() throws(PeerControlMessageError) -> CommandRevisions {
        CommandRevisions(patch: try readRevision(), capability: try readRevision(),
                         permission: try readRevision(), parameter: try readRevision(),
                         graph: try readRevision())
    }

    /// A finite double from its bit pattern; NaN and infinities are `nonFiniteValue`.
    mutating func readDouble() throws(PeerControlMessageError) -> Double {
        let value = Double(bitPattern: try readUInt64())
        guard value.isFinite else { throw .nonFiniteValue }
        return value
    }

    /// The double first, then the unit: a value with both defects is `nonFiniteValue`.
    mutating func readValue() throws(PeerControlMessageError) -> ParameterValue {
        let value = try readDouble()
        return ParameterValue(value: value, unit: try readCoded(ParameterUnit.self))
    }

    mutating func readCoded<Value: PeerControlCoded>(
        _ type: Value.Type
    ) throws(PeerControlMessageError) -> Value {
        let start = offset
        guard let value = Value(wireCode: try readUInt8()) else { throw .malformed(offset: start) }
        return value
    }

    private mutating func readBigEndian(byteCount: Int) throws(PeerControlMessageError) -> UInt64 {
        guard byteCount <= remaining else { throw .malformed(offset: offset) }
        var value: UInt64 = 0
        for byte in bytes[offset..<(offset + byteCount)] {
            value = value << 8 | UInt64(byte)
        }
        offset += byteCount
        return value
    }
}
