//
//  ReadinessV1RecordRefusal.swift
//  FluxKlang
//
//  Why a readiness transition cannot become a contract v1 `readinessRecord` (#107 RXR1). In memory only;
//  nothing is clamped, remapped or serialized in its place.
//

/// The first offence `ReadinessV1Record.make` finds, in this order: `seq`, `actionId`, the transition, a missing
/// reason, then `reason`, then `note`.
enum ReadinessV1RecordRefusal: Error, Hashable, Sendable {
    /// `seq` is below 1.
    case invalidSeq(Int)
    /// The action ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidActionID(ActionID)
    /// `to` is not in `from.allowedNext` (media-contract.md §7), including every `from == to`.
    case illegalTransition(from: ReadinessState, to: ReadinessState)
    /// `to` is `failed` or `invalidated` and no reason was given (§7: both states carry a reason).
    case missingReason(to: ReadinessState)
    /// The reason is empty, all whitespace, or longer than `ReadinessV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidReason(bytes: Int)
    /// The note is empty, all whitespace, or longer than `ReadinessV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidNote(bytes: Int)
}
