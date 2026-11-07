/// What a successful append would do: the ids to evict and the ids kept, both ascending by ordinal.
struct RetentionPlan: Equatable, Sendable {
    let evict: [CheckpointID]
    let keep: [CheckpointID]

    fileprivate init(evict: [CheckpointID], keep: [CheckpointID]) {
        self.evict = evict
        self.keep = keep
    }
}

/// Plans which records an append evicts. The newest `preMigration` and the newest `manual` record (counting the
/// incoming one) are pinned and never evicted; eviction is oldest ordinal first among the rest.
enum CheckpointRetention {
    /// Re-validates the journal, then applies the admission checks, then plans the eviction. Refuses
    /// `.cannotMakeRoom` when the pins alone keep a cap exceeded. Never mutates the journal.
    static func plan(
        journal: CheckpointJournal,
        incoming: CheckpointRecord
    ) throws(CheckpointRefusal) -> RetentionPlan {
        try journal.validateState()
        try journal.checkAdmission(of: incoming)
        let limits = journal.limits
        let pinned = pinnedOrdinals(journal.records + [incoming])
        var count = journal.records.count + 1
        // Both sums are bounded by the caps (at most 2^40) plus one record (at most 2^32).
        var total = journal.totalBytes + incoming.byteCount
        var evict: [CheckpointID] = []
        for record in journal.records where !pinned.contains(record.ordinal) {
            if count <= limits.maxRecords && total <= limits.maxTotalBytes { break }
            evict.append(record.id)
            count -= 1
            total -= record.byteCount
        }
        guard count <= limits.maxRecords, total <= limits.maxTotalBytes else { throw .cannotMakeRoom }
        let evicted = Set(evict)
        let keep = journal.records.map(\.id).filter { !evicted.contains($0) }
        return RetentionPlan(evict: evict, keep: keep)
    }

    private static func pinnedOrdinals(_ records: [CheckpointRecord]) -> Set<UInt64> {
        var pinned = Set<UInt64>()
        for reason in CheckpointReason.allCases where reason.isPinEligible {
            if let newest = records.last(where: { $0.reason == reason }) { pinned.insert(newest.ordinal) }
        }
        return pinned
    }
}
