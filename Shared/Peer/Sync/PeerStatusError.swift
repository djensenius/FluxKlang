//
//  PeerStatusError.swift
//  FluxKlang
//
//  Typed refusals of the grant-scoped catalog and capability status projection
//  (#95, slice C1). Every refusal names the first defect in the documented
//  order and leaves the inputs unchanged; nothing is truncated or clamped.
//

/// Why one status entry is not valid. The checks run in declaration order.
enum PeerStatusEntryFault: Hashable, Sendable {
    /// A NaN or infinite lower or upper bound.
    case nonFiniteBound
    case invertedBounds
    /// Only `.live` descriptors are ever projected.
    case notLive(ControlClass)
    /// The bounds do not fit the unit (boolean 0...1, normalized 0...1, percent 0...100, index integral).
    case unitBounds(ParameterUnit)
}

enum PeerStatusError: Error, Hashable, Sendable {
    case invalidEntry(ParameterID, PeerStatusEntryFault)
    case tooManyEntries(count: Int, limit: Int)
    /// The smallest id that appears twice.
    case duplicateEntry(ParameterID)
    case deltaTooLarge(count: Int, limit: Int)
    /// The change set exceeds the delta limit; the caller must send a snapshot instead.
    case requiresSnapshot(changeCount: Int, limit: Int)
    /// The smallest id that is both upserted and removed.
    case overlappingChanges(ParameterID)
    /// The first epoch that differs, host before connection.
    case sessionMismatch(StaleDependency)
    case sequenceExhausted
    /// The found sequence is the current one or older.
    case staleSequence(current: PeerSequence, found: PeerSequence)
    case sequenceGap(expected: PeerSequence, found: PeerSequence)
    case revisionRegressed
    case emptyDelta
    /// Visibility or a writable flag changed while neither `permission` nor `capability` advanced.
    case permissionChangeWithoutRevision
    /// The smallest removed id that is not in the projection.
    case removedUnknownEntry(ParameterID)
    /// The smallest upserted id whose entry is already equal in the projection.
    case redundantUpsert(ParameterID)
}
