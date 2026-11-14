//
//  AppModelStoreLifecycleTests.swift
//  FluxKlangTests
//
//  Sequential per-owner tail captures, not a global-at-entry snapshot, future-producer
//  barrier, concurrent bootstrap claim, or durable-save guarantee. Siri is joined only for cleanup.
//

import CoreGraphics
import Foundation
import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
@MainActor
struct AppModelStoreLifecycleTests {
    @Test func startupReturnsWithNormalizedAndLinkedDomainPayloadPersisted() async throws {
        try requireProcessIsolation()
        let fixture = try StoreLifecycleFixture()
        defer { fixture.cleanUp() }
        let startup = StoreLifecyclePayload(name: "Startup")
        try await fixture.seed(startup)
        await fixture.domain.save(StoreLifecycleSpatialEnvelope(array: startup.array), to: "spatial.json")
        let model = fixture.makeModel()
        let initialWing = model.wing

        await model.loadStores()
        // No await or throwing assertion may precede this synchronous observation.
        let disk = Result { try fixture.readDomain() }
        await model.awaitDomainScheduledSaveSnapshots()
        await model.awaitSiriEntityIndexingSnapshot()

        // Cleanup joins precede even a decoding failure, including when the lifecycle join regresses.
        verifyDomain(model, saved: try disk.get(), payload: startup, array: startup.array)
        verifyStartupOnly(model, payload: startup)
        verifyPassiveHardware(model, initialWing: initialWing, fixture: fixture)
    }

    @Test func reloadPersistsRetainedSpatialArrayWithoutReloadingStartupOnlyState() async throws {
        try requireProcessIsolation()
        let fixture = try StoreLifecycleFixture()
        defer { fixture.cleanUp() }
        let startup = StoreLifecyclePayload(name: "Before reload")
        try await fixture.seed(startup)
        await fixture.domain.save(StoreLifecycleSpatialEnvelope(array: startup.array), to: "spatial.json")
        let model = fixture.makeModel()
        let initialWing = model.wing

        await model.loadStores()
        let startupDisk = Result { try fixture.readDomain() }
        await model.awaitDomainScheduledSaveSnapshots()
        await model.awaitSiriEntityIndexingSnapshot()
        verifyDomain(model, saved: try startupDisk.get(), payload: startup, array: startup.array)
        verifyStartupOnly(model, payload: startup)

        // All startup work is joined before reseeding or removing the one owned file.
        let retainedArray = model.spatial.array
        #expect(retainedArray == startup.array)
        #expect(retainedArray != SpeakerArray.standardQuad)
        let replacement = StoreLifecyclePayload(name: "Replacement")
        try await fixture.seed(replacement)
        try await fixture.history.save(AssistantConversationRecord(
            tombstone: startup.conversation.id, deletedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let records = try await fixture.history.loadRecords()
        #expect(records.compactMap(\.conversation) == [replacement.conversation])
        #expect(await fixture.drafts.load() == replacement.draft)
        let replacementLCXL = await fixture.launch.load(
            LaunchControlXLConfiguration.self, from: "launch-control-xl.json")
        #expect(replacementLCXL == replacement.launchConfiguration)
        #expect(replacement.launchConfiguration != startup.launchConfiguration)
        try FileManager.default.removeItem(at: fixture.domainDirectory.appendingPathComponent("spatial.json"))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.domainDirectory.appendingPathComponent("spatial.json").path))

        await model.reloadStores()
        // Spatial is read FIRST: its missing-file save is the final domain producer.
        // Capture before another actor read or Siri debounce wait could mask a missing exit join.
        let reloadDisk = Result { try fixture.readDomain() }
        await model.awaitDomainScheduledSaveSnapshots()
        await model.awaitSiriEntityIndexingSnapshot()

        verifyDomain(model, saved: try reloadDisk.get(), payload: replacement, array: retainedArray)
        verifyStartupOnly(model, payload: startup)
        verifyPassiveHardware(model, initialWing: initialWing, fixture: fixture)
    }

