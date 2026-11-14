import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct PluginCatalogTests {
    @Test func identityIgnoresNamesVersionsAndScanOrder() throws {
        let verb = try Self.identity("Verb", manufacturer: "Ab C")
        let echo = try Self.identity("Echo")
        #expect(verb.id.rawValue == "plg.au2.61756678.56657262.41622043")
        #expect(try Self.identity("Verb", manufacturer: "Ab C") == verb)
        #expect(try Self.identity("Verb", manufacturer: "Ab C", format: .audioUnitV3).id != verb.id)

        var forward = PluginCatalog()
        var reversed = PluginCatalog()
        let entries = try [Self.described(verb, name: "Room Verb"), Self.described(echo, name: "Tape Echo")]
        _ = try forward.apply(PluginScanReport(entries: entries), for: forward.request(depth: .metadataOnly))
        _ = try reversed.apply(
            PluginScanReport(entries: entries.reversed()), for: reversed.request(depth: .metadataOnly)
        )
        #expect(forward == reversed)

        let renamed = try Self.described(verb, name: "Hall Verb", version: 0x0002_0100)
        let change = try forward.apply(
            PluginScanReport(entries: [renamed, entries[1]]), for: forward.request(depth: .metadataOnly)
        )
        #expect(change.changed == [verb.id])
        #expect(forward.entries[verb.id]?.lastKnown?.name == "Hall Verb")
    }

    @Test func malformedCodesAndUnsupportedTypesAreRefused() throws {
        #expect(throws: PluginIdentityError.invalidFourCharacterCode("abc")) { try PluginFourCharacterCode("abc") }
        #expect(throws: PluginIdentityError.invalidFourCharacterCode("ab\u{7}c")) {
            try PluginFourCharacterCode("ab\u{7}c")
        }
        #expect(PluginFourCharacterCode(rawValue: 0x6175_6600) == nil)
        let output = try PluginFourCharacterCode("auou")
        #expect(throws: PluginIdentityError.unsupportedComponentType(output)) {
            try PluginIdentity(
                format: .audioUnitV2, type: output,
                subtype: PluginFourCharacterCode("Verb"), manufacturer: PluginFourCharacterCode("Fxkl")
            )
        }
    }

    @Test func generationStepsOnlyWhenTheCatalogChanges() throws {
        var catalog = PluginCatalog()
        let verb = try Self.identity("Verb")
        #expect(catalog.scanState == .notScanned)
        #expect(catalog.generation == .initial)

        let first = try catalog.apply(PluginScanReport(entries: []), for: catalog.request(depth: .metadataOnly))
        #expect(first.generation.value == 2 && first.changed.isEmpty)
        let report = try PluginScanReport(entries: [Self.described(verb)])
        let added = try catalog.apply(report, for: catalog.request(depth: .metadataOnly))
        let rescan = try catalog.apply(report, for: catalog.request(depth: .metadataOnly))
        #expect(added.generation.value == 3 && added.changed == [verb.id])
        #expect(rescan.generation == added.generation && rescan.changed.isEmpty)
        #expect(catalog.isCurrent(added.generation))

        let updated = try catalog.apply(
            PluginScanReport(entries: [Self.described(verb, version: 0x0001_0001)]),
            for: catalog.request(depth: .metadataOnly)
        )
        #expect(updated.generation.value == 4)
        #expect(!catalog.isCurrent(added.generation))
    }

    @Test func missingAndFailedReferencesKeepPlaceholdersWithoutSubstitution() throws {
        var catalog = PluginCatalog()
        let echo = try Self.identity("Echo")
        let lookalike = try Self.identity("Ech2")
        let reference = try PluginReference(identity: echo, lastKnownName: "Tape Echo", lastKnownVersion: nil)
        #expect(catalog.resolve(reference).outcome == Self.placeholder(reference, .notScanned, nil))

        let original = try Self.described(echo, name: "Tape Echo")
        _ = try catalog.apply(PluginScanReport(entries: [original]), for: catalog.request(depth: .metadataOnly))
        let lastKnown = try Self.descriptor(echo, name: "Tape Echo")
        #expect(catalog.resolve(reference).outcome == .available(lastKnown, versionChanged: false))

        let sameName = try Self.described(lookalike, name: "Tape Echo")
        _ = try catalog.apply(PluginScanReport(entries: [sameName]), for: catalog.request(depth: .metadataOnly))
        #expect(catalog.entries[echo.id]?.presence == .missing)
        #expect(catalog.resolve(reference).outcome == Self.placeholder(reference, .notInstalled, lastKnown))

        let failed = PluginScanEntry(identity: echo, outcome: .failed(.metadataUnavailable))
        _ = try catalog.apply(PluginScanReport(entries: [failed]), for: catalog.request(depth: .metadataOnly))
        #expect(catalog.resolve(reference).outcome
            == Self.placeholder(reference, .failed(.metadataUnavailable), lastKnown))

        let gone = try Self.identity("Gone")
        let unknown = try PluginReference(identity: gone, lastKnownName: "Gone", lastKnownVersion: nil)
        #expect(catalog.resolve(unknown).outcome == Self.placeholder(unknown, .notInstalled, nil))

        let pinned = try PluginReference(
            identity: echo, lastKnownName: "Tape Echo", lastKnownVersion: PluginVersion(rawValue: 9)
        )
        _ = try catalog.apply(PluginScanReport(entries: [original]), for: catalog.request(depth: .metadataOnly))
        #expect(catalog.resolve(pinned).outcome == .available(lastKnown, versionChanged: true))
    }

    @Test func probeCrashesAndHangsQuarantineUntilExplicitRelease() throws {
        var catalog = PluginCatalog()
        let verb = try Self.identity("Verb")
        let synth = try Self.identity("Synt", type: "aumu")
        let probe = PluginScanReport(entries: [
            PluginScanEntry(identity: verb, outcome: .probeCrashed),
            PluginScanEntry(identity: synth, outcome: .probeTimedOut)
        ])
        _ = try catalog.apply(probe, for: catalog.request(depth: .instantiatingProbe))
        #expect(catalog.request(depth: .instantiatingProbe).quarantined == [verb.id, synth.id])
        #expect(catalog.entries[synth.id]?.quarantine == .probeTimedOut)
        #expect(catalog.entries[verb.id]?.presence == .needsRescan)

        _ = try catalog.apply(
            PluginScanReport(entries: [Self.described(verb), Self.described(synth)]),
            for: catalog.request(depth: .instantiatingProbe)
        )
        let reference = try PluginReference(identity: verb, lastKnownName: "Verb", lastKnownVersion: nil)
        let described = try Self.descriptor(verb)
        #expect(catalog.resolve(reference).outcome
            == Self.placeholder(reference, .quarantined(.probeCrashed), described))

        let expected = try catalog.generation.next()
        let release = try catalog.releaseQuarantine(verb.id)
        #expect(release.changed == [verb.id] && release.generation == expected)
        #expect(catalog.resolve(reference).outcome == .available(described, versionChanged: false))
        #expect(throws: PluginCatalogError.notQuarantined(verb.id)) { try catalog.releaseQuarantine(verb.id) }
    }

    @Test(arguments: InvalidReport.allCases)
    func invalidReportsChangeNothing(_ invalid: InvalidReport) throws {
        var catalog = PluginCatalog()
        let verb = try Self.identity("Verb")
        let crashed = PluginScanReport(entries: [PluginScanEntry(identity: verb, outcome: .probeCrashed)])
        _ = try catalog.apply(crashed, for: catalog.request(depth: .instantiatingProbe))
        let echo = try Self.identity("Echo")
        let metadata = catalog.request(depth: .metadataOnly)
        let scenario: InvalidScenario
        switch invalid {
        case .duplicate:
            scenario = try .init([Self.described(echo), Self.described(echo)], metadata, .duplicateIdentity(echo.id))
        case .mismatchedDescriptor:
            let entry = try PluginScanEntry(identity: echo, outcome: .described(Self.descriptor(verb)))
            scenario = .init([entry], metadata, .descriptorIdentityMismatch(echo.id))
        case .probeDuringMetadataScan:
            let entry = PluginScanEntry(identity: echo, outcome: .probeTimedOut)
            scenario = .init([entry], metadata, .probeOutcomeFromMetadataScan(echo.id))
        case .probedQuarantined:
            scenario = .init(crashed.entries, catalog.request(depth: .instantiatingProbe),
                             .probedQuarantinedPlugin(verb.id))
        case .staleRequest:
            scenario = .init([], PluginScanRequest(depth: .instantiatingProbe, quarantined: []), .staleRequest)
        case .tooManyEntries:
            let maximum = PluginCatalogLimits.entries + PluginCatalogLimits.quarantineHeadroom
            scenario = try .init(Self.report(count: maximum + 1).entries, metadata, .tooManyEntries(maximum: maximum))
        }
        let before = catalog
        #expect(throws: scenario.expected) {
            try catalog.apply(PluginScanReport(entries: scenario.entries), for: scenario.request)
        }
        #expect(catalog == before)
    }

    @Test func capDefersNewcomersUntilAnExplicitForget() throws {
        var catalog = PluginCatalog()
        let full = try Self.report(count: PluginCatalogLimits.entries)
        _ = try catalog.apply(full, for: catalog.request(depth: .metadataOnly))
        _ = try catalog.apply(PluginScanReport(entries: []), for: catalog.request(depth: .metadataOnly))
        #expect(catalog.entries.count == PluginCatalogLimits.entries)
        #expect(catalog.entries.values.allSatisfy { $0.presence == .missing })

        let before = catalog
        let newcomer = try PluginScanReport(entries: [Self.described(Self.identity("New!"))])
        let deferred = try catalog.apply(newcomer, for: catalog.request(depth: .metadataOnly))
        #expect(deferred == PluginCatalogChange(generation: before.generation, changed: [], deferred: 1))
        #expect(catalog == before)

        let forgotten = full.entries[0].identity.id
        let expected = try before.generation.next()
        let forget = try catalog.forget(forgotten)
        #expect(forget.changed == [forgotten] && forget.generation == expected)
        let admitted = try catalog.apply(newcomer, for: catalog.request(depth: .metadataOnly))
        #expect(admitted.changed == [newcomer.entries[0].identity.id])
        #expect(catalog.entries.count == PluginCatalogLimits.entries && catalog.entries[forgotten] == nil)
    }

    @Test func quarantineEvidenceUsesBoundedHeadroomAboveTheCap() throws {
        var catalog = try Self.fullCatalog()
        let headroom = PluginCatalogLimits.quarantineHeadroom
        let maximum = PluginCatalogLimits.entries + headroom
        let evidence = try Self.evidence(count: headroom + 1)
        let first = try catalog.recordQuarantine([evidence[0]])
        #expect(first.changed == [evidence[0].identity.id] && catalog.entries.count == PluginCatalogLimits.entries + 1)

        let before = catalog
        #expect(throws: PluginCatalogError.quarantineHeadroomExhausted(maximum: maximum)) {
            try catalog.recordQuarantine(Array(evidence.dropFirst()))
        }
        #expect(catalog == before)
        _ = try catalog.recordQuarantine(Array(evidence.dropFirst().dropLast()))
        #expect(catalog.entries.count == maximum && catalog.quarantined.count == headroom)
        #expect(throws: PluginCatalogError.tooManyEntries(maximum: PluginCatalogLimits.entries)) {
            try catalog.releaseQuarantine(evidence[0].identity.id)
        }
    }

    @Test func forgetThenReleaseThenForgetRecoversABareEntryAtTheCap() throws {
        var catalog = try Self.fullCatalog()
        _ = try catalog.apply(PluginScanReport(entries: []), for: catalog.request(depth: .metadataOnly))
        let bare = try Self.evidence(count: 1)[0]
        _ = try catalog.recordQuarantine([bare])
        let id = bare.identity.id
        #expect(throws: PluginCatalogError.tooManyEntries(maximum: PluginCatalogLimits.entries)) {
            try catalog.releaseQuarantine(id)
        }
        #expect(throws: PluginCatalogError.cannotForget(id, .quarantined)) { try catalog.forget(id) }

        _ = try catalog.forget(Self.report(count: 1).entries[0].identity.id)
        let released = try catalog.releaseQuarantine(id)
        #expect(released.changed == [id] && catalog.quarantined.isEmpty)
        #expect(throws: PluginCatalogError.cannotForget(id, .notMissing)) { try catalog.forget(id) }
        _ = try catalog.apply(PluginScanReport(entries: []), for: catalog.request(depth: .metadataOnly))
        _ = try catalog.forget(id)
        #expect(catalog.entries[id] == nil && catalog.entries.count == PluginCatalogLimits.entries - 1)
    }

    @Test func describingABareEntryOverTheCapIsDeferredWhileAbsencesApply() throws {
        var catalog = try Self.fullCatalog()
        let bare = try Self.evidence(count: 1)[0]
        _ = try catalog.recordQuarantine([bare])
        let before = catalog
        let report = try PluginScanReport(entries: [Self.described(bare.identity)])
        let change = try catalog.apply(report, for: catalog.request(depth: .metadataOnly))
        #expect(change.deferred == 1 && change.changed.count == PluginCatalogLimits.entries)
        #expect(catalog.entries[bare.identity.id] == before.entries[bare.identity.id])
        #expect(catalog.entries.values.filter { $0.presence == .missing }.count == PluginCatalogLimits.entries)
    }

    @Test func forgetRefusesAnythingButMissingUnquarantinedEntries() throws {
        var catalog = PluginCatalog()
        let verb = try Self.identity("Verb")
        let echo = try Self.identity("Echo")
        let crashed = PluginScanReport(entries: [PluginScanEntry(identity: verb, outcome: .probeCrashed)])
        _ = try catalog.apply(crashed, for: catalog.request(depth: .instantiatingProbe))
        let installed = try PluginScanReport(entries: [Self.described(echo)])
        _ = try catalog.apply(installed, for: catalog.request(depth: .metadataOnly))
        #expect(catalog.entries[verb.id]?.presence == .missing)

        let before = catalog
        let unknown = try Self.identity("Gone").id
        let refusals: [(PluginID, PluginForgetRefusal)] = [(verb.id, .quarantined), (echo.id, .notMissing),
                                                           (unknown, .unknown)]
        for (id, refusal) in refusals {
            #expect(throws: PluginCatalogError.cannotForget(id, refusal)) { try catalog.forget(id) }
        }
        #expect(catalog == before)
    }

    @Test func descriptorMetadataIsBounded() throws {
        let verb = try Self.identity("Verb")
        let layout = try PluginBusLayout(inputChannels: [2], outputChannels: [2])
        let long = String(repeating: "n", count: PluginCatalogLimits.nameBytes + 1)
        #expect(throws: PluginDescriptorError.invalidName) {
            try PluginDescriptor(identity: verb, name: long, manufacturerName: "M", version: .init(rawValue: 1),
                                 buses: layout)
        }
        #expect(throws: PluginDescriptorError.invalidManufacturerName) {
            try PluginDescriptor(identity: verb, name: "V", manufacturerName: " ", version: .init(rawValue: 1),
                                 buses: layout)
        }
        let buses = Array(repeating: 1, count: PluginCatalogLimits.busesPerDirection + 1)
        #expect(throws: PluginDescriptorError.tooManyBuses(.output, count: buses.count)) {
            try PluginBusLayout(inputChannels: [], outputChannels: buses)
        }
        #expect(throws: PluginDescriptorError.invalidChannelCount(.input, bus: 1, count: 0)) {
            try PluginBusLayout(inputChannels: [2, 0], outputChannels: [2])
        }
        #expect(throws: PluginDescriptorError.invalidChannelCount(.input, bus: 0, count: 65)) {
            try PluginBusLayout(inputChannels: [65], outputChannels: [2])
        }
    }
}

