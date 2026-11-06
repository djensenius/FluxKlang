//
//  SMFRefusal.swift
//  FluxKlang
//
//  Typed refusals of the Standard MIDI File reader (#112 CL2). A refused read
//  returns no clip and no report. `offset` is a byte offset into the file and
//  `track` a zero-based index among the file's MTrk chunks. SysEx events,
//  refused controllers, stray Note Offs, zero-length notes and non-note events
//  at the clip end are not refusals: the reader skips and counts them in
//  `SMFReadReport`.
//

/// Why Standard MIDI File bytes are not read into a `MIDIClip`.
enum SMFRefusal: Error, Equatable, Sendable {
    /// The file holds more than `limit` bytes (`SMFReadLimits.maximumFileBytes`).
    case fileTooLarge(bytes: Int, limit: Int)
    /// The data ends inside a chunk header, a variable-length quantity or an event (a SysEx event included) that
    /// starts at `offset`. Fewer than 8 bytes after the last chunk are refused this way, never ignored.
    case truncated(offset: Int)
    /// The file does not start with an `MThd` chunk of at least 6 bytes.
    case missingHeader
    /// The chunk at `offset` declares `length` bytes, more than remain in the file.
    case chunkOverrunsFile(offset: Int, length: UInt32)
    /// Only formats 0 and 1 are read; format 2 holds independent sequences, not one clip.
    case unsupportedFormat(UInt16)
    /// The division has bit 15 set: SMPTE frames per second and ticks per frame, which are not musical ticks.
    case smpteDivision(UInt16)
    /// Ticks per quarter must be nonzero and divide 15,360, so every tick scales to clip ticks exactly.
    case unsupportedDivision(UInt16)
    /// The header declares no tracks, more than `limit` tracks, or more than one track in format 0.
    case trackCountOutOfRange(declared: UInt16, limit: Int)
    /// The header declares `declared` tracks but the file holds `found` MTrk chunks. More chunks than declared are
    /// refused at the first extra one, before the rest of the file is scanned.
    case trackCountMismatch(declared: UInt16, found: Int)
    /// A variable-length quantity at `offset` runs past four bytes (values above 0x0FFFFFFF).
    case overlongQuantity(offset: Int)
    /// The file holds more than `limit` events (`SMFReadLimits.maximumEvents`), meta and SysEx events included.
    case tooManyEvents(limit: Int)
    /// An event's time, in clip ticks, is past `MIDIClip.maximumLengthTicks`.
    case timeBeyondLimit(track: Int, ticks: Int64)
    /// A data byte at `offset` starts an event, but no channel status precedes it for running status. Meta and
    /// SysEx events cancel running status (RP-001), so a data byte right after one is refused this way.
    case missingRunningStatus(track: Int, offset: Int)
    /// The status byte at `offset` is a system common or real-time status (0xF1...0xFE other than 0xF7), which an
    /// SMF track cannot hold.
    case invalidStatus(track: Int, offset: Int, status: UInt8)
    /// The channel message whose data starts at `offset` has a data byte of 0x80 or above.
    case invalidDataByte(track: Int, offset: Int)
    /// The End of Track meta event at `offset` has a nonzero length.
    case malformedEndOfTrack(track: Int, offset: Int)
    /// Bytes follow the End of Track meta event of `track`, starting at `offset`.
    case eventAfterEndOfTrack(track: Int, offset: Int)
    /// The track chunk ends without an End of Track meta event.
    case missingEndOfTrack(track: Int)
    /// A Note On for a channel and note that is already sounding, in merged order; a clip note cannot overlap
    /// another of the same channel and note.
    case noteOnWhileSounding(track: Int, ticks: Int64, channel: UInt8, note: UInt8)
    /// A Note On is left with no Note Off to close it, after each tick's Note Offs first close notes sounding from
    /// earlier ticks (a retrigger written Note On first gives the tick's Note Off to the earlier note). `startTicks`
    /// is its Note On time in clip ticks; the note reported is the earliest such in read order.
    case noteNotReleased(channel: UInt8, note: UInt8, startTicks: Int64)
    /// `MIDIClip.make` refused the clip the file describes; item indexes are in read order, skipped events
    /// excluded.
    case clip(MIDIClipRefusal)
}
