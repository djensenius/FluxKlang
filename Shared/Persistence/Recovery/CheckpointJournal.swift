/// The records a successful `append` removed, ascending by ordinal.
struct CheckpointEviction: Equatable, Sendable {
    let evicted: [CheckpointRecord]

    fileprivate init(evicted: [CheckpointRecord]) {
        self.evicted = evicted
    }
}

/// A bounded journal of checkpoint records, always strictly ascending by ordinal. Built empty by `make` or loaded
/// (and fully validated) by `restore`; `records` changes only through `append`, which is all-or-nothing.
struct CheckpointJournal: Equatable, Sendable {
    let limits: CheckpointLimits
    private(set) var records: [CheckpointRecord]

    private init(limits: CheckpointLimits, records: [CheckpointRecord]) {
        self.limits = limits
        self.records = records
    }

    static func make(limits: CheckpointLimits) -> CheckpointJournal {
        CheckpointJournal(limits: limits, records: [])
    }

    /// Loads persisted records; they must already satisfy every journal invariant. An empty list is legal.
    static func restore(
        limits: CheckpointLimits,
        records: [CheckpointRecord]
    ) throws(CheckpointRefusal) -> CheckpointJournal {
        let checked = try limits.revalidated()
        try validate(limits: checked, records: records)
        return CheckpointJournal(limits: checked, records: records)
    }

    /// The sum of the record byte counts. Bounded by `limits.maxTotalBytes` (at most 2^40), so it cannot overflow.
    var totalBytes: Int {
        records.reduce(0) { $0 + $1.byteCount }
    }

    /// The ordinal a caller should give the next record; refuses at `UInt64.max`. An empty journal starts at 0.
    func nextOrdinal() throws(CheckpointRefusal) -> UInt64 {
        guard let newest = records.last else { return 0 }
        let (next, overflow) = newest.ordinal.addingReportingOverflow(1)
        guard !overflow else { throw .ordinalOverflow }
        return next
    }

    /// The newest record (highest ordinal) with the same digest and byte count as `probe`.
    func newestRecord(sameContentAs probe: CheckpointRecord) -> CheckpointRecord? {
        records.last { $0.isSameContent(as: probe) }
    }

    /// Appends `record`, evicting per `CheckpointRetention`. Refusal order: ordinal not increasing, duplicate id,
    /// record too large, cannot make room. A refusal leaves the journal unchanged.
    mutating func append(_ record: CheckpointRecord) throws(CheckpointRefusal) -> CheckpointEviction {
        let plan = try CheckpointRetention.plan(journal: self, incoming: record)
        let evictIDs = Set(plan.evict)
        let evicted = records.filter { evictIDs.contains($0.id) }
        var next = records.filter { !evictIDs.contains($0.id) }
        next.append(record)
        records = next
        return CheckpointEviction(evicted: evicted)
    }

    /// Point-of-use re-validation of the limits and of the stored records.
    func validateState() throws(CheckpointRefusal) {
        let checked = try limits.revalidated()
        try Self.validate(limits: checked, records: records)
    }

    /// The admission checks for `incoming`, in refusal order. Never mutates.
    func checkAdmission(of incoming: CheckpointRecord) throws(CheckpointRefusal) {
        if let newest = records.last, incoming.ordinal <= newest.ordinal {
            throw .ordinalNotIncreasing(ordinal: incoming.ordinal, newest: newest.ordinal)
        }
        if records.contains(where: { $0.id == incoming.id }) { throw .duplicateID(incoming.id) }
        if incoming.byteCount > limits.maxRecordBytes {
            throw .recordTooLarge(byteCount: incoming.byteCount, limit: limits.maxRecordBytes)
        }
    }

    // Counting first bounds the sum: at most 256 records of at most 2^32 bytes each.
    private static func validate(
        limits: CheckpointLimits,
        records: [CheckpointRecord]
    ) throws(CheckpointRefusal) {
        guard records.count <= limits.maxRecords else { throw .invalidJournal(.tooManyRecords(records.count)) }
        var seen = Set<CheckpointID>()
        var total = 0
        for (index, record) in records.enumerated() {
            guard record.byteCount <= limits.maxRecordBytes else {
                throw .invalidJournal(.recordOverLimit(record.id))
            }
            guard seen.insert(record.id).inserted else { throw .invalidJournal(.duplicateID(record.id)) }
            if index > 0, record.ordinal <= records[index - 1].ordinal {
                throw .invalidJournal(.ordinalNotIncreasing(index: index))
            }
            total += record.byteCount
        }
        guard total <= limits.maxTotalBytes else { throw .invalidJournal(.totalOverCap(total)) }
    }
}
