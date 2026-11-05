//
//  PeerSyncSnapshot.swift
//  FluxKlang
//
//  Neutral, bounded snapshot and delta values for one peer session (#95). A
//  session is a host epoch plus a connection epoch; sequences are scoped to it
//  and a reconnect always starts from a fresh snapshot. S1 carries parameter
//  values and the command revisions only. No byte codec, no execution payloads.
//
//  This deviates from the per-host log `seq` in the workspace-ux
//  examples/commands.json draft. A per-session counter needs no host-wide
//  ledger that survives reconnects. With the resnapshot rule, a gap can only
//  mean loss inside one live session, and that is always answered with a
//  resync. A host-wide audit log may still number entries separately.
//

import Foundation

/// One peer session: the host epoch and the connection epoch it was opened
/// under. Compared by equality only, like the epochs it wraps.
struct PeerSyncSession: Hashable, Sendable {
    let hostEpoch: HostEpoch
    let connectionEpoch: ConnectionEpoch

    /// Nil when the connection epoch belongs to another host.
    init?(hostEpoch: HostEpoch, connectionEpoch: ConnectionEpoch) {
        guard connectionEpoch.host == hostEpoch.host else { return nil }
        self.hostEpoch = hostEpoch
        self.connectionEpoch = connectionEpoch
    }

    /// Binds a negotiated #93 session to host-assigned identities. The IDs come
    /// from the host, never from peer bytes.
    init(host: HostID, connection: ConnectionID, negotiated: PeerNegotiatedSession) {
        hostEpoch = HostEpoch(host: host, generation: negotiated.hostEpoch)
        connectionEpoch = ConnectionEpoch(connection: connection, host: host, generation: negotiated.connectionEpoch)
    }

    /// The first epoch that differs from `self`, host before connection.
    func staleDependency(host: HostEpoch, connection: ConnectionEpoch?) -> StaleDependency? {
        guard host == hostEpoch else { return .hostEpoch }
        guard connection == connectionEpoch else { return .connectionEpoch }
        return nil
    }
}

enum PeerSequenceError: Error, Hashable, Sendable {
    case outOfRange(Int)
    case exhausted
}

/// A position in one session's stream, 0…2^53−1. Zero means "before the first
/// delta or command"; every delta and command envelope uses 1 or more. Never wraps.
struct PeerSequence: Hashable, Comparable, Sendable, CustomStringConvertible {
    static let maximumValue = 9_007_199_254_740_991
    static let origin = PeerSequence(uncheckedValue: 0)

    let value: Int

    init(_ value: Int) throws(PeerSequenceError) {
        guard (0...Self.maximumValue).contains(value) else { throw .outOfRange(value) }
        self.value = value
    }

    private init(uncheckedValue: Int) { value = uncheckedValue }

    var description: String { String(value) }

