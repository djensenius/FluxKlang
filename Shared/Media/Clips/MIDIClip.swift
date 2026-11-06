//
//  MIDIClip.swift
//  FluxKlang
//
//  A checked MIDI clip (#112 CL1): note spans and other channel-voice events
//  in clip ticks at 15,360 per quarter, holding MIDI 1 values only. A clip is
//  built only through `make`, which validates every item; its storage is
//  read-only outside this file.
//

/// One authored note span `[startTicks, endTicks)` in clip ticks. Channels are 1...16 as in `MIDI1Semantic`.
struct MIDIClipNote: Hashable, Sendable {
    var channel: UInt8
    var note: UInt8
    /// Note On velocity, 1...127 (0 would be a Note Off in MIDI 1).
    var velocity: UInt8
    /// Note Off (release) velocity, 0...127.
    var releaseVelocity: UInt8 = 64
    var startTicks: Int64
    var endTicks: Int64
}

/// One authored clip item. Its index in `MIDIClip.items` is its authoring order.
enum MIDIClipItem: Equatable, Sendable {
    case note(MIDIClipNote)
    /// A channel-voice message other than Note On / Note Off at `ticks`.
    case event(ticks: Int64, message: MIDI1Semantic)
}

struct MIDIClip: Equatable, Sendable {
    /// The most items (notes plus events) one clip holds.
    static let maximumItems = 16_384
    /// 1024 bars of 4/4.
    static let maximumLengthTicks: Int64 = 1024 * 4 * MusicalTime.ticksPerQuarter

    private(set) var lengthTicks: Int64
    private(set) var items: [MIDIClipItem]

    private init(lengthTicks: Int64, items: [MIDIClipItem]) {
        self.lengthTicks = lengthTicks
        self.items = items
    }

    /// Controllers that hold notes past their Note Off: sustain (64), sostenuto (66) and hold 2 (69).
    private static let holdControllers: Set<UInt8> = [64, 66, 69]
    /// Channel mode messages (all sound off … poly on) act on notes the clip does not own.
    private static let channelModeControllers: ClosedRange<UInt8> = 120...127

    /// A clip of `lengthTicks` holding `items` in authoring order, or the first refusal found. Checks run in a fixed
    /// order: length, item count, then each item in authoring order (channel, data ranges, then the note span, or
    /// for an event its kind and then its tick), then note-holding controllers, then overlapping notes. The
    /// note-holding check refuses the first item, in authoring order, that is a hold controller (64, 66, 69) or a
    /// channel mode message (120...127) at any value, with `.unsupportedMessage(item:)`: stop() releases notes
    /// only with Note Offs, so a clip may not sustain or touch notes beyond its own spans.
    static func make(lengthTicks: Int64, items: [MIDIClipItem]) throws(MIDIClipRefusal) -> MIDIClip {
        guard (1...maximumLengthTicks).contains(lengthTicks) else { throw .lengthOutOfRange(lengthTicks) }
        guard items.count <= maximumItems else { throw .tooManyItems(count: items.count, limit: maximumItems) }
        var spans: [UInt16: [Span]] = [:]
        for (index, item) in items.enumerated() {
            switch item {
            case .note(let note):
                try check(note, item: index, lengthTicks: lengthTicks)
                spans[UInt16(note.channel) << 8 | UInt16(note.note), default: []]
                    .append(Span(start: note.startTicks, end: note.endTicks, item: index))
            case let .event(ticks, message):
                try check(message, item: index)
                guard ticks >= 0, ticks < lengthTicks else { throw .eventOutsideClip(item: index, ticks: ticks) }
            }
        }
        if let item = items.firstIndex(where: holdsNotes) { throw .unsupportedMessage(item: item) }
        for key in spans.keys.sorted() {
            let sorted = spans[key, default: []].sorted { ($0.start, $0.item) < ($1.start, $1.item) }
            for (earlier, later) in zip(sorted, sorted.dropFirst()) where earlier.end > later.start {
                throw .overlappingNotes(first: earlier.item, second: later.item)
            }
        }
        return MIDIClip(lengthTicks: lengthTicks, items: items)
    }

    /// The Note Off of the note at `item`; `nil` for a non-note item.
    func noteOff(item: Int) -> MIDI1Semantic? {
        guard case .note(let note) = items[item] else { return nil }
        return .noteOff(channel: note.channel, note: note.note, velocity: note.releaseVelocity)
    }

    private struct Span {
        let start: Int64
        let end: Int64
        let item: Int
    }

    /// Whether `item` is a hold controller or a channel mode message, either of which may leave notes sounding
    /// that stop() cannot release, or act on notes the clip does not own.
    private static func holdsNotes(_ item: MIDIClipItem) -> Bool {
        guard case .event(_, .controlChange(_, let controller, _)) = item else { return false }
        return holdControllers.contains(controller) || channelModeControllers.contains(controller)
    }

    private static func check(_ note: MIDIClipNote, item: Int, lengthTicks: Int64) throws(MIDIClipRefusal) {
        try check(channel: note.channel, item: item)
        guard note.note < 0x80, (1..<0x80).contains(note.velocity), note.releaseVelocity < 0x80 else {
            throw .invalidData(item: item)
        }
        guard note.startTicks >= 0, note.startTicks < note.endTicks, note.endTicks <= lengthTicks else {
            throw .invalidNoteSpan(item: item, startTicks: note.startTicks, endTicks: note.endTicks)
        }
    }

    private static func check(_ message: MIDI1Semantic, item: Int) throws(MIDIClipRefusal) {
        let valid: Bool
        switch message {
        case .noteOn, .noteOff:
            throw .noteMessageOutsideSpan(item: item)
        case .systemCommon, .realTime, .sysEx:
            throw .unsupportedMessage(item: item)
        case let .polyphonicPressure(channel, note, pressure):
            try check(channel: channel, item: item)
            valid = note < 0x80 && pressure < 0x80
        case let .controlChange(channel, controller, value):
            try check(channel: channel, item: item)
            valid = controller < 0x80 && value < 0x80
        case let .programChange(channel, program):
            try check(channel: channel, item: item)
            valid = program < 0x80
        case let .channelPressure(channel, pressure):
            try check(channel: channel, item: item)
            valid = pressure < 0x80
        case let .pitchBend(channel, value):
            try check(channel: channel, item: item)
            valid = value < 0x4000
        }
        guard valid else { throw .invalidData(item: item) }
    }

    private static func check(channel: UInt8, item: Int) throws(MIDIClipRefusal) {
        guard (1...16).contains(channel) else { throw .invalidChannel(item: item, channel: channel) }
    }
}
