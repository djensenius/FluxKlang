//
//  SMFExportV1RecordRefusal.swift
//  FluxKlang
//
//  Why a written Standard MIDI File cannot become a contract v1 `exportRecord` (#548 SMF3). In memory
//  only; nothing is clamped, remapped or serialized in its place.
//

/// The first offence `SMFExportV1Record.make` finds, in this order: `seq`, `exportId`, the stream list (none, too
/// many, the first repeat, then the first that fails the ID pattern), the file's header (readable, format, division
/// kind, division value), each loss count (in `SMFExportLoss.allCases` order), then `note`.
enum SMFExportV1RecordRefusal: Error, Hashable, Sendable {
    /// `seq` is below 1.
    case invalidSeq(Int)
    /// The export ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidExportID(ExportID)
    /// The stream list is empty: the schema needs at least one stream.
    case noStreams
    /// More than `MIDICaptureLog.maximumStreams` streams.
    case tooManyStreams(count: Int)
    /// This stream, the first in list order that equals an earlier one, is repeated.
    case duplicateStream(StreamID)
    /// This stream ID, the first one in list order that does, does not match the media contract ID pattern.
    case invalidStream(StreamID)
    /// The bytes do not start with a whole `MThd` chunk: fewer than 14 bytes, another magic, a chunk length below 6
    /// or beyond the file.
    case unreadableHeader
    /// The header's format is above 1.
    case unsupportedFormat(UInt16)
    /// The header's division has bit 15 set (SMPTE time code), which the schema cannot describe.
    case smpteDivision(UInt16)
    /// The header's division is 0 or does not divide `MusicalTime.ticksPerQuarter`.
    case unsupportedDivision(UInt16)
    /// This category, the first in `SMFExportLoss.allCases` order, has a count below 1: the schema's counts are
    /// positive.
    case invalidLossCount(loss: SMFExportLoss, count: Int)
    /// The note is empty, all whitespace, or longer than `SMFExportV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidNote(bytes: Int)
}
