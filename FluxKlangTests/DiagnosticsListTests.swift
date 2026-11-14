import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private enum ListFixture {
    static func record(
        _ id: String, _ severity: DiagnosticSeverity, _ summary: String = "text", subject: DiagnosticSubject? = nil
    ) throws -> NeutralDiagnosticRecord {
        NeutralDiagnosticRecord(id: try DiagnosticID(id), severity: severity, summary: summary, subject: subject)
    }

    static func ids(_ result: DiagnosticsListResult) -> [String] {
        result.rows.map(\.id.rawValue)
    }

    static func ticks(_ result: DiagnosticsListResult) -> [UInt64] {
        result.rows.map(\.firstSeen)
    }

    static func padded(_ number: Int, width: Int) -> String {
        let text = String(number)
        return String(repeating: "0", count: width - text.count) + text
    }

    /// `count` distinct warnings `dgn.0000`, `dgn.0001`, ...
    static func warnings(_ count: Int) throws -> [NeutralDiagnosticRecord] {
        var records: [NeutralDiagnosticRecord] = []
        for index in 0..<count { records.append(try record("dgn.\(padded(index, width: 4))", .warning)) }
        return records
    }

    static func observe(
        _ records: [NeutralDiagnosticRecord], tick: UInt64, _ ledger: DiagnosticsListLedger = .empty
    ) throws -> DiagnosticsListResult {
        try DiagnosticsList.observe(records, tick: tick, ledger: ledger)
    }

    static func row(_ id: String, in result: DiagnosticsListResult) throws -> DiagnosticsListRow {
        try #require(result.rows.first { $0.id.rawValue == id })
    }

    static func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }
}

@Suite("Diagnostics list", .productionAccessAudit)
struct DiagnosticsListTests {
    // MARK: - Order

    @Test
    func diagnosticsListGoldenOrderIsSeverityThenIdBytesAtOneTick() throws {
        let records = [
            try ListFixture.record("w.1", .warning), try ListFixture.record("i.1", .info),
            try ListFixture.record("e.1", .error), try ListFixture.record("w.0", .warning)
        ]
        let result = try ListFixture.observe(records, tick: 5)
        let expectedIDs = ["e.1", "w.0", "w.1", "i.1"]
        let expectedTicks: [UInt64] = [5, 5, 5, 5]
        let expectedCounts = WorkspaceStatusDiagnosticCounts(errors: 1, warnings: 2, infos: 1)
        #expect(ListFixture.ids(result) == expectedIDs)
        #expect(ListFixture.ticks(result) == expectedTicks)
        #expect(result.counts == expectedCounts)
    }

    @Test
    func diagnosticsListSeverityBeatsTickAndTickOrdersWithinASeverity() throws {
        let rowA = try ListFixture.record("dgn.a", .warning)
        let rowB = try ListFixture.record("dgn.b", .warning)
        let rowC = try ListFixture.record("dgn.c", .error)
        let first = try ListFixture.observe([rowA], tick: 10)
        let second = try ListFixture.observe([rowA, rowB], tick: 20, first.ledger)
        let third = try ListFixture.observe([rowA, rowB, rowC], tick: 30, second.ledger)
        let expectedIDs = ["dgn.c", "dgn.a", "dgn.b"]
        let expectedTicks: [UInt64] = [30, 10, 20]
        let expectedLedger: [DiagnosticID: UInt64] = [
            try DiagnosticID("dgn.a"): 10, try DiagnosticID("dgn.b"): 20, try DiagnosticID("dgn.c"): 30
        ]
        #expect(ListFixture.ids(third) == expectedIDs)
        #expect(ListFixture.ticks(third) == expectedTicks)
        #expect(third.ledger.firstSeen == expectedLedger)
        #expect(third.ledger.lastTick == 30)
    }

    @Test
    func diagnosticsListAnIdThatLeavesIsReleasedAndReturnsAsANewRow() throws {
        let rowA = try ListFixture.record("dgn.a", .warning)
        let rowB = try ListFixture.record("dgn.b", .warning)
        let first = try ListFixture.observe([rowA, rowB], tick: 10)
        let second = try ListFixture.observe([rowB], tick: 20, first.ledger)
        let expectedAfterRelease: [DiagnosticID: UInt64] = [try DiagnosticID("dgn.b"): 10]
        #expect(second.ledger.firstSeen == expectedAfterRelease)
        let third = try ListFixture.observe([rowA, rowB], tick: 30, second.ledger)
        let expectedIDs = ["dgn.b", "dgn.a"]
        let expectedTicks: [UInt64] = [10, 30]
        #expect(ListFixture.ids(third) == expectedIDs)
        #expect(ListFixture.ticks(third) == expectedTicks)
    }

