//
//  DispatchV1RecordRefusal.swift
//  FluxKlang
//
//  Why a dispatched event cannot become a contract v1 `dispatchRecord` (#107 DPR1). In memory only;
//  nothing is clamped, remapped or serialized in its place.
//

/// The first offence `DispatchV1Record.make` finds, in this order: `seq`, `stream`, `streamSeq`, `event`, then
/// `note`.
enum DispatchV1RecordRefusal: Error, Hashable, Sendable {
    /// `seq` is below 1.
    case invalidSeq(Int)
    /// The stream ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidStream(StreamID)
    /// `streamSeq` is 0; the schema's `streamSeq` is at least 1.
    case invalidStreamSeq(UInt64)
    /// The event is empty, all whitespace, or longer than `DispatchV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidEvent(bytes: Int)
    /// The note is empty, all whitespace, or longer than `DispatchV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidNote(bytes: Int)
}
