//
//  PeerControlMessage+Encode.swift
//  FluxKlang
//
//  Encoding of the snapshot, delta and resync messages and the shared field
//  writers (#95, slice S2). Encode refuses before it returns any bytes.
//

import Foundation

extension PeerControlMessage {
    /// Encodes `message` as one control payload. Refusal order: entry limits, then
    /// unencodable or non-finite values in field order, then the payload size.
    /// `limits` and `frameLimits` are required: the caller's bounds are enforced
    /// here, not trusted from the message.
    static func encode(
        _ message: PeerControlMessage,
        limits: PeerSyncLimits,
        frameLimits: PeerFrameLimits
    ) throws(PeerControlMessageError) -> [UInt8] {
        var writer = PeerWireWriter()
        writer.append(message.tag.rawValue)
        switch message {
        case .snapshot(let snapshot): try writeSnapshot(snapshot, limits: limits, into: &writer)
        case .delta(let delta): try writeDelta(delta, limits: limits, into: &writer)
        case .resync(let request): try writeResync(request, into: &writer)
        case .command(let envelope): try writeCommand(envelope, into: &writer)
        case .result(let result): try writeResult(result, into: &writer)
        }
        let bytes = writer.bytes
        guard bytes.count <= frameLimits.maximumPayloadBytes else { throw .payloadTooLarge(bytes.count) }
        return bytes
    }

    private static func writeSnapshot(
        _ snapshot: PeerSyncSnapshot,
        limits: PeerSyncLimits,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        guard snapshot.values.count <= limits.maximumSnapshotValues else {
            throw .tooManyEntries(snapshot.values.count)
        }
        try writeSession(snapshot.session, into: &writer)
        writeSequence(snapshot.sequence, into: &writer)
        writeRevisions(snapshot.revisions, into: &writer)
        writer.append(UInt32(truncatingIfNeeded: snapshot.values.count))
        try writeEntries(snapshot.values, into: &writer)
    }

    private static func writeDelta(
        _ delta: PeerSyncDelta,
        limits: PeerSyncLimits,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        guard delta.changeCount <= limits.maximumDeltaChanges else { throw .tooManyEntries(delta.changeCount) }
        guard delta.removals.allSatisfy({ delta.updates[$0] == nil }) else {
            throw .unencodable(.overlappingChanges)
        }
        try writeSession(delta.session, into: &writer)
        writeSequence(delta.sequence, into: &writer)
        writeRevisions(delta.revisions, into: &writer)
        writer.append(UInt32(truncatingIfNeeded: delta.updates.count))
        writer.append(UInt32(truncatingIfNeeded: delta.removals.count))
        try writeEntries(delta.updates, into: &writer)
        for removed in sortedByBytes(delta.removals) { try writeID(removed, into: &writer) }
    }

    private static func writeResync(
        _ request: PeerResyncWireRequest,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        try writeSession(request.session, into: &writer)
        writeSequence(request.lastApplied, into: &writer)
        switch request.reason {
        case .gap(let expected, let found):
            writer.append(UInt8(1))
            writeSequence(expected, into: &writer)
            writeSequence(found, into: &writer)
        case .repeated(let sequence):
            writer.append(UInt8(2))
            writeSequence(sequence, into: &writer)
        case .unappliable: writer.append(UInt8(3))
        case .snapshotRefused: writer.append(UInt8(4))
        }
    }

    // MARK: Field writers shared with the command section

    static func writeSession(
        _ session: PeerSyncSession,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        try writeID(session.hostEpoch.host, into: &writer)
        writer.append(UInt64(session.hostEpoch.generation.value))
        try writeID(session.connectionEpoch.connection, into: &writer)
        writer.append(UInt64(session.connectionEpoch.generation.value))
    }

    static func writeSequence(_ sequence: PeerSequence, into writer: inout PeerWireWriter) {
        writer.append(UInt64(sequence.value))
    }

    static func writeGeneration(_ generation: Generation, into writer: inout PeerWireWriter) {
        writer.append(UInt64(generation.value))
    }

    static func writeRevisions(_ revisions: CommandRevisions, into writer: inout PeerWireWriter) {
        let ordered = [revisions.patch, revisions.capability, revisions.permission,
                       revisions.parameter, revisions.graph]
        for revision in ordered { writer.append(UInt64(revision.value)) }
    }

    static func writeID(
        _ id: ContractID<some ContractIDTag>,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        try writeText(id.rawValue, bounds: Wire.idBytes, wide: false, into: &writer)
    }

    /// Writes a UTF-8 length (one byte, or two when `wide`) and the bytes. The length is
    /// the `utf8` count, never the Character count.
    static func writeText(
        _ text: String,
        bounds: ClosedRange<Int>,
        wide: Bool,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        let utf8 = text.utf8
        guard bounds.contains(utf8.count) else { throw .unencodable(.textLength(utf8.count)) }
        if wide {
            writer.append(UInt16(truncatingIfNeeded: utf8.count))
        } else {
            writer.append(UInt8(truncatingIfNeeded: utf8.count))
        }
        writer.append(utf8)
    }

    static func writeDouble(_ value: Double, into writer: inout PeerWireWriter) throws(PeerControlMessageError) {
        guard value.isFinite else { throw .nonFiniteValue }
        writer.append(value.bitPattern)
    }

    static func writeValue(
        _ value: ParameterValue,
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        try writeDouble(value.value, into: &writer)
        writer.append(value.unit.wireCode)
    }

    private static func writeEntries(
        _ values: [ParameterID: ParameterValue],
        into writer: inout PeerWireWriter
    ) throws(PeerControlMessageError) {
        for id in sortedByBytes(values.keys) {
            try writeID(id, into: &writer)
            if let value = values[id] { try writeValue(value, into: &writer) }
        }
    }

    /// Ascending by UTF-8 bytes, the one order the decoder accepts.
    private static func sortedByBytes(_ ids: some Sequence<ParameterID>) -> [ParameterID] {
        ids.sorted { $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8) }
    }
}
