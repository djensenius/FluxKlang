//
//  AppModelPersistenceOwnershipTests.swift
//  FluxKlangTests
//
//  Domain-store forwarding only: no AppModel lifecycle or hardware operations.
//  AppIcon and chat process preferences remain the existing process-selected ones.
//

import CoreGraphics
import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct AppModelPersistenceOwnershipTests {
    @Test func injectedDomainStoreReachesAllSevenOwners() async throws {
        try requireProcessIsolation()
        let fixture = AppModelDomainFixture()
        defer { fixture.cleanUp() }
        let defaults = try #require(UserDefaults(suiteName: fixture.suite))
        defer { defaults.removePersistentDomain(forName: fixture.suite) }
        try FileManager.default.createDirectory(at: fixture.launchDirectory, withIntermediateDirectories: true)
        let domain = JSONFileStore(directory: fixture.domainDirectory, cloud: nil)
        await fixture.seed(domain)
        let model = fixture.makeModel(domain: domain, defaults: defaults)

        await loadDomainOwners(model)
        await drainDomainSaves(model)

        // Each identity and payload is fixture-owned, not a seeded application default.
        #expect(model.faderLayout.layout.strips == [fixture.strip])
        #expect(model.equipment.items == [fixture.equipment] + Equipment.confirmedLiveAdditions)
        #expect(model.environments.environments == [fixture.environment])
        #expect(model.environments.activeID == fixture.environment.id)
        #expect(model.studioConnections.connections == fixture.connections)
        #expect(model.presets.presets == [fixture.preset])
        #expect(model.routingSnapshots.snapshots == [fixture.routing])
        #expect(model.spatial.array == fixture.array)
    }

    @Test func modelOwnedMutationsWriteDomainFilesNotLaunchControlFiles() async throws {
        try requireProcessIsolation()
        let fixture = AppModelDomainFixture()
        defer { fixture.cleanUp() }
        let defaults = try #require(UserDefaults(suiteName: fixture.suite))
        defer { defaults.removePersistentDomain(forName: fixture.suite) }
        try FileManager.default.createDirectory(at: fixture.launchDirectory, withIntermediateDirectories: true)
        let domain = JSONFileStore(directory: fixture.domainDirectory, cloud: nil)
        await fixture.seed(domain)
        let model = fixture.makeModel(domain: domain, defaults: defaults)
        await loadDomainOwners(model)
        await drainDomainSaves(model)

        var strip = fixture.strip
        strip.customLabel = "Written fader"
        var equipment = fixture.equipment
        equipment.name = "Written equipment"
        var environment = fixture.environment
        environment.name = "Written environment"
        var preset = fixture.preset
        preset.name = "Written preset"
        var routing = fixture.routing
        routing.name = "Written routing"
        var array = fixture.array
        array.speakers[0].name = "Written speaker"
        var connections = fixture.connections
        connections.home.inputs[0].labelOverride = "Written Home input"

        model.faderLayout.setLabel(strip.customLabel, for: strip.id)
        model.equipment.update(equipment)
        model.environments.renameActive(to: environment.name)
        model.presets.update(preset)
        model.routingSnapshots.update(routing)
        model.spatial.setSpeakerName(fixture.speaker.id, to: array.speakers[0].name)
        // Drain every enqueued producer before the throwing Studio operation or any read.
        await drainDomainSaves(model)
        try await model.studioConnections.replaceHome(connections.home, equipment: model.equipment.items)
        // Studio's awaited public method owns its persistence; it has no scheduled-save tail.

        let savedFaders = try fixture.read(FaderLayout.self, from: "fader-layout.json")
        let savedEquipment = try fixture.read([Equipment].self, from: "equipment.json")
        let savedEnvironments = try fixture.read(AppModelEnvironmentEnvelope.self, from: "environments.json")
        let savedStudio = try fixture.read(StudioConnectionsStore.Persisted.self, from: "studio-connections.json")
        let savedPresets = try fixture.read([Preset].self, from: "presets.json")
        let savedRouting = try fixture.read([Preset].self, from: "routing_snapshots.json")
        let savedSpatial = try fixture.read(AppModelSpatialEnvelope.self, from: "spatial.json")
        #expect(savedFaders.strips == [strip])
        #expect(savedEquipment == [equipment] + Equipment.confirmedLiveAdditions)
        #expect(savedEnvironments.environments == [environment])
        #expect(savedEnvironments.activeID == environment.id)
        #expect(savedEnvironments.migratedChain == true)
        #expect(savedEnvironments.migratedEffectEquipmentLinks == true)
        #expect(savedStudio.connections == connections)
        #expect(savedStudio.initialized == true)
        #expect(savedStudio.confirmedOutputDefaultsVersion == fixture.outputDefaultsVersion)
        #expect(savedPresets == [preset])
        #expect(savedRouting == [routing])
        #expect(savedSpatial.array == array)
        let launchFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.launchDirectory.path)
        #expect(launchFiles.isEmpty, "Domain writes must not use the separately injected LCXL directory")
    }

    private func requireProcessIsolation() throws {
        let isTesting = AppPersistence.isTesting
        let deniesLiveServices = AssistantServiceIsolation.deniesLiveServices
        let modelFlagDisabled = ProcessInfo.processInfo.environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] != "1"
        let routingFlagDisabled = ProcessInfo.processInfo.environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] != "1"
        try #require(isTesting && deniesLiveServices && modelFlagDisabled && routingFlagDisabled)
    }

    private func loadDomainOwners(_ model: AppModel) async {
        // Deliberately do not use loadStores/reloadStores: those also start unrelated services.
        await model.faderLayout.load()
        await model.equipment.load()
        await model.environments.load()
        await model.studioConnections.load(
            equipment: model.equipment.items,
            environments: model.environments.environments,
            activeID: model.environments.activeID)
        await model.presets.load()
        await model.routingSnapshots.load()
        await model.spatial.load()
    }

    private func drainDomainSaves(_ model: AppModel) async {
        // No concurrent producers are started here; these are captured-tail waits, not global quiescence.
        await model.faderLayout.awaitScheduledSavesSnapshot()
        await model.equipment.awaitScheduledSavesSnapshot()
        await model.environments.awaitScheduledSavesSnapshot()
        await model.presets.awaitScheduledSavesSnapshot()
        await model.routingSnapshots.awaitScheduledSavesSnapshot()
        await model.spatial.awaitScheduledSavesSnapshot()
    }
}