extension PluginCatalogTests {
    @Test func releasedProbeNeedsAFreshDescriptionBeforeItResolves() throws {
        var catalog = PluginCatalog()
        let verb = try Self.identity("Verb")
        let described = try PluginScanReport(entries: [Self.described(verb)])
        _ = try catalog.apply(described, for: catalog.request(depth: .metadataOnly))
        let crashed = PluginScanReport(entries: [PluginScanEntry(identity: verb, outcome: .probeCrashed)])
        _ = try catalog.apply(crashed, for: catalog.request(depth: .instantiatingProbe))
        _ = try catalog.releaseQuarantine(verb.id)

        let reference = try PluginReference(identity: verb, lastKnownName: "Verb", lastKnownVersion: nil)
        let stale = try Self.descriptor(verb)
        #expect(catalog.resolve(reference).outcome == Self.placeholder(reference, .needsRescan, stale))

        let fresh = try Self.described(verb, version: 0x0002_0000)
        _ = try catalog.apply(PluginScanReport(entries: [fresh]), for: catalog.request(depth: .metadataOnly))
        let current = try Self.descriptor(verb, version: 0x0002_0000)
        #expect(catalog.resolve(reference).outcome == .available(current, versionChanged: false))
    }

    @Test func recordedQuarantineCommitsOnlyRealChanges() throws {
        var catalog = PluginCatalog()
        let verb = try Self.identity("Verb")
        let echo = try Self.identity("Echo")
        let described = try PluginScanReport(entries: [Self.described(echo)])
        _ = try catalog.apply(described, for: catalog.request(depth: .metadataOnly))
        let expected = try catalog.generation.next()

        let first = try catalog.recordQuarantine([
            PluginQuarantineEvidence(identity: verb, reason: .probeTimedOut),
            PluginQuarantineEvidence(identity: echo, reason: .probeCrashed)
        ])
        #expect(first.changed == [echo.id, verb.id].sorted() && first.generation == expected)
        #expect(catalog.entries[verb.id] == PluginCatalogEntry(identity: verb, presence: .needsRescan,
                                                               quarantine: .probeTimedOut))
        #expect(catalog.entries[echo.id]?.presence == .needsRescan)

        let again = try catalog.recordQuarantine([PluginQuarantineEvidence(identity: verb, reason: .probeCrashed)])
        #expect(again == PluginCatalogChange(generation: first.generation, changed: []))
        #expect(catalog.entries[verb.id]?.quarantine == .probeTimedOut)

        let before = catalog
        let duplicate = PluginQuarantineEvidence(identity: echo, reason: .probeCrashed)
        #expect(throws: PluginCatalogError.duplicateIdentity(echo.id)) {
            try catalog.recordQuarantine([duplicate, duplicate])
        }
        #expect(catalog == before)
    }

    @Test func generationOverflowIsRefusedWithoutChange() throws {
        let last = try Generation(Generation.maximumValue - 1)
        var catalog = PluginCatalog(generation: last)
        _ = try catalog.apply(PluginScanReport(entries: []), for: catalog.request(depth: .metadataOnly))
        #expect(catalog.generation.value == Generation.maximumValue)

        let before = catalog
        let verb = try Self.identity("Verb")
        #expect(throws: PluginCatalogError.generationOverflow) {
            try catalog.apply(PluginScanReport(entries: [Self.described(verb)]),
                              for: catalog.request(depth: .metadataOnly))
        }
        #expect(throws: PluginCatalogError.generationOverflow) {
            try catalog.recordQuarantine([PluginQuarantineEvidence(identity: verb, reason: .probeCrashed)])
        }
        #expect(catalog == before)
        let identical = try catalog.apply(PluginScanReport(entries: []), for: catalog.request(depth: .metadataOnly))
        #expect(identical.changed.isEmpty && catalog == before)
    }

    @Test func sameCodesUnderBothFormatsResolveIndependently() throws {
        var catalog = PluginCatalog()
        let au2 = try Self.identity("Verb")
        let au3 = try Self.identity("Verb", format: .audioUnitV3)
        let report = try PluginScanReport(entries: [Self.described(au2, name: "Verb v2"),
                                                    PluginScanEntry(identity: au3, outcome: .probeCrashed)])
        _ = try catalog.apply(report, for: catalog.request(depth: .instantiatingProbe))
        #expect(catalog.entries.count == 2)

        let ref2 = try PluginReference(identity: au2, lastKnownName: "Verb", lastKnownVersion: nil)
        let ref3 = try PluginReference(identity: au3, lastKnownName: "Verb", lastKnownVersion: nil)
        let descriptor2 = try Self.descriptor(au2, name: "Verb v2")
        #expect(catalog.resolve(ref2).outcome == .available(descriptor2, versionChanged: false))
        #expect(catalog.resolve(ref3).outcome == Self.placeholder(ref3, .quarantined(.probeCrashed), nil))
    }

    @Test func quarantineIsRetainedWhileMissingOrFailed() throws {
        var catalog = PluginCatalog()
        let verb = try Self.identity("Verb")
        let crashed = PluginScanReport(entries: [PluginScanEntry(identity: verb, outcome: .probeCrashed)])
        _ = try catalog.apply(crashed, for: catalog.request(depth: .instantiatingProbe))
        let reference = try PluginReference(identity: verb, lastKnownName: "Verb", lastKnownVersion: nil)
        let quarantined = Self.placeholder(reference, .quarantined(.probeCrashed), nil)

        _ = try catalog.apply(PluginScanReport(entries: []), for: catalog.request(depth: .instantiatingProbe))
        #expect(catalog.entries[verb.id]?.presence == .missing)
        #expect(catalog.resolve(reference).outcome == quarantined)

        let failed = PluginScanReport(entries: [PluginScanEntry(identity: verb, outcome: .failed(.validationFailed))])
        _ = try catalog.apply(failed, for: catalog.request(depth: .instantiatingProbe))
        #expect(catalog.entries[verb.id]?.presence == .failed(.validationFailed))
        #expect(catalog.resolve(reference).outcome == quarantined)
    }

    @Test(arguments: ["Verb\u{0}", "\u{202E}breV", "Ve\u{7}rb", "Ve\u{200B}rb", "Verb\n2", "\u{FEFF}Verb"])
    func controlAndFormatScalarsAreRefusedInNames(_ name: String) throws {
        let verb = try Self.identity("Verb")
        let layout = try PluginBusLayout(inputChannels: [2], outputChannels: [2])
        #expect(throws: PluginDescriptorError.invalidName) {
            try PluginDescriptor(identity: verb, name: name, manufacturerName: "M", version: .init(rawValue: 1),
                                 buses: layout)
        }
        #expect(throws: PluginDescriptorError.invalidManufacturerName) {
            try PluginDescriptor(identity: verb, name: "V", manufacturerName: name, version: .init(rawValue: 1),
                                 buses: layout)
        }
        #expect(throws: PluginDescriptorError.invalidName) {
            try PluginReference(identity: verb, lastKnownName: name, lastKnownVersion: nil)
        }
        #expect(PluginDescriptor.isValidName("Réverb – Hall"))
    }
}

