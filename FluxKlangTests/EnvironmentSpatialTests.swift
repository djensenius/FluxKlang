//
//  EnvironmentSpatialTests.swift
//  FluxKlangTests
//

import CoreGraphics
import Foundation
import Testing
@testable import FluxKlang

struct EnvironmentSpatialTests {
    private let quad = SpeakerArray.standardQuad.speakers
    private let centre = CGPoint(x: 0.5, y: 0.5)

    // MARK: - SpatialRouting compilation

    @Test func monoSourceSendsToEverySpeakerBus() {
        let source = SpatialSource(name: "Mono", left: .channel(5), position: centre)
        let settings = SpatialRouting.settings(for: source, speakers: quad)

        // 4 speaker buses × (send-on + send-level).
        #expect(settings.count == 8)
        let onAddresses = settings.filter { $0.address.hasSuffix("/on") }.map(\.address)
        #expect(Set(onAddresses) == [
            "/ch/5/send/1/on", "/ch/5/send/2/on", "/ch/5/send/3/on", "/ch/5/send/4/on"
        ])
        #expect(settings.filter { $0.address.hasSuffix("/on") }.allSatisfy { $0.value == .int(1) })
    }

    @Test func centreOverSymmetricQuadIsAboutMinusSixDecibels() {
        let source = SpatialSource(name: "Mono", left: .channel(5), position: centre)
        let levels = SpatialRouting.settings(for: source, speakers: quad)
            .filter { $0.address.hasSuffix("/lvl") }
            .compactMap { $0.value.floatValue }
        #expect(levels.count == 4)
        for level in levels {
            #expect(abs(level + 6.02) < 0.1)
        }
    }

    @Test func stereoSourceDrivesBothChannels() {
        let source = SpatialSource(
            name: "Stereo", mode: .stereo,
            left: .channel(5), right: .channel(6),
            position: centre, width: 0.5
        )
        let settings = SpatialRouting.settings(for: source, speakers: quad)
        #expect(settings.count == 16)
        #expect(settings.contains { $0.address == "/ch/5/send/1/on" })
        #expect(settings.contains { $0.address == "/ch/6/send/4/on" })
    }

    @Test func noSpeakersYieldsNoSettings() {
        let source = SpatialSource(name: "Mono", left: .channel(5), position: centre)
        #expect(SpatialRouting.settings(for: source, speakers: []).isEmpty)
    }

    // MARK: - Voice → source

    @Test func sourceVoiceBuildsMonoSpatialSource() {
        let voice = EnvironmentVoice(
            id: "source:x", kind: .source, name: "Synth",
            sourceNames: ["Synth"], channels: [7], isStereo: false
        )
        let source = voice.spatialSource(position: centre, width: 0.5)
        #expect(source?.mode == .mono)
        #expect(source?.left == .channel(7))
        #expect(source?.right == nil)
    }

    @Test func stereoVoiceBuildsStereoSpatialSource() {
        let voice = EnvironmentVoice(
            id: "return:x", kind: .effectReturn, name: "Reverb",
            sourceNames: ["A", "B"], channels: [39, 40], isStereo: true
        )
        let source = voice.spatialSource(position: centre, width: 0.5)
        #expect(source?.mode == .stereo)
        #expect(source?.left == .channel(39))
        #expect(source?.right == .channel(40))
    }

    @Test func voiceWithoutChannelsHasNoSource() {
        let voice = EnvironmentVoice(
            id: "return:x", kind: .effectReturn, name: "Empty",
            sourceNames: [], channels: [], isStereo: false
        )
        #expect(voice.spatialSource(position: centre, width: 0.5) == nil)
    }

    // MARK: - Voice id helpers

    @Test func remapRewritesReturnIDsAndLeavesSourcesAlone() {
        let oldEffect = UUID()
        let newEffect = UUID()
        let equipment = UUID()
        let remap = [oldEffect: newEffect]
        #expect(EnvironmentVoice.remap(voiceID: "return:\(oldEffect.uuidString)", effects: remap)
            == "return:\(newEffect.uuidString)")
        #expect(EnvironmentVoice.remap(voiceID: "source:\(equipment.uuidString)", effects: remap)
            == "source:\(equipment.uuidString)")
        #expect(EnvironmentVoice.remap(voiceID: "return:\(UUID().uuidString)", effects: [:])
            .hasPrefix("return:"))
    }

    // MARK: - Environment placement persistence

    @Test func placementsSurviveACodableRoundTrip() throws {
        var environment = RoutingEnvironment(name: "Live")
        environment.placements["source:abc"] = VoicePlacement(position: CGPoint(x: 0.2, y: 0.8), width: 0.3)
        let data = try JSONEncoder().encode(environment)
        let decoded = try JSONDecoder().decode(RoutingEnvironment.self, from: data)
        #expect(decoded.placements["source:abc"]?.width == 0.3)
        #expect(decoded.placements["source:abc"]?.position == CGPoint(x: 0.2, y: 0.8))
    }

    @Test func graphSurvivesACodableRoundTrip() throws {
        var environment = RoutingEnvironment(name: "Live")
        let node = ChainNode(kind: .wingChannel(3), title: "Channel 3", position: CGPoint(x: 10, y: 20))
        environment.graph.addNode(node)
        let data = try JSONEncoder().encode(environment)
        let decoded = try JSONDecoder().decode(RoutingEnvironment.self, from: data)
        #expect(decoded.graph.nodes.count == 1)
        #expect(decoded.graph.node(node.id)?.title == "Channel 3")
        #expect(decoded.graph.node(node.id)?.position == CGPoint(x: 10, y: 20))
    }

    @Test func legacyEnvironmentWithoutPlacementsDecodes() throws {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"Old\"}"
        let decoded = try JSONDecoder().decode(RoutingEnvironment.self, from: Data(json.utf8))
        #expect(decoded.placements.isEmpty)
        #expect(decoded.effects.isEmpty)
        // Environments saved before the per-environment canvas decode with an
        // empty graph rather than failing.
        #expect(decoded.graph.nodes.isEmpty)
        #expect(decoded.graph.edges.isEmpty)
        // Environments saved before the semantic studio graph decode with empty
        // endpoint/stem state rather than failing.
        #expect(decoded.studioGraph.nodes.isEmpty)
        #expect(decoded.studioGraph.edges.isEmpty)
        #expect(decoded.studioEndpoints.isEmpty)
        #expect(decoded.studioSetup.devices.isEmpty)
        #expect(decoded.name == "Old")
    }

    @Test func duplicatingRemapsReturnPlacementsAndKeepsSources() {
        let first = Effect(name: "Reverb")
        var second = Effect(name: "Delay")
        second.destinationEffectID = first.id
        var environment = RoutingEnvironment(name: "Song", effects: [first, second])
        let sourceKey = "source:\(UUID().uuidString)"
        environment.placements[sourceKey] = VoicePlacement(width: 0.1)
        environment.placements[EnvironmentVoice.returnID(first.id)] = VoicePlacement(width: 0.2)
        environment.placements[EnvironmentVoice.returnID(second.id)] = VoicePlacement(width: 0.3)

        let copy = environment.duplicated(named: "Song Copy")
        #expect(copy.placements.count == 3)
        #expect(copy.placements[sourceKey]?.width == 0.1)
        // The first/second placements follow their effects' new identities.
        #expect(copy.placements[EnvironmentVoice.returnID(copy.effects[0].id)]?.width == 0.2)
        #expect(copy.placements[EnvironmentVoice.returnID(copy.effects[1].id)]?.width == 0.3)
        // The original effect ids are gone.
        #expect(copy.placements[EnvironmentVoice.returnID(first.id)] == nil)
    }

    @Test func duplicatingCopiesTheCanvasGraph() {
        var environment = RoutingEnvironment(name: "Song")
        environment.graph.addNode(ChainNode(kind: .wingBus(2), title: "Bus 2", position: .zero))
        environment.graph.addNode(ChainNode(kind: .wingOutput(5), title: "Output 5", position: .zero))

        let copy = environment.duplicated(named: "Song Copy")
        #expect(copy.graph.nodes.count == 2)
        #expect(copy.graph.nodes.contains { $0.kind == .wingBus(2) })
        #expect(copy.graph.nodes.contains { $0.kind == .wingOutput(5) })
    }
}