private struct AppModelEnvironmentEnvelope: Codable, Sendable {
    var environments: [RoutingEnvironment]
    var activeID: RoutingEnvironment.ID?
    var migratedChain: Bool?
    var migratedEffectEquipmentLinks: Bool?
}

private struct AppModelSpatialEnvelope: Codable, Sendable {
    var array: SpeakerArray
}

@MainActor
private struct AppModelDomainFixture {
    let root = URL.temporaryDirectory.appendingPathComponent("app-model-domain-\(UUID().uuidString)")
    let strip = FaderStrip(id: UUID(), node: .channel(19), customLabel: "Domain fader")
    let equipment = Equipment(id: UUID(), name: "Domain fixture synth", outputs: ["Mono"])
    let environmentID = UUID()
    let inputID = UUID()
    let preset = Preset(id: UUID(), name: "Domain preset",
                        settings: [WingSetting(address: WingAddress.fader(.channel, 19), value: .float(0.37))],
                        wingScene: 12)
    let routing = Preset(id: UUID(), name: "Domain routing",
                         settings: [WingSetting(address: WingAddress.channelSourceIndex(19), value: .int(24))],
                         wingScene: 13)
    let speaker = Speaker(id: UUID(), name: "Domain speaker", node: .bus(7), position: CGPoint(x: 0.2, y: 0.8))
    // AppModel retains bundled Studio defaults. Mark this seed at the actual bundled
    // version so the test measures forwarding, not a defaults migration or resource absence.
    let outputDefaultsVersion = StudioOutputDefaults.bundled()?.version ?? 0

    var domainDirectory: URL { root.appendingPathComponent("domain") }
    var launchDirectory: URL { root.appendingPathComponent("launch-control") }
    var suite: String { root.lastPathComponent }
    var array: SpeakerArray { SpeakerArray(speakers: [speaker], pairs: []) }
    var environment: RoutingEnvironment {
        RoutingEnvironment(
            id: environmentID, name: "Domain environment",
            placements: ["source:\(equipment.id.uuidString)": VoicePlacement(
                position: CGPoint(x: 0.3, y: 0.6), width: 0.2)])
    }
    var connections: GlobalStudioConnections {
        GlobalStudioConnections(home: StudioHomeConnections(inputs: [
            StudioInputConnection(id: inputID, connector: 24, equipmentID: equipment.id, outputPort: 0,
                                  labelOverride: "Domain Home input")
        ]))
    }

    func seed(_ store: JSONFileStore) async {
        await store.save(FaderLayout(strips: [strip]), to: "fader-layout.json")
        // Equipment legitimately merges confirmed additions on load.
        await store.save([equipment], to: "equipment.json")
        // Valid active identity, empty endpoint graph, and completed migration flags
        // avoid testing unrelated Environment normalization/migration behavior.
        await store.save(AppModelEnvironmentEnvelope(
            environments: [environment], activeID: environment.id,
            migratedChain: true, migratedEffectEquipmentLinks: true), to: "environments.json")
        await store.save(StudioConnectionsStore.Persisted(
            connections: connections, initialized: true,
            confirmedOutputDefaultsVersion: outputDefaultsVersion), to: "studio-connections.json")
        await store.save([preset], to: "presets.json")
        await store.save([routing], to: "routing_snapshots.json")
        await store.save(AppModelSpatialEnvelope(array: array), to: "spatial.json")
    }

    func makeModel(domain: JSONFileStore, defaults: UserDefaults) -> AppModel {
        // Callers qualify actual process selection before constructing this fixture or factories.
        AppModel(
            assistant: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
            assistantProviderSettings: AssistantProviderSettings(
                defaults: defaults, credentials: MemoryAssistantCredentialStore()),
            hardware: HardwareServiceFactories(makeLaunchControlXLInput: { InertLaunchControlXLInput() }),
            launchControlXLStore: JSONFileStore(directory: launchDirectory, cloud: nil),
            domainStore: domain,
            assistantConversationStore: AssistantConversationStore(local: AssistantBackendHistoryStore(), cloud: nil))
    }

    func read<Value: Decodable>(_ type: Value.Type, from name: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: domainDirectory.appendingPathComponent(name)))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