extension PluginCatalogTests {
    enum InvalidReport: CaseIterable, Sendable {
        case duplicate, mismatchedDescriptor, probeDuringMetadataScan, probedQuarantined, staleRequest, tooManyEntries
    }

    struct InvalidScenario {
        let entries: [PluginScanEntry]
        let request: PluginScanRequest
        let expected: PluginCatalogError

        init(_ entries: [PluginScanEntry], _ request: PluginScanRequest, _ expected: PluginCatalogError) {
            self.entries = entries
            self.request = request
            self.expected = expected
        }
    }

    static func identity(
        _ subtype: String, type: String = "aufx", manufacturer: String = "Fxkl", format: PluginFormat = .audioUnitV2
    ) throws -> PluginIdentity {
        try PluginIdentity(
            format: format, type: PluginFourCharacterCode(type),
            subtype: PluginFourCharacterCode(subtype), manufacturer: PluginFourCharacterCode(manufacturer)
        )
    }

    static func descriptor(
        _ identity: PluginIdentity, name: String? = nil, version: UInt32 = 0x0001_0000
    ) throws -> PluginDescriptor {
        try PluginDescriptor(
            identity: identity, name: name ?? identity.subtype.description, manufacturerName: "Fixture Audio",
            version: PluginVersion(rawValue: version),
            buses: PluginBusLayout(inputChannels: [2], outputChannels: [2], acceptsMIDI: identity.kind == .instrument)
        )
    }

