//
//  WorkspaceStatusSources.swift
//  FluxKlang
//
//  Pure mappers from values the app already owns to two fields of `WorkspaceStatusInputs` (#99 WSS1). They read,
//  sound, store and announce nothing, and keep no state.
//

/// Derives the status strip's diagnostic counts and device rows. The shell and show readiness parts of
/// `WorkspaceStatusInputs` have their own initialisers; the permissions are stored as they are.
enum WorkspaceStatusSources {
    /// The most descriptors `deviceRows(_:names:)` accepts: the inventory limit, not a new number.
    static let maximumDevices = DeviceCapabilityLimits.devices

    /// The counts by severity of `records`, one pass. Total: any list gives counts, including an empty one.
    /// Records are counted as given (no dedupe by id) and the counts are neither validated nor clamped:
    /// `WorkspaceStatusDiagnosticSummary.make` refuses a count above `WorkspaceStatusInputs.maximumCount`.
    static func diagnosticCounts(of records: [NeutralDiagnosticRecord]) -> WorkspaceStatusDiagnosticCounts {
        var errors = 0
        var warnings = 0
        var infos = 0
        for record in records {
            switch record.severity {
            case .error: errors += 1
            case .warning: warnings += 1
            case .info: infos += 1
            }
        }
        return WorkspaceStatusDiagnosticCounts(errors: errors, warnings: warnings, infos: infos)
    }
}
