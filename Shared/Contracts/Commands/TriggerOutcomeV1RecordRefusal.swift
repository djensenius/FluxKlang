//
//  TriggerOutcomeV1RecordRefusal.swift
//  FluxKlang
//
//  Why a trigger outcome cannot become a contract v1 `outcomeRecord` (#107 OXR1). In memory only;
//  nothing is clamped, remapped or serialized in its place.
//

/// The first offence `TriggerOutcomeV1Record.make` finds, in this order: `seq`, `triggerId`, the outcome's
/// v1 media shape, then `note`.
enum TriggerOutcomeV1RecordRefusal: Error, Hashable, Sendable {
    /// `seq` is below 1.
    case invalidSeq(Int)
    /// The trigger ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidTriggerID(TriggerID)
    /// `TriggerOutcome.validateMediaShape()` refused the outcome; its error is carried unchanged.
    case invalidShape(TriggerOutcomeValidationError)
    /// The note is empty, all whitespace, or longer than `TriggerOutcomeV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidNote(bytes: Int)
}
