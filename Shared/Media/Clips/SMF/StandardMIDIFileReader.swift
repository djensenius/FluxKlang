//
//  StandardMIDIFileReader.swift
//  FluxKlang
//
//  Reads Standard MIDI File bytes into a `MIDIClip` (#112 CL2), bounded by
//  `SMFReadLimits`. Formats 0 and 1 at a division that divides 15,360 are read;
//  each file tick scales exactly to clip ticks. Unknown chunks are skipped and
//  counted. Running status is honoured for channel messages and cancelled by
//  meta and SysEx events.
//
//  Format 1 tracks are merged into one clip in a fixed order: by tick, then
//  track index, then position in the track. Notes pair Note On to Note Off per
//  channel and note in that merged order, across tracks. Whatever the merged
//  events cannot form (a Note On while its note sounds, a Note Off with nothing
//  sounding, a note never released) is refused, as is anything `MIDIClip.make`
//  refuses. The clip length is the latest End of Track time.
//

extension StandardMIDIFile {
    /// The clip `bytes` describe, with a report of everything skipped, or the first refusal found. Checks run in
    /// file order: size, header (format, division, track count), chunks, the track count found, each track's
    /// events in order, then note pairing in merged order, then `MIDIClip.make`.
    static func read(_ bytes: [UInt8], limits: SMFReadLimits = .standard) throws(SMFRefusal) -> SMFReadResult {
        guard bytes.count <= limits.maximumFileBytes else {
            throw .fileTooLarge(bytes: bytes.count, limit: limits.maximumFileBytes)
        }
        var offset = 0
        let header = try header(bytes, at: &offset, limits: limits)
        var tracks: [Range<Int>] = []
        var unknownChunks = 0
        while offset < bytes.count {
            guard let next = try chunk(bytes, at: &offset) else { throw .truncated(offset: offset) }
            if next.type.elementsEqual("MTrk".utf8) { tracks.append(next.body) } else { unknownChunks += 1 }
        }
        guard tracks.count == Int(header.tracks) else {
            throw .trackCountMismatch(declared: header.tracks, found: tracks.count)
        }
        let scale = MusicalTime.ticksPerQuarter / Int64(header.division)
        var parser = TrackParser(bytes: bytes, scale: scale, limits: limits)
        var timed: [Timed] = []
        var lengthTicks: Int64 = 0
        for (track, body) in tracks.enumerated() {
            lengthTicks = max(lengthTicks, try parser.parse(track: track, body: body, into: &timed))
        }
        timed.sort { ($0.ticks, $0.track, $0.position) < ($1.ticks, $1.track, $1.position) }
        let clipItems = try items(of: timed)
        let clip: MIDIClip
        do {
            clip = try MIDIClip.make(lengthTicks: lengthTicks, items: clipItems)
        } catch {
            throw .clip(error)
        }
        let report = SMFReadReport(format: header.format, division: header.division, tracks: tracks.count,
                                   ignoredMeta: parser.ignoredMeta, unknownChunks: unknownChunks,
                                   ignoredHeaderBytes: header.extraBytes)
        return SMFReadResult(clip: clip, report: report)
    }

    /// One channel message of the merged tracks, in clip ticks.
    private struct Timed {
        let ticks: Int64
        let track: Int
        let position: Int
        let message: MIDI1Semantic
    }

    /// The fields of an `MThd` chunk this version reads.
    private struct Header {
        let format: UInt16
        let tracks: UInt16
        let division: UInt16
        /// Header bytes past the first six.
        let extraBytes: Int
    }

    /// The checked header chunk at `offset`, moving `offset` past it: format, then division, then track count.
    private static func header(_ bytes: [UInt8], at offset: inout Int,
                               limits: SMFReadLimits) throws(SMFRefusal) -> Header {
        guard let chunk = try chunk(bytes, at: &offset), chunk.type.elementsEqual("MThd".utf8),
              chunk.body.count >= 6 else { throw .missingHeader }
        let start = chunk.body.lowerBound
        let header = Header(format: word(bytes, at: start), tracks: word(bytes, at: start + 2),
                            division: word(bytes, at: start + 4), extraBytes: chunk.body.count - 6)
        guard header.format <= 1 else { throw .unsupportedFormat(header.format) }
        guard header.division & 0x8000 == 0 else { throw .smpteDivision(header.division) }
        guard header.division > 0, MusicalTime.ticksPerQuarter % Int64(header.division) == 0 else {
            throw .unsupportedDivision(header.division)
        }
        guard header.tracks > 0, Int(header.tracks) <= limits.maximumTracks,
              header.format == 1 || header.tracks == 1 else {
            throw .trackCountOutOfRange(declared: header.tracks, limit: limits.maximumTracks)
        }
        return header
    }

    /// The chunk at `offset`, moving `offset` past it; `nil` when fewer than 8 bytes remain.
    private static func chunk(_ bytes: [UInt8], at offset: inout Int) throws(SMFRefusal)
        -> (type: ArraySlice<UInt8>, body: Range<Int>)? {
        let start = offset
        guard bytes.count - start >= 8 else { return nil }
        let type = bytes[start..<start + 4]
        let length = UInt32(word(bytes, at: start + 4)) << 16 | UInt32(word(bytes, at: start + 6))
        guard UInt64(length) <= UInt64(bytes.count - start - 8) else {
            throw .chunkOverrunsFile(offset: start, length: length)
        }
        offset = start + 8 + Int(length)
        return (type, start + 8..<offset)
    }

