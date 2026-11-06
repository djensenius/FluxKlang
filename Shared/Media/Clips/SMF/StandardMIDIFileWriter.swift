//
//  StandardMIDIFileWriter.swift
//  FluxKlang
//
//  Writes a `MIDIClip` as a format 0 Standard MIDI File (#112 CL2). Every
//  event carries its own status byte (no running status). Events are in tick
//  order; at one tick, Note Offs come first, then Note Ons and other events,
//  each by onset tick and authoring order, as `MIDIClipPlacement` plays them.
//  End of Track sits at the clip length. No tempo or other meta event is written.
//

extension StandardMIDIFile {
    /// `clip` as a format 0 file of one track at `division` ticks per quarter, with its declared losses (none).
    /// Every clip is representable: its length and every delta fit a four-byte quantity.
    static func write(_ clip: MIDIClip) -> SMFWriteResult {
        let order = clip.items.indices.sorted { (onset(clip.items[$0]), $0) < (onset(clip.items[$1]), $1) }
        var entries: [Entry] = []
        for (rank, index) in order.enumerated() {
            switch clip.items[index] {
            case .note(let note):
                let status = 0x80 | (note.channel - 1)
                entries.append(Entry(ticks: note.startTicks, offFirst: 1, rank: rank,
                                     bytes: [status | 0x10, note.note, note.velocity]))
                entries.append(Entry(ticks: note.endTicks, offFirst: 0, rank: rank,
                                     bytes: [status, note.note, note.releaseVelocity]))
            case let .event(ticks, message):
                entries.append(Entry(ticks: ticks, offFirst: 1, rank: rank, bytes: bytes(of: message)))
            }
        }
        entries.sort { ($0.ticks, $0.offFirst, $0.rank) < ($1.ticks, $1.offFirst, $1.rank) }
        var track: [UInt8] = []
        var previous: Int64 = 0
        for entry in entries {
            track += quantity(UInt32(entry.ticks - previous)) + entry.bytes
            previous = entry.ticks
        }
        track += quantity(UInt32(clip.lengthTicks - previous)) + [0xFF, 0x2F, 0x00]
        let header: [UInt8] = Array("MThd".utf8) + bigEndian(6, count: 4) + bigEndian(0, count: 2)
            + bigEndian(1, count: 2) + bigEndian(Int(division), count: 2)
        let bytes = header + Array("MTrk".utf8) + bigEndian(track.count, count: 4) + track
        let reordered = order.enumerated().filter { $0.offset != $0.element }.count
        return SMFWriteResult(bytes: bytes, losses: losses(of: clip), reorderedItems: reordered)
    }

    /// One event of the track: `offFirst` is 0 for a Note Off and 1 otherwise; `rank` is the item's onset order.
    private struct Entry {
        let ticks: Int64
        let offFirst: Int
        let rank: Int
        let bytes: [UInt8]
    }

    /// A note's start tick or an event's tick.
    private static func onset(_ item: MIDIClipItem) -> Int64 {
        switch item {
        case .note(let note): note.startTicks
        case .event(let ticks, _): ticks
        }
    }

    /// The MIDI 1 bytes of a clip event. `MIDIClip.make` admits only the channel-voice cases below.
    private static func bytes(of message: MIDI1Semantic) -> [UInt8] {
        switch message {
        case let .polyphonicPressure(channel, note, pressure): [0xA0 | (channel - 1), note, pressure]
        case let .controlChange(channel, controller, value): [0xB0 | (channel - 1), controller, value]
        case let .programChange(channel, program): [0xC0 | (channel - 1), program]
        case let .channelPressure(channel, pressure): [0xD0 | (channel - 1), pressure]
        case let .pitchBend(channel, value): [0xE0 | (channel - 1), UInt8(value & 0x7F), UInt8(value >> 7)]
        case .noteOn, .noteOff, .systemCommon, .realTime, .sysEx:
            preconditionFailure("MIDIClip.make admits no \(message) event")
        }
    }

    private static func bigEndian(_ value: Int, count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}
