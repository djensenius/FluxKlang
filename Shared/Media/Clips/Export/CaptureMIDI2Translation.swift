//
//  CaptureMIDI2Translation.swift
//  FluxKlang
//
//  The merge queue of a capture export and the pass that translates its MIDI 2.0 channel-voice entries to MIDI 1
//  messages (#584 SMF2b-2). The translator omits bytes its receiver was already sent, which is only valid in the
//  order the file will hold them, so the pass runs over the queue after it is sorted.
//

/// One decoded capture of the merge queue: a MIDI 1 channel-voice message (MT 0x2) or a MIDI 2.0 channel-voice
/// message (MT 0x4) already moved to the export's one canonical group.
struct CaptureMergeEntry: Sendable {
    enum Content: Sendable {
        /// `resets` is the channel whose translator state the message makes stale (see `CaptureMIDI2Translation`).
        case midi1(MIDI1Semantic, resets: UMPChannel?)
        /// `classified` is true when `SMFCaptureLossClassifier` already counted `perNoteDropped` or
        /// `umpOnlyDropped` for the capture.
        case midi2(UMPMIDI2ChannelVoice, classified: Bool)
    }

    let ticks: Int64
    let stream: StreamID
    let index: Int
    let content: Content

    /// The merge order of the export: ticks, stream id by UTF-8 bytes, record index.
    func precedes(_ other: CaptureMergeEntry) -> Bool {
        if ticks != other.ticks { return ticks < other.ticks }
        if stream != other.stream {
            return stream.rawValue.utf8.lexicographicallyPrecedes(other.stream.rawValue.utf8)
        }
        return index < other.index
    }
}

/// The MIDI 1 messages of a sorted queue and the MT 0x4 captures that produced none.
struct CaptureMIDI2Translation: Equatable, Sendable {
    /// In file order.
    private(set) var messages: [CaptureTimedMessage] = []
    /// MT 0x4 captures that translated to no MIDI 1 message: the file lacks them.
    private(set) var silentVoices = 0
    /// The silent ones the classifier counted neither as `perNoteDropped` nor as `umpOnlyDropped`.
    private(set) var silentUncounted = 0

    /// MIDI 1 controllers whose bytes this export may write without the translator: Bank Select (0, 32), Data Entry
    /// MSB (6), Data Increment and Decrement (96, 97) and the RPN and NRPN selection (98...101). They make the
    /// translator's cached bank, selection or Data Entry MSB stale. CC 38 caches nothing. CC 120...127, 64, 66 and
    /// 69 are refused by `MIDIClip.make`, so no export holding one reaches a file.
    static func resetsTranslator(controller: UInt8) -> Bool {
        [0, 6, 32, 96, 97, 98, 99, 100, 101].contains(controller)
    }

    /// Sorts `queue` once and translates it in that order with one translator, whose group is `canonical`.
    /// `sysExTicks` are the ticks of the delivered SysEx messages, ascending: a SysEx can reset a receiver, so the
    /// translator starts afresh at the first voice at or after each. That is conservative (the writer puts a SysEx
    /// before the non-Note-Off events of its tick): a byte may be repeated, never missing.
    static func translate(_ queue: [CaptureMergeEntry], canonical: UMPGroup?,
                          sysExTicks: [Int64]) throws(CaptureClipExportRefusal) -> CaptureMIDI2Translation {
        var result = CaptureMIDI2Translation()
        var translator = UMPMIDI2ToMIDI1Translator()
        var pending = 0
        for entry in queue.sorted(by: { $0.precedes($1) }) {
            switch entry.content {
            case let .midi1(message, resets):
                if let canonical, let resets { translator.reset(group: canonical, channel: resets) }
                result.messages.append(CaptureTimedMessage(ticks: entry.ticks, message: message))
            case let .midi2(voice, classified):
                var sysExApplied = false
                while pending < sysExTicks.count, sysExTicks[pending] <= entry.ticks {
                    pending += 1
                    sysExApplied = true
                }
                if sysExApplied { translator = UMPMIDI2ToMIDI1Translator() }
                let output: UMPTranslationOutput<UMPMIDI1ChannelVoice>
                do throws(UMPRefusal) {
                    output = try translator.translate(voice)
                } catch {
                    throw .invalidChannelVoice(stream: entry.stream, index: entry.index, error)
                }
                if output.messages.isEmpty {
                    result.silentVoices += 1
                    if !classified { result.silentUncounted += 1 }
                }
                for message in output.messages {
                    result.messages.append(CaptureTimedMessage(ticks: entry.ticks, message: message.semantic))
                }
            }
        }
        return result
    }
}
