import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectCheckpointTests {
    static func activationJournal(extra: [CheckpointRecord] = []) throws -> CheckpointJournal {
        let stored = [try Self.record(1, .manual, id: 11), try Self.record(2, .preRestore, id: 12)] + extra
        return try Self.journal(try Self.limits(6), stored)
    }

    static func activationRefusal(
        record: CheckpointRecord,
        confirming recordID: CheckpointID,
        journal: CheckpointJournal,
        graph: GraphDocument
    ) -> CheckpointRefusal? {
        do throws(CheckpointRefusal) {
            _ = try RestoreActivation.make(
                record: record,
                confirmedBy: RestoreConfirmation.make(recordID: recordID),
                journal: journal,
                graph: graph
            )
        } catch {
            return error
        }
        return nil
    }

    @Test func aLoadedCheckpointIsInactiveAndCarriesItsRecord() throws {
        let record = try Self.record(1, .manual, id: 11)
        let disposition = RestoreDisposition.loaded(record)
        #expect(disposition == .inactive(record))
        #expect(disposition != .active)
        #expect(RestoreDisposition.inactive(record) != .inactive(try Self.record(2)))
    }

    @Test func aConfirmationNamesTheRecordItWasMadeFor() {
        #expect(RestoreConfirmation.make(recordID: CheckpointID(31)).recordID == CheckpointID(31))
        let first = RestoreConfirmation.make(recordID: CheckpointID(31))
        #expect(first != RestoreConfirmation.make(recordID: CheckpointID(32)))
    }

    @Test func activationForcesRequiresReviewAndKeepsEveryOtherGraphField() throws {
        let journal = try Self.activationJournal()
        let target = try #require(journal.records.first)
        let armed = try Self.graph(requiresReview: false)
        let activation = try RestoreActivation.make(
            record: target,
            confirmedBy: RestoreConfirmation.make(recordID: target.id),
            journal: journal,
            graph: armed
        )
        #expect(activation.graph.requiresReview)
        var expected = armed
        expected.requiresReview = true
        #expect(activation.graph == expected)
        #expect(activation.record == target)
        #expect(activation.disposition == .active)
        #expect(!armed.requiresReview)
    }

    @Test func activationKeepsAnAlreadyFlaggedGraphFlagged() throws {
        let journal = try Self.activationJournal()
        let target = try #require(journal.records.first)
        let flagged = try Self.graph(requiresReview: true)
        let activation = try RestoreActivation.make(
            record: target,
            confirmedBy: RestoreConfirmation.make(recordID: target.id),
            journal: journal,
            graph: flagged
        )
        #expect(activation.graph == flagged)
    }

    @Test func activationRefusesARecordThatIsNotInTheJournalAndAnEmptyJournal() throws {
        let journal = try Self.activationJournal()
        let stranger = try Self.record(1, .manual, id: 99)
        let graph = try Self.graph(requiresReview: false)
        #expect(Self.activationRefusal(record: stranger, confirming: stranger.id, journal: journal, graph: graph)
            == .recordNotInJournal)
        let empty = CheckpointJournal.make(limits: try Self.limits())
        let target = try #require(journal.records.first)
        #expect(Self.activationRefusal(record: target, confirming: target.id, journal: empty, graph: graph)
            == .recordNotInJournal)
    }

    @Test func activationRefusesACopyThatDiffersFromTheStoredRecordUnderTheSameID() throws {
        let journal = try Self.activationJournal()
        let graph = try Self.graph(requiresReview: false)
        let copies = [
            try Self.record(1, .manual, id: 11, label: "edited"),
            try Self.record(1, .manual, bytes: 11, id: 11),
            try Self.record(1, .manual, id: 11, seed: 77),
            try Self.record(1, .autosave, id: 11)
        ]
        for copy in copies {
            #expect(Self.activationRefusal(record: copy, confirming: copy.id, journal: journal, graph: graph)
                == .recordNotInJournal)
        }
    }

    @Test func activationRefusesAConfirmationForAnotherRecordWithNonDefaultIDs() throws {
        let journal = try Self.activationJournal()
        let target = try #require(journal.records.first)
        let graph = try Self.graph(requiresReview: false)
        #expect(Self.activationRefusal(record: target, confirming: CheckpointID(205), journal: journal, graph: graph)
            == .confirmationMismatch(expected: CheckpointID(11), found: CheckpointID(205)))
        let other = try #require(journal.records.last)
        #expect(Self.activationRefusal(record: target, confirming: other.id, journal: journal, graph: graph)
            == .confirmationMismatch(expected: CheckpointID(11), found: CheckpointID(12)))
    }

    @Test func activationNeedsThePreRestoreCheckpointToBeTheNewestJournalRecord() throws {
        let graph = try Self.graph(requiresReview: false)
        let target = try Self.record(1, .manual, id: 11)
        let alone = try Self.journal(try Self.limits(), [target])
        #expect(Self.activationRefusal(record: target, confirming: target.id, journal: alone, graph: graph)
            == .preRestoreMissing)
        let autosaveLast = try Self.journal(try Self.limits(), [
            target,
            try Self.record(2, .preRestore, id: 12),
            try Self.record(3, .autosave, id: 13)
        ])
        #expect(Self.activationRefusal(record: target, confirming: target.id, journal: autosaveLast, graph: graph)
            == .preRestoreMissing)
        let manualLast = try Self.journal(try Self.limits(), [try Self.record(0, .preRestore, id: 10), target])
        #expect(Self.activationRefusal(record: target, confirming: target.id, journal: manualLast, graph: graph)
            == .preRestoreMissing)
    }

    @Test func aPreRestoreCheckpointMustBeNewerThanTheRestoredRecord() throws {
        let graph = try Self.graph(requiresReview: false)
        let selfRestore = try Self.record(2, .preRestore, id: 12)
        let journal = try Self.journal(try Self.limits(), [try Self.record(1, .manual, id: 11), selfRestore])
        #expect(Self.activationRefusal(record: selfRestore, confirming: selfRestore.id, journal: journal, graph: graph)
            == .preRestoreMissing)
        let newer = try Self.journal(try Self.limits(), [selfRestore, try Self.record(3, .preRestore, id: 13)])
        #expect(Self.activationRefusal(record: selfRestore, confirming: selfRestore.id, journal: newer, graph: graph)
            == nil)
    }

    @Test func activationRefusesAnUnknownRecordBeforeAMismatchedConfirmation() throws {
        let journal = try Self.activationJournal()
        let stranger = try Self.record(1, .manual, id: 99)
        let graph = try Self.graph(requiresReview: false)
        #expect(Self.activationRefusal(record: stranger, confirming: CheckpointID(5), journal: journal, graph: graph)
            == .recordNotInJournal)
    }

    @Test func activationRefusesAMismatchedConfirmationBeforeAMissingPreRestore() throws {
        let target = try Self.record(1, .manual, id: 11)
        let journal = try Self.journal(try Self.limits(), [target])
        let graph = try Self.graph(requiresReview: false)
        #expect(Self.activationRefusal(record: target, confirming: CheckpointID(5), journal: journal, graph: graph)
            == .confirmationMismatch(expected: CheckpointID(11), found: CheckpointID(5)))
    }

    @Test func activationRefusesAnUnknownRecordBeforeAMissingPreRestore() throws {
        let known = try Self.record(1, .manual, id: 11)
        let journal = try Self.journal(try Self.limits(), [known])
        let stranger = try Self.record(1, .manual, id: 99)
        let graph = try Self.graph(requiresReview: false)
        #expect(Self.activationRefusal(record: stranger, confirming: stranger.id, journal: journal, graph: graph)
            == .recordNotInJournal)
    }

    @Test func activationFollowsTheRealAppendOfAPreRestoreCheckpoint() throws {
        var journal = try Self.journal(try Self.limits(), [try Self.record(1, .manual, id: 11)])
        let target = try #require(journal.records.first)
        let graph = try Self.graph(requiresReview: false)
        #expect(Self.activationRefusal(record: target, confirming: target.id, journal: journal, graph: graph)
            == .preRestoreMissing)
        _ = try journal.append(try Self.record(try journal.nextOrdinal(), .preRestore, id: 12))
        #expect(Self.activationRefusal(record: target, confirming: target.id, journal: journal, graph: graph) == nil)
    }

    @Test func aRefusedActivationLeavesTheJournalAndTheGraphUnchanged() throws {
        let journal = try Self.activationJournal(extra: [try Self.record(3, .autosave, id: 13)])
        let target = try #require(journal.records.first)
        let graph = try Self.graph(requiresReview: false)
        let journalBefore = journal
        let graphBefore = graph
        #expect(Self.activationRefusal(record: target, confirming: CheckpointID(1), journal: journal, graph: graph)
            != nil)
        #expect(journal == journalBefore)
        #expect(graph == graphBefore)
        #expect(!graph.requiresReview)
    }
}