    @Test
    func diagnosticsListASeverityChangeKeepsFirstSeenAndMovesTheRowToItsNewGroup() throws {
        let rowB = try ListFixture.record("dgn.b", .error)
        let infoA = try ListFixture.record("dgn.a", .info, "old", subject: .graph)
        let nodeSubject = DiagnosticSubject.node(id: try NodeID("node.one"))
        let errorA = try ListFixture.record("dgn.a", .error, "new", subject: nodeSubject)
        let first = try ListFixture.observe([infoA], tick: 10)
        let second = try ListFixture.observe([infoA, rowB], tick: 15, first.ledger)
        let third = try ListFixture.observe([errorA, rowB], tick: 20, second.ledger)
        let expectedIDs = ["dgn.a", "dgn.b"]
        let expectedTicks: [UInt64] = [10, 15]
        #expect(ListFixture.ids(third) == expectedIDs)
        #expect(ListFixture.ticks(third) == expectedTicks)
        let rowOfA = try ListFixture.row("dgn.a", in: third)
        #expect(rowOfA.severity == .error)
        #expect(ListFixture.bytes(rowOfA.summary) == ListFixture.bytes("new"))
        #expect(rowOfA.subject == nodeSubject)
    }

    // MARK: - Count

    private func expectDerivedCount(offered: Int, rows: Int, hidden: Int) throws {
        let result = try ListFixture.observe(try ListFixture.warnings(offered), tick: 1)
        let total = result.counts.errors + result.counts.warnings + result.counts.infos
        let expected = WorkspaceStatusDiagnosticCounts(errors: 0, warnings: rows, infos: 0)
        #expect(result.rows.count == rows)
        #expect(total == result.rows.count)
        #expect(result.counts == expected)
        #expect(result.hiddenOverLimit == hidden)
        #expect(result.ledger.firstSeen.count == rows)
    }

    @Test
    func diagnosticsListCountEqualsTheKeptRowsAtZeroOneAndAroundTheRowCap() throws {
        let cap = DiagnosticsList.maximumRows
        try expectDerivedCount(offered: 0, rows: 0, hidden: 0)
        try expectDerivedCount(offered: 1, rows: 1, hidden: 0)
        try expectDerivedCount(offered: cap - 1, rows: cap - 1, hidden: 0)
        try expectDerivedCount(offered: cap, rows: cap, hidden: 0)
        try expectDerivedCount(offered: cap + 1, rows: cap, hidden: 1)
    }

    @Test
    func diagnosticsListTheCapKeepsErrorsThatSortLaterByIdBytesThanTheWarningsAroundThem() throws {
        // Fixture C of the sheet: the raw counts of these 310 records are (10, 300, 0); the list keeps 256 rows.
        var records: [NeutralDiagnosticRecord] = []
        for index in 0..<300 {
            records.append(try ListFixture.record("a-warn.\(ListFixture.padded(index, width: 3))", .warning))
        }
        for index in 0..<10 {
            records.append(try ListFixture.record("err.\(ListFixture.padded(index, width: 2))", .error))
        }
        let result = try ListFixture.observe(records, tick: 1)
        let expectedCounts = WorkspaceStatusDiagnosticCounts(errors: 10, warnings: 246, infos: 0)
        let expectedHead = (0..<10).map { "err.\(ListFixture.padded($0, width: 2))" }
        #expect(result.counts == expectedCounts)
        #expect(result.rows.count == DiagnosticsList.maximumRows)
        #expect(result.hiddenOverLimit == 54)
        #expect(Array(ListFixture.ids(result).prefix(10)) == expectedHead)
        #expect(result.rows.last?.id.rawValue == "a-warn.245")
    }

    @Test
    func diagnosticsListACountTakenFromTheRecordsDisagreesWithTheListAndTheListCountsItsRows() throws {
        // Fixture A. WorkspaceStatusSources.diagnosticCounts(of:) counts every record given, so it gives
        // (errors 2, warnings 0, infos 1) here (read from its loop; its own test pins nine records as nine).
        let rawCounts = WorkspaceStatusDiagnosticCounts(errors: 2, warnings: 0, infos: 1)
        let rowA = try ListFixture.record("dgn.a", .error)
        let rowB = try ListFixture.record("dgn.b", .info)
        let forward = try ListFixture.observe([rowA, rowA, rowB], tick: 1)
        let reverse = try ListFixture.observe([rowB, rowA, rowA], tick: 1)
        let expectedCounts = WorkspaceStatusDiagnosticCounts(errors: 1, warnings: 0, infos: 1)
        let expectedIDs = ["dgn.a", "dgn.b"]
        #expect(forward.counts != rawCounts)
        #expect(forward.counts == expectedCounts)
        #expect(forward.rows.count == 2)
        #expect(forward.collapsedDuplicates == 1)
        #expect(ListFixture.ids(forward) == expectedIDs)
        #expect(reverse.counts == expectedCounts)
        #expect(ListFixture.ids(reverse) == expectedIDs)
    }

