import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// One MIDI 2.0 channel voice packet (MT 0x4, group 0, channel 0) and the losses the translator must declare for it.
private struct DownProbe {
    let name: String
    let words: [UInt32]
    let reasons: [UMPTranslationLossReason]
}

/// #83 "Legacy works without CI" and "fidelity loss/downgrade explicit".
extension UMPCapabilityTests {
    /// Every MIDI 2.0 → MIDI 1.0 loss reason, each reached by a packet, plus two lossless controls.
    private static let downProbes: [DownProbe] = [
        DownProbe(name: "registered per-note controller", words: [0x4000_3C01, 0x8000_0000],
                  reasons: [.perNoteController]),
        DownProbe(name: "assignable per-note controller", words: [0x4010_3C02, 0x8000_0000],
                  reasons: [.perNoteController]),
        DownProbe(name: "per-note pitch bend", words: [0x4060_3C00, 0x9000_0000], reasons: [.perNotePitchBend]),
        DownProbe(name: "per-note management", words: [0x40F0_3C03, 0], reasons: [.perNoteManagement]),
        DownProbe(name: "relative registered controller", words: [0x4040_0007, 0x0000_0010],
                  reasons: [.relativeController]),
        DownProbe(name: "MIDI 2.0 CC 0", words: [0x40B0_0000, 0x8000_0000], reasons: [.controllerReservedInMIDI2]),
        DownProbe(name: "registered controller 127/127", words: [0x4020_7F7F, 0x8000_0000],
                  reasons: [.nullParameterAddress]),
        DownProbe(name: "note on, attribute type 3", words: [0x4090_3C03, 0x8000_1234], reasons: [.attributeDropped]),
        DownProbe(name: "note on, velocity 0x0001", words: [0x4090_3C00, 0x0001_0000],
                  reasons: [.velocityDownscaled, .noteOnVelocityRemapped]),
        DownProbe(name: "note on, high-resolution velocity 0x8123", words: [0x4090_3C00, 0x8123_0000],
                  reasons: [.velocityDownscaled]),
        DownProbe(name: "CC 7, value 0x12345678", words: [0x40B0_0700, 0x1234_5678], reasons: [.valueDownscaled]),
        DownProbe(name: "note on, velocity 0x8000 (lossless)", words: [0x4090_3C00, 0x8000_0000], reasons: []),
        DownProbe(name: "CC 7, value 0x80000000 (lossless)", words: [0x40B0_0700, 0x8000_0000], reasons: [])
    ]

    private static let allFeatures: [MIDICapabilityFeature] = [
        .umpTransport, .midi2Protocol, .jitterReduction, .functionBlocks, .ciDiscovery, .profileConfiguration
    ]

    /// Runs every probe down through a fresh translator and returns the union of the reasons it returned, in
    /// `UMPTranslationLossReason` declaration order.
    private static func observedDownLosses() throws -> [UMPTranslationLossReason] {
        var observed = Set<UMPTranslationLossReason>()
        for probe in downProbes {
            let voice = try UMPMIDI2ChannelVoice(decoding: UMPPacket(words: probe.words))
            var translator = UMPMIDI2ToMIDI1Translator()
            let output = try translator.translate(voice)
            #expect(output.losses.map(\.reason) == probe.reasons, "\(probe.name)")
            #expect(translator.losses.total == probe.reasons.count, "\(probe.name)")
            observed.formUnion(output.losses.map(\.reason))
        }
        return UMPTranslationLossReason.allCases.filter(observed.contains)
    }

    @Test func noCIAnswerIsLegacyByteStreamWhateverTheEndpoint() throws {
        let midi2 = [Self.endpointMIDI2, Self.block0, Self.block1]
        let midi1 = [Self.endpointMIDI1, Self.midi1Block0]
        let losses = MIDICapabilityResolver.midi2ToMIDI1Losses
        let missing = MIDICapabilityDowngrade(
            reason: .ciAnswerMissing, lost: Self.allFeatures, possibleTranslationLosses: [])
        let cases: [([[UInt32]], [MIDICapabilityDowngrade])] = [
            ([], [
                MIDICapabilityDowngrade(
                    reason: .noUMPEndpoint, lost: [.umpTransport, .midi2Protocol, .jitterReduction, .functionBlocks],
                    possibleTranslationLosses: []),
                missing
            ]),
            (midi2, [
                MIDICapabilityDowngrade(
                    reason: .ciAnswerMissing, lost: Self.allFeatures, possibleTranslationLosses: losses)
            ]),
            (midi1, [
                missing,
                MIDICapabilityDowngrade(
                    reason: .endpointLacksMIDI2, lost: [.midi2Protocol], possibleTranslationLosses: losses)
            ])
        ]
        for (packets, downgrades) in cases {
            let result = try Self.negotiate(packets, ci: [])
            #expect(result.level == .legacyByteStream)
            #expect(result.features.isEmpty)
            #expect(result.functionBlocks.isEmpty)
            #expect(result.profiles.isEmpty)
            #expect(result.downgrades == downgrades)
        }
    }

