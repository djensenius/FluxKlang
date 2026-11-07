import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectCheckpointTests {
    @Test func sameContentIgnoresIdOrdinalLabelReasonAndRevision() throws {
        let first = try CheckpointRecord.make(
            id: CheckpointID(1),
            ordinal: 1,
            revision: ContractRevision(0),
            reason: .manual,
            digest: Array(repeating: 9, count: 32),
            byteCount: 40,
            label: "first"
        )
        let second = try CheckpointRecord.make(
            id: CheckpointID(2),
            ordinal: 2,
            revision: ContractRevision(7),
            reason: .autosave,
            digest: Array(repeating: 9, count: 32),
            byteCount: 40,
            label: "second"
        )
        #expect(first.isSameContent(as: second))
        #expect(second.isSameContent(as: first))
        #expect(first != second)
    }

    @Test func sameContentComparesTheWholeDigest() throws {
        let base = try Self.record(1, seed: 5)
        var changedLast = Array(repeating: UInt8(5), count: 32)
        changedLast[31] = 6
        var changedFirst = Array(repeating: UInt8(5), count: 32)
        changedFirst[0] = 6
        for digest in [changedLast, changedFirst] {
            let other = try CheckpointRecord.make(
                id: CheckpointID(1),
                ordinal: 1,
                revision: ContractRevision(0),
                reason: .autosave,
                digest: digest,
                byteCount: 10,
                label: ""
            )
            #expect(!base.isSameContent(as: other))
            #expect(!other.isSameContent(as: base))
        }
    }

    @Test func sameContentComparesTheByteCount() throws {
        let base = try Self.record(1, bytes: 10, seed: 5)
        #expect(!base.isSameContent(as: try Self.record(1, bytes: 11, seed: 5)))
        #expect(!base.isSameContent(as: try Self.record(1, bytes: 9, seed: 5)))
        #expect(base.isSameContent(as: try Self.record(2, bytes: 10, seed: 5)))
    }

    @Test func zeroByteRecordsCompareByDigestAlone() throws {
        let empty = try Self.record(1, bytes: 0, seed: 3)
        #expect(empty.isSameContent(as: try Self.record(2, .manual, bytes: 0, seed: 3, label: "x")))
        #expect(!empty.isSameContent(as: try Self.record(3, bytes: 0, seed: 4)))
        #expect(!empty.isSameContent(as: try Self.record(4, bytes: 1, seed: 3)))
    }

    @Test func newestRecordWithTheSameContentIsTheHighestOrdinal() throws {
        let stored = [
            try Self.record(1, seed: 7),
            try Self.record(2, seed: 8),
            try Self.record(3, seed: 7),
            try Self.record(4, seed: 9)
        ]
        let journal = try Self.journal(try Self.limits(), stored)
        let found = try #require(journal.newestRecord(sameContentAs: try Self.record(50, seed: 7)))
        #expect(found.ordinal == 3)
        let unique = try #require(journal.newestRecord(sameContentAs: try Self.record(51, seed: 8)))
        #expect(unique.ordinal == 2)
        #expect(journal.newestRecord(sameContentAs: try Self.record(52, seed: 99)) == nil)
    }

    @Test func anEmptyJournalFindsNoContentMatch() throws {
        let journal = CheckpointJournal.make(limits: try Self.limits())
        #expect(journal.newestRecord(sameContentAs: try Self.record(1, bytes: 0)) == nil)
    }

    @Test func aMatchIgnoresIdAndLabelOfTheStoredRecord() throws {
        let stored = try Self.record(5, .manual, bytes: 20, id: 900, seed: 4, label: "kept")
        let journal = try Self.journal(try Self.limits(), [stored])
        let probe = try Self.record(1, .autosave, bytes: 20, id: 1, seed: 4, label: "probe")
        #expect(journal.newestRecord(sameContentAs: probe) == stored)
    }
}
