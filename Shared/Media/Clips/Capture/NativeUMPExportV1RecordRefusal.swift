//
//  NativeUMPExportV1RecordRefusal.swift
//  FluxKlang
//
//  Why a native UMP export cannot become a contract v1 `exportRecord` (#112 NXR1). In memory
//  only; nothing is clamped, remapped or serialized in its place.
//

/// The first offence `NativeUMPExportV1Record.make` finds, in this order: `seq`, `exportId`, each stream (lowest
/// index first), the origin's `sampleClock`, each offset (lowest index first), then `note`.
enum NativeUMPExportV1RecordRefusal: Error, Hashable, Sendable {
    /// `seq` is below 1.
    case invalidSeq(Int)
    /// The export ID does not match the media contract ID pattern `^[a-z][a-z0-9-]*\.[a-z0-9.-]+$`.
    case invalidExportID(ExportID)
    /// This stream ID, the first one in list order that does, does not match the media contract ID pattern.
    case invalidStream(StreamID)
    /// The origin's sample clock does not match the media contract ID pattern.
    case invalidOriginClock(ClockID)
    /// The offset at this index is negative: the schema's `offsetsNs` items are counts (minimum 0). An export whose
    /// origin lies after a capture (for example in a later generation) has no v1 record.
    case negativeOffset(index: Int, offsetNs: Int64)
    /// The note is empty, all whitespace, or longer than `NativeUMPExportV1Record.maximumNoteBytes` UTF-8 bytes.
    case invalidNote(bytes: Int)
}