    @Test func ciNAKDecodesAndMissingAnswerIsLegacy() throws {
        let decoded = try MIDICIMessage.decode(payload: Self.nak, limits: .standard)
        guard case let .nak(header, report) = decoded else {
            Issue.record("not a NAK: \(decoded)")
            return
        }
        #expect(header.source.rawValue == 0x0765_4321)
        #expect(header.destination.rawValue == 0x0123_4567)
        #expect(report?.originalSubID == 0x70)
        let decoded11 = try MIDICIMessage.decode(payload: Self.nak11, limits: .standard)
        guard case .nak(_, nil) = decoded11 else {
            Issue.record("not a CI 1.1 NAK: \(decoded11)")
            return
        }
        // Production decodes the NAK and `MIDICapabilityDiscovery` maps it to `.missing`, because
        // `MIDICapabilityCIAnswer` has no "refused" or "timed out" case. The resolver then gives legacy.
        let packets = [Self.endpointMIDI2, Self.block0, Self.block1]
        let silent = try Self.negotiate(packets, ci: [])
        for payload in [Self.nak, Self.nak11] {
            let answer = try Self.ciAnswer(reply: payload)
            #expect(answer == .missing)
            #expect(try Self.negotiate(packets, ci: [payload]) == silent)
        }
        #expect(silent.level == .legacyByteStream)
    }

    @Test func midi1OnlyPeerRecordsTheDowngradeAndItsLosses() throws {
        let result = try Self.negotiate(
            [Self.endpointMIDI1, Self.midi1Block0], ci: [Self.reply])
        #expect(result.level == .umpMIDI1)
        #expect(result.features == [.umpTransport, .functionBlocks, .ciDiscovery])
        #expect(result.functionBlocks.map(\.midi1Mode) == [.unrestricted])
        #expect(result.downgrades == [
            MIDICapabilityDowngrade(
                reason: .endpointLacksMIDI2, lost: [.midi2Protocol],
                possibleTranslationLosses: MIDICapabilityResolver.midi2ToMIDI1Losses)
        ])
    }

    @Test func possibleTranslationLossesAreExactlyWhatTheTranslatorDeclares() throws {
        let observed = try Self.observedDownLosses()
        let peer = try Self.negotiate([Self.endpointMIDI1, Self.midi1Block0], ci: [Self.reply])
        let silent = try Self.negotiate(
            [Self.endpointMIDI2, Self.block0, Self.block1], ci: [])
        let downgrades = peer.downgrades + silent.downgrades
        #expect(downgrades.map(\.reason) == [.endpointLacksMIDI2, .ciAnswerMissing])
        for downgrade in downgrades {
            #expect(downgrade.possibleTranslationLosses == observed, "\(downgrade.reason)")
        }
        // The headline per-note and precision losses are among them.
        #expect(observed.contains(.perNoteController))
        #expect(observed.contains(.perNotePitchBend))
        #expect(observed.contains(.velocityDownscaled))
        // MIDI 1.0 → 2.0 reasons are never predicted for a downgrade.
        let upward: Set<UMPTranslationLossReason> = [
            .incompleteBankSelect, .dataEntryWithoutParameter, .dataEntryLSBWithoutMSB, .dataIncrementUnmapped
        ]
        #expect(Set(UMPTranslationLossReason.allCases).subtracting(upward) == Set(observed))
    }

    @Test func blockMIDI1ModeRecordsADowngradeButDoesNotLowerTheLevel() throws {
        // The endpoint level stays `umpMIDI2`. Block 1 is a MIDI 1.0 block on a MIDI 2.0 endpoint; it is listed with
        // its mode, and `functionBlockMIDI1Only` names it with the MIDI 2.0 → 1.0 losses (#572 gap 3).
        let result = try Self.negotiate([Self.endpointMIDI2, Self.block0, Self.block1], ci: [Self.reply])
        #expect(result.level == .umpMIDI2)
        #expect(result.functionBlocks.map(\.midi1Mode) == [.notMIDI1, .unrestricted])
        #expect(result.downgrades == [Self.block1MIDI1Only])
        #expect(result.downgrades.first?.possibleTranslationLosses == (try Self.observedDownLosses()))
    }
}
