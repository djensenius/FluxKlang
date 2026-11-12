/// The transport the negotiation settled on. It never rises above what the facts support.
enum MIDICapabilityLevel: Equatable, Sendable, CaseIterable {
    /// MIDI 1.0 bytes, with no UMP.
    case legacyByteStream
    /// UMP carrying MIDI 1.0 channel voice messages.
    case umpMIDI1
    /// UMP carrying MIDI 2.0 channel voice messages.
    case umpMIDI2

    /// 0 for `legacyByteStream`, 1 for `umpMIDI1`, 2 for `umpMIDI2`.
    var rank: Int {
        switch self {
        case .legacyByteStream: return 0
        case .umpMIDI1: return 1
        case .umpMIDI2: return 2
        }
    }

    var isUMP: Bool {
        switch self {
        case .legacyByteStream: return false
        case .umpMIDI1, .umpMIDI2: return true
        }
    }
}

/// A capability that is granted or lost. The declaration order is the order of every list of features.
enum MIDICapabilityFeature: Equatable, Sendable, CaseIterable {
    case umpTransport
    case midi2Protocol
    case jitterReduction
    case functionBlocks
    case ciDiscovery
    case profileConfiguration
}

/// Why a downgrade was recorded. The declaration order is the order of `MIDINegotiatedCapability.downgrades`.
enum MIDICapabilityDowngradeReason: Equatable, Sendable, CaseIterable {
    /// There is no endpoint information.
    case noUMPEndpoint
    /// The endpoint supports neither MIDI 1.0 nor MIDI 2.0.
    case endpointSupportsNoProtocol
    /// No MIDI-CI Discovery answer.
    case ciAnswerMissing
    /// The endpoint supports MIDI 1.0 only.
    case endpointLacksMIDI2
    /// The level is `umpMIDI2` but at least one active function block declares a MIDI 1.0 mode (`unrestricted` or
    /// `restricted`): the groups of those blocks carry MIDI 1.0. The endpoint level stays `umpMIDI2` and no
    /// endpoint-wide feature is lost; the record names the blocks in `functionBlockIndices`. Recorded only at the
    /// `umpMIDI2` level (at `umpMIDI1` `endpointLacksMIDI2` already covers every group), and never for an inactive
    /// block.
    case functionBlockMIDI1Only
    /// Profiles were advertised but the Discovery category does not announce profile configuration; the profiles
    /// are ignored.
    case profilesNotAdvertised

    /// The features this reason takes away, in `MIDICapabilityFeature` declaration order.
    var lostFeatures: [MIDICapabilityFeature] {
        switch self {
        case .noUMPEndpoint, .endpointSupportsNoProtocol:
            return [.umpTransport, .midi2Protocol, .jitterReduction, .functionBlocks]
        case .ciAnswerMissing:
            return MIDICapabilityFeature.allCases
        case .endpointLacksMIDI2:
            return [.midi2Protocol]
        case .functionBlockMIDI1Only:
            return []
        case .profilesNotAdvertised:
            return [.profileConfiguration]
        }
    }
}

/// One recorded downgrade. `possibleTranslationLosses` lists what a later MIDI 2.0 to MIDI 1.0 translation could
/// lose; it is not an observation, and it is empty for a reason that does not lead to such a translation.
/// `functionBlockIndices` names the affected function blocks, ascending; it is empty for every reason except
/// `functionBlockMIDI1Only`, whose downgrade applies to those blocks' groups only.
struct MIDICapabilityDowngrade: Equatable, Sendable {
    let reason: MIDICapabilityDowngradeReason
    let lost: [MIDICapabilityFeature]
    let possibleTranslationLosses: [UMPTranslationLossReason]
    let functionBlockIndices: [Int]

    init(
        reason: MIDICapabilityDowngradeReason, lost: [MIDICapabilityFeature],
        possibleTranslationLosses: [UMPTranslationLossReason], functionBlockIndices: [Int] = []
    ) {
        self.reason = reason
        self.lost = lost
        self.possibleTranslationLosses = possibleTranslationLosses
        self.functionBlockIndices = functionBlockIndices
    }
}

/// The outcome of a negotiation. `functionBlocks` and `profiles` are sorted by value and `features` and `downgrades`
/// follow the declaration order of their enums, so equal facts in any input order give equal results.
struct MIDINegotiatedCapability: Equatable, Sendable {
    let level: MIDICapabilityLevel
    /// The granted features in `MIDICapabilityFeature` declaration order.
    let features: [MIDICapabilityFeature]
    /// Every supplied function block, sorted, when the level is UMP; empty at the legacy level.
    let functionBlocks: [UMPStreamFunctionBlockInfo]
    /// The advertised profiles, sorted, when `profileConfiguration` is granted; otherwise empty.
    let profiles: [MIDICapabilityProfileID]
    /// One record per reason present in the facts, in `MIDICapabilityDowngradeReason` declaration order.
    let downgrades: [MIDICapabilityDowngrade]
}
