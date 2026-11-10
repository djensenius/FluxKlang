//
//  DiagnosticsListTypes.swift
//  FluxKlang
//
//  The values of the diagnostics list model (#99, DGL1): a row, the ledger of first-seen ticks and the result. The
//  initializers are fileprivate; the builders at the end of this file are the only way to make one.
//

/// One list row. The summary is untrusted display text, kept byte for byte. Not `Equatable`: free text would
/// compare by canonical equivalence.
struct DiagnosticsListRow: Sendable {
    let id: DiagnosticID
    let severity: DiagnosticSeverity
    let summary: String
    let subject: DiagnosticSubject?
    /// The injected tick of the first call that showed this id since it was last absent.
    let firstSeen: UInt64

    fileprivate init(
        id: DiagnosticID, severity: DiagnosticSeverity, summary: String, subject: DiagnosticSubject?,
        firstSeen: UInt64
    ) {
        self.id = id
        self.severity = severity
        self.summary = summary
        self.subject = subject
        self.firstSeen = firstSeen
    }
}

/// What the next call needs: the first-seen tick of each shown id and the last tick. Ids and ticks only, so its
/// equality is byte equality of ASCII ids.
struct DiagnosticsListLedger: Equatable, Sendable {
    /// At most `DiagnosticsList.maximumRows` entries, one per shown row.
    let firstSeen: [DiagnosticID: UInt64]
    /// The tick of the last accepted call; nil before the first.
    let lastTick: UInt64?

    fileprivate init(firstSeen: [DiagnosticID: UInt64], lastTick: UInt64?) {
        self.firstSeen = firstSeen
        self.lastTick = lastTick
    }

    static let empty = DiagnosticsListLedger(firstSeen: [:], lastTick: nil)
}

/// What one call decided. `counts` is derived from `rows` and nothing else, so its three numbers add up to
/// `rows.count`; `hiddenOverLimit` and `collapsedDuplicates` sit beside it and are not part of it.
struct DiagnosticsListResult: Sendable {
    /// At most `DiagnosticsList.maximumRows` rows in display order.
    let rows: [DiagnosticsListRow]
    let counts: WorkspaceStatusDiagnosticCounts
    /// Distinct ids left out by the row cap.
    let hiddenOverLimit: Int
    /// Records folded into another record of the same id.
    let collapsedDuplicates: Int
    /// Feed this to the next call.
    let ledger: DiagnosticsListLedger

    fileprivate init(
        rows: [DiagnosticsListRow], counts: WorkspaceStatusDiagnosticCounts, hiddenOverLimit: Int,
        collapsedDuplicates: Int, ledger: DiagnosticsListLedger
    ) {
        self.rows = rows
        self.counts = counts
        self.hiddenOverLimit = hiddenOverLimit
        self.collapsedDuplicates = collapsedDuplicates
        self.ledger = ledger
    }
}

// MARK: - Builders

extension DiagnosticsListRow {
    static func make(_ record: NeutralDiagnosticRecord, firstSeen: UInt64) -> DiagnosticsListRow {
        DiagnosticsListRow(
            id: record.id, severity: record.severity, summary: record.summary, subject: record.subject,
            firstSeen: firstSeen
        )
    }
}

extension DiagnosticsListLedger {
    /// A ledger of exactly `rows`, so an id that is not shown is released.
    static func make(rows: [DiagnosticsListRow], tick: UInt64) -> DiagnosticsListLedger {
        var firstSeen: [DiagnosticID: UInt64] = [:]
        for row in rows { firstSeen[row.id] = row.firstSeen }
        return DiagnosticsListLedger(firstSeen: firstSeen, lastTick: tick)
    }
}

extension DiagnosticsListResult {
    /// Derives `counts` from `rows` in one pass. Exhaustive over the severities.
    static func make(
        rows: [DiagnosticsListRow], hiddenOverLimit: Int, collapsedDuplicates: Int, ledger: DiagnosticsListLedger
    ) -> DiagnosticsListResult {
        var errors = 0
        var warnings = 0
        var infos = 0
        for row in rows {
            switch row.severity {
            case .error: errors += 1
            case .warning: warnings += 1
            case .info: infos += 1
            }
        }
        return DiagnosticsListResult(
            rows: rows, counts: WorkspaceStatusDiagnosticCounts(errors: errors, warnings: warnings, infos: infos),
            hiddenOverLimit: hiddenOverLimit, collapsedDuplicates: collapsedDuplicates, ledger: ledger
        )
    }
}
