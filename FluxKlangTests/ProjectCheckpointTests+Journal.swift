import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectCheckpointTests {
    @Test func aNewJournalIsEmptyWithZeroBytesAndKeepsItsLimits() throws {
        let limits = try Self.limits(3, total: 90, record: 30)
        let journal = CheckpointJournal.make(limits: limits)
        #expect(journal.records.isEmpty)
        #expect(journal.totalBytes == 0)
        #expect(journal.limits == limits)
    }

    @Test func appendKeepsTheRecordsAscendingAndReportsNoEviction() throws {
        var journal = CheckpointJournal.make(limits: try Self.limits())
        let first = try journal.append(try Self.record(2))
        let second = try journal.append(try Self.record(5))
        let third = try journal.append(try Self.record(6))
        #expect(first.evicted.isEmpty)
        #expect(second.evicted.isEmpty)
        #expect(third.evicted.isEmpty)
        #expect(Self.ordinals(journal) == [2, 5, 6])
        #expect(journal.totalBytes == 30)
    }

    @Test func anOrdinalEqualToOrBelowTheNewestIsRefusedAndOneAboveIsAccepted() throws {
        var journal = try Self.journal(try Self.limits(), [try Self.record(5), try Self.record(8)])
        #expect(Self.refusal(of: &journal, appending: try Self.record(8, id: 300))
            == .ordinalNotIncreasing(ordinal: 8, newest: 8))
        #expect(Self.refusal(of: &journal, appending: try Self.record(7, id: 301))
            == .ordinalNotIncreasing(ordinal: 7, newest: 8))
        #expect(Self.refusal(of: &journal, appending: try Self.record(0, id: 302))
            == .ordinalNotIncreasing(ordinal: 0, newest: 8))
        _ = try journal.append(try Self.record(9, id: 303))
        #expect(Self.ordinals(journal) == [5, 8, 9])
    }

    @Test func anEmptyJournalAcceptsOrdinalZeroAndTheLargestOrdinal() throws {
        var zero = CheckpointJournal.make(limits: try Self.limits())
        _ = try zero.append(try Self.record(0))
        #expect(Self.ordinals(zero) == [0])
        var largest = CheckpointJournal.make(limits: try Self.limits())
        _ = try largest.append(try Self.record(UInt64.max, id: 5))
        #expect(Self.ordinals(largest) == [UInt64.max])
        #expect(Self.refusal(of: &largest, appending: try Self.record(UInt64.max, id: 6))
            == .ordinalNotIncreasing(ordinal: UInt64.max, newest: UInt64.max))
        #expect(Self.refusal(of: &largest, appending: try Self.record(0, id: 7))
            == .ordinalNotIncreasing(ordinal: 0, newest: UInt64.max))
    }

    @Test func theNextOrdinalStartsAtZeroFollowsTheNewestAndRefusesOverflow() throws {
        var journal = CheckpointJournal.make(limits: try Self.limits())
        #expect(try journal.nextOrdinal() == 0)
        _ = try journal.append(try Self.record(41))
        #expect(try journal.nextOrdinal() == 42)
        var nearEnd = CheckpointJournal.make(limits: try Self.limits())
        _ = try nearEnd.append(try Self.record(UInt64.max - 1))
        #expect(try nearEnd.nextOrdinal() == UInt64.max)
        _ = try nearEnd.append(try Self.record(UInt64.max, id: 1))
        #expect(throws: CheckpointRefusal.ordinalOverflow) { try nearEnd.nextOrdinal() }
    }

    @Test func aDuplicateIDIsRefusedWithTheJournalUnchanged() throws {
        var journal = try Self.journal(try Self.limits(), [try Self.record(1, id: 77), try Self.record(2, id: 78)])
        #expect(Self.refusal(of: &journal, appending: try Self.record(3, id: 77)) == .duplicateID(CheckpointID(77)))
        #expect(Self.refusal(of: &journal, appending: try Self.record(3, id: 78)) == .duplicateID(CheckpointID(78)))
        _ = try journal.append(try Self.record(3, id: 79))
        #expect(Self.ordinals(journal) == [1, 2, 3])
    }

    @Test func aRecordAtTheRecordLimitIsAcceptedAndOneByteOverIsRefused() throws {
        let limits = try Self.limits(4, total: 1_000, record: 200)
        var journal = CheckpointJournal.make(limits: limits)
        #expect(Self.refusal(of: &journal, appending: try Self.record(1, bytes: 201))
            == .recordTooLarge(byteCount: 201, limit: 200))
        _ = try journal.append(try Self.record(1, bytes: 200))
        #expect(journal.totalBytes == 200)
        #expect(Self.refusal(of: &journal, appending: try Self.record(2, bytes: 4_000))
            == .recordTooLarge(byteCount: 4_000, limit: 200))
    }

    @Test func aZeroByteRecordIsLegalInAnEmptyJournalAndAtAnyCap() throws {
        var journal = CheckpointJournal.make(limits: try Self.limits(1, total: 1, record: 1))
        _ = try journal.append(try Self.record(1, bytes: 0))
        #expect(journal.totalBytes == 0)
        let eviction = try journal.append(try Self.record(2, bytes: 0))
        #expect(eviction.evicted.map(\.ordinal) == [1])
        #expect(Self.ordinals(journal) == [2])
    }

    @Test func appendRefusesTheOrdinalBeforeADuplicateID() throws {
        var journal = try Self.journal(try Self.limits(), [try Self.record(5, id: 50)])
        let both = try Self.record(4, id: 50)
        #expect(Self.refusal(of: &journal, appending: both) == .ordinalNotIncreasing(ordinal: 4, newest: 5))
    }

    @Test func appendRefusesADuplicateIDBeforeAnOversizedRecord() throws {
        let limits = try Self.limits(4, total: 1_000, record: 100)
        var journal = try Self.journal(limits, [try Self.record(5, id: 50)])
        let both = try Self.record(6, bytes: 101, id: 50)
        #expect(Self.refusal(of: &journal, appending: both) == .duplicateID(CheckpointID(50)))
    }

    @Test func appendRefusesAnOversizedRecordBeforeCannotMakeRoom() throws {
        let limits = try Self.limits(2, total: 1_000, record: 100)
        var journal = try Self.journal(limits, [try Self.record(1, .manual), try Self.record(2, .preMigration)])
        let both = try Self.record(3, .autosave, bytes: 101)
        #expect(Self.refusal(of: &journal, appending: both) == .recordTooLarge(byteCount: 101, limit: 100))
        let roomOnly = try Self.record(3, .autosave, bytes: 100)
        #expect(Self.refusal(of: &journal, appending: roomOnly) == .cannotMakeRoom)
    }

    @Test func restoreAcceptsAnEmptyListAndAFullValidList() throws {
        let limits = try Self.limits(3, total: 30, record: 10)
        #expect(try CheckpointJournal.restore(limits: limits, records: []).records.isEmpty)
        let full = [try Self.record(1), try Self.record(3), try Self.record(9)]
        let journal = try CheckpointJournal.restore(limits: limits, records: full)
        #expect(journal.records == full)
        #expect(journal.totalBytes == 30)
    }

    @Test func restoreRefusesOneRecordOverTheRecordCap() throws {
        let limits = try Self.limits(3, total: 1_000, record: 100)
        let four = [try Self.record(1), try Self.record(2), try Self.record(3), try Self.record(4)]
        #expect(throws: CheckpointRefusal.invalidJournal(.tooManyRecords(4))) {
            try CheckpointJournal.restore(limits: limits, records: four)
        }
        #expect(try CheckpointJournal.restore(limits: limits, records: Array(four.prefix(3))).records.count == 3)
    }

    @Test func restoreRefusesARecordOverTheRecordLimitButAcceptsEquality() throws {
        let limits = try Self.limits(3, total: 1_000, record: 100)
        let restored = try CheckpointJournal.restore(limits: limits, records: [try Self.record(1, bytes: 100)])
        #expect(restored.records.count == 1)
        #expect(throws: CheckpointRefusal.invalidJournal(.recordOverLimit(CheckpointID(101)))) {
            try CheckpointJournal.restore(limits: limits, records: [try Self.record(1, bytes: 101)])
        }
    }

    @Test func restoreRefusesATotalOverTheCapButAcceptsEquality() throws {
        let limits = try Self.limits(3, total: 30, record: 20)
        let atCap = [try Self.record(1, bytes: 20), try Self.record(2, bytes: 10)]
        #expect(try CheckpointJournal.restore(limits: limits, records: atCap).totalBytes == 30)
        let over = [try Self.record(1, bytes: 20), try Self.record(2, bytes: 11)]
        #expect(throws: CheckpointRefusal.invalidJournal(.totalOverCap(31))) {
            try CheckpointJournal.restore(limits: limits, records: over)
        }
    }

    @Test func restoreRefusesDuplicateIDsAndNonIncreasingOrdinals() throws {
        let limits = try Self.limits()
        #expect(throws: CheckpointRefusal.invalidJournal(.duplicateID(CheckpointID(5)))) {
            try CheckpointJournal.restore(
                limits: limits,
                records: [try Self.record(1, id: 5), try Self.record(2, id: 5)]
            )
        }
        #expect(throws: CheckpointRefusal.invalidJournal(.ordinalNotIncreasing(index: 1))) {
            try CheckpointJournal.restore(limits: limits, records: [try Self.record(2), try Self.record(2, id: 9)])
        }
        #expect(throws: CheckpointRefusal.invalidJournal(.ordinalNotIncreasing(index: 2))) {
            let records = [try Self.record(1), try Self.record(5), try Self.record(3)]
            _ = try CheckpointJournal.restore(limits: limits, records: records)
        }
    }

    @Test func aRestoredJournalAppliesTheSameRulesAsABuiltOne() throws {
        let limits = try Self.limits(2, total: 1_000, record: 100)
        var restored = try Self.journal(limits, [try Self.record(1), try Self.record(2)])
        var built = CheckpointJournal.make(limits: limits)
        _ = try built.append(try Self.record(1))
        _ = try built.append(try Self.record(2))
        #expect(restored == built)
        let eviction = try restored.append(try Self.record(3))
        #expect(eviction.evicted.map(\.ordinal) == [1])
    }

    @Test func validateStateAcceptsAnEmptyAndAFilledJournal() throws {
        try CheckpointJournal.make(limits: try Self.limits()).validateState()
        try Self.journal(try Self.limits(), [try Self.record(1), try Self.record(2)]).validateState()
    }
}
