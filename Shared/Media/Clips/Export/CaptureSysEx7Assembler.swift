//
//  CaptureSysEx7Assembler.swift
//  FluxKlang
//
//  Assembles the SysEx7 (MT 0x3) captures of an export into whole messages (#584 SMF2a). Pure and value-typed; it
//  follows the state table of the kernel's `SysExAssembler` (one open message per source, here per stream and
//  group) but shares none of its types, and it has no size bound: a capture log is bounded already.
//

/// One assembled SysEx message: the payload bytes (7-bit, without F0 and F7) and where its first packet was
/// captured.
struct CaptureSysEx7Message: Equatable, Sendable {
    /// The musical ticks of the message's first packet.
    let ticks: Int64
    let stream: StreamID
    /// The index into `MIDICaptureLog.records` of the message's first packet.
    let index: Int
    let payload: [UInt8]

    /// The merge order of the export: ticks, stream id by UTF-8 bytes, record index.
    func precedes(_ other: CaptureSysEx7Message) -> Bool {
        if ticks != other.ticks { return ticks < other.ticks }
        if stream != other.stream {
            return stream.rawValue.utf8.lexicographicallyPrecedes(other.stream.rawValue.utf8)
        }
        return index < other.index
    }
}

/// Assembles SysEx7 packets, fed in capture order, into messages keyed by (stream, group).
///
/// | Packet | no message open | message open |
/// |---|---|---|
/// | `complete` | deliver | abort the open message, deliver |
/// | `start` | open | abort the open message, open anew |
/// | `continue` | dropped | append |
/// | `end` | dropped | append, deliver |
///
/// An aborted, orphaned or never finished message is not delivered; each of its packets counts once in `dropped`.
struct CaptureSysEx7Assembler: Equatable, Sendable {
    private struct Key: Hashable, Sendable {
        let stream: StreamID
        let group: UInt8
    }

    private struct Open: Equatable, Sendable {
        let ticks: Int64
        let index: Int
        var payload: [UInt8]
        var packets: Int
    }

    private var open: [Key: Open] = [:]
    /// Packets of messages that were aborted, orphaned or (after `finish`) never finished.
    private(set) var dropped = 0

    /// Takes the next packet of `stream`, captured at `ticks` as record `index`; returns the message it completes.
    mutating func accept(_ packet: UMPSysEx7Packet, stream: StreamID, ticks: Int64,
                         index: Int) -> CaptureSysEx7Message? {
        let key = Key(stream: stream, group: packet.group.value)
        switch packet.status {
        case .complete:
            abort(key)
            return CaptureSysEx7Message(ticks: ticks, stream: stream, index: index, payload: packet.bytes)
        case .start:
            abort(key)
            open[key] = Open(ticks: ticks, index: index, payload: packet.bytes, packets: 1)
            return nil
        case .continue:
            // The entry leaves the dictionary before the append, so the payload is uniquely referenced and the
            // append is in place; appending to a copy held by the dictionary would copy the whole payload each time.
            guard var message = open.removeValue(forKey: key) else {
                dropped += 1
                return nil
            }
            message.payload += packet.bytes
            message.packets += 1
            open[key] = message
            return nil
        case .end:
            guard var message = open.removeValue(forKey: key) else {
                dropped += 1
                return nil
            }
            message.payload += packet.bytes
            return CaptureSysEx7Message(ticks: message.ticks, stream: stream, index: message.index,
                                        payload: message.payload)
        }
    }

    /// Ends the selection: the packets of every message still open are dropped.
    mutating func finish() {
        dropped += open.values.reduce(0) { $0 + $1.packets }
        open = [:]
    }

    private mutating func abort(_ key: Key) {
        if let aborted = open.removeValue(forKey: key) { dropped += aborted.packets }
    }
}