    private func requireProcessIsolation() throws {
        let isTesting = AppPersistence.isTesting
        let deniesLiveServices = AssistantServiceIsolation.deniesLiveServices
        let modelFlagDisabled = ProcessInfo.processInfo.environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] != "1"
        let routingFlagDisabled = ProcessInfo.processInfo.environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] != "1"
        try #require(isTesting && deniesLiveServices && modelFlagDisabled && routingFlagDisabled)
    }

    private func verifyDomain(
        _ model: AppModel, saved: StoreLifecycleDisk, payload: StoreLifecyclePayload, array: SpeakerArray
    ) {
        #expect(model.faderLayout.layout.strips == [payload.strip])
        #expect(model.equipment.items == [payload.equipment] + Equipment.confirmedLiveAdditions)
        #expect(model.environments.environments == [payload.normalizedEnvironment])
        #expect(model.environments.activeID == payload.environment.id)
        #expect(model.studioConnections.connections == payload.connections)
        #expect(model.presets.presets == [payload.preset])
        #expect(model.routingSnapshots.snapshots == [payload.routing])
        #expect(model.spatial.array == array)
        #expect(saved.faders.strips == [payload.strip])
        #expect(saved.equipment == [payload.equipment] + Equipment.confirmedLiveAdditions)
        #expect(saved.environments.environments == [payload.normalizedEnvironment])
        #expect(saved.environments.activeID == payload.environment.id)
        #expect(saved.environments.migratedChain == true)
        #expect(saved.environments.migratedEffectEquipmentLinks == true)
        #expect(saved.studio.connections == payload.connections)
        #expect(saved.studio.initialized == true)
        #expect(saved.studio.confirmedOutputDefaultsVersion == payload.outputDefaultsVersion)
        #expect(saved.presets == [payload.preset])
        #expect(saved.routing == [payload.routing])
        #expect(saved.spatial.array == array)
    }

    private func verifyStartupOnly(_ model: AppModel, payload: StoreLifecyclePayload) {
        #expect(model.launchControlXL.configuration == payload.launchConfiguration)
        #expect(model.launchControlXL.status == .disabled)
        #expect(model.launchControlXL.lastAction == nil)
        #expect(model.assistant.pendingStudioDraft == payload.draft)
        #expect(model.assistantChat.conversations == [payload.conversation])
        #expect(model.assistantChat.selectedConversationID == payload.conversation.id)
        #expect(model.assistantChat.selectedConversation == payload.conversation)
        #expect(model.assistantChat.persistenceDiagnostics.isEmpty)
    }

    private func verifyPassiveHardware(
        _ model: AppModel, initialWing: WingController, fixture: StoreLifecycleFixture
    ) {
        #expect(fixture.inputsMade == 0)
        #expect(model.wing === initialWing)
        #expect(model.wing.connection == .disconnected)
        #expect(model.wing.sessionID == nil)
        #expect(model.wing.transportWriteCount == 0)
        #expect(model.wing.values.isEmpty && model.wing.confirmedValues.isEmpty)
        // Disabled LCXL never starts input/callbacks. Never-connected inert WING creates
        // no listener/keepalive/refresh tasks; disconnect would unnecessarily replace it.
        // Guarded services can legitimately record denied attempts; no zero-audit claim.
    }
}

private struct StoreLifecycleEnvironmentEnvelope: Codable, Sendable {
    var environments: [RoutingEnvironment]
    var activeID: RoutingEnvironment.ID?
    var migratedChain: Bool?
    var migratedEffectEquipmentLinks: Bool?
}

private struct StoreLifecycleSpatialEnvelope: Codable, Sendable {
    var array: SpeakerArray
}

