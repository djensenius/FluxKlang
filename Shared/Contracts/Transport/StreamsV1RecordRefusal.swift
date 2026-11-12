//
//  StreamsV1RecordRefusal.swift
//  FluxKlang
//
//  Why a list of streams cannot become the contract v1 trace's `streams` header (#107 STR1, media-contract
//  §6.5, schema `$defs.stream`). In memory only; nothing is dropped, clamped, renumbered or reordered.
//

/// The first offence `StreamsV1Record.make` finds, in this order: an empty list, a list over the bound (before any
/// stream is read), then each stream in the caller's order, checked for its ID pattern, a negative ordinal, an ID
/// already declared and an ordinal already declared.
enum StreamsV1RecordRefusal: Error, Hashable, Sendable {
    /// No streams. A trace with none omits the `streams` header instead.
    case empty
    /// More than `StreamsV1Record.maximumStreams` streams.
    case tooManyStreams(count: Int)
    /// The stream ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidStreamID(StreamID)
    /// The ordinal is below 0 (`$defs.count`).
    case negativeOrdinal(StreamID, Int)
    /// An earlier stream has the same ID; the checker refuses a repeated `streamId` too.
    case duplicateStreamID(StreamID)
    /// An earlier stream has the same ordinal. The checker accepts this; the exporter refuses it because the §6.5
    /// dispatch order would be ambiguous. Names the later stream.
    case duplicateOrdinal(StreamID, ordinal: Int)
}