private struct EnvironmentPersistenceEnvelope: Codable, Sendable {
    var environments: [RoutingEnvironment]
    var activeID: RoutingEnvironment.ID?
    var migratedChain: Bool?
    var migratedEffectEquipmentLinks: Bool?

    static func read(from directory: URL) throws -> Self {
        let fileURL = directory.appendingPathComponent("environments.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: fileURL))
    }
}

extension EnvironmentSpatialTests {
    @MainActor
    @Test func legacyEffectsAndChainPersistThroughSnapshotCompletion() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("environments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = JSONFileStore(directory: directory, cloud: nil)
        let reverb = Effect(name: "Legacy reverb", sendOutputs: [3, 4], returnInputs: [5, 6])
        let delay = Effect(name: "Legacy delay", isStereo: false, sendOutputs: [7], returnInputs: [8],
                           sourceInstruments: [UUID()], destinationEffectID: reverb.id)
        let effects = [reverb, delay]
        let bus = ChainNode(kind: .wingBus(2), title: "Send", position: CGPoint(x: 10, y: 20))
        let output = ChainNode(kind: .wingOutput(3), title: "Out", position: CGPoint(x: 200, y: 20))
        var graph = ChainGraph(nodes: [bus, output])
        graph.connect(from: ChainPortRef(nodeID: bus.id, side: .output, port: 0),
                      to: ChainPortRef(nodeID: output.id, side: .input, port: 0))
        try JSONEncoder().encode(effects).write(to: directory.appendingPathComponent("effects.json"))
        try JSONEncoder().encode(graph).write(to: directory.appendingPathComponent("chain.json"))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("environments.json").path))

