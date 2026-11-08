/// Turns discovered facts into a negotiated capability and an explicit record of every downgrade. A pure function of
/// its argument: it never talks to a device, never opens an endpoint and never raises the level. A missing MIDI-CI
/// answer, a missing endpoint or an endpoint without any protocol gives the legacy MIDI 1.0 byte-stream level;
/// otherwise the level is `umpMIDI2` when the endpoint supports MIDI 2.0 and `umpMIDI1` when it does not.
///
/// A downgrade is recorded for every defect present in the facts, whatever the resulting level (see
/// `MIDICapabilityDowngradeReason`). Invalid or ambiguous facts are refused, in the order documented at
/// `MIDICapabilityRefusal`; nothing is repaired.
enum MIDICapabilityResolver {
    /// The MIDI 2.0 to MIDI 1.0 losses a later translation could cause, in `UMPTranslationLossReason` order.
    static let midi2ToMIDI1Losses: [UMPTranslationLossReason] = [
        .perNoteController, .perNotePitchBend, .perNoteManagement, .relativeController,
        .controllerReservedInMIDI2, .nullParameterAddress, .attributeDropped, .noteOnVelocityRemapped,
        .velocityDownscaled, .valueDownscaled
    ]

    /// The validated, sorted facts the decisions are made from.
    struct Inputs {
        let endpoint: UMPStreamEndpointInfo?
        let blocks: [UMPStreamFunctionBlockInfo]
        let profiles: [MIDICapabilityProfileID]
        let answered: Bool
        let profileConfigurationAnnounced: Bool

        var supportsMIDI1: Bool {
            endpoint?.supportsMIDI1 ?? false
        }

        var supportsMIDI2: Bool {
            endpoint?.supportsMIDI2 ?? false
        }

        var hasJitterReduction: Bool {
            guard let endpoint else { return false }
            return endpoint.receivesJitterReduction || endpoint.transmitsJitterReduction
        }

        var hasActiveBlock: Bool {
            blocks.contains { $0.isActive }
        }
    }

    static func negotiate(_ facts: MIDICapabilityFacts) throws(MIDICapabilityRefusal) -> MIDINegotiatedCapability {
        let inputs = try validatedInputs(facts)
        let level = level(of: inputs)
        let features = MIDICapabilityFeature.allCases.filter { isGranted($0, level: level, inputs: inputs) }
        let downgrades = MIDICapabilityDowngradeReason.allCases.compactMap { downgrade($0, inputs: inputs) }
        return MIDINegotiatedCapability(
            level: level,
            features: features,
            functionBlocks: level.isUMP ? inputs.blocks : [],
            profiles: features.contains(.profileConfiguration) ? inputs.profiles : [],
            downgrades: downgrades)
    }

    static func level(of inputs: Inputs) -> MIDICapabilityLevel {
        guard inputs.answered else { return .legacyByteStream }
        if inputs.supportsMIDI2 { return .umpMIDI2 }
        if inputs.supportsMIDI1 { return .umpMIDI1 }
        return .legacyByteStream
    }

    static func isGranted(_ feature: MIDICapabilityFeature, level: MIDICapabilityLevel, inputs: Inputs) -> Bool {
        switch feature {
        case .umpTransport:
            return level.isUMP
        case .midi2Protocol:
            return level == .umpMIDI2
        case .jitterReduction:
            return level.isUMP && inputs.hasJitterReduction
        case .functionBlocks:
            return level.isUMP && inputs.hasActiveBlock
        case .ciDiscovery:
            return inputs.answered
        case .profileConfiguration:
            return inputs.profileConfigurationAnnounced && !inputs.profiles.isEmpty
        }
    }

    static func downgrade(_ reason: MIDICapabilityDowngradeReason, inputs: Inputs) -> MIDICapabilityDowngrade? {
        guard isPresent(reason, inputs: inputs) else { return nil }
        return MIDICapabilityDowngrade(
            reason: reason, lost: reason.lostFeatures, possibleTranslationLosses: translationLosses(reason, inputs))
    }

    private static func isPresent(_ reason: MIDICapabilityDowngradeReason, inputs: Inputs) -> Bool {
        switch reason {
        case .noUMPEndpoint:
            return inputs.endpoint == nil
        case .endpointSupportsNoProtocol:
            return inputs.endpoint != nil && !inputs.supportsMIDI1 && !inputs.supportsMIDI2
        case .ciAnswerMissing:
            return !inputs.answered
        case .endpointLacksMIDI2:
            return inputs.supportsMIDI1 && !inputs.supportsMIDI2
        case .profilesNotAdvertised:
            return inputs.answered && !inputs.profiles.isEmpty && !inputs.profileConfigurationAnnounced
        }
    }

    private static func translationLosses(
        _ reason: MIDICapabilityDowngradeReason, _ inputs: Inputs
    ) -> [UMPTranslationLossReason] {
        switch reason {
        case .ciAnswerMissing:
            return inputs.supportsMIDI2 ? midi2ToMIDI1Losses : []
        case .endpointLacksMIDI2:
            return midi2ToMIDI1Losses
        case .noUMPEndpoint, .endpointSupportsNoProtocol, .profilesNotAdvertised:
            return []
        }
    }
}