    // MARK: - Duplicates and text

    @Test
    func diagnosticsListDuplicatesCollapseToTheMostUrgentThenTheSmallerSummaryBytesThenTheFirstInput() throws {
        let mixed = [
            try ListFixture.record("dgn.x", .info, "b"), try ListFixture.record("dgn.x", .warning, "z"),
            try ListFixture.record("dgn.x", .warning, "a")
        ]
        let collapsed = try ListFixture.observe(mixed, tick: 1)
        let onlyRow = try #require(collapsed.rows.first)
        #expect(collapsed.rows.count == 1)
        #expect(onlyRow.severity == .warning)
        #expect(ListFixture.bytes(onlyRow.summary) == [0x61])
        #expect(collapsed.collapsedDuplicates == 2)

        let node = DiagnosticSubject.node(id: try NodeID("node.one"))
        let graphFirst = try ListFixture.record("dgn.x", .warning, "same", subject: .graph)
        let nodeFirst = try ListFixture.record("dgn.x", .warning, "same", subject: node)
        let tieForward = try ListFixture.observe([graphFirst, nodeFirst], tick: 1)
        let tieReverse = try ListFixture.observe([nodeFirst, graphFirst], tick: 1)
        #expect(tieForward.rows.first?.subject == DiagnosticSubject.graph)
        #expect(tieReverse.rows.first?.subject == node)

        // U+00E9 is C3 A9; "e" plus U+0301 is 65 CC 81. By bytes 0x65 sorts first; String order calls them equal.
        let composed = try ListFixture.record("dgn.x", .warning, "\u{e9}")
        let decomposed = try ListFixture.record("dgn.x", .warning, "e\u{301}")
        let expectedBytes: [UInt8] = [0x65, 0xCC, 0x81]
        for records in [[composed, decomposed], [decomposed, composed]] {
            let result = try ListFixture.observe(records, tick: 1)
            let row = try #require(result.rows.first)
            #expect(result.rows.count == 1)
            #expect(ListFixture.bytes(row.summary) == expectedBytes)
        }
    }

    @Test
    func diagnosticsListIdsAreOrderedByBytesAndSummariesPassThroughUnchanged() throws {
        let ordering = [
            try ListFixture.record("dgn.A", .warning), try ListFixture.record("dgn.a", .warning),
            try ListFixture.record("dgn-z", .warning), try ListFixture.record("dgn:q", .warning)
        ]
        let ordered = try ListFixture.observe(ordering, tick: 1)
        let expectedIDs = ["dgn-z", "dgn.A", "dgn.a", "dgn:q"]
        #expect(ListFixture.ids(ordered) == expectedIDs)

        let texts = [
            try ListFixture.record("txt.a", .warning, "e\u{301}"), try ListFixture.record("txt.b", .warning, "\u{e9}"),
            try ListFixture.record("txt.c", .warning, " pad\n")
        ]
        let result = try ListFixture.observe(texts, tick: 1)
        #expect(result.rows.count == 3)
        let decomposed = ListFixture.bytes(try ListFixture.row("txt.a", in: result).summary)
        let composed = ListFixture.bytes(try ListFixture.row("txt.b", in: result).summary)
        let padded = ListFixture.bytes(try ListFixture.row("txt.c", in: result).summary)
        let expectedPadded: [UInt8] = [0x20, 0x70, 0x61, 0x64, 0x0A]
        #expect(decomposed == [0x65, 0xCC, 0x81])
        #expect(composed == [0xC3, 0xA9])
        #expect(padded == expectedPadded)
    }

    // MARK: - Limits and tick

