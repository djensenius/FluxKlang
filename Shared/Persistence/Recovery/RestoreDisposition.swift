/// Whether a loaded checkpoint is acting on the document. Loading always yields `.inactive`.
enum RestoreDisposition: Equatable, Sendable {
    case inactive(CheckpointRecord)
    case active

    /// The disposition of a checkpoint that was just loaded; activation is a separate explicit call.
    static func loaded(_ record: CheckpointRecord) -> RestoreDisposition {
        .inactive(record)
    }
}

/// The explicit request to activate one checkpoint, naming it by id.
struct RestoreConfirmation: Equatable, Sendable {
    let recordID: CheckpointID

    private init(recordID: CheckpointID) {
        self.recordID = recordID
    }

    static func make(recordID: CheckpointID) -> RestoreConfirmation {
        RestoreConfirmation(recordID: recordID)
    }
}

/// A successful activation: the restored graph, always flagged `requiresReview` (disarmed).
struct RestoreActivation: Equatable, Sendable {
    let record: CheckpointRecord
    let graph: GraphDocument

    var disposition: RestoreDisposition { .active }

    private init(record: CheckpointRecord, graph: GraphDocument) {
        self.record = record
        self.graph = graph
    }

    /// Refusal order: record not in the journal (or different from its stored copy), confirmation names another
    /// record, the newest journal record is not a `preRestore` checkpoint newer than `record`. The journal is a
    /// required parameter: the `preRestore` checkpoint of the current state must already be appended. The order
    /// above is the order of the three checks; faults from `validateState()` follow no promised order.
    static func make(
        record: CheckpointRecord,
        confirmedBy confirmation: RestoreConfirmation,
        journal: CheckpointJournal,
        graph: GraphDocument
    ) throws(CheckpointRefusal) -> RestoreActivation {
        try journal.validateState()
        guard journal.records.contains(where: { $0.id == record.id && $0 == record }) else {
            throw .recordNotInJournal
        }
        guard confirmation.recordID == record.id else {
            throw .confirmationMismatch(expected: record.id, found: confirmation.recordID)
        }
        guard let newest = journal.records.last, newest.reason == .preRestore, newest.ordinal > record.ordinal else {
            throw .preRestoreMissing
        }
        var restored = graph
        restored.requiresReview = true
        return RestoreActivation(record: record, graph: restored)
    }
}
