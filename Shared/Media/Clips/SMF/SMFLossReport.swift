//
//  SMFLossReport.swift
//  FluxKlang
//
//  What a Standard MIDI File write or read (#112 CL2) loses, ignores or
//  reorders. The export categories are exactly those of
//  docs/transformation/media-contract.md §9.3 ("SMF export losses"); a read
//  report counts, by type, everything the reader skips instead of converting.
//

/// A loss category of an SMF export, as named in media-contract.md §9.3. A clip export counts none of them; see
/// `StandardMIDIFile.losses(of:)`.
enum SMFExportLoss: String, CaseIterable, Hashable, Sendable {
    case timingQuantized
    case syntheticTempoMap
    case velocityDownscaled
    case noteOnVelocityRemapped
    case valueDownscaled
    case attributeDropped
    case perNoteDropped
    case umpOnlyDropped
    case fidelityUnverified
    case passesOverlaid
    case groupsFlattened
}

/// The declared losses of one SMF export (media-contract.md §9.3): each category counted, only nonzero counts
/// stored. `lossless` is true exactly when `losses` is empty.
struct SMFExportLossReport: Equatable, Sendable {
    let losses: [SMFExportLoss: Int]

    var lossless: Bool { losses.isEmpty }
}

/// The written bytes of one clip, with the declared losses.
struct SMFWriteResult: Equatable, Sendable {
    /// A format 0 Standard MIDI File at `StandardMIDIFile.division` ticks per quarter.
    let bytes: [UInt8]
    /// Always lossless for a `MIDIClip`; see `StandardMIDIFile.losses(of:)`.
    let losses: SMFExportLossReport
    /// How many items a read of `bytes` returns at another index. A file keeps time order, not authoring order:
    /// the reader returns the items stably sorted by onset tick (note start or event tick). Playback through
    /// `MIDIClipPlacement` is unchanged, as it orders by tick before authoring order; `MIDIClipScheduler.stop()`
    /// may release sounding notes in another order. Zero exactly when the items are already in that order, and
    /// then a read returns the clip unchanged.
    let reorderedItems: Int
}

/// A meta event type the reader skips. Tempo, meter, key and SMPTE offset are never converted: clip ticks are
/// musical and a clip carries no tempo map.
enum SMFMetaKind: Hashable, Sendable {
    /// FF 00.
    case sequenceNumber
    /// FF 01...0F: text, copyright, track name, instrument, lyric, marker, cue point and reserved text types.
    case text
    /// FF 20.
    case channelPrefix
    /// FF 21.
    case port
    /// FF 51.
    case tempo
    /// FF 54.
    case smpteOffset
    /// FF 58.
    case timeSignature
    /// FF 59.
    case keySignature
    /// FF 7F.
    case sequencerSpecific
    /// Any other type except End of Track (FF 2F), which sets the clip length.
    case other(type: UInt8)

    init(type: UInt8) {
        switch type {
        case 0x00: self = .sequenceNumber
        case 0x01...0x0F: self = .text
        case 0x20: self = .channelPrefix
        case 0x21: self = .port
        case 0x51: self = .tempo
        case 0x54: self = .smpteOffset
        case 0x58: self = .timeSignature
        case 0x59: self = .keySignature
        case 0x7F: self = .sequencerSpecific
        default: self = .other(type: type)
        }
    }
}

/// Everything a read kept out of the clip, counted by type. Nothing is skipped without a count here.
struct SMFReadReport: Equatable, Sendable {
    /// The header format, 0 or 1.
    let format: UInt16
    /// The header's ticks per quarter; each file tick is `15360 / division` clip ticks.
    let division: UInt16
    /// The MTrk chunks merged into the clip.
    let tracks: Int
    /// Meta events skipped, by kind (End of Track excluded).
    let ignoredMeta: [SMFMetaKind: Int]
    /// Chunks of unknown type skipped, as the SMF specification requires.
    let unknownChunks: Int
    /// Header bytes past the six this version reads, skipped.
    let ignoredHeaderBytes: Int
}

/// A clip read from Standard MIDI File bytes, with what the read skipped.
struct SMFReadResult: Equatable, Sendable {
    let clip: MIDIClip
    let report: SMFReadReport
}
