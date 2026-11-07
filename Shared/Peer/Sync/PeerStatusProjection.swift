//
//  PeerStatusProjection.swift
//  FluxKlang
//
//  The catalog and capability status one peer may see at one point of its
//  session stream (#95, slice C1). The publisher builds it from the validated
//  `ParameterCatalog` and the peer's `PeerGrantSet`; the receiver builds a
//  baseline from entries and then applies deltas. Only `.live` descriptors
//  are projected, so structural and hazardous parameters never leave the host.
//  Both sides carry the PUBLISHER's session and revisions: idempotence is not
//  freshness, so a delta of another session or sequence is refused. Entries
//  are ascending by id bytes, so no input order changes a projection. A
//  refused operation changes nothing: every value here is immutable.
//

struct PeerStatusProjection: Hashable, Sendable {
    let session: PeerSyncSession
    let sequence: PeerSequence
    let revisions: CommandRevisions
    /// Ascending by id bytes, unique, at most `maximumSnapshotValues` of the limits it was built under.
    let entries: [PeerStatusEntry]

    private init(stamp: PeerStatusStamp, entries: [PeerStatusEntry]) {
        session = stamp.session
        sequence = stamp.sequence
        revisions = stamp.revisions
        self.entries = entries
    }

    var stamp: PeerStatusStamp { PeerStatusStamp(session: session, sequence: sequence, revisions: revisions) }

    /// Publisher side. A grant for a parameter missing from the catalog adds nothing. Uses
    /// `limits.maximumSnapshotValues` only; the delta limit has no meaning for a snapshot.
    static func make(stamp: PeerStatusStamp, catalog: ParameterCatalog, grants: PeerGrantSet,
                     limits: PeerSyncLimits) throws(PeerStatusError) -> PeerStatusProjection {
        let visible = catalog.parameters.compactMap { PeerStatusEntry.project($0, grants: grants) }
        try requireFits(visible.count, limits)
        return PeerStatusProjection(stamp: stamp, entries: visible.sortedByID())
    }

    /// Receiver baseline. Refuses too many entries, then the smallest duplicated id.
    static func make(stamp: PeerStatusStamp, entries: [PeerStatusEntry],
                     limits: PeerSyncLimits) throws(PeerStatusError) -> PeerStatusProjection {
        try requireFits(entries.count, limits)
        if let duplicate = entries.smallestDuplicateID() { throw .duplicateEntry(duplicate) }
        return PeerStatusProjection(stamp: stamp, entries: entries.sortedByID())
    }

    /// The delta that turns `self` into `target`. Refusals in order: session, sequence, revision regression,
    /// entry count, a visibility or writable change without a `permission` or `capability` advance, an empty
    /// delta, more changes than `limits.maximumDeltaChanges` (`.requiresSnapshot`, never a truncated delta).
    func delta(to target: PeerStatusProjection, limits: PeerSyncLimits) throws(PeerStatusError) -> PeerStatusDelta {
        try requireSession(target.session)
        try requireNext(target.sequence)
        guard !target.revisions.regresses(from: revisions) else { throw .revisionRegressed }
        try Self.requireFits(max(entries.count, target.entries.count), limits)
        try requireVersioned(target.revisions, target.entries)
        let known = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(target.entries.map(\.id))
        let upserts = target.entries.filter { known[$0.id] != $0 }
        let removals = Set(entries.map(\.id).filter { !kept.contains($0) })
        let count = upserts.count + removals.count
        guard count > 0 || target.revisions != revisions else { throw .emptyDelta }
        guard count <= limits.maximumDeltaChanges else {
            throw .requiresSnapshot(changeCount: count, limit: limits.maximumDeltaChanges)
        }
        return try PeerStatusDelta.make(stamp: target.stamp, upserts: upserts, removals: removals, limits: limits)
    }

    /// Receiver side. Refusals in order: session, sequence, revision regression, delta size, empty delta,
    /// removal of an unknown id, an upsert equal to the resident entry, result size, and a visibility or
    /// writable change without a `permission` or `capability` advance. Returns a new projection.
    func applying(_ delta: PeerStatusDelta, limits: PeerSyncLimits) throws(PeerStatusError) -> PeerStatusProjection {
        try requireSession(delta.session)
        try requireNext(delta.sequence)
        guard !delta.revisions.regresses(from: revisions) else { throw .revisionRegressed }
        guard delta.changeCount <= limits.maximumDeltaChanges else {
            throw .deltaTooLarge(count: delta.changeCount, limit: limits.maximumDeltaChanges)
        }
        guard delta.changeCount > 0 || delta.revisions != revisions else { throw .emptyDelta }
        let result = try merged(delta)
        try Self.requireFits(result.count, limits)
        try requireVersioned(delta.revisions, result)
        return PeerStatusProjection(stamp: PeerStatusStamp(session: session, sequence: delta.sequence,
                                                           revisions: delta.revisions), entries: result)
    }

    private func merged(_ delta: PeerStatusDelta) throws(PeerStatusError) -> [PeerStatusEntry] {
        let original = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resident = original
        for removed in delta.removals where resident.removeValue(forKey: removed) == nil {
            throw .removedUnknownEntry(removed)
        }
        for entry in delta.upserts {
            if original[entry.id] == entry { throw .redundantUpsert(entry.id) }
            resident[entry.id] = entry
        }
        return resident.values.sortedByID()
    }

    private static func requireFits(_ count: Int, _ limits: PeerSyncLimits) throws(PeerStatusError) {
        guard count <= limits.maximumSnapshotValues else {
            throw .tooManyEntries(count: count, limit: limits.maximumSnapshotValues)
        }
    }

    private func requireSession(_ other: PeerSyncSession) throws(PeerStatusError) {
        if let stale = session.staleDependency(host: other.hostEpoch, connection: other.connectionEpoch) {
            throw .sessionMismatch(stale)
        }
    }

    private func requireNext(_ found: PeerSequence) throws(PeerStatusError) {
        let expected: PeerSequence
        do { expected = try sequence.next() } catch { throw .sequenceExhausted }
        guard found == expected else {
            if found <= sequence { throw .staleSequence(current: sequence, found: found) }
            throw .sequenceGap(expected: expected, found: found)
        }
    }

    /// A changed id set or writable flag needs a `permission` or `capability` advance to explain it.
    private func requireVersioned(_ target: CommandRevisions,
                                  _ targetEntries: [PeerStatusEntry]) throws(PeerStatusError) {
        let advanced = target.permission > revisions.permission || target.capability > revisions.capability
        guard !advanced else { return }
        let before = Dictionary(entries.map { ($0.id, $0.writable) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(targetEntries.map { ($0.id, $0.writable) }, uniquingKeysWith: { first, _ in first })
        guard before == after else { throw .permissionChangeWithoutRevision }
    }
}
