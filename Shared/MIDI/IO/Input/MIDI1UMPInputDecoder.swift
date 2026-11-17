/// Why `MIDI1UMPInputDecoder` dropped a packet (or a whole batch) or cut an open SysEx short.
enum MIDI1UMPInputSkip: Equatable, Sendable {
    /// The splitter refused the batch, or the typed decoder for MT 0x1, 0x2 or 0x3 refused the packet.
    case malformed(UMPRefusal)
    /// An MT 0x4 MIDI 2.0 channel voice packet on a MIDI 1.0-protocol input.
    case protocolMismatch(UMPMessageType)
    /// A packet with no MIDI 1.0 byte form: utility, Data 128-bit, Flex Data, Stream or a reserved type.
    case notMIDI1(UMPMessageType)
    /// `MIDI1Wire` refused a decoded event. `UMPRefusal` has no case for this, and a decoded MT 0x1 or 0x2 event is
    /// always well formed, so this is not expected to occur.
    case wireRefused(MIDI1WireRefusal)
    /// A SysEx7 continue or end with no SysEx open: its bytes are dropped so they cannot be read as data under
    /// running status or as part of another message.
    case orphanSysEx(UMPSysEx7Status)
    /// A SysEx7 continue or end from a group other than the one whose SysEx is open: dropped so it cannot be
    /// spliced into that payload. The open SysEx stays open for its own group.
    case foreignGroupSysEx(UMPSysEx7Status)
    /// An open SysEx was cut off by a start, a complete SysEx, a channel voice message or a System Common message,
    /// from any group. The parser discards the partial payload at that status byte; the interrupting message itself
    /// is emitted.
    case sysExInterrupted
}

/// The MIDI 1.0 bytes decoded from one batch of UMP words, every packet that gave no bytes, and every SysEx cut short.
struct MIDI1UMPInputDecoding: Equatable, Sendable {
    let bytes: [UInt8]
    let skipped: [MIDI1UMPInputSkip]
}

/// Turns MIDI 1.0-protocol UMP words (as `MIDIInputPortCreateWithProtocol(..., ._1_0, ...)` delivers them) back into
/// the MIDI 1.0 byte stream that `MIDI1Parser` consumes (#81).
///
/// The decoder keeps the group of the open SysEx, if any, so that its output is always well framed for one
/// `MIDI1Parser` fed every byte it emits, across `decode` calls. Pair one decoder with one parser per source, and
/// `reset()` both together.
///
/// - The batch is framed by the injected splitter (standard by default). A batch ending inside a packet, or more words
///   than the splitter's bound, is refused whole: no bytes, one `.malformed` skip.
/// - MT 0x1 (System Common and Real Time) and MT 0x2 (MIDI 1.0 channel voice) are decoded by their UMP types and
///   written by `MIDI1Wire`, each message whole with its status byte (no running status).
/// - MT 0x3 (SysEx7): start gives F0 payload and opens a SysEx for its group; continue gives payload and end gives
///   payload F7 only while a SysEx of the same group is open (end closes). With none open they are skipped as
///   `.orphanSysEx`; from another group than the open one, as `.foreignGroupSysEx`, with the open SysEx left as it
///   is. Complete gives F0 payload F7. `MIDI1Parser` joins the parts and bounds the payload.
/// - An open SysEx closes, with a `.sysExInterrupted` skip, on a start or complete, a channel voice message or a
///   System Common message of any group, because the parser discards the partial at that status byte. Real Time
///   never closes it.
/// - A packet a typed decoder refuses is skipped as `.malformed` and gives no bytes; a refused batch or packet also
///   closes an open SysEx (fail closed), so its later parts become orphans and no F7 completes the partial.
/// - MT 0x4 is skipped as `.protocolMismatch`; every other type is skipped as `.notMIDI1`, whatever its content.
///   These skips leave the SysEx state unchanged.
/// - Groups: the non-SysEx messages of every group are merged into one byte stream, in input order. Only one SysEx
///   is tracked at a time, by group. While one is open, the continue and end fragments of another group's SysEx are
///   dropped, never spliced into it; a start from another group replaces it (the later start wins). MIDI 1.0 devices
///   use group 0.
struct MIDI1UMPInputDecoder: Equatable, Sendable {
    let splitter: UMPStreamSplitter
    /// The group of the open SysEx; nil when none is open.
    private var sysExGroup: UMPGroup?

    init(splitter: UMPStreamSplitter = .standard) {
        self.splitter = splitter
    }

    /// Closes any open SysEx. Reset the paired `MIDI1Parser` at the same time.
    mutating func reset() {
        sysExGroup = nil
    }

    mutating func decode(_ words: [UInt32]) -> MIDI1UMPInputDecoding {
        let packets: [UMPPacket]
        do {
            packets = try splitter.split(words)
        } catch {
            sysExGroup = nil
            return MIDI1UMPInputDecoding(bytes: [], skipped: [.malformed(error)])
        }
        var bytes: [UInt8] = []
        var skipped: [MIDI1UMPInputSkip] = []
        for packet in packets {
            decode(packet, bytes: &bytes, skipped: &skipped)
        }
        return MIDI1UMPInputDecoding(bytes: bytes, skipped: skipped)
    }

    private mutating func decode(_ packet: UMPPacket, bytes: inout [UInt8], skipped: inout [MIDI1UMPInputSkip]) {
        let event: MIDI1Event
        do {
            switch packet.messageType {
            case .system:
                event = try UMPSystemCommonRealTime(decoding: packet).event
            case .midi1ChannelVoice:
                event = try UMPMIDI1ChannelVoice(decoding: packet).event
            case .data64:
                sysEx7(try UMPSysEx7Packet(decoding: packet), bytes: &bytes, skipped: &skipped)
                return
            case .midi2ChannelVoice:
                skipped.append(.protocolMismatch(packet.messageType))
                return
            default:
                skipped.append(.notMIDI1(packet.messageType))
                return
            }
        } catch {
            sysExGroup = nil
            skipped.append(.malformed(error))
            return
        }
        let wire: [UInt8]
        do {
            wire = try MIDI1Wire.bytes(event: event)
        } catch {
            sysExGroup = nil
            skipped.append(.wireRefused(error))
            return
        }
        var isRealTime = false
        if case .realTime = event { isRealTime = true }
        if sysExGroup != nil, !isRealTime {
            sysExGroup = nil
            skipped.append(.sysExInterrupted)
        }
        bytes += wire
    }

    private mutating func sysEx7(_ sysEx: UMPSysEx7Packet, bytes: inout [UInt8], skipped: inout [MIDI1UMPInputSkip]) {
        switch sysEx.status {
        case .start, .complete:
            if sysExGroup != nil { skipped.append(.sysExInterrupted) }
            let isComplete = sysEx.status == .complete
            bytes += [0xF0] + sysEx.bytes + (isComplete ? [0xF7] : [])
            sysExGroup = isComplete ? nil : sysEx.group
        case .continue, .end:
            guard let openGroup = sysExGroup else {
                skipped.append(.orphanSysEx(sysEx.status))
                return
            }
            guard sysEx.group == openGroup else {
                skipped.append(.foreignGroupSysEx(sysEx.status))
                return
            }
            let isEnd = sysEx.status == .end
            bytes += sysEx.bytes + (isEnd ? [0xF7] : [])
            sysExGroup = isEnd ? nil : openGroup
        }
    }
}
