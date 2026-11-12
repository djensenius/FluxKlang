//
//  TriggerV1RecordRefusal.swift
//  FluxKlang
//
//  Why a trigger stamp cannot become a contract v1 `triggerRecord` (#107 TXR1). In memory only;
//  nothing is clamped, remapped or serialized in its place.
//

/// The first offence `TriggerV1Record.make` finds, in this order: `seq`, the trigger ID, the action ID, an empty
/// `requires`, too many requirements, then each requirement in the stamp's order (a `musicalMap` kind, then its
/// subject, then a duplicate key), then the grid, the musical ticks, and finally the note.
enum TriggerV1RecordRefusal: Error, Hashable, Sendable {
    /// `seq` is below 1.
    case invalidSeq(Int)
    /// The trigger ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidTriggerID(TriggerID)
    /// The action ID does not match the media contract ID pattern.
    case invalidActionID(ActionID)
    /// The stamp has no requirement; the schema's `requires` needs at least one member.
    case noRequirements
    /// The stamp has more than `TriggerStamp.maximumRequirements` requirements; carries the count.
    case tooManyRequirements(Int)
    /// A requirement is on a `musicalMap` counter; a map revision is never a dependency (M3).
    case musicalMapRequirement(GenerationKey)
    /// A requirement's subject does not match the media contract ID pattern.
    case invalidRequirementSubject(GenerationKey)
    /// A requirement repeats an earlier key, even with an equal generation.
    case duplicateRequirement(GenerationKey)
    /// The target is `.grid(ticks:)` with ticks below 1.
    case invalidGrid(Int64)
    /// The target is `.musical(atTicks:)` with ticks below 0.
    case negativeMusicalTicks(Int64)
    /// The note is empty, all whitespace, or longer than `TriggerV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidNote(bytes: Int)
}