private struct StoreLifecycleDisk {
    var spatial: StoreLifecycleSpatialEnvelope
    var environments: StoreLifecycleEnvironmentEnvelope
    var faders: FaderLayout
    var equipment: [Equipment]
    var studio: StudioConnectionsStore.Persisted
    var presets: [Preset]
    var routing: [Preset]
}

@MainActor
private final class StoreLifecycleFixture {
    let root = URL.temporaryDirectory.appendingPathComponent("app-model-lifecycle-\(UUID().uuidString)")
    let defaults: UserDefaults
    let drafts = AssistantBackendDraftStore()
    let domain: JSONFileStore
    let launch: JSONFileStore
    let history: LocalAssistantHistoryBackend
    private(set) var inputsMade = 0

    var domainDirectory: URL { root.appendingPathComponent("domain") }

    init() throws {
        defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        domain = JSONFileStore(directory: root.appendingPathComponent("domain"), cloud: nil)
        launch = JSONFileStore(directory: root.appendingPathComponent("launch-control"), cloud: nil)
        history = LocalAssistantHistoryBackend(directory: root.appendingPathComponent("history"))
    }

    func seed(_ payload: StoreLifecyclePayload) async throws {
        try #require(!payload.draft.hasErrors, "The directly built pending draft must be valid")
        await domain.save(FaderLayout(strips: [payload.strip]), to: "fader-layout.json")
        await domain.save([payload.equipment], to: "equipment.json")
        await domain.save(StoreLifecycleEnvironmentEnvelope(
            environments: [payload.environment], activeID: payload.environment.id,
            migratedChain: true, migratedEffectEquipmentLinks: false), to: "environments.json")
        await domain.save(StudioConnectionsStore.Persisted(
            connections: payload.connections, initialized: true,
            confirmedOutputDefaultsVersion: payload.outputDefaultsVersion), to: "studio-connections.json")
        await domain.save([payload.preset], to: "presets.json")
        await domain.save([payload.routing], to: "routing_snapshots.json")
        // This is deliberately separate from domainStore, including during replacement.
        await launch.save(payload.launchConfiguration, to: "launch-control-xl.json")
        await drafts.save(payload.draft)
        try await history.save(AssistantConversationRecord(conversation: payload.conversation))
    }

    func makeModel() -> AppModel {
        let hardware = HardwareServiceFactories(makeLaunchControlXLInput: { [weak self] in
            self?.inputsMade += 1
            return InertLaunchControlXLInput()
        })
        // Other factory defaults are inert. AppIcon/chat preferences retain the
        // existing process-selected isolated defaults; neither is changed here.
        return AppModel(
            assistant: AssistantCoordinator(draftStore: drafts),
            assistantProviderSettings: AssistantProviderSettings(
                defaults: defaults, credentials: MemoryAssistantCredentialStore()),
            hardware: hardware, launchControlXLStore: launch, domainStore: domain,
            assistantConversationStore: AssistantConversationStore(local: history, cloud: nil))
    }

    func readDomain() throws -> StoreLifecycleDisk {
        // Synchronous disk decoding only, with the final producer's file first.
        let spatial = try read(StoreLifecycleSpatialEnvelope.self, from: "spatial.json")
        return try StoreLifecycleDisk(
            spatial: spatial,
            environments: read(StoreLifecycleEnvironmentEnvelope.self, from: "environments.json"),
            faders: read(FaderLayout.self, from: "fader-layout.json"),
            equipment: read([Equipment].self, from: "equipment.json"),
            studio: read(StudioConnectionsStore.Persisted.self, from: "studio-connections.json"),
            presets: read([Preset].self, from: "presets.json"),
            routing: read([Preset].self, from: "routing_snapshots.json"))
    }

