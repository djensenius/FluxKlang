//
//  WorkspaceStatusRefusal.swift
//  FluxKlang
//
//  Why the status projection or the announcer refuses its input (#99 W3). Every
//  refusal is typed, and a refusal leaves the inputs and the announcer unchanged.
//

/// The input a refusal names, with the row index where the input is a row.
enum WorkspaceStatusField: Hashable, Sendable {
    case hostName
    case deviceName(index: Int)
    case peerName(index: Int)
    case discardedCommands(peerIndex: Int)
    case draftCount
    case diagnosticCount(DiagnosticSeverity)
    case showReadinessEntries
    case showReadinessBlockedEntries
    case showReadinessSetBlockers
}

/// Why `WorkspaceStatusProjection.make(_:)` or the announcer refused. The projection reports the first
/// failure in the order documented there; nothing is trimmed, truncated, clamped or repaired.
enum WorkspaceStatusRefusal: Error, Hashable, Sendable {
    /// A name is empty. Names are never trimmed, so only a zero-length name is empty.
    case emptyName(WorkspaceStatusField)
    /// A name has more than `WorkspaceStatusInputs.maximumNameUTF8Bytes` UTF-8 bytes. Names are never truncated.
    case nameTooLong(WorkspaceStatusField, bytes: Int)
    /// A count is outside `0...WorkspaceStatusInputs.maximumCount`.
    case countOutOfRange(WorkspaceStatusField, value: Int)
    /// The nominal clock rate is outside `WorkspaceStatusInputs.sampleRates`.
    case nominalRateOutOfRange(Int)
    /// The measured clock rate is outside `WorkspaceStatusInputs.sampleRates`.
    case measuredRateOutOfRange(Int)
    /// The announcer was given a tick smaller than the newest one it accepted; ticks never go backwards.
    case tickWentBackwards(last: UInt64, found: UInt64)
    /// The show readiness input reports more blocked entries than entries.
    case blockedEntriesExceedEntries(blocked: Int, entries: Int)
}
