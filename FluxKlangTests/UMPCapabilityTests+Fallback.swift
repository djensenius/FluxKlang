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

/// One endpoint protocol's expected §9.1 receive fidelity through either input backend.
private struct FidelityRow {
    let endpoint: MIDIEndpointProtocol
    let verified: Bool
    let translated: Bool
    let losses: [UMPTranslationLossReason]
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

    // MARK: - Receive fidelity of a CoreMIDI binding (#791, M81-EP2)

    private typealias Adapter = CoreMIDIAdapterTests

    private static let receiveFormats: [MIDIPacketBatch.Format] = [.bytes, .midi1UMP]

    private static func fidelity(
        _ endpoint: MIDIEndpointProtocol, _ format: MIDIPacketBatch.Format
    ) -> CoreMIDIReceiveFidelity {
        CoreMIDIReceiveFidelity(endpoint: endpoint, format: format)
    }

    @Test func receiveFidelityFollowsSection91ForEveryEndpointAndFormat() throws {
        let observed = try Self.observedDownLosses()
        #expect(!observed.isEmpty)
        let table = [
            FidelityRow(endpoint: .midi1, verified: true, translated: false, losses: []),
            FidelityRow(endpoint: .midi2, verified: true, translated: true, losses: observed),
            FidelityRow(endpoint: .unknown, verified: false, translated: false, losses: [])
        ]
        #expect(table.map(\.endpoint) == MIDIEndpointProtocol.allCases)
        for row in table {
            for format in Self.receiveFormats {
                let fidelity = Self.fidelity(row.endpoint, format)
                let label = "\(row.endpoint) through \(format)"
                #expect(fidelity.endpoint == row.endpoint, "\(label)")
                #expect(fidelity.format == format, "\(label)")
                #expect(fidelity.receive == .midi1, "\(label)")
                #expect(fidelity.verified == row.verified, "\(label)")
                #expect(fidelity.translatedByOS == row.translated, "\(label)")
                #expect(fidelity.possibleTranslationLosses == row.losses, "\(label)")
            }
        }
    }

    /// The fidelity restates the §9.1 rule `MIDIProtocolStamp` already implements; the two must never drift apart.
    @Test func receiveFidelityAgreesWithTheCaptureProtocolStamp() throws {
        let noteOn = try UMPPacket(words: [0x2090_3C64])
        for endpoint in MIDIEndpointProtocol.allCases {
            for format in Self.receiveFormats {
                let fidelity = Self.fidelity(endpoint, format)
                let stamp = try MIDIProtocolStamp.classify(noteOn, endpoint: endpoint, port: fidelity.receive)
                let label = "\(endpoint) through \(format)"
                #expect(stamp.endpoint == fidelity.endpoint && stamp.port == fidelity.receive, "\(label)")
                #expect(stamp.verified == fidelity.verified, "\(label)")
                #expect(stamp.translatedByOS == fidelity.translatedByOS, "\(label)")
                #expect(stamp.effective == .midi1, "\(label)")
            }
        }
    }

    @Test func bindingsReportReceiveFidelityInEnumerationOrder() throws {
        let unit = { (ref: UInt32, protocolID: Int32?) in
            Adapter.reporting(protocolID, Adapter.source(ref, "Launch Control XL"))
        }
        let rows: [(record: CoreMIDIEndpointRecord, endpoint: MIDIEndpointProtocol)] = [
            (unit(30, 2), .midi2), (unit(10, nil), .unknown), (unit(20, 1), .midi1), (unit(50, 0), .unknown),
            (unit(40, 2), .midi2), (unit(60, 3), .unknown)
        ]
        let update = Adapter.bind(rows.map(\.record))
        try #require(update.registrations.count == rows.count)
        for format in Self.receiveFormats {
            let reported = update.bindings.receiveFidelity(format: format)
            try #require(reported.count == rows.count)
            #expect(reported.map(\.ref) == [30, 10, 20, 50, 40, 60])
            #expect(reported.map(\.token) == update.bindings.sources.map(\.token))
            #expect(reported.map(\.fidelity.format) == Array(repeating: format, count: rows.count))
            #expect(reported.map(\.fidelity) == rows.map { Self.fidelity($0.endpoint, format) })
            #expect(reported.map(\.fidelity.translatedByOS) == [true, false, false, false, true, false])
            #expect(reported.map(\.fidelity.verified) == [true, false, true, false, true, false])
        }
        #expect(CoreMIDIEndpointBindings().receiveFidelity(format: .bytes).isEmpty)
    }

    @Test func receiveFidelityFollowsKeptChangesRekeysAndRegistrations() throws {
        let unit = Adapter.source(11, "Launch Control XL", uniqueID: 500)
        let twin = Adapter.source(12, "Launch Control XL 2", uniqueID: 500)
        let first = Adapter.bind([Adapter.reporting(1, unit)])
        let token = try Adapter.token(of: 11, in: first)
        #expect(first.bindings.receiveFidelity(format: .midi1UMP) == [
            .init(ref: 11, token: token, fidelity: Self.fidelity(.midi1, .midi1UMP))
        ])

        let kept = Adapter.bind([Adapter.reporting(2, unit)], after: first.bindings)
        #expect(kept.protocolChanges == [.init(ref: 11, token: token, from: .midi1, to: .midi2)])
        let keptFidelity = kept.bindings.receiveFidelity(format: .midi1UMP)
        try #require(keptFidelity.count == 1)
        #expect(keptFidelity[0] == .init(ref: 11, token: token, fidelity: Self.fidelity(.midi2, .midi1UMP)))
        #expect(keptFidelity[0].fidelity.translatedByOS)

        let rekeyed = Adapter.bind([Adapter.reporting(nil, unit), Adapter.reporting(2, twin)], after: kept.bindings)
        #expect(rekeyed.detaches.map(\.ref) == [11] && rekeyed.registrations.map(\.ref) == [11, 12])
        #expect(rekeyed.protocolChanges.isEmpty)
        let rekeyedFidelity = rekeyed.bindings.receiveFidelity(format: .bytes)
        try #require(rekeyedFidelity.count == 2)
        #expect(rekeyedFidelity[0].token != token)
        #expect(rekeyedFidelity == [
            .init(ref: 11, token: try Adapter.token(of: 11, in: rekeyed), fidelity: Self.fidelity(.unknown, .bytes)),
            .init(ref: 12, token: try Adapter.token(of: 12, in: rekeyed), fidelity: Self.fidelity(.midi2, .bytes))
        ])

        let settled = Adapter.bind([Adapter.reporting(1, unit), Adapter.reporting(2, twin)], after: rekeyed.bindings)
        #expect(settled.detaches.isEmpty && settled.registrations.isEmpty)
        let settledFidelity = settled.bindings.receiveFidelity(format: .bytes)
        try #require(settledFidelity.count == 2)
        #expect(settled.protocolChanges == [
            .init(ref: 11, token: settledFidelity[0].token, from: .unknown, to: .midi1)
        ])
        #expect(settledFidelity.map(\.token) == rekeyedFidelity.map(\.token))
        #expect(settledFidelity.map(\.fidelity) == [Self.fidelity(.midi1, .bytes), Self.fidelity(.midi2, .bytes)])
        #expect(settledFidelity.map(\.fidelity.possibleTranslationLosses.isEmpty) == [true, false])
    }
}
