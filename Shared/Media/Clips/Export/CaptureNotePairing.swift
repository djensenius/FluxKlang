//
//  CaptureNotePairing.swift
//  FluxKlang
//
//  Pairs the MIDI 1 channel-voice messages of a capture into clip items (#112 CL5): a Note On opens a note on its
//  channel and note, a Note Off (or a Note On of velocity 0) closes it. `MIDIClip` refuses Note On and Note Off as
//  events, so every sounding note must become a `MIDIClipNote` span.
//

/// One MIDI 1 channel-voice message at a clip tick.
struct CaptureTimedMessage: Equatable, Sendable {
    let ticks: Int64
    let message: MIDI1Semantic
}

/// The clip items of one capture and what pairing had to repair or drop. Built only by `pair`.
struct CaptureNotePairing: Equatable, Sendable {
    /// The release velocity of a note that is still open at the end and of a note closed by a velocity-0 Note On.
    /// A Note Off with no open note produces no note and is only counted.
    static let defaultReleaseVelocity: UInt8 = 64

    /// Notes at their Note On position and the other events in input order, so items are in onset order.
    let items: [MIDIClipItem]
    /// Note Offs (or velocity-0 Note Ons) with no open note on their channel and note, dropped and counted.
    let unpairedOffs: Int
    /// Notes still open at the end, closed at the clip length.
    let openNotesClosed: Int
    /// Zero-length notes (End == Start), widened by one tick.
    let widenedNotes: Int

    private init(items: [MIDIClipItem], unpairedOffs: Int, openNotesClosed: Int, widenedNotes: Int) {
        self.items = items
        self.unpairedOffs = unpairedOffs
        self.openNotesClosed = openNotesClosed
        self.widenedNotes = widenedNotes
    }

    private struct Open {
        let index: Int
        let note: MIDIClipNote
    }

    /// Pairs `events`, which must be in nondecreasing tick order (a later Note Off before its Note On is left to
    /// the clip to refuse), per channel and note. Work is linear in `events.count`: one pass over the ticks, one
    /// pairing pass, and one pass over the notes still open. Refuses any tick outside `0...lengthTicks`, then a
    /// Note On on a note that is sounding, then more than `MIDIClip.maximumItems` items. `otherItems` is how many
    /// items outside `events` share that cap (the SysEx events of an export): they count toward the limit and are
    /// included in the refusal's `count`, even when the paired items alone exceed it. `lengthTicks` must not be
    /// negative: `0...lengthTicks` traps on a negative bound (`make` guarantees at least 1).
    static func pair(_ events: [CaptureTimedMessage], lengthTicks: Int64,
                     otherItems: Int = 0) throws(CaptureClipExportRefusal) -> CaptureNotePairing {
        for event in events where !(0...lengthTicks).contains(event.ticks) {
            throw .ticksOutOfRange(ticks: event.ticks, lengthTicks: lengthTicks)
        }
        var items: [MIDIClipItem] = []
        items.reserveCapacity(events.count)
        var open: [UInt16: Open] = [:]
        var unpaired = 0
        var widened = 0
        for event in events {
            switch event.message {
            case let .noteOn(channel, note, velocity) where velocity > 0:
                let key = key(channel, note)
                if let sounding = open[key] {
                    throw .noteOnWhileSounding(channel: channel, note: note, ticks: event.ticks,
                                               sinceTicks: sounding.note.startTicks)
                }
                let span = MIDIClipNote(channel: channel, note: note, velocity: velocity,
                                        releaseVelocity: defaultReleaseVelocity, startTicks: event.ticks,
                                        endTicks: event.ticks)
                open[key] = Open(index: items.count, note: span)
                items.append(.note(span))
            case let .noteOn(channel, note, _):
                try close(channel, note, at: event.ticks, release: defaultReleaseVelocity, items: &items,
                          open: &open, unpaired: &unpaired, widened: &widened, lengthTicks: lengthTicks)
            case let .noteOff(channel, note, velocity):
                try close(channel, note, at: event.ticks, release: velocity, items: &items, open: &open,
                          unpaired: &unpaired, widened: &widened, lengthTicks: lengthTicks)
            default:
                items.append(.event(ticks: event.ticks, message: event.message))
            }
        }
        let leftOpen = open.values.sorted { $0.index < $1.index }
        for sounding in leftOpen {
            let span = try ended(sounding.note, at: lengthTicks, release: sounding.note.releaseVelocity,
                                 widened: &widened, lengthTicks: lengthTicks)
            items[sounding.index] = .note(span)
        }
        guard items.count + otherItems <= MIDIClip.maximumItems else {
            throw .tooManyItems(count: items.count + otherItems, limit: MIDIClip.maximumItems)
        }
        return CaptureNotePairing(items: items, unpairedOffs: unpaired, openNotesClosed: leftOpen.count,
                                  widenedNotes: widened)
    }

    // The close step threads the pairing's running state; the parameters are kept flat on purpose.
    // swiftlint:disable function_parameter_count
    private static func close(_ channel: UInt8, _ note: UInt8, at ticks: Int64, release: UInt8,
                              items: inout [MIDIClipItem], open: inout [UInt16: Open], unpaired: inout Int,
                              widened: inout Int, lengthTicks: Int64) throws(CaptureClipExportRefusal) {
        guard let sounding = open.removeValue(forKey: key(channel, note)) else {
            unpaired += 1
            return
        }
        items[sounding.index] = .note(try ended(sounding.note, at: ticks, release: release, widened: &widened,
                                                lengthTicks: lengthTicks))
    }
    // swiftlint:enable function_parameter_count

    /// `note` ending at `ticks`, one tick later when that would make it zero-length.
    private static func ended(_ note: MIDIClipNote, at ticks: Int64, release: UInt8, widened: inout Int,
                              lengthTicks: Int64) throws(CaptureClipExportRefusal) -> MIDIClipNote {
        var span = note
        span.releaseVelocity = release
        span.endTicks = ticks
        if ticks == note.startTicks {
            let (end, overflow) = ticks.addingReportingOverflow(1)
            guard !overflow else { throw .ticksOutOfRange(ticks: ticks, lengthTicks: lengthTicks) }
            span.endTicks = end
            widened += 1
        }
        return span
    }

    private static func key(_ channel: UInt8, _ note: UInt8) -> UInt16 {
        UInt16(channel) << 8 | UInt16(note)
    }
}
