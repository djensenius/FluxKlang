import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectCheckpointTests {
    static func rawIDs(_ ids: [CheckpointID]) -> [UInt64] {
        ids.map(\.rawValue)
    }

    @Test func aPlanForAnEmptyJournalEvictsAndKeepsNothing() throws {
        let journal = CheckpointJournal.make(limits: try Self.limits(1, total: 10, record: 10))
        let plan = try CheckpointRetention.plan(journal: journal, incoming: try Self.record(0, bytes: 10))
        #expect(plan.evict.isEmpty)
        #expect(plan.keep.isEmpty)
    }

    @Test func theRecordCapEvictsNothingAtNAndTheOldestAtNPlusOne() throws {
        let limits = try Self.limits(3)
        let two = try Self.journal(limits, [try Self.record(1), try Self.record(2)])
        let atCap = try CheckpointRetention.plan(journal: two, incoming: try Self.record(3))
        #expect(Self.rawIDs(atCap.evict).isEmpty)
        #expect(Self.rawIDs(atCap.keep) == [101, 102])
        let three = try Self.journal(limits, [try Self.record(1), try Self.record(2), try Self.record(3)])
        let over = try CheckpointRetention.plan(journal: three, incoming: try Self.record(4))
        #expect(Self.rawIDs(over.evict) == [101])
        #expect(Self.rawIDs(over.keep) == [102, 103])
    }

    @Test func evictionFollowsTheOrdinalNotTheIdOrTheListPosition() throws {
        let limits = try Self.limits(3, total: 100, record: 100)
        let stored = [
            try Self.record(1, bytes: 30, id: 900),
            try Self.record(2, bytes: 30, id: 800),
            try Self.record(3, bytes: 30, id: 700)
        ]
        let journal = try Self.journal(limits, stored)
        let plan = try CheckpointRetention.plan(journal: journal, incoming: try Self.record(4, bytes: 60, id: 1))
        #expect(Self.rawIDs(plan.evict) == [900, 800])
        #expect(Self.rawIDs(plan.keep) == [700])
    }

    @Test func theTotalCapEvictsNothingAtNAndOneRecordAtNPlusOne() throws {
        let limits = try Self.limits(8, total: 100, record: 60)
        let journal = try Self.journal(limits, [try Self.record(1, bytes: 40), try Self.record(2, bytes: 40)])
        let atCap = try CheckpointRetention.plan(journal: journal, incoming: try Self.record(3, bytes: 20))
        #expect(atCap.evict.isEmpty)
        let over = try CheckpointRetention.plan(journal: journal, incoming: try Self.record(3, bytes: 21))
        #expect(Self.rawIDs(over.evict) == [101])
        #expect(Self.rawIDs(over.keep) == [102])
    }

    @Test func theTotalCapKeepsEvictingUntilTheIncomingRecordFits() throws {
        let limits = try Self.limits(8, total: 100, record: 100)
        let stored = [try Self.record(1, bytes: 30), try Self.record(2, bytes: 30), try Self.record(3, bytes: 30)]
        let journal = try Self.journal(limits, stored)
        let one = try CheckpointRetention.plan(journal: journal, incoming: try Self.record(4, bytes: 40))
        #expect(Self.rawIDs(one.evict) == [101])
        let two = try CheckpointRetention.plan(journal: journal, incoming: try Self.record(4, bytes: 41))
        #expect(Self.rawIDs(two.evict) == [101, 102])
        let all = try CheckpointRetention.plan(journal: journal, incoming: try Self.record(4, bytes: 100))
        #expect(Self.rawIDs(all.evict) == [101, 102, 103])
        #expect(all.keep.isEmpty)
    }

    @Test func theRecordCapAndTheTotalCapCanBindTogether() throws {
        let limits = try Self.limits(3, total: 100, record: 100)
        let stored = [try Self.record(1, bytes: 10), try Self.record(2, bytes: 10), try Self.record(3, bytes: 70)]
        let journal = try Self.journal(limits, stored)
        let countOnly = try CheckpointRetention.plan(journal: journal, incoming: try Self.record(4, bytes: 15))
        #expect(Self.rawIDs(countOnly.evict) == [101])
        let both = try CheckpointRetention.plan(journal: journal, incoming: try Self.record(4, bytes: 40))
        #expect(Self.rawIDs(both.evict) == [101, 102, 103])
    }

    @Test func theNewestManualAndTheNewestPreMigrationSurviveWhileOlderAutosavesAreEvicted() throws {
        let limits = try Self.limits(4)
        let stored = [
            try Self.record(1, .manual),
            try Self.record(2, .preMigration),
            try Self.record(3, .autosave),
            try Self.record(4, .autosave)
        ]
        var journal = try Self.journal(limits, stored)
        let first = try journal.append(try Self.record(5, .autosave))
        #expect(first.evicted.map(\.ordinal) == [3])
        let second = try journal.append(try Self.record(6, .autosave))
        #expect(second.evicted.map(\.ordinal) == [4])
        #expect(Self.ordinals(journal) == [1, 2, 5, 6])
    }

    @Test func onlyTheNewestRecordOfEachPinnedReasonIsPinned() throws {
        let limits = try Self.limits(4)
        let stored = [
            try Self.record(1, .manual),
            try Self.record(2, .manual),
            try Self.record(3, .preMigration),
            try Self.record(4, .preMigration)
        ]
        var journal = try Self.journal(limits, stored)
        let first = try journal.append(try Self.record(5, .autosave))
        #expect(first.evicted.map(\.ordinal) == [1])
        let second = try journal.append(try Self.record(6, .autosave))
        #expect(second.evicted.map(\.ordinal) == [3])
        #expect(Self.ordinals(journal) == [2, 4, 5, 6])
    }

    @Test func anIncomingManualReleasesThePreviousManualPin() throws {
        let limits = try Self.limits(2)
        let stored = [try Self.record(1, .manual), try Self.record(2, .autosave)]
        var kept = try Self.journal(limits, stored)
        #expect(try kept.append(try Self.record(3, .autosave)).evicted.map(\.ordinal) == [2])
        #expect(Self.ordinals(kept) == [1, 3])
        var released = try Self.journal(limits, stored)
        #expect(try released.append(try Self.record(3, .manual)).evicted.map(\.ordinal) == [1])
        #expect(Self.ordinals(released) == [2, 3])
    }

    @Test func anIncomingPreMigrationReleasesThePreviousPreMigrationPin() throws {
        let limits = try Self.limits(2)
        let stored = [try Self.record(1, .preMigration), try Self.record(2, .autosave)]
        var journal = try Self.journal(limits, stored)
        #expect(try journal.append(try Self.record(3, .preMigration)).evicted.map(\.ordinal) == [1])
        #expect(Self.ordinals(journal) == [2, 3])
    }

    @Test func preRestoreAndAutosaveRecordsAreNeverPinned() throws {
        let limits = try Self.limits(2)
        var journal = try Self.journal(limits, [try Self.record(1, .preRestore), try Self.record(2, .autosave)])
        #expect(try journal.append(try Self.record(3, .autosave)).evicted.map(\.ordinal) == [1])
        #expect(try journal.append(try Self.record(4, .preRestore)).evicted.map(\.ordinal) == [2])
    }

    @Test func pinsThatAloneFillTheRecordCapRefuseCannotMakeRoomAndChangeNothing() throws {
        let limits = try Self.limits(2)
        var journal = try Self.journal(limits, [try Self.record(1, .manual), try Self.record(2, .preMigration)])
        let before = journal
        #expect(Self.refusal(of: &journal, appending: try Self.record(3, .autosave)) == .cannotMakeRoom)
        #expect(Self.refusal(of: &journal, appending: try Self.record(3, .preRestore)) == .cannotMakeRoom)
        #expect(throws: CheckpointRefusal.cannotMakeRoom) {
            try CheckpointRetention.plan(journal: before, incoming: try Self.record(3, .autosave))
        }
        #expect(journal == before)
    }

    @Test func pinsThatAloneFillTheTotalCapRefuseAtNPlusOneAndAcceptAtN() throws {
        let limits = try Self.limits(4, total: 100, record: 60)
        let stored = [try Self.record(1, .manual, bytes: 60), try Self.record(2, .preMigration, bytes: 30)]
        var journal = try Self.journal(limits, stored)
        #expect(Self.refusal(of: &journal, appending: try Self.record(3, .autosave, bytes: 11)) == .cannotMakeRoom)
        let eviction = try journal.append(try Self.record(3, .autosave, bytes: 10))
        #expect(eviction.evicted.isEmpty)
        #expect(journal.totalBytes == 100)
    }

    @Test func aRefusedAppendNeverEvictsAnUnpinnedRecordOnTheWay() throws {
        let limits = try Self.limits(3, total: 100, record: 100)
        let stored = [
            try Self.record(1, .manual, bytes: 60),
            try Self.record(2, .autosave, bytes: 10),
            try Self.record(3, .autosave, bytes: 10)
        ]
        var journal = try Self.journal(limits, stored)
        #expect(Self.refusal(of: &journal, appending: try Self.record(4, .autosave, bytes: 50)) == .cannotMakeRoom)
        #expect(Self.ordinals(journal) == [1, 2, 3])
        let fits = try journal.append(try Self.record(4, .autosave, bytes: 40))
        #expect(fits.evicted.map(\.ordinal) == [2, 3])
    }

    @Test func smallRecordCapsJamUntilAPinnedReasonArrives() throws {
        let one = try Self.limits(1)
        var pinned = try Self.journal(one, [try Self.record(1, .manual)])
        #expect(Self.refusal(of: &pinned, appending: try Self.record(2, .autosave)) == .cannotMakeRoom)
        #expect(try pinned.append(try Self.record(2, .manual)).evicted.map(\.ordinal) == [1])
        var loose = try Self.journal(one, [try Self.record(1, .autosave)])
        #expect(try loose.append(try Self.record(2, .autosave)).evicted.map(\.ordinal) == [1])
        let two = try Self.limits(2)
        var pair = try Self.journal(two, [try Self.record(1, .manual), try Self.record(2, .preMigration)])
        #expect(try pair.append(try Self.record(3, .manual)).evicted.map(\.ordinal) == [1])
        #expect(try pair.append(try Self.record(4, .preMigration)).evicted.map(\.ordinal) == [2])
        #expect(Self.ordinals(pair) == [3, 4])
    }

    @Test func evictedRecordsAreReturnedWithTheirFullValuesOldestFirst() throws {
        let limits = try Self.limits(3, total: 100, record: 100)
        let stored = [
            try Self.record(1, .autosave, bytes: 30, id: 9, seed: 1, label: "one"),
            try Self.record(2, .preRestore, bytes: 30, id: 8, seed: 2, label: "two"),
            try Self.record(3, .autosave, bytes: 30, id: 7, seed: 3, label: "three")
        ]
        var journal = try Self.journal(limits, stored)
        let eviction = try journal.append(try Self.record(4, bytes: 60))
        #expect(eviction.evicted == [stored[0], stored[1]])
        #expect(journal.records.map(\.ordinal) == [3, 4])
    }

    @Test func appendAppliesExactlyTheRetentionPlan() throws {
        let limits = try Self.limits(3, total: 100, record: 100)
        let stored = [try Self.record(1, .manual, bytes: 20), try Self.record(2), try Self.record(3)]
        var journal = try Self.journal(limits, stored)
        let incoming = try Self.record(4, bytes: 20, id: 555)
        let plan = try CheckpointRetention.plan(journal: journal, incoming: incoming)
        let eviction = try journal.append(incoming)
        #expect(eviction.evicted.map(\.id) == plan.evict)
        #expect(journal.records.map(\.id) == plan.keep + [incoming.id])
        #expect(Self.rawIDs(plan.evict) == [102])
    }

    @Test func aPlanRefusesInAdmissionOrderAndReportsTheOrdinalFirst() throws {
        let journal = try Self.journal(try Self.limits(), [try Self.record(5, id: 50)])
        #expect(throws: CheckpointRefusal.ordinalNotIncreasing(ordinal: 4, newest: 5)) {
            try CheckpointRetention.plan(journal: journal, incoming: try Self.record(4, id: 50))
        }
        #expect(throws: CheckpointRefusal.duplicateID(CheckpointID(50))) {
            try CheckpointRetention.plan(journal: journal, incoming: try Self.record(6, id: 50))
        }
        #expect(throws: CheckpointRefusal.recordTooLarge(byteCount: 501, limit: 500)) {
            try CheckpointRetention.plan(journal: journal, incoming: try Self.record(6, bytes: 501))
        }
    }

    @Test func aJournalOfTheLargestRecordsFillsTheTotalCapExactlyAndEvictsOneAtNPlusOne() throws {
        let limits = try CheckpointLimits.make(maxRecords: 256, maxTotalBytes: 1 << 40, maxRecordBytes: 1 << 32)
        let huge = 1 << 32
        let full = try (0..<256).map { try Self.record(UInt64($0), bytes: huge) }
        var journal = try Self.journal(limits, full)
        #expect(journal.totalBytes == 1 << 40)
        let eviction = try journal.append(try Self.record(256, bytes: huge))
        #expect(eviction.evicted.map(\.ordinal) == [0])
        #expect(journal.totalBytes == 1 << 40)
        #expect(journal.records.count == 256)
        let small = try Self.journal(limits, Array(full.prefix(255)))
        let plan = try CheckpointRetention.plan(journal: small, incoming: try Self.record(256, bytes: huge))
        #expect(plan.evict.isEmpty)
    }

    @Test func aFullRecordCapOfTwoHundredFiftySixEvictsOnlyTheOldestAtNPlusOne() throws {
        let limits = try CheckpointLimits.make(maxRecords: 256, maxTotalBytes: 1 << 40, maxRecordBytes: 1 << 32)
        let full = try (0..<256).map { try Self.record(UInt64($0), bytes: 0) }
        var journal = try Self.journal(limits, full)
        let eviction = try journal.append(try Self.record(256, bytes: 0))
        #expect(eviction.evicted.map(\.ordinal) == [0])
        #expect(journal.records.first?.ordinal == 1)
        #expect(journal.records.last?.ordinal == 256)
        #expect(journal.records.count == 256)
    }

    @Test func aLongAppendSequenceKeepsEveryInvariantAndEvictsOldestFirst() throws {
        var journal = CheckpointJournal.make(limits: try Self.limits(3))
        var evictedOrdinals: [[UInt64]] = []
        for ordinal in UInt64(0)..<6 {
            let eviction = try journal.append(try Self.record(ordinal))
            evictedOrdinals.append(eviction.evicted.map(\.ordinal))
        }
        #expect(evictedOrdinals == [[], [], [], [0], [1], [2]])
        #expect(Self.ordinals(journal) == [3, 4, 5])
    }

    @Test func mixedSizesNeverBreakTheCapsAndEveryRefusalChangesNothing() throws {
        let limits = try Self.limits(4, total: 150, record: 90)
        let sizes = [30, 60, 10, 90, 20, 70, 90, 5, 90, 90, 1, 0]
        let reasons: [CheckpointReason] = [.autosave, .manual, .autosave, .autosave, .preMigration, .autosave]
        var journal = CheckpointJournal.make(limits: limits)
        var refused = 0
        for (index, size) in sizes.enumerated() {
            let record = try Self.record(UInt64(index), reasons[index % reasons.count], bytes: size)
            if Self.refusal(of: &journal, appending: record) != nil { refused += 1 }
            #expect(journal.totalBytes <= 150)
            #expect(journal.records.count <= 4)
            #expect(Self.ordinals(journal) == Self.ordinals(journal).sorted())
            try journal.validateState()
        }
        #expect(refused == 1)
        #expect(Self.ordinals(journal) == [7, 9, 10, 11])
        #expect(journal.totalBytes == 96)
    }
}