    private func read<Value: Decodable>(_ type: Value.Type, from name: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: domainDirectory.appendingPathComponent(name)))
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: root.lastPathComponent)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private struct StoreLifecyclePayload {
    let strip: FaderStrip
    let equipment: Equipment
    let environment: RoutingEnvironment
    let normalizedEnvironment: RoutingEnvironment
    let connections: GlobalStudioConnections
    let preset: Preset
    let routing: Preset
    let array: SpeakerArray
    let launchConfiguration: LaunchControlXLConfiguration
    let conversation: AssistantConversation
    let draft: StudioPatchDraft
    let outputDefaultsVersion = StudioOutputDefaults.bundled()?.version ?? 0

    init(name: String) {
        let equipment = Equipment(name: "\(name) fixture device", inputs: ["In"], outputs: ["Mono"])
        self.equipment = equipment
        strip = FaderStrip(id: UUID(), node: .channel(19), customLabel: "\(name) fader")
        preset = Preset(id: UUID(), name: "\(name) preset",
                        settings: [WingSetting(address: WingAddress.fader(.channel, 19), value: .float(0.37))],
                        wingScene: 12)
        routing = Preset(id: UUID(), name: "\(name) routing",
                         settings: [WingSetting(address: WingAddress.channelSourceIndex(19), value: .int(24))],
                         wingScene: 13)
        array = SpeakerArray(speakers: [
            Speaker(id: UUID(), name: "\(name) speaker", node: .bus(7), position: CGPoint(x: 0.2, y: 0.8))
        ], pairs: [])
        connections = GlobalStudioConnections(home: StudioHomeConnections(inputs: [
            StudioInputConnection(id: UUID(), connector: 24, equipmentID: equipment.id, outputPort: 0,
                                  labelOverride: "\(name) Home input")
        ]))
        let connector = WingOutputConnector(index: 3)
        let canonical = StudioEndpoint(name: "\(name) desk", destination: .custom, outputConnectors: [connector])
        let duplicate = StudioEndpoint(name: "\(name) duplicate", destination: .custom, outputConnectors: [connector])
        let unused = StudioEndpoint(name: "\(name) unused", destination: .custom, outputConnectors: [.init(index: 4)])
        let canonicalNode = StudioNode(kind: .endpoint(canonical.id), title: canonical.name,
                                       position: CGPoint(x: 10, y: 20))
        let duplicateNode = StudioNode(kind: .endpoint(duplicate.id), title: duplicate.name,
                                       position: CGPoint(x: 100, y: 20))
        let effect = Effect(name: "  \(equipment.name.uppercased()) ", isStereo: false,
                            sendOutputs: [3], returnInputs: [24])
        let environment = RoutingEnvironment(
            name: "\(name) environment", effects: [effect],
            studioGraph: StudioGraph(nodes: [canonicalNode, duplicateNode]),
            studioEndpoints: [canonical, duplicate, unused])
        self.environment = environment
        var normalized = environment
        normalized.studioGraph = StudioGraph(nodes: [canonicalNode])
        normalized.studioEndpoints = [canonical]
        normalized.effects[0].equipmentID = equipment.id
        normalizedEnvironment = normalized
        launchConfiguration = LaunchControlXLConfiguration(
            version: 1, mode: .disabled,
            mapping: LaunchControlXLMapping(
                sourceNameContains: ["\(name) LCXL \(UUID().uuidString)"], channel: 16,
                faderCCs: Array(5...12), panOrBalanceCCs: Array(13...20),
                selectCCs: Array(37...44), muteCCs: Array(45...52),
                bankPreviousCC: 103, bankNextCC: 102))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        conversation = AssistantConversation(
            id: UUID(), title: "\(name) history", createdAt: timestamp, modifiedAt: timestamp,
            summary: "\(name) owned history",
            messages: [AssistantMessage(role: .user, text: "\(name) restored message", createdAt: timestamp)])
        // Pure draft construction, not assistant execution or a response-generation path.
        draft = StudioWiringAdvisor.build(
            request: StudioWiringRequest(sourceInstrumentIDs: [equipment.id], destination: .finalMix),
            equipment: [equipment], effects: [], connections: connections,
            currentGraph: StudioGraph(), environmentID: environment.id)
    }
}
