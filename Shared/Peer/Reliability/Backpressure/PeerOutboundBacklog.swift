//
//  PeerOutboundBacklog.swift
//  FluxKlang
//
//  A bounded record of the deltas a host published but the controller has not
//  acknowledged, for one peer session (#97, R3). It holds counts only: the
//  change count of each pending delta, never the delta. When it is full the host
//  calls `collapse`, which empties it, reports what it dropped and requires a
//  snapshot; the stream then continues after that snapshot. A collapse never
//  invents a delta.
//

/// What a collapse dropped, exactly. Output only: made by the backlog; nothing takes one as input.
struct PeerBacklogCollapse: Hashable, Sendable {
    let droppedDeltas: Int
    let droppedChanges: Int
}

struct PeerOutboundBacklog: Hashable, Sendable {
    static let deltaBounds = 1...4_096
    static let changeBounds = 1...65_536

    let session: PeerSyncSession
    let maxPendingDeltas: Int
    let maxPendingChanges: Int
    /// Everything at or below this sequence is acknowledged or covered by a snapshot.
    private(set) var acknowledgedThrough: PeerSequence
    /// The newest sequence recorded (or covered by a snapshot); the next delta must be exactly the one after it.
    private(set) var recordedThrough: PeerSequence
    private(set) var pendingChanges = 0
    /// True after a collapse, until a snapshot at or above `acknowledgedThrough` is applied.
    private(set) var requiresSnapshot = false
    /// Change count per pending delta, oldest first; entry i is sequence `acknowledgedThrough + 1 + i`.
    private var pendingChangeCounts: [Int] = []

    private init(session: PeerSyncSession, snapshotSequence: PeerSequence, maxPendingDeltas: Int,
                 maxPendingChanges: Int) {
        self.session = session
        self.maxPendingDeltas = maxPendingDeltas
        self.maxPendingChanges = maxPendingChanges
        acknowledgedThrough = snapshotSequence
        recordedThrough = snapshotSequence
    }

    /// `snapshotSequence` is the sequence of the snapshot the stream continues from; the first delta must be the
    /// one after it. Names the first bad limit, in parameter order.
    static func make(session: PeerSyncSession, snapshotSequence: PeerSequence, maxPendingDeltas: Int,
                     maxPendingChanges: Int) throws(PeerBackpressureRefusal) -> PeerOutboundBacklog {
        guard deltaBounds.contains(maxPendingDeltas) else { throw .invalidLimit(.maxPendingDeltas) }
        guard changeBounds.contains(maxPendingChanges) else { throw .invalidLimit(.maxPendingChanges) }
        return PeerOutboundBacklog(session: session, snapshotSequence: snapshotSequence,
                                   maxPendingDeltas: maxPendingDeltas, maxPendingChanges: maxPendingChanges)
    }

    var pendingDeltas: Int { pendingChangeCounts.count }

    /// Records `delta`. Refusal order: `sessionMismatch`, `overflow` (no next sequence), `sequenceGap`, then the
    /// limits, by count only: `backlogFull` (delta limit), `overflow` (change total overflows), `backlogFull`
    /// (change limit). A refusal leaves the whole value unchanged. A delta whose change count alone exceeds
    /// `maxPendingChanges` is `backlogFull` even when the backlog is empty: collapse to a snapshot at or above it.
    mutating func record(delta: PeerSyncDelta) throws(PeerBackpressureRefusal) {
        try record(session: delta.session, sequence: delta.sequence, changeCount: delta.changeCount)
    }

    /// The counting core of `record(delta:)`, with the same order. A negative `changeCount` is `overflow`.
    mutating func record(session deltaSession: PeerSyncSession, sequence: PeerSequence,
                         changeCount: Int) throws(PeerBackpressureRefusal) {
        guard deltaSession == session else { throw .sessionMismatch }
        guard let expected = try? recordedThrough.next() else { throw .overflow }
        guard sequence == expected else { throw .sequenceGap(expected: expected, found: sequence) }
        guard pendingChangeCounts.count < maxPendingDeltas else { throw .backlogFull }
        guard changeCount >= 0 else { throw .overflow }
        let (total, overflowed) = pendingChanges.addingReportingOverflow(changeCount)
        guard !overflowed else { throw .overflow }
        guard total <= maxPendingChanges else { throw .backlogFull }
        pendingChangeCounts.append(changeCount)
        pendingChanges = total
        recordedThrough = expected
    }

    /// Drops the pending deltas at or below `sequence` and returns how many. A value below
    /// `acknowledgedThrough` (already acknowledged) or above `recordedThrough` (never recorded) is ignored, so a
    /// repeated or late acknowledgement changes nothing and an out-of-order pair ends in the same state.
    @discardableResult
    mutating func acknowledge(through sequence: PeerSequence) -> Int {
        guard sequence >= acknowledgedThrough, sequence <= recordedThrough else { return 0 }
        return dropPending(through: sequence)
    }

    /// Empties the backlog for a snapshot at `snapshotSequence`, which must be at or above `recordedThrough`
    /// (`snapshotBehind` otherwise, no change). Reports exactly what was dropped, then requires a snapshot until
    /// `snapshotApplied`. Collapsing an empty backlog reports zero and still requires the snapshot.
    mutating func collapse(to snapshotSequence: PeerSequence) throws(PeerBackpressureRefusal) -> PeerBacklogCollapse {
        guard snapshotSequence >= recordedThrough else {
            throw .snapshotBehind(newest: recordedThrough, found: snapshotSequence)
        }
        let report = PeerBacklogCollapse(droppedDeltas: pendingChangeCounts.count, droppedChanges: pendingChanges)
        pendingChangeCounts = []
        pendingChanges = 0
        acknowledgedThrough = snapshotSequence
        recordedThrough = snapshotSequence
        requiresSnapshot = true
        return report
    }

    /// Clears `requiresSnapshot` when a snapshot at or above `acknowledgedThrough` was applied; deltas it covers
    /// are dropped and a snapshot ahead of everything recorded moves the stream forward. Returns false, with no
    /// change, when no snapshot is required or the snapshot is older than the floor.
    @discardableResult
    mutating func snapshotApplied(through sequence: PeerSequence) -> Bool {
        guard requiresSnapshot, sequence >= acknowledgedThrough else { return false }
        if sequence > recordedThrough {
            pendingChangeCounts = []
            pendingChanges = 0
            acknowledgedThrough = sequence
            recordedThrough = sequence
        } else {
            dropPending(through: sequence)
        }
        requiresSnapshot = false
        return true
    }

    /// Callers pass a sequence in `acknowledgedThrough...recordedThrough`, so the count fits the pending list.
    @discardableResult
    private mutating func dropPending(through sequence: PeerSequence) -> Int {
        let count = sequence.value - acknowledgedThrough.value
        let dropped = pendingChangeCounts.prefix(count).reduce(0, +)
        pendingChangeCounts.removeFirst(count)
        pendingChanges -= dropped
        acknowledgedThrough = sequence
        return count
    }
}
