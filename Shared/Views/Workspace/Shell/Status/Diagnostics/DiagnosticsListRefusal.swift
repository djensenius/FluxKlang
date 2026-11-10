//
//  DiagnosticsListRefusal.swift
//  FluxKlang
//
//  Why one call of the diagnostics list model was refused (#99, DGL1). A refused call changes nothing.
//

/// Deliberately not `Codable`: nothing persists a refusal.
enum DiagnosticsListRefusal: Error, Equatable, Sendable {
    /// More records than `DiagnosticsList.maximumOffered`; carries the offered count. Checked first.
    case tooManyRecords(offered: Int)
    /// The tick is smaller than the ledger's last tick; carries both.
    case tickWentBackwards(last: UInt64, given: UInt64)
}
