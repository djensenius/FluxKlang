//
//  StandardMIDIFileReader.swift
//  FluxKlang
//
//  Reads Standard MIDI File bytes into a `MIDIClip` (#112 CL2), bounded by
//  `SMFReadLimits`. Formats 0 and 1 at a division that divides 15,360 are read;
//  each file tick scales exactly to clip ticks. Running status is honoured for
//  channel messages and cancelled by meta and SysEx events.
//
//  Skipped and counted in `SMFReadReport`, never refused and never silent:
//  unknown chunks, header bytes past six, meta events, SysEx events (F0, and F7
//  escapes and continuation packets, each with its delta time kept), the
//  controllers `MIDIClip.make` refuses (sustain 64, sostenuto 66, hold 2 69 and
//  channel mode 120...127), Note Offs with nothing sounding, zero-length notes
//  (a Note On and its Note Off at one tick), and non-note events at or after
//  the clip length (End of Track), such as a final pitch-bend reset.
//
//  Trailing bytes are strict: fewer than 8 bytes after the last chunk are
//  refused as `truncated`, and bytes after End of Track as
//  `eventAfterEndOfTrack`, since either marks a damaged file. Running status is
//  not carried across meta or SysEx events (RP-001): a data byte after one is
//  refused as `missingRunningStatus`.
//
//  Format 1 tracks are merged into one clip in a fixed order: by tick, then
//  Note Offs before other messages (as the writer orders them), then track
//  index, then position in the track. Notes pair Note On to Note Off per
//  channel and note in that merged order, across tracks; a Note Off closes only
//  a note sounding from an earlier tick, so no note is ever stretched. A Note
//  Off with nothing sounding pairs with a later-in-file Note On of the same
//  channel and note at its tick as a skipped zero-length note (see
//  `ItemBuilder`). A Note On while its note sounds and a Note On with no Note
//  Off after it are refused, as is anything `MIDIClip.make` refuses. The clip
//  length is the latest End of Track time.
//

extension StandardMIDIFile {
    /// The clip `bytes` describe, with a report of everything skipped, or the first refusal found. Checks run in
    /// file order: size, header (format, division, track count), chunks (refused as soon as there are more MTrk
    /// chunks than declared), the track count found, each track's events in order, then note pairing in merged
    /// order, then `MIDIClip.make`.
    static func read(_ bytes: [UInt8], limits: SMFReadLimits = .standard) throws(SMFRefusal) -> SMFReadResult {
        try readCountingPairingSteps(bytes, limits: limits).result
    }