    private static func word(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    /// Clip items from merged messages: a note item at its Note On, completed at the matching Note Off; any other
    /// message as an event item at its tick.
    private static func items(of timed: [Timed]) throws(SMFRefusal) -> [MIDIClipItem] {
        var items: [MIDIClipItem] = []
        var sounding: [UInt16: Int] = [:]
        for event in timed {
            switch event.message {
            case let .noteOn(channel, note, velocity):
                let key = UInt16(channel) << 8 | UInt16(note)
                guard sounding[key] == nil else {
                    throw .noteOnWhileSounding(track: event.track, ticks: event.ticks, channel: channel, note: note)
                }
                sounding[key] = items.count
                items.append(.note(MIDIClipNote(channel: channel, note: note, velocity: velocity,
                                                startTicks: event.ticks, endTicks: event.ticks)))
            case let .noteOff(channel, note, velocity):
                guard let index = sounding.removeValue(forKey: UInt16(channel) << 8 | UInt16(note)),
                      case .note(var span) = items[index] else {
                    throw .noteOffWithoutNoteOn(track: event.track, ticks: event.ticks, channel: channel, note: note)
                }
                span.endTicks = event.ticks
                span.releaseVelocity = velocity
                items[index] = .note(span)
            default:
                items.append(.event(ticks: event.ticks, message: event.message))
            }
        }
        if let index = sounding.values.min(), case .note(let span) = items[index] {
            throw .noteNotReleased(channel: span.channel, note: span.note, startTicks: span.startTicks)
        }
        return items
    }

    /// Parses track chunks into timed channel messages, counting events against the file-wide bound and skipped
    /// meta events by kind.
    private struct TrackParser {
        let bytes: [UInt8]
        let scale: Int64
        let limits: SMFReadLimits
        private(set) var events = 0
        private(set) var ignoredMeta: [SMFMetaKind: Int] = [:]

        init(bytes: [UInt8], scale: Int64, limits: SMFReadLimits) {
            self.bytes = bytes
            self.scale = scale
            self.limits = limits
        }

        /// Appends the track's channel messages to `timed` and returns its End of Track time in clip ticks.
        mutating func parse(track: Int, body: Range<Int>, into timed: inout [Timed]) throws(SMFRefusal) -> Int64 {
            var offset = body.lowerBound
            let end = body.upperBound
            var ticks: Int64 = 0
            var running: UInt8?
            var position = 0
            while offset < end {
                events += 1
                guard events <= limits.maximumEvents else { throw .tooManyEvents(limit: limits.maximumEvents) }
                ticks += Int64(try StandardMIDIFile.readQuantity(bytes, at: &offset, end: end)) * scale
                guard ticks <= MIDIClip.maximumLengthTicks else { throw .timeBeyondLimit(track: track, ticks: ticks) }
                guard offset < end else { throw .truncated(offset: offset) }
                let start = offset
                switch bytes[start] {
                case 0xFF:
                    running = nil
                    if try meta(track: track, at: &offset, end: end) { return ticks }
                case 0xF0, 0xF7:
                    throw .sysExNotRepresentable(track: track, ticks: ticks)
                case 0xF1...0xFE:
                    throw .invalidStatus(track: track, offset: start, status: bytes[start])
                default:
                    let message = try channelMessage(track: track, at: &offset, end: end, running: &running)
                    timed.append(Timed(ticks: ticks, track: track, position: position, message: message))
                    position += 1
                }
            }
            throw .missingEndOfTrack(track: track)
        }

        /// Skips and counts the meta event at `offset`, or checks End of Track: `true` exactly at a well-formed End
        /// of Track that ends the chunk.
        private mutating func meta(track: Int, at offset: inout Int, end: Int) throws(SMFRefusal) -> Bool {
            let start = offset
            offset += 1
            guard offset < end else { throw .truncated(offset: start) }
            let type = bytes[offset]
            offset += 1
            let length = Int(try StandardMIDIFile.readQuantity(bytes, at: &offset, end: end))
            guard length <= end - offset else { throw .truncated(offset: start) }
            offset += length
            guard type == 0x2F else {
                ignoredMeta[SMFMetaKind(type: type), default: 0] += 1
                return false
            }
            guard length == 0 else { throw .malformedEndOfTrack(track: track, offset: start) }
            guard offset == end else { throw .eventAfterEndOfTrack(track: track, offset: offset) }
            return true
        }

        /// The channel message at `offset`, with its own status or the running one.
        private func channelMessage(track: Int, at offset: inout Int, end: Int,
                                    running: inout UInt8?) throws(SMFRefusal) -> MIDI1Semantic {
            let start = offset
            if bytes[offset] >= 0x80 {
                running = bytes[offset]
                offset += 1
            }
            guard let status = running else { throw .missingRunningStatus(track: track, offset: start) }
            let count = status & 0xE0 == 0xC0 ? 1 : 2
            guard end - offset >= count else { throw .truncated(offset: start) }
            let data = offset
            offset += count
            let second = count == 2 ? bytes[data + 1] : nil
            guard let message = MIDI1Event.channel(status: status, data1: bytes[data], data2: second).semantic else {
                throw .invalidDataByte(track: track, offset: data)
            }
            return message
        }
    }
}
