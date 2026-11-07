//
//  SMFTempoScan.swift
//  FluxKlang
//
//  Scans Standard MIDI File bytes for tempo (FF 51) and time signature (FF 58)
//  meta events and returns them as a proposal (#112 CL6). It is a separate
//  pass over the same bytes the CL2 reader reads: the reader is untouched and
//  still counts both kinds in `SMFReadReport.ignoredMeta`.
//
//  Header, chunk and track structure follow the reader exactly (formats 0 and
//  1, a division that divides 15,360, `SMFReadLimits`, running status cancelled
//  by meta and SysEx events) and refuse the same defects with the same
//  `SMFRefusal` values, wrapped as `SMFTempoRefusal.file`. Channel, SysEx and
//  unrelated meta events are skipped by length. Note pairing and clip checks
//  are not made here, so a file the reader refuses only for them still scans.
//

enum SMFTempoScan {
    /// The tempo and meter proposed by `bytes`, or the first refusal found. Checks run in file order: size, header,
    /// chunks, then each track's events in order (a tempo or meter defect refuses at its place in that order), then
    /// the merge: `tooManySegments`, then `tooManyMeterChanges`. No partial proposal is ever returned.
    static func scan(_ bytes: [UInt8], limits: SMFReadLimits = .standard) throws(SMFTempoRefusal) -> SMFTempoProposal {
        guard bytes.count <= limits.maximumFileBytes else {
            throw .file(.fileTooLarge(bytes: bytes.count, limit: limits.maximumFileBytes))
        }
        var offset = 0
        let header = try header(bytes, at: &offset, limits: limits)
        let tracks = try trackBodies(bytes, from: offset, declared: header.tracks)
        var scanner = TrackScanner(bytes: bytes, scale: MusicalTime.ticksPerQuarter / Int64(header.division),
                                   limits: limits)
        for (track, body) in tracks.enumerated() {
            try scanner.scan(track: track, body: body)
        }
        return try merge(tempos: scanner.tempos, meters: scanner.meters)
    }

    /// One tempo event: its segment (validated, in clip ticks) and its place in the file.
    struct TempoEvent {
        let segment: TempoSegment
        let track: Int
        let position: Int
    }

    /// One time signature event, in clip ticks, and its place in the file.
    struct MeterEvent {
        let ticks: Int64
        let meter: MusicalMeter
        let track: Int
        let position: Int
    }

    private struct Header {
        let tracks: UInt16
        let division: UInt16
    }

    /// The checked header chunk at `offset`, moving `offset` past it: format, then division, then track count.
    private static func header(_ bytes: [UInt8], at offset: inout Int,
                               limits: SMFReadLimits) throws(SMFTempoRefusal) -> Header {
        guard let chunk = try chunk(bytes, at: &offset), chunk.type.elementsEqual("MThd".utf8),
              chunk.body.count >= 6 else { throw .file(.missingHeader) }
        let start = chunk.body.lowerBound
        let format = word(bytes, at: start)
        let tracks = word(bytes, at: start + 2)
        let division = word(bytes, at: start + 4)
        guard format <= 1 else { throw .file(.unsupportedFormat(format)) }
        guard division & 0x8000 == 0 else { throw .file(.smpteDivision(division)) }
        guard division > 0, MusicalTime.ticksPerQuarter % Int64(division) == 0 else {
            throw .file(.unsupportedDivision(division))
        }
        guard tracks > 0, Int(tracks) <= limits.maximumTracks, format == 1 || tracks == 1 else {
            throw .file(.trackCountOutOfRange(declared: tracks, limit: limits.maximumTracks))
        }
        return Header(tracks: tracks, division: division)
    }

