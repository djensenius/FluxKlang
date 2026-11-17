/// Why `MIDI1UMPInputDecoder` dropped a packet (or a whole batch) without emitting bytes.
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
}

/// The MIDI 1.0 byte stream decoded from one batch of UMP words, and every packet that gave no bytes.
struct MIDI1UMPInputDecoding: Equatable, Sendable {
    let bytes: [UInt8]
    let skipped: [MIDI1UMPInputSkip]
}

/// Turns MIDI 1.0-protocol UMP words (as `MIDIInputPortCreateWithProtocol(..., ._1_0, ...)` delivers them) back into
/// the MIDI 1.0 byte stream that `MIDI1Parser` consumes (#81). Pure and stateless; nothing calls it yet.
///
/// - The batch is framed by `UMPStreamSplitter.standard`. A batch that ends inside a packet, or holds more words
///   than the splitter's bound, is refused whole: no bytes, one `.malformed` skip.
/// - MT 0x1 (System Common and Real Time) and MT 0x2 (MIDI 1.0 channel voice) are decoded by their UMP types and
///   written by `MIDI1Wire`, each message whole with its status byte (no running status).
/// - MT 0x3 (SysEx7) maps by status alone: complete gives F0 payload F7, start F0 payload, continue payload, end
///   payload F7. `MIDI1Parser` joins the parts across calls and bounds the payload; this type keeps no state.
/// - A packet a typed decoder refuses is skipped as `.malformed` and gives no bytes; the next packet still decodes.
/// - MT 0x4 is skipped as `.protocolMismatch`; every other type is skipped as `.notMIDI1`, whatever its content.
/// - The Group is ignored: every group is merged into one byte stream, in input order. MIDI 1.0 devices use group 0.
enum MIDI1UMPInputDecoder {
    static func decode(_ words: [UInt32]) -> MIDI1UMPInputDecoding {
        let packets: [UMPPacket]
        do {
            packets = try UMPStreamSplitter.standard.split(words)
        } catch {
            return MIDI1UMPInputDecoding(bytes: [], skipped: [.malformed(error)])
        }
        var bytes: [UInt8] = []
        var skipped: [MIDI1UMPInputSkip] = []
        for packet in packets {
            switch decode(packet) {
            case let .bytes(packetBytes):
                bytes += packetBytes
            case let .skipped(skip):
                skipped.append(skip)
            }
        }
        return MIDI1UMPInputDecoding(bytes: bytes, skipped: skipped)
    }

    private enum PacketOutcome {
        case bytes([UInt8])
        case skipped(MIDI1UMPInputSkip)
    }

    private static func decode(_ packet: UMPPacket) -> PacketOutcome {
        let event: MIDI1Event
        do {
            switch packet.messageType {
            case .system:
                event = try UMPSystemCommonRealTime(decoding: packet).event
            case .midi1ChannelVoice:
                event = try UMPMIDI1ChannelVoice(decoding: packet).event
            case .data64:
                return .bytes(sysEx7Bytes(try UMPSysEx7Packet(decoding: packet)))
            case .midi2ChannelVoice:
                return .skipped(.protocolMismatch(packet.messageType))
            default:
                return .skipped(.notMIDI1(packet.messageType))
            }
        } catch {
            return .skipped(.malformed(error))
        }
        do {
            return .bytes(try MIDI1Wire.bytes(event: event))
        } catch {
            return .skipped(.wireRefused(error))
        }
    }

    private static func sysEx7Bytes(_ sysEx: UMPSysEx7Packet) -> [UInt8] {
        switch sysEx.status {
        case .complete: return [0xF0] + sysEx.bytes + [0xF7]
        case .start: return [0xF0] + sysEx.bytes
        case .continue: return sysEx.bytes
        case .end: return sysEx.bytes + [0xF7]
        }
    }
}