    static func described(
        _ identity: PluginIdentity, name: String? = nil, version: UInt32 = 0x0001_0000
    ) throws -> PluginScanEntry {
        try PluginScanEntry(identity: identity, outcome: .described(descriptor(identity, name: name, version: version)))
    }

    static func report(count: Int) throws -> PluginScanReport {
        try PluginScanReport(entries: (0..<count).map { index in
            let digits = String(index, radix: 16)
            return try described(identity(String(repeating: "0", count: 4 - digits.count) + digits))
        })
    }

    static func fullCatalog() throws -> PluginCatalog {
        var catalog = PluginCatalog()
        _ = try catalog.apply(report(count: PluginCatalogLimits.entries), for: catalog.request(depth: .metadataOnly))
        return catalog
    }

    static func evidence(count: Int) throws -> [PluginQuarantineEvidence] {
        try (0..<count).map { index in
            let digits = String(index, radix: 16)
            let crashed = try identity(String(repeating: "0", count: 4 - digits.count) + digits, manufacturer: "Qrnt")
            return PluginQuarantineEvidence(identity: crashed, reason: .probeCrashed)
        }
    }

    static func placeholder(
        _ reference: PluginReference, _ reason: PluginPlaceholderReason, _ lastKnown: PluginDescriptor?
    ) -> PluginResolutionOutcome {
        .placeholder(PluginPlaceholder(reference: reference, reason: reason, lastKnown: lastKnown))
    }
}