    func next() throws(PeerSequenceError) -> PeerSequence {
        guard value < Self.maximumValue else { throw .exhausted }
        return PeerSequence(uncheckedValue: value + 1)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

struct PeerSyncLimits: Hashable, Sendable {
    static let snapshotValueBounds = 1...65_536
    static let deltaChangeBounds = 1...4_096
    static let standard = PeerSyncLimits(uncheckedSnapshot: 4_096, delta: 256)

    let maximumSnapshotValues: Int
    let maximumDeltaChanges: Int

    init?(maximumSnapshotValues: Int, maximumDeltaChanges: Int) {
        guard Self.snapshotValueBounds.contains(maximumSnapshotValues),
              Self.deltaChangeBounds.contains(maximumDeltaChanges) else { return nil }
        self.init(uncheckedSnapshot: maximumSnapshotValues, delta: maximumDeltaChanges)
    }

    private init(uncheckedSnapshot: Int, delta: Int) {
        maximumSnapshotValues = uncheckedSnapshot
        maximumDeltaChanges = delta
    }
}

enum PeerSyncError: Error, Hashable, Sendable {
    case snapshotTooLarge(count: Int, limit: Int)
    case deltaTooLarge(count: Int, limit: Int)
    case emptyDelta
    case overlappingChanges(ParameterID)
    case removedUnknownValue(ParameterID)
    /// A NaN or infinite value, like `ParameterValueError.nonFinite`, naming the smallest such ID.
    case nonFiniteValue(ParameterID)
    case revisionRegressed
    case sequenceExhausted
    case snapshotBehind(current: PeerSequence, found: PeerSequence)
}

/// The whole mirrored state at `sequence`: deltas continue at `sequence + 1`.
struct PeerSyncSnapshot: Hashable, Sendable {
    let session: PeerSyncSession
    let sequence: PeerSequence
    let revisions: CommandRevisions
    let values: [ParameterID: ParameterValue]

    func validate(_ limits: PeerSyncLimits) throws(PeerSyncError) {
        guard values.count <= limits.maximumSnapshotValues else {
            throw .snapshotTooLarge(count: values.count, limit: limits.maximumSnapshotValues)
        }
        if let bad = values.smallestNonFiniteID { throw .nonFiniteValue(bad) }
    }
}

/// One step of the stream: the revisions after the step, plus disjoint
/// updates and removals.
struct PeerSyncDelta: Hashable, Sendable {
    let session: PeerSyncSession
    let sequence: PeerSequence
    let revisions: CommandRevisions
    let updates: [ParameterID: ParameterValue]
    let removals: Set<ParameterID>

    var changeCount: Int { updates.count + removals.count }

    func validate(_ limits: PeerSyncLimits) throws(PeerSyncError) {
        guard changeCount <= limits.maximumDeltaChanges else {
            throw .deltaTooLarge(count: changeCount, limit: limits.maximumDeltaChanges)
        }
        if let shared = removals.filter({ updates[$0] != nil }).min() { throw .overlappingChanges(shared) }
        if let bad = updates.smallestNonFiniteID { throw .nonFiniteValue(bad) }
    }
}

/// The values and revisions a snapshot plus its contiguous deltas produce.
struct PeerSyncState: Hashable, Sendable {
    let sequence: PeerSequence
    let revisions: CommandRevisions
    let values: [ParameterID: ParameterValue]

    init(_ snapshot: PeerSyncSnapshot) {
        sequence = snapshot.sequence
        revisions = snapshot.revisions
        values = snapshot.values
    }

    private init(sequence: PeerSequence, revisions: CommandRevisions, values: [ParameterID: ParameterValue]) {
        self.sequence = sequence
        self.revisions = revisions
        self.values = values
    }

    /// Applies a delta whose session and sequence the caller already checked.
    /// When several IDs are at fault, the error names the smallest.
    func applying(_ delta: PeerSyncDelta, limits: PeerSyncLimits) throws(PeerSyncError) -> PeerSyncState {
        try delta.validate(limits)
        guard delta.changeCount > 0 || delta.revisions != revisions else { throw .emptyDelta }
        guard !delta.revisions.regresses(from: revisions) else { throw .revisionRegressed }
        var next = values
        for removed in delta.removals.sorted() {
            guard next.removeValue(forKey: removed) != nil else { throw .removedUnknownValue(removed) }
        }
        next.merge(delta.updates) { _, new in new }
        guard next.count <= limits.maximumSnapshotValues else {
            throw .snapshotTooLarge(count: next.count, limit: limits.maximumSnapshotValues)
        }
        return PeerSyncState(sequence: delta.sequence, revisions: delta.revisions, values: next)
    }
}

extension CommandRevisions {
    /// True when any component of `self` is below the same component of `base`.
    func regresses(from base: CommandRevisions) -> Bool {
        patch < base.patch || capability < base.capability || permission < base.permission
            || parameter < base.parameter || graph < base.graph
    }
}

private extension Dictionary where Key == ParameterID, Value == ParameterValue {
    var smallestNonFiniteID: ParameterID? { filter { !$0.value.value.isFinite }.keys.min() }
}
