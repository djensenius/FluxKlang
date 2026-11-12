//
//  SMFCaptureLossClassifier.swift
//  FluxKlang
//
//  The SMF export losses one MIDI capture contributes by itself (#112 MLC1,
//  media-contract.md §9.3). A building block for an SMF export record: it
//  reads only the packet words and the §9.1 protocol stamp, so timing, pass
//  and group losses, which depend on the other captures, are not counted here.
//  To be wired into `CaptureClipExport.smf()` by #584 (SMF2b), once MT 0x4 is written (it is dropped today).
//

/// Counts the §9.3 categories one capture adds to an SMF export, exactly as the reference checker does per event
/// (docs/transformation/media-contract/check_media_contract.py: the per-event loss branch of `on_export`,
/// `midi2_losses` and `VALUE_BITS`):
///
/// - MT 0x4 with effective protocol `midi2` (genuine MIDI 2.0), by opcode (bits 20...23 of word 0):
///   - Note Off (0x8) and Note On (0x9), velocity the top 16 bits of word 1: a Note On whose top 7 velocity bits are 0
///     counts `noteOnVelocityRemapped`; any note whose velocity is not the min-centre-max upscale of its top 7 bits
///     counts `velocityDownscaled` (independently, so a Note On velocity `0x0100` counts both); an attribute type
///     (word 0's low byte) ≠ 0 counts `attributeDropped`.
///   - Poly pressure (0xA), Control Change (0xB) and channel pressure (0xD) to 7 bits, Registered (0x2) and Assignable
///     (0x3) Controller and pitch bend (0xE) to 14 bits: word 1 not the upscale of its top bits counts
///     `valueDownscaled`.
///   - Per-note controllers (0x0, 0x1), per-note pitch bend (0x6) and per-note management (0xF): `perNoteDropped`.
///   - Program Change (0xC): nothing.
///   - Any other opcode (relative controllers 0x4, 0x5 and reserved 0x7): `umpOnlyDropped`.
/// - Otherwise MT 0x4 from an `unknown` endpoint: `fidelityUnverified`.
/// - Otherwise MT 0x4 (OS-upscaled MIDI 1.0 from a `midi1` endpoint), MT 0x2 and MT 0x3: nothing.
/// - Any other Message Type: `umpOnlyDropped`.
///
/// Only nonzero counts are stored, as in `SMFExportLossReport.losses`; an export sums them over its captures. Pure
/// and deterministic. Does not translate: `UMPMIDI2ToMIDI1Translator` declares other losses (reserved controllers,
/// null parameter addresses) that §9.3 does not count.
enum SMFCaptureLossClassifier {
    /// MIDI 2.0 opcode → the MIDI 1.0 bit width its 32-bit value reduces to (checker `VALUE_BITS`).
    private static let valueBits: [UInt32: Int] = [0xA: 7, 0xB: 7, 0xD: 7, 0x2: 14, 0x3: 14, 0xE: 14]

    /// The §9.3 losses of exporting `packet` to an SMF; `stamp` must be the one `MIDIProtocolStamp.classify` returned
    /// for this packet (as in `MIDICaptureRecord`).
    static func losses(of packet: UMPPacket, stamp: MIDIProtocolStamp) -> [SMFExportLoss: Int] {
        let words = packet.words
        switch packet.messageType {
        case .midi2ChannelVoice where stamp.effective == .midi2:
            return midi2Losses(first: words[0], second: words[1])
        case .midi2ChannelVoice where stamp.endpoint == .unknown:
            return [.fidelityUnverified: 1]
        case .midi1ChannelVoice, .data64, .midi2ChannelVoice:
            return [:]
        default:
            return [.umpOnlyDropped: 1]
        }
    }

    /// Checker `midi2_losses`: one genuine MIDI 2.0 channel voice message converted to MIDI 1.0 SMF bytes.
    private static func midi2Losses(first: UInt32, second: UInt32) -> [SMFExportLoss: Int] {
        var out: [SMFExportLoss: Int] = [:]
        let opcode = (first >> 20) & 0xF
        switch opcode {
        case 0x8, 0x9:
            let velocity = second >> 16
            if opcode == 0x9 && velocity >> 9 == 0 { out[.noteOnVelocityRemapped] = 1 }
            if !survives(velocity, bits: 7, of: 16) { out[.velocityDownscaled] = 1 }
            if first & 0xFF != 0 { out[.attributeDropped] = 1 }
        case 0x0, 0x1, 0x6, 0xF:
            out[.perNoteDropped] = 1
        case 0xC:
            break
        default:
            if let bits = valueBits[opcode] {
                if !survives(second, bits: bits, of: 32) { out[.valueDownscaled] = 1 }
            } else {
                out[.umpOnlyDropped] = 1
            }
        }
        return out
    }

    /// Whether `value` (`width` bits) is the min-centre-max upscale of its top `bits` bits. The reduced value always
    /// fits `bits`, so `scaleUp` cannot refuse; were it to, the value would count as not surviving.
    private static func survives(_ value: UInt32, bits: Int, of width: Int) -> Bool {
        let reduced = value >> UInt32(width - bits)
        return (try? UMPScaling.scaleUp(reduced, fromBits: bits, toBits: width)) == value
    }
}