    @Test
    func diagnosticsListOfferedRecordsAreAcceptedUpToTheLimitAndRefusedOneAboveBeforeTheTick() throws {
        let limit = 4_096
        #expect(DiagnosticsList.maximumOffered == 4_096)
        let below = try ListFixture.observe(try ListFixture.warnings(limit - 1), tick: 1)
        #expect(below.rows.count == DiagnosticsList.maximumRows)
        #expect(below.hiddenOverLimit == limit - 1 - DiagnosticsList.maximumRows)
        let atLimit = try ListFixture.observe(try ListFixture.warnings(limit), tick: 1)
        #expect(atLimit.rows.count == DiagnosticsList.maximumRows)
        #expect(atLimit.hiddenOverLimit == limit - DiagnosticsList.maximumRows)
        #expect(atLimit.collapsedDuplicates == 0)

        let repeated = Array(repeating: try ListFixture.record("dgn.x", .warning), count: limit)
        let folded = try ListFixture.observe(repeated, tick: 1)
        #expect(folded.rows.count == 1)
        #expect(folded.collapsedDuplicates == limit - 1)

        // The record limit is checked first: this call also carries a tick below the ledger's last tick.
        let later = try ListFixture.observe([try ListFixture.record("dgn.x", .warning)], tick: 100)
        let tooMany = try ListFixture.warnings(limit + 1)
        #expect(throws: DiagnosticsListRefusal.tooManyRecords(offered: limit + 1)) {
            _ = try ListFixture.observe(tooMany, tick: 5, later.ledger)
        }
    }

    @Test
    func diagnosticsListATickBelowTheLastIsRefusedAnEqualTickIsAcceptedAndARefusalLeavesRecovery() throws {
        let rowA = try ListFixture.record("dgn.a", .warning)
        let rowB = try ListFixture.record("dgn.b", .warning)
        let atMax = try ListFixture.observe([rowA], tick: UInt64.max)
        let below = UInt64.max - 1
        #expect(throws: DiagnosticsListRefusal.tickWentBackwards(last: UInt64.max, given: below)) {
            _ = try ListFixture.observe([rowA], tick: below, atMax.ledger)
        }
        let equal = try ListFixture.observe([rowA], tick: UInt64.max, atMax.ledger)
        #expect(equal.rows.count == 1)

        let emptyAtFifty = try ListFixture.observe([], tick: 50)
        #expect(throws: DiagnosticsListRefusal.tickWentBackwards(last: 50, given: 40)) {
            _ = try ListFixture.observe([rowA], tick: 40, emptyAtFifty.ledger)
        }

        let base = try ListFixture.observe([rowA], tick: 50)
        #expect(throws: DiagnosticsListRefusal.tickWentBackwards(last: 50, given: 40)) {
            _ = try ListFixture.observe([rowA, rowB], tick: 40, base.ledger)
        }
        let recovered = try ListFixture.observe([rowA, rowB], tick: 60, base.ledger)
        let expectedTicks: [UInt64] = [50, 60]
        #expect(ListFixture.ticks(recovered) == expectedTicks)
        #expect(recovered.ledger.lastTick == 60)
    }

    @Test
    func diagnosticsListEqualInputsGiveEqualResultsAndALaterTickKeepsTheFirstSeenTicks() throws {
        let records = try ListFixture.warnings(DiagnosticsList.maximumRows)
        let first = try ListFixture.observe(records, tick: 10)
        let again = try ListFixture.observe(records, tick: 10)
        #expect(ListFixture.ids(first) == ListFixture.ids(again))
        #expect(ListFixture.ticks(first) == ListFixture.ticks(again))
        #expect(first.counts == again.counts)
        #expect(first.hiddenOverLimit == again.hiddenOverLimit)
        #expect(first.collapsedDuplicates == again.collapsedDuplicates)
        #expect(first.ledger == again.ledger)

        let later = try ListFixture.observe(records, tick: 20, first.ledger)
        let keptTicks = Set(ListFixture.ticks(later))
        let expectedTicks: Set<UInt64> = [10]
        #expect(later.ledger.firstSeen.count == DiagnosticsList.maximumRows)
        #expect(keptTicks == expectedTicks)
        #expect(later.ledger.lastTick == 20)
    }

    @Test
    func diagnosticsListAnIdHiddenByTheCapReturnsWithANewFirstSeenTick() throws {
        let offered = try ListFixture.warnings(257)
        let hiddenID = "dgn.0256"
        let atTen = try ListFixture.observe(offered, tick: 10)
        #expect(atTen.rows.count == 256)
        #expect(atTen.hiddenOverLimit == 1)
        #expect(atTen.ledger.firstSeen.count == 256)
        #expect(atTen.ledger.firstSeen[try DiagnosticID(hiddenID)] == nil)
        let atTwenty = try ListFixture.observe(offered, tick: 20, atTen.ledger)
        #expect(atTwenty.hiddenOverLimit == 1)

        // The hidden id returns as an error, so it is shown: it is new to the ledger and takes the tick 30.
        let returned = try ListFixture.warnings(256) + [try ListFixture.record(hiddenID, .error)]
        let atThirty = try ListFixture.observe(returned, tick: 30, atTwenty.ledger)
        let row = try ListFixture.row(hiddenID, in: atThirty)
        #expect(row.firstSeen == 30)
        #expect(ListFixture.ids(atThirty).first == hiddenID)
        let warningTicks = Set(atThirty.rows.dropFirst().map(\.firstSeen))
        let expectedTicks: Set<UInt64> = [10]
        #expect(warningTicks == expectedTicks)
        #expect(atThirty.rows.count == 256)
        #expect(atThirty.hiddenOverLimit == 1)
    }
}
