//
//  PeerStatusDelta.swift
//  FluxKlang
//
//  One step of the status stream (#95, slice C1): the session, sequence and
//  revisions after the step, the entries that are new or changed, and the ids
//  that left. Built only by the throwing `make`, which enforces the delta
//  limit itself because a delta carries no limits of its own.
//

/// Where a projection or delta sits in the publisher's stream: the session, the sequence and the revisions.
struct PeerStatusStamp: Hashable, Sendable {
    var session: PeerSyncSession
    var sequence: PeerSequence
    var revisions: CommandRevisions
}

struct PeerStatusDelta: Hashable, Sendable {
    let session: PeerSyncSession
    let sequence: PeerSequence
    let revisions: CommandRevisions
    /// Ascending by id bytes, unique.
    let upserts: [PeerStatusEntry]
    /// Ascending by id bytes, unique, disjoint from the upserted ids.
    let removals: [ParameterID]

    var changeCount: Int { upserts.count + removals.count }

    private init(stamp: PeerStatusStamp, upserts: [PeerStatusEntry], removals: [ParameterID]) {
        session = stamp.session
        sequence = stamp.sequence
        revisions = stamp.revisions
        self.upserts = upserts
        self.removals = removals
    }

    /// Refuses, in order: more changes than `limits.maximumDeltaChanges` (counted before de-duplication),
    /// a duplicated upsert id, an id both upserted and removed. Input order never changes the result.
    static func make(stamp: PeerStatusStamp, upserts: [PeerStatusEntry], removals: Set<ParameterID>,
                     limits: PeerSyncLimits) throws(PeerStatusError) -> PeerStatusDelta {
        let count = upserts.count + removals.count
        guard count <= limits.maximumDeltaChanges else {
            throw .deltaTooLarge(count: count, limit: limits.maximumDeltaChanges)
        }
        if let duplicate = upserts.smallestDuplicateID() { throw .duplicateEntry(duplicate) }
        let upserted = Set(upserts.map(\.id))
        let shared = removals.filter { upserted.contains($0) }
        if let first = shared.sorted(by: PeerStatusEntry.precedes).first { throw .overlappingChanges(first) }
        return PeerStatusDelta(stamp: stamp, upserts: upserts.sortedByID(),
                               removals: removals.sorted(by: PeerStatusEntry.precedes))
    }
}