    /// `read(_:limits:)`, with the zero-length pairing work it did: one step per pending Note Off a Note On's
    /// cursor passes or takes. Tests use it to pin linear pairing; it is built only from this read's own state.
    static func readCountingPairingSteps(_ bytes: [UInt8], limits: SMFReadLimits = .standard)
        throws(SMFRefusal) -> (result: SMFReadResult, pairingSteps: Int) {
        guard bytes.count <= limits.maximumFileBytes else {
            throw .fileTooLarge(bytes: bytes.count, limit: limits.maximumFileBytes)
        }
        var offset = 0
        let header = try header(bytes, at: &offset, limits: limits)
        var tracks: [Range<Int>] = []
        var unknownChunks = 0
        while offset < bytes.count {
            guard let next = try chunk(bytes, at: &offset) else { throw .truncated(offset: offset) }
            if next.type.elementsEqual("MTrk".utf8) {
                tracks.append(next.body)
                guard tracks.count <= Int(header.tracks) else {
                    throw .trackCountMismatch(declared: header.tracks, found: tracks.count)
                }
            } else {
                unknownChunks += 1
            }
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
        timed.sort {
            ($0.ticks, $0.offFirst, $0.track, $0.position) < ($1.ticks, $1.offFirst, $1.track, $1.position)
        }
        var builder = ItemBuilder(lengthTicks: lengthTicks)
        for event in timed {
            try builder.add(event)
        }
        try builder.finish()
        let clip: MIDIClip
        do {
            clip = try MIDIClip.make(lengthTicks: lengthTicks, items: builder.items)
        } catch {
            throw .clip(error)
        }
        let report = SMFReadReport(format: header.format, division: header.division, tracks: tracks.count,
                                   ignoredMeta: parser.ignoredMeta, unknownChunks: unknownChunks,
                                   ignoredHeaderBytes: header.extraBytes, ignoredSysEx: parser.ignoredSysEx,
                                   ignoredControllers: parser.ignoredControllers,
                                   ignoredNoteOffs: builder.ignoredNoteOffs,
                                   ignoredZeroLengthNotes: builder.ignoredZeroLengthNotes,
                                   ignoredEventsAtEnd: builder.ignoredEventsAtEnd)
        return (SMFReadResult(clip: clip, report: report), builder.pairingSteps)
    }

    /// One channel message of the merged tracks, in clip ticks.
    private struct Timed {
        let ticks: Int64
        let track: Int
        let position: Int
        let message: MIDI1Semantic

        /// 0 for a Note Off (or Note On with velocity 0), 1 otherwise: at one tick, Note Offs come first.
        var offFirst: Int {
            if case .noteOff = message { 0 } else { 1 }
        }
    }

    /// Controllers `MIDIClip.make` refuses, which the reader skips and counts instead: sustain (64), sostenuto
    /// (66), hold 2 (69) and the channel mode messages (120...127).
    private static let skippedControllers = Set<UInt8>([64, 66, 69] + Array(120...127))

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

    /// One channel and note's pending Note Offs in `ItemBuilder`: each one's place in the file, in merged order, and
    /// a cursor at the first that no Note On has taken or passed.
    private struct PendingOffs {
        var places: [(track: Int, position: Int)] = []
        var next = 0
    }

    /// Builds clip items from merged messages: a note item at its Note On, completed at the matching Note Off; any
    /// other message as an event item at its tick. Skips and counts what a clip cannot hold:
    /// - a zero-length note: a Note Off that finds nothing sounding pairs with a Note On of the same channel and
    ///   note at the same tick that comes earlier in the file, by track index and then position (so across tracks
    ///   the On's track must be lower). Note Offs sort first within a tick, so such an Off waits, pending, until
    ///   the tick ends; each On takes the earliest pending Off after it in the file. Neither becomes a note.
    ///   Ons reach a tick in file order, so a cursor per channel and note passes or takes each Off once; linear.
    /// - a Note Off still pending when the tick ends: nothing was sounding (`ignoredNoteOffs`);
    /// - a non-note event at or after the clip length, which a clip cannot hold (`ignoredEventsAtEnd`).
    /// A Note Off never extends a note: it closes only a note sounding from an earlier tick.
    private struct ItemBuilder {
        let lengthTicks: Int64
        private(set) var items: [MIDIClipItem] = []
        private(set) var ignoredNoteOffs = 0
        private(set) var ignoredZeroLengthNotes = 0
        private(set) var ignoredEventsAtEnd = 0
        /// Pending Note Offs passed or taken by a Note On's cursor: at most one step per Note Off.
        private(set) var pairingSteps = 0
        /// The item index of each sounding note, by channel and note.
        private var sounding: [UInt16: Int] = [:]
        /// Note Offs at `pendingTicks` that found nothing sounding, by channel and note.
        private var pending: [UInt16: PendingOffs] = [:]
        /// How many of `pending`'s Note Offs no Note On has taken.
        private var unpaired = 0
        private var pendingTicks: Int64 = 0

        init(lengthTicks: Int64) {
            self.lengthTicks = lengthTicks
        }

        private static func key(_ channel: UInt8, _ note: UInt8) -> UInt16 {
            UInt16(channel) << 8 | UInt16(note)
        }

        /// Adds the next message in merged order.
        mutating func add(_ event: Timed) throws(SMFRefusal) {
            if event.ticks != pendingTicks {
                endPendingTick()
                pendingTicks = event.ticks
            }
            switch event.message {
            case let .noteOn(channel, note, velocity):
                let key = Self.key(channel, note)
                if takePendingOff(key, after: event) {
                    ignoredZeroLengthNotes += 1
                    return
                }
                guard sounding[key] == nil else {
                    throw .noteOnWhileSounding(track: event.track, ticks: event.ticks, channel: channel, note: note)
                }
                sounding[key] = items.count
                items.append(.note(MIDIClipNote(channel: channel, note: note, velocity: velocity,
                                                startTicks: event.ticks, endTicks: event.ticks)))
            case let .noteOff(channel, note, velocity):
                let key = Self.key(channel, note)
                guard let index = sounding.removeValue(forKey: key), case .note(var span) = items[index] else {
                    pending[key, default: PendingOffs()].places.append((event.track, event.position))
                    unpaired += 1
                    return
                }
                span.endTicks = event.ticks
                span.releaseVelocity = velocity
                items[index] = .note(span)
            default:
                guard event.ticks < lengthTicks else {
                    ignoredEventsAtEnd += 1
                    return
                }
                items.append(.event(ticks: event.ticks, message: event.message))
            }
        }

        /// Ends the last tick and refuses a note still sounding: a Note On left with no Note Off to close it.
        mutating func finish() throws(SMFRefusal) {
            endPendingTick()
            if let index = sounding.values.min(), case .note(let span) = items[index] {
                throw .noteNotReleased(channel: span.channel, note: span.note, startTicks: span.startTicks)
            }
        }

        /// Takes the earliest pending Note Off of `key` after `event` in the file, if there is one. Within a tick,
        /// Note Ons arrive in file order, so an Off before this On is before every later On too: the cursor passes
        /// it for good, and each Off is passed or taken once.
        private mutating func takePendingOff(_ key: UInt16, after event: Timed) -> Bool {
            guard var offs = pending[key] else { return false }
            defer { pending[key] = offs }
            while offs.next < offs.places.count,
                  !((offs.places[offs.next].track, offs.places[offs.next].position) > (event.track, event.position)) {
                offs.next += 1
                pairingSteps += 1
            }
            guard offs.next < offs.places.count else { return false }
            offs.next += 1
            pairingSteps += 1
            unpaired -= 1
            return true
        }

        /// Counts the Note Offs of the tick that ends that found nothing sounding and paired with no Note On.
        private mutating func endPendingTick() {
            ignoredNoteOffs += unpaired
            unpaired = 0
            pending = [:]
        }
    }

    /// Parses track chunks into timed channel messages, counting events against the file-wide bound and skipped
    /// meta events, SysEx events and controllers by kind.
    private struct TrackParser {
        let bytes: [UInt8]
        let scale: Int64
        let limits: SMFReadLimits
        private(set) var events = 0
        private(set) var ignoredMeta: [SMFMetaKind: Int] = [:]
        private(set) var ignoredSysEx: [SMFSysExKind: Int] = [:]
        private(set) var ignoredControllers: [UInt8: Int] = [:]

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
                    running = nil
                    try sysEx(at: &offset, end: end)
                case 0xF1...0xFE:
                    throw .invalidStatus(track: track, offset: start, status: bytes[start])
                default:
                    let message = try channelMessage(track: track, at: &offset, end: end, running: &running)
                    guard !skipped(message) else { continue }
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

        /// Skips and counts the SysEx event at `offset`: F0 (a message, or the first packet of a divided one) or F7
        /// (an escape or a continuation packet), then its length and that many bytes.
        private mutating func sysEx(at offset: inout Int, end: Int) throws(SMFRefusal) {
            let start = offset
            offset += 1
            let length = Int(try StandardMIDIFile.readQuantity(bytes, at: &offset, end: end))
            guard length <= end - offset else { throw .truncated(offset: start) }
            offset += length
            ignoredSysEx[bytes[start] == 0xF0 ? .message : .escape, default: 0] += 1
        }

        /// Whether `message` is a controller in `skippedControllers`, counting it if so.
        private mutating func skipped(_ message: MIDI1Semantic) -> Bool {
            guard case let .controlChange(_, controller, _) = message,
                  StandardMIDIFile.skippedControllers.contains(controller) else { return false }
            ignoredControllers[controller, default: 0] += 1
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
