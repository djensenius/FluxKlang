//
//  MIDICaptureV1RecordRefusal.swift
//  FluxKlang
//
//  Why an accepted MIDI capture cannot become a contract v1 `midiCaptureRecord` (#112 MXR1).
//  In memory only; nothing is clamped, remapped or serialized in its place.
//

/// The first offence `MIDICaptureV1Record.make` finds, in this order: `seq`, `stream`, `musicalTicks`, then `note`.
enum MIDICaptureV1RecordRefusal: Error, Hashable, Sendable {
    /// `seq` is below 1.
    case invalidSeq(Int)
    /// The stream ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidStream(StreamID)
    /// The musical ticks are negative: the schema's `musicalTicks` is a count (minimum 0). `MIDICaptureLog` already
    /// refuses such a capture, so this only keeps the record fail-closed if that ever changes.
    case negativeMusicalTicks(Int64)
    /// The note is empty, all whitespace, or longer than `MIDICaptureV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidNote(bytes: Int)
}
