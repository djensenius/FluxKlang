//
//  GenerationV1RecordRefusal.swift
//  FluxKlang
//
//  Why a generation bump cannot become a contract v1 `generationRecord` (#84 GXR1). In memory only;
//  nothing is clamped, remapped or serialized in its place.
//

/// The first offence `GenerationV1Record.make` finds, in this order: `seq`, the counter subject, the reason's
/// kind, the step from `from` to `to`, the `rateChange` rate, the musical-map payload (presence, then its clock
/// and revision, then extension fields), then `note`.
enum GenerationV1RecordRefusal: Error, Hashable, Sendable {
    /// `seq` is below 1.
    case invalidSeq(Int)
    /// The counter subject does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidCounterSubject(GenerationKey)
    /// The reason belongs to another counter kind (media-contract.md §5.1), as `GenerationLedger` also refuses.
    case reasonDoesNotMatchKind(GenerationKey, GenerationBumpReason)
    /// `to` is not exactly `from + 1`.
    case notConsecutive(from: Generation, to: Generation)
    /// A `rateChange` names a rate outside the v1 `$defs.rate` set (`MediaNominalRate`).
    case invalidRate(Int)
    /// A tempo map or meter was passed for a counter that is not `musicalMap`.
    case musicalMapNotAllowed
    /// A `musicalMap` counter has no tempo map; the checker requires the whole new map on every revision.
    case musicalMapRequired
    /// The tempo map belongs to another musical clock than the counter's subject, or its revision is not `to`.
    case musicalMapMismatch
    /// A tempo segment or the meter carries additive extension fields, which the v1 record cannot hold.
    case musicalMapExtensionFields
    /// The note is empty, all whitespace, or longer than `RecordingTakeV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidNote(bytes: Int)
}
