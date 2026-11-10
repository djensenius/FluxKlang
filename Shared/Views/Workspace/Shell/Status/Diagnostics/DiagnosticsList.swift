//
//  DiagnosticsList.swift
//  FluxKlang
//
//  Turns the diagnostic records a host holds into the rows of a list and a count that cannot disagree with them
//  (#99, DGL1). Nothing calls this yet. It shows nothing, reads no time (the tick is injected), persists nothing and
//  sends nothing; `WorkspaceStatusSources.diagnosticCounts(of:)` is unchanged.
//

/// Rows are ordered by severity, then by the tick at which the id was first seen, then by id UTF-8 bytes; the row cap
/// keeps the same prefix, so the rows that survive the cap are the rows shown. The caller keeps the ledger of the
/// last result and passes it to the next call.
enum DiagnosticsList {
    /// The most rows one result holds. It mirrors `NeutralSnapshot.Limits.diagnostics`.
    static let maximumRows = 256
    /// The most records one call accepts (16 times `maximumRows`, an engineering constant).
    static let maximumOffered = 4_096

    /// Checks, first failure wins: (1) at most `maximumOffered` records, (2) the tick is not below the ledger's last
    /// tick. A repeated id is collapsed into one row (the more urgent severity wins, then the summary that sorts
    /// first by UTF-8 bytes, then the first in input order) and counted in `collapsedDuplicates`.
    static func observe(
        _ records: [NeutralDiagnosticRecord], tick: UInt64, ledger: DiagnosticsListLedger
    ) throws(DiagnosticsListRefusal) -> DiagnosticsListResult {
        guard records.count <= maximumOffered else { throw .tooManyRecords(offered: records.count) }
        try requireTick(tick, after: ledger.lastTick)
        let collapsed = collapse(records)
        let rows = collapsed.records.map { DiagnosticsListRow.make($0, firstSeen: ledger.firstSeen[$0.id] ?? tick) }
        let ordered = rows.sorted(by: precedes)
        let kept = Array(ordered.prefix(maximumRows))
        return DiagnosticsListResult.make(
            rows: kept, hiddenOverLimit: ordered.count - kept.count, collapsedDuplicates: collapsed.duplicates,
            ledger: DiagnosticsListLedger.make(rows: kept, tick: tick)
        )
    }

    private static func requireTick(_ tick: UInt64, after last: UInt64?) throws(DiagnosticsListRefusal) {
        guard let last else { return }
        guard tick >= last else { throw .tickWentBackwards(last: last, given: tick) }
    }

    /// One record per id and the number of records folded away. The order of the records returned is not defined.
    private static func collapse(
        _ records: [NeutralDiagnosticRecord]
    ) -> (records: [NeutralDiagnosticRecord], duplicates: Int) {
        var byID: [DiagnosticID: NeutralDiagnosticRecord] = [:]
        var duplicates = 0
        for record in records {
            guard let current = byID[record.id] else {
                byID[record.id] = record
                continue
            }
            duplicates += 1
            if beats(record, current) { byID[record.id] = record }
        }
        return (Array(byID.values), duplicates)
    }

    /// Whether `candidate` replaces `current`: strictly more urgent, or the same urgency and a summary that sorts
    /// first by UTF-8 bytes. A full tie keeps `current`.
    private static func beats(_ candidate: NeutralDiagnosticRecord, _ current: NeutralDiagnosticRecord) -> Bool {
        if candidate.severity.rank != current.severity.rank {
            return candidate.severity.rank < current.severity.rank
        }
        return candidate.summary.utf8.lexicographicallyPrecedes(current.summary.utf8)
    }

    /// The total display order: severity rank, first-seen tick, then id bytes (unique after the collapse).
    private static func precedes(_ lhs: DiagnosticsListRow, _ rhs: DiagnosticsListRow) -> Bool {
        if lhs.severity.rank != rhs.severity.rank {
            return lhs.severity.rank < rhs.severity.rank
        }
        if lhs.firstSeen != rhs.firstSeen {
            return lhs.firstSeen < rhs.firstSeen
        }
        return lhs.id.rawValue.utf8.lexicographicallyPrecedes(rhs.id.rawValue.utf8)
    }
}
