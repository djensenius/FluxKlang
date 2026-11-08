import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The downgrade records of the capability negotiation (#83, slice CAP1): which reasons are recorded, what each one
/// loses and which translation losses it carries.
extension MIDICapabilityNegotiationTests {
    static let transportLost: [Feature] = [.umpTransport, .midi2Protocol, .jitterReduction, .functionBlocks]
    static let everythingLost: [Feature] = [
        .umpTransport, .midi2Protocol, .jitterReduction, .functionBlocks, .ciDiscovery, .profileConfiguration
    ]
    static let midi2Only: [Feature] = [.midi2Protocol]
    static let profilesOnly: [Feature] = [.profileConfiguration]
    static let midi2ToMIDI1: [UMPTranslationLossReason] = [
        .perNoteController, .perNotePitchBend, .perNoteManagement, .relativeController,
        .controllerReservedInMIDI2, .nullParameterAddress, .attributeDropped, .noteOnVelocityRemapped,
        .velocityDownscaled, .valueDownscaled
    ]
    static let noLosses: [UMPTranslationLossReason] = []

    static func record(
        _ reason: MIDICapabilityDowngradeReason, lost: [Feature], losses: [UMPTranslationLossReason]
    ) -> MIDICapabilityDowngrade {
        MIDICapabilityDowngrade(reason: reason, lost: lost, possibleTranslationLosses: losses)
    }

    @Test func aFullMIDI2EndpointWithAnAnswerRecordsNoDowngradeWithOrWithoutProfiles() throws {
        let none: [MIDICapabilityDowngrade] = []
        let withoutProfiles = try Self.negotiated(try Self.full(blocks: Self.tiles(3)))
        #expect(withoutProfiles.downgrades == none)
        let profiles = [try Self.profile(1), try Self.profile(2)]
        let withProfiles = try Self.negotiated(try Self.full(profiles: profiles))
        #expect(withProfiles.downgrades == none)
    }

    @Test func aMissingEndpointRecordsOnlyNoUMPEndpointWithItsFourLostFeatures() throws {
        let result = try Self.negotiated(Self.facts(nil, [], try Self.answer()))
        let expected = [Self.record(.noUMPEndpoint, lost: Self.transportLost, losses: Self.noLosses)]
        #expect(result.downgrades == expected)
    }

    @Test func anEndpointWithNoProtocolRecordsOnlyEndpointSupportsNoProtocolWithItsFourLostFeatures() throws {
        let result = try Self.negotiated(Self.facts(Self.endpoint(of: .noProtocol), [], try Self.answer()))
        let expected = [Self.record(.endpointSupportsNoProtocol, lost: Self.transportLost, losses: Self.noLosses)]
        #expect(result.downgrades == expected)
    }

    @Test func aMissingAnswerOnAMIDI2EndpointRecordsOnlyCIAnswerMissingWithAllSixLostFeaturesAndTheTenLosses() throws {
        let result = try Self.negotiated(Self.facts(Self.endpoint(of: .midi1And2), [], .missing))
        let expected = [Self.record(.ciAnswerMissing, lost: Self.everythingLost, losses: Self.midi2ToMIDI1)]
        #expect(result.downgrades == expected)
    }

    @Test func aMIDI1OnlyEndpointWithAnAnswerRecordsOnlyEndpointLacksMIDI2WithTheTenLosses() throws {
        let result = try Self.negotiated(Self.facts(Self.endpoint(of: .midi1Only), [], try Self.answer()))
        let expected = [Self.record(.endpointLacksMIDI2, lost: Self.midi2Only, losses: Self.midi2ToMIDI1)]
        #expect(result.downgrades == expected)
    }

    @Test func profilesWithTheCategoryBitClearRecordOnlyProfilesNotAdvertisedAndAreIgnored() throws {
        let advertised = [try Self.profile(5)]
        let result = try Self.negotiated(try Self.full(category: Self.silentCategory, profiles: advertised))
        let expected = [Self.record(.profilesNotAdvertised, lost: Self.profilesOnly, losses: Self.noLosses)]
        #expect(result.downgrades == expected)
        let none: [MIDICapabilityProfileID] = []
        #expect(result.profiles == none)
    }

    @Test func noProfilesAdvertisedRecordsNoProfilesNotAdvertisedWhateverTheCategoryBit() throws {
        let none: [MIDICapabilityDowngrade] = []
        let silent = try Self.negotiated(try Self.full(category: Self.silentCategory))
        #expect(silent.downgrades == none)
        let announcing = try Self.negotiated(try Self.full(category: Self.announcingCategory))
        #expect(announcing.downgrades == none)
    }

    @Test func noEndpointAndNoAnswerRecordNoUMPEndpointThenCIAnswerMissingWithoutTranslationLosses() throws {
        let result = try Self.negotiated(Self.facts(nil, [], .missing))
        let expected = [
            Self.record(.noUMPEndpoint, lost: Self.transportLost, losses: Self.noLosses),
            Self.record(.ciAnswerMissing, lost: Self.everythingLost, losses: Self.noLosses)
        ]
        #expect(result.downgrades == expected)
    }

    @Test func noProtocolAndNoAnswerRecordEndpointSupportsNoProtocolThenCIAnswerMissing() throws {
        let result = try Self.negotiated(Self.facts(Self.endpoint(of: .noProtocol), [], .missing))
        let expected = [
            Self.record(.endpointSupportsNoProtocol, lost: Self.transportLost, losses: Self.noLosses),
            Self.record(.ciAnswerMissing, lost: Self.everythingLost, losses: Self.noLosses)
        ]
        #expect(result.downgrades == expected)
    }

    @Test func aMIDI1OnlyEndpointWithoutAnAnswerRecordsCIAnswerMissingBeforeEndpointLacksMIDI2() throws {
        let result = try Self.negotiated(Self.facts(Self.endpoint(of: .midi1Only), [], .missing))
        let expected = [
            Self.record(.ciAnswerMissing, lost: Self.everythingLost, losses: Self.noLosses),
            Self.record(.endpointLacksMIDI2, lost: Self.midi2Only, losses: Self.midi2ToMIDI1)
        ]
        #expect(result.downgrades == expected)
    }

    @Test func aMIDI1OnlyEndpointWithSilentProfilesRecordsEndpointLacksMIDI2ThenProfilesNotAdvertised() throws {
        let silent = try Self.answer(category: Self.silentCategory, profiles: [try Self.profile(3)])
        let result = try Self.negotiated(Self.facts(Self.endpoint(of: .midi1Only), [], silent))
        let expected = [
            Self.record(.endpointLacksMIDI2, lost: Self.midi2Only, losses: Self.midi2ToMIDI1),
            Self.record(.profilesNotAdvertised, lost: Self.profilesOnly, losses: Self.noLosses)
        ]
        #expect(result.downgrades == expected)
        #expect(result.level == Level.umpMIDI1)
    }

    @Test func aMIDI2OnlyEndpointWithoutAnAnswerStillCarriesTheTenLossesOnCIAnswerMissing() throws {
        let result = try Self.negotiated(Self.facts(Self.endpoint(of: .midi2Only), [], .missing))
        let expected = [Self.record(.ciAnswerMissing, lost: Self.everythingLost, losses: Self.midi2ToMIDI1)]
        #expect(result.downgrades == expected)
    }

    @Test func theTranslationLossListIsPinnedAgainstALiteralOfTenReasonsInDeclarationOrder() throws {
        let pinned: [UMPTranslationLossReason] = [
            .perNoteController, .perNotePitchBend, .perNoteManagement, .relativeController,
            .controllerReservedInMIDI2, .nullParameterAddress, .attributeDropped, .noteOnVelocityRemapped,
            .velocityDownscaled, .valueDownscaled
        ]
        let result = try Self.negotiated(Self.facts(Self.endpoint(of: .midi1And2), [], .missing))
        let record = try #require(result.downgrades.first)
        #expect(record.possibleTranslationLosses == pinned)
        #expect(pinned.count == 10)
        let lacking = try Self.negotiated(Self.facts(Self.endpoint(of: .midi1Only), [], try Self.answer()))
        let lackingRecord = try #require(lacking.downgrades.first)
        #expect(lackingRecord.possibleTranslationLosses == pinned)
    }

    @Test func theDowngradeReasonsAreDeclaredInTheCanonicalOrder() {
        let expected: [MIDICapabilityDowngradeReason] = [
            .noUMPEndpoint, .endpointSupportsNoProtocol, .ciAnswerMissing, .endpointLacksMIDI2, .profilesNotAdvertised
        ]
        #expect(MIDICapabilityDowngradeReason.allCases == expected)
    }
}
