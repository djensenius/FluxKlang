import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct ProjectCheckpointTests {
    static let digestBytes = 32

    static func limits(_ records: Int = 4, total: Int = 1_000, record: Int = 500) throws -> CheckpointLimits {
        try CheckpointLimits.make(maxRecords: records, maxTotalBytes: total, maxRecordBytes: record)
    }

    static func record(
        _ ordinal: UInt64,
        _ reason: CheckpointReason = .autosave,
        bytes: Int = 10,
        id: UInt64? = nil,
        seed: UInt8? = nil,
        label: String = ""
    ) throws -> CheckpointRecord {
        try CheckpointRecord.make(
            id: CheckpointID(id ?? ordinal &+ 100),
            ordinal: ordinal,
            revision: ContractRevision(0),
            reason: reason,
            digest: Array(repeating: seed ?? UInt8(truncatingIfNeeded: ordinal), count: digestBytes),
            byteCount: bytes,
            label: label
        )
    }

    static func journal(_ limits: CheckpointLimits, _ records: [CheckpointRecord]) throws -> CheckpointJournal {
        try CheckpointJournal.restore(limits: limits, records: records)
    }

    static func ordinals(_ journal: CheckpointJournal) -> [UInt64] {
        journal.records.map(\.ordinal)
    }

    /// Appends and returns the typed refusal, asserting the whole journal is unchanged after it.
    static func refusal(of journal: inout CheckpointJournal, appending record: CheckpointRecord) -> CheckpointRefusal? {
        let before = journal
        do throws(CheckpointRefusal) {
            _ = try journal.append(record)
        } catch {
            #expect(journal == before)
            return error
        }
        return nil
    }

    static func graph(requiresReview: Bool) throws -> GraphDocument {
        GraphDocument(id: try GraphID("graph-r2"), label: "Restore me", requiresReview: requiresReview)
    }

    @Test func limitsAcceptTheHardCeilingsAndTheFloors() throws {
        let ceiling = try CheckpointLimits.make(
            maxRecords: 256,
            maxTotalBytes: 1 << 40,
            maxRecordBytes: 1 << 32
        )
        #expect(ceiling.maxRecords == 256)
        #expect(ceiling.maxTotalBytes == 1_099_511_627_776)
        #expect(ceiling.maxRecordBytes == 4_294_967_296)
        let floor = try CheckpointLimits.make(maxRecords: 1, maxTotalBytes: 1, maxRecordBytes: 1)
        #expect(floor.maxRecords == 1)
        #expect(floor.maxTotalBytes == 1)
        #expect(floor.maxRecordBytes == 1)
    }

    @Test func limitsRefuseOneOverEachCeilingAndZeroAndNegatives() throws {
        for records in [257, 0, -1] {
            #expect(throws: CheckpointRefusal.invalidLimits(.maxRecords)) {
                try CheckpointLimits.make(maxRecords: records, maxTotalBytes: 100, maxRecordBytes: 10)
            }
        }
        for total in [(1 << 40) + 1, 0, -1] {
            #expect(throws: CheckpointRefusal.invalidLimits(.maxTotalBytes)) {
                try CheckpointLimits.make(maxRecords: 4, maxTotalBytes: total, maxRecordBytes: 1)
            }
        }
        for record in [(1 << 32) + 1, 0, -1] {
            #expect(throws: CheckpointRefusal.invalidLimits(.maxRecordBytes)) {
                try CheckpointLimits.make(maxRecords: 4, maxTotalBytes: 1 << 40, maxRecordBytes: record)
            }
        }
    }

    @Test func limitsRefuseARecordCapAboveTheTotalCapButAcceptEquality() throws {
        #expect(throws: CheckpointRefusal.invalidLimits(.recordExceedsTotal)) {
            try CheckpointLimits.make(maxRecords: 4, maxTotalBytes: 100, maxRecordBytes: 101)
        }
        let equal = try CheckpointLimits.make(maxRecords: 4, maxTotalBytes: 100, maxRecordBytes: 100)
        #expect(equal.maxRecordBytes == 100)
        #expect(equal.maxTotalBytes == 100)
    }

    @Test func limitsNameTheFirstBadFieldInDeclaredOrder() throws {
        #expect(throws: CheckpointRefusal.invalidLimits(.maxRecords)) {
            try CheckpointLimits.make(maxRecords: 0, maxTotalBytes: 0, maxRecordBytes: 0)
        }
        #expect(throws: CheckpointRefusal.invalidLimits(.maxTotalBytes)) {
            try CheckpointLimits.make(maxRecords: 1, maxTotalBytes: 0, maxRecordBytes: 0)
        }
        #expect(throws: CheckpointRefusal.invalidLimits(.maxRecordBytes)) {
            try CheckpointLimits.make(maxRecords: 1, maxTotalBytes: 1, maxRecordBytes: 0)
        }
        #expect(throws: CheckpointRefusal.invalidLimits(.maxRecordBytes)) {
            try CheckpointLimits.make(maxRecords: 1, maxTotalBytes: 5, maxRecordBytes: (1 << 32) + 1)
        }
    }

    @Test func revalidatedLimitsEqualTheValidatedOriginal() throws {
        let original = try Self.limits(7, total: 900, record: 300)
        #expect(try original.revalidated() == original)
    }

    @Test func aDigestMustBeExactlyThirtyTwoBytes() throws {
        for count in [0, 31, 33] {
            #expect(throws: CheckpointRefusal.invalidDigestLength(count)) {
                try CheckpointRecord.make(
                    id: CheckpointID(1),
                    ordinal: 1,
                    revision: ContractRevision(0),
                    reason: .manual,
                    digest: Array(repeating: 7, count: count),
                    byteCount: 1,
                    label: ""
                )
            }
        }
        let record = try Self.record(1)
        #expect(record.digest.count == 32)
    }

    @Test func aLabelIsCountedInUTF8BytesNotCharacters() throws {
        let sixtyFour = String(repeating: "\u{20AC}", count: 21) + "a"
        #expect(sixtyFour.utf8.count == 64)
        #expect(sixtyFour.count == 22)
        #expect(try Self.record(1, label: sixtyFour).label == sixtyFour)
        let sixtyFive = String(repeating: "\u{20AC}", count: 21) + "aa"
        #expect(sixtyFive.utf8.count == 65)
        #expect(sixtyFive.count == 23)
        #expect(throws: CheckpointRefusal.labelTooLong(65)) { try Self.record(1, label: sixtyFive) }
        #expect(try Self.record(1, label: "").label.isEmpty)
        let combining = String(repeating: "e\u{301}", count: 22)
        #expect(throws: CheckpointRefusal.labelTooLong(66)) { try Self.record(1, label: combining) }
    }

    @Test func aByteCountAcceptsZeroAndTheHardCeilingAndRefusesOutsideThem() throws {
        #expect(try Self.record(1, bytes: 0).byteCount == 0)
        #expect(try Self.record(1, bytes: 1 << 32).byteCount == 4_294_967_296)
        #expect(throws: CheckpointRefusal.invalidByteCount((1 << 32) + 1)) {
            try Self.record(1, bytes: (1 << 32) + 1)
        }
        #expect(throws: CheckpointRefusal.invalidByteCount(-1)) { try Self.record(1, bytes: -1) }
    }

    @Test func theRecordFactoryChecksDigestThenLabelThenByteCount() throws {
        let longLabel = String(repeating: "a", count: 65)
        #expect(throws: CheckpointRefusal.invalidDigestLength(5)) {
            try CheckpointRecord.make(
                id: CheckpointID(1),
                ordinal: 1,
                revision: ContractRevision(0),
                reason: .manual,
                digest: [1, 2, 3, 4, 5],
                byteCount: -1,
                label: longLabel
            )
        }
        #expect(throws: CheckpointRefusal.labelTooLong(65)) { try Self.record(1, bytes: -1, label: longLabel) }
    }

    @Test func aRecordStoresEverySuppliedFieldUnchanged() throws {
        let made = try CheckpointRecord.make(
            id: CheckpointID(42),
            ordinal: 9,
            revision: ContractRevision(5),
            reason: .preMigration,
            digest: Array(0..<32),
            byteCount: 77,
            label: "before 2.0"
        )
        #expect(made.id == CheckpointID(42))
        #expect(made.ordinal == 9)
        #expect(made.revision == (try ContractRevision(5)))
        #expect(made.reason == .preMigration)
        #expect(made.digest == Array(0..<32))
        #expect(made.byteCount == 77)
        #expect(made.label == "before 2.0")
    }

    @Test func recordEqualityComparesLabelsByUTF8BytesNotCanonicalEquivalence() throws {
        let precomposed = try Self.record(1, label: "\u{E9}")
        let decomposed = try Self.record(1, label: "e\u{301}")
        #expect(precomposed.label == decomposed.label)
        #expect(precomposed != decomposed)
        #expect(precomposed == (try Self.record(1, label: "\u{E9}")))
    }

    @Test func recordEqualityComparesEveryField() throws {
        let base = try Self.record(3, .manual, bytes: 10, id: 8, seed: 1, label: "a")
        #expect(base == (try Self.record(3, .manual, bytes: 10, id: 8, seed: 1, label: "a")))
        #expect(base != (try Self.record(4, .manual, bytes: 10, id: 8, seed: 1, label: "a")))
        #expect(base != (try Self.record(3, .autosave, bytes: 10, id: 8, seed: 1, label: "a")))
        #expect(base != (try Self.record(3, .manual, bytes: 11, id: 8, seed: 1, label: "a")))
        #expect(base != (try Self.record(3, .manual, bytes: 10, id: 9, seed: 1, label: "a")))
        #expect(base != (try Self.record(3, .manual, bytes: 10, id: 8, seed: 2, label: "a")))
        #expect(base != (try Self.record(3, .manual, bytes: 10, id: 8, seed: 1, label: "b")))
        let otherRevision = try CheckpointRecord.make(
            id: CheckpointID(8),
            ordinal: 3,
            revision: ContractRevision(1),
            reason: .manual,
            digest: Array(repeating: 1, count: 32),
            byteCount: 10,
            label: "a"
        )
        #expect(base != otherRevision)
    }

    @Test func onlyManualAndPreMigrationReasonsAreEligibleForPinning() {
        #expect(CheckpointReason.allCases == [.manual, .autosave, .preMigration, .preRestore])
        #expect(CheckpointReason.manual.isPinEligible)
        #expect(CheckpointReason.preMigration.isPinEligible)
        #expect(!CheckpointReason.autosave.isPinEligible)
        #expect(!CheckpointReason.preRestore.isPinEligible)
    }
}