    /// The MTrk bodies from `offset` to the end of the file; unknown chunks are skipped. Refuses more MTrk chunks
    /// than `declared` at the first extra one, and fewer at the end.
    private static func trackBodies(_ bytes: [UInt8], from start: Int,
                                    declared: UInt16) throws(SMFTempoRefusal) -> [Range<Int>] {
        var offset = start
        var tracks: [Range<Int>] = []
        while offset < bytes.count {
            guard let next = try chunk(bytes, at: &offset) else { throw .file(.truncated(offset: offset)) }
            guard next.type.elementsEqual("MTrk".utf8) else { continue }
            tracks.append(next.body)
            guard tracks.count <= Int(declared) else {
                throw .file(.trackCountMismatch(declared: declared, found: tracks.count))
            }
        }
        guard tracks.count == Int(declared) else {
            throw .file(.trackCountMismatch(declared: declared, found: tracks.count))
        }
        return tracks
    }

    /// The chunk at `offset`, moving `offset` past it; `nil` when fewer than 8 bytes remain.
    private static func chunk(_ bytes: [UInt8], at offset: inout Int) throws(SMFTempoRefusal)
        -> (type: ArraySlice<UInt8>, body: Range<Int>)? {
        let start = offset
        guard bytes.count - start >= 8 else { return nil }
        let type = bytes[start..<start + 4]
        let length = UInt32(word(bytes, at: start + 4)) << 16 | UInt32(word(bytes, at: start + 6))
        guard UInt64(length) <= UInt64(bytes.count - start - 8) else {
            throw .file(.chunkOverrunsFile(offset: start, length: length))
        }
        offset = start + 8 + Int(length)
        return (type, start + 8..<offset)
    }

    private static func word(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    /// Merges the events in (clip tick, track, position) order. See `SMFTempoProposal` for the rules.
    private static func merge(tempos: [TempoEvent], meters: [MeterEvent]) throws(SMFTempoRefusal) -> SMFTempoProposal {
        let merged = try mergeTempos(tempos)
        let orderedMeters = meters.sorted { ($0.ticks, $0.track, $0.position) < ($1.ticks, $1.track, $1.position) }
        var later = orderedMeters.map { SMFMeterChange(atTicks: $0.ticks, meter: $0.meter) }
        var initial: MusicalMeter?
        if let first = orderedMeters.first, first.ticks == 0 {
            initial = first.meter
            later.removeFirst()
        }
        return try SMFTempoProposal.make(segments: merged.segments, initialMeter: initial,
                                         laterMeterChanges: later, counts: merged.counts)
    }

    /// The segments of `tempos`: one per distinct tick (the last in merged order wins), none equal in tempo to the one
    /// in force, after the default at tick 0 when no tempo is there.
    private static func mergeTempos(_ tempos: [TempoEvent])
        throws(SMFTempoRefusal) -> (segments: [TempoSegment], counts: SMFTempoCounts) {
        let ordered = tempos.sorted {
            ($0.segment.atTicks, $0.track, $0.position) < ($1.segment.atTicks, $1.track, $1.position)
        }
        var segments: [TempoSegment] = []
        var superseded = 0
        var coalesced = 0
        let defaulted = ordered.first?.segment.atTicks != 0
        if defaulted {
            segments.append(try segment(atTicks: 0, microsPerQuarter: SMFTempoProposal.defaultMicrosPerQuarter))
        }
        var index = 0
        while index < ordered.count {
            var last = index
            while last + 1 < ordered.count, ordered[last + 1].segment.atTicks == ordered[index].segment.atTicks {
                last += 1
            }
            superseded += last - index
            let winner = ordered[last].segment
            if segments.last?.microsPerQuarter == winner.microsPerQuarter {
                coalesced += 1
            } else {
                segments.append(winner)
            }
            index = last + 1
        }
        return (segments, SMFTempoCounts(supersededTempos: superseded, coalescedTempos: coalesced,
                                         defaultedInitialTempo: defaulted))
    }

    /// A segment, refusing as the scan does a tempo the contract does not accept.
    static func segment(atTicks: Int64, microsPerQuarter: Int64) throws(SMFTempoRefusal) -> TempoSegment {
        do {
            return try TempoSegment(atTicks: atTicks, microsPerQuarter: microsPerQuarter)
        } catch {
            throw .tempoOutOfRange(atTicks: atTicks, microsPerQuarter: microsPerQuarter)
        }
    }
}