        let owner = EnvironmentStore(store: store)
        await owner.load()
        await owner.awaitScheduledSavesSnapshot()

        let saved = try EnvironmentPersistenceEnvelope.read(from: directory)
        let environment = try #require(saved.environments.first)
        #expect(saved.environments.count == 1)
        #expect(environment.name == "Default")
        #expect(saved.activeID == environment.id)
        #expect(owner.activeID == environment.id)
        #expect(environment.effects == effects)
        #expect(environment.graph == graph)
        #expect(saved.migratedChain == true)
        #expect(owner.environments == saved.environments)

        let reloadedOwner = EnvironmentStore(store: store)
        await reloadedOwner.load()
        await reloadedOwner.awaitScheduledSavesSnapshot()

        let reloaded = try EnvironmentPersistenceEnvelope.read(from: directory)
        #expect(reloaded.environments == [environment])
        #expect(reloaded.activeID == environment.id)
        #expect(reloaded.migratedChain == true)
        #expect(reloadedOwner.environments == [environment])
        #expect(reloadedOwner.activeID == environment.id)
    }

    @MainActor
    @Test func endpointNormalizationPersistsWithoutChainMigrationWrite() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("environments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = JSONFileStore(directory: directory, cloud: nil)
        let connector = WingOutputConnector(index: 3)
        let canonical = StudioEndpoint(name: "Desk", destination: .custom, outputConnectors: [connector])
        let duplicate = StudioEndpoint(name: "Duplicate desk", destination: .custom, outputConnectors: [connector])
        let unused = StudioEndpoint(name: "Unused", destination: .custom, outputConnectors: [.init(index: 4)])
        let canonicalNode = StudioNode(kind: .endpoint(canonical.id), title: "Desk",
                                       position: CGPoint(x: 10, y: 20))
        let duplicateNode = StudioNode(kind: .endpoint(duplicate.id), title: "Duplicate desk",
                                       position: CGPoint(x: 100, y: 20))
        let first = RoutingEnvironment(name: "Not selected")
        let selected = RoutingEnvironment(
            name: "Selected", studioGraph: StudioGraph(nodes: [canonicalNode, duplicateNode]),
            studioEndpoints: [canonical, duplicate, unused]
        )
        // The chain flag prevents an unrelated migration write from masking a missing normalization save.
        let seed = EnvironmentPersistenceEnvelope(environments: [first, selected], activeID: selected.id,
                                                  migratedChain: true, migratedEffectEquipmentLinks: false)
        try JSONEncoder().encode(seed).write(to: directory.appendingPathComponent("environments.json"))

        let owner = EnvironmentStore(store: store)
        await owner.load()
        await owner.awaitScheduledSavesSnapshot()

        var expected = selected
        expected.studioGraph = StudioGraph(nodes: [canonicalNode])
        expected.studioEndpoints = [canonical]
        let saved = try EnvironmentPersistenceEnvelope.read(from: directory)
        #expect(saved.environments == [first, expected])
        #expect(saved.activeID == selected.id)
        #expect(saved.migratedChain == true)
        #expect(saved.migratedEffectEquipmentLinks == false)
        #expect(owner.environments == [first, expected])
        #expect(owner.activeID == selected.id)

        let reloadedOwner = EnvironmentStore(store: store)
        await reloadedOwner.load()
        await reloadedOwner.awaitScheduledSavesSnapshot()

        let reloaded = try EnvironmentPersistenceEnvelope.read(from: directory)
        #expect(reloaded.environments == [first, expected])
        #expect(reloaded.activeID == selected.id)
        #expect(reloaded.migratedChain == true)
        #expect(reloadedOwner.environments == [first, expected])
        #expect(reloadedOwner.activeID == selected.id)
    }

    @MainActor
    @Test func orderedMutationsPersistEquipmentLinkAndRespectDeliberateClear() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("environments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileStore(directory: directory, cloud: nil)
        let owner = EnvironmentStore(store: store)
        let equipment = Equipment(name: "Reverb")
        let effect = Effect(name: "  REVERB ")
        #expect(effect.id != equipment.id)

        let environmentID = owner.addEnvironment(named: "Before")
        owner.add(effect)
        owner.renameActive(to: "Final")
        owner.migrateEffectEquipmentLinks(using: [equipment])
        await owner.awaitScheduledSavesSnapshot()

        var linkedEffect = effect
        linkedEffect.equipmentID = equipment.id
        var expected = RoutingEnvironment(id: environmentID, name: "Final", effects: [linkedEffect])
        let saved = try EnvironmentPersistenceEnvelope.read(from: directory)
        #expect(saved.environments == [expected])
        #expect(saved.activeID == environmentID)
        #expect(saved.migratedEffectEquipmentLinks == true)
        #expect(owner.environments == [expected])

        linkedEffect.equipmentID = nil
        owner.update(linkedEffect)
        await owner.awaitScheduledSavesSnapshot()

        expected.effects = [effect]
        let cleared = try EnvironmentPersistenceEnvelope.read(from: directory)
        #expect(cleared.environments == [expected])
        #expect(cleared.activeID == environmentID)
        #expect(cleared.migratedEffectEquipmentLinks == true)

        let reloadedOwner = EnvironmentStore(store: store)
        await reloadedOwner.load()
        await reloadedOwner.awaitScheduledSavesSnapshot()

        let reloaded = try EnvironmentPersistenceEnvelope.read(from: directory)
        #expect(reloaded.environments == [expected])
        #expect(reloaded.activeID == environmentID)
        #expect(reloaded.migratedEffectEquipmentLinks == true)
        #expect(reloadedOwner.environments == [expected])
        #expect(reloadedOwner.activeID == environmentID)

        reloadedOwner.migrateEffectEquipmentLinks(using: [equipment])
        await reloadedOwner.awaitScheduledSavesSnapshot()

        let remigrated = try EnvironmentPersistenceEnvelope.read(from: directory)
        #expect(remigrated.environments == [expected])
        #expect(remigrated.activeID == environmentID)
        #expect(remigrated.migratedEffectEquipmentLinks == true)
        #expect(reloadedOwner.environments == [expected])
    }
}
