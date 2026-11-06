//
//  StandardMIDIFile.swift
//  FluxKlang
//
//  A bounded Standard MIDI File (RP-001) codec for `MIDIClip` (#112 CL2):
//  pure bytes in and out, no file system I/O. The writer emits format 0 at
//  15,360 ticks per quarter, the clip resolution, so no tick is quantized.
//
//  Deliberate limits of this version:
//  - Tempo is never written: clip ticks are musical. The reader skips tempo,
//    time and key signature and every other meta event, counting each by kind in
//    `SMFReadReport`; none is converted. A caller-supplied tempo map is a follow-up.
//  - SysEx is refused on read: a clip holds channel-voice messages only.
//  - UMP capture export (media-contract.md §9.2), MIDI Clip File and playback
//    scheduling are out of scope.
//

/// The Standard MIDI File codec for `MIDIClip`. Writing then reading a clip returns it unchanged whenever its items
/// are in onset-tick order (see `SMFWriteResult.reorderedItems`).
enum StandardMIDIFile {
    /// Ticks per quarter written in every header: the clip resolution, `MusicalTime.ticksPerQuarter` (fits in 15
    /// bits, so bit 15, the SMPTE flag, is clear).
    static let division = UInt16(MusicalTime.ticksPerQuarter)
    /// The largest variable-length quantity: four bytes of seven bits.
    static let maximumQuantity: UInt32 = 0x0FFF_FFFF

    /// The declared losses of writing `clip` (media-contract.md §9.3). None applies to a clip, so the report is
    /// empty:
    /// - `timingQuantized`: the file division is the clip resolution, so every tick is written exactly.
    /// - `syntheticTempoMap`: every clip tick is a musical stamp; no tempo map is invented (none is written).
    /// - `velocityDownscaled`, `noteOnVelocityRemapped`, `valueDownscaled`, `attributeDropped`, `perNoteDropped`,
    ///   `umpOnlyDropped`, `fidelityUnverified`: a clip holds MIDI 1 channel-voice values only, checked by
    ///   `MIDIClip.make`, with no MIDI 2 or UMP data.
    /// - `passesOverlaid`: a clip is one pass; loops belong to `MIDIClipPlacement`, which is not written.
    /// - `groupsFlattened`: MIDI 1 messages carry no group.
    static func losses(of clip: MIDIClip) -> SMFExportLossReport {
        SMFExportLossReport(losses: [:])
    }

    /// The variable-length quantity of `value`, most significant group first. `value` must be at most
    /// `maximumQuantity`.
    static func quantity(_ value: UInt32) -> [UInt8] {
        precondition(value <= maximumQuantity, "a variable-length quantity holds at most 28 bits")
        var bytes = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            bytes.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
            rest >>= 7
        }
        return bytes
    }

    /// Reads the variable-length quantity at `offset`, stopping before `end`, and moves `offset` past it. Refuses
    /// a quantity longer than four bytes, so the value is at most `maximumQuantity`.
    static func readQuantity(_ bytes: [UInt8], at offset: inout Int, end: Int) throws(SMFRefusal) -> UInt32 {
        let start = offset
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard offset < end else { throw .truncated(offset: start) }
            let byte = bytes[offset]
            offset += 1
            value = value << 7 | UInt32(byte & 0x7F)
            if byte < 0x80 { return value }
        }
        throw .overlongQuantity(offset: start)
    }
}

/// The bounds of one read. A file past any bound is refused, never truncated.
struct SMFReadLimits: Equatable, Sendable {
    /// The most bytes a file may hold.
    var maximumFileBytes = 4 << 20
    /// The most MTrk chunks a header may declare.
    var maximumTracks = 64
    /// The most events, meta and End of Track included, across all tracks.
    var maximumEvents = 65_536

    /// 4 MiB, 64 tracks and 65,536 events: room for a full clip (`MIDIClip.maximumItems` notes are 32,768 events).
    static let standard = SMFReadLimits()
}
