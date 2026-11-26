import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// Exercise the legacy injection contract without fabricating file outcomes.
private struct LegacyPendingDraftStore: PendingStudioPatchPersisting {
    let forwarding: PendingPersistenceForwarder

    func load() async -> PendingStudioPatchLoadOutcome { await forwarding.load() }
    func save(_ draft: StudioPatchDraft?) async -> PendingStudioPatchMutationOutcome {
        await forwarding.save(draft)
    }
}

@MainActor
final class AppModelPendingDraftAcceptanceFixture {
    let file: URL
    let environmentFile: URL
    let receiptGate = PendingPersistenceGate()
    let forwarding: PendingPersistenceForwarder
    let coordinator: AssistantCoordinator
    let wing = WingController(transport: InertWingTransport())
    let presentation = StudioDraftDiscardPresentation()
    private let resources: AssistantFixtureResources
    private let instrument = Equipment(name: "Acceptance fixture source", outputs: ["Out"])
    private var model: AppModel?
    private var acceptance: Task<StudioPatchMergeResult?, Never>?
    private var cancellations: [@MainActor () -> Void] = []
    private var joins: [@MainActor () async -> Void] = []
    private var closed = false
    private(set) var setupSavesJoined = false

    private init(resources: AssistantFixtureResources, legacyStore: Bool) {
        self.resources = resources
        file = resources.root.appendingPathComponent("pending/draft.json")
        environmentFile = resources.root.appendingPathComponent("domain/environments.json")
        let store = PendingStudioPatchStore(fileURL: file, directory: resources.root)
        forwarding = PendingPersistenceForwarder(store: store)
        if legacyStore {
            coordinator = AssistantCoordinator(draftStore: LegacyPendingDraftStore(forwarding: forwarding))
        } else {
            coordinator = AssistantCoordinator(draftStore: forwarding)
        }
    }

    static func run(
        legacyStore: Bool = false,
        _ body: @MainActor (AppModelPendingDraftAcceptanceFixture) async throws -> Void
    ) async throws {
        // Admission precedes even fixture/dependency construction; host startup needs launch flags too.
        try await withAssistantFixtureResources { resources in
            try requireNoProductionEntries()
            let fixture = AppModelPendingDraftAcceptanceFixture(resources: resources, legacyStore: legacyStore)
            resources.onFinish { await fixture.finish() }
            try await body(fixture)
        }
    }

    func prepare(
        mode: StudioDraftApplicationMode = .append, seedGraph: Bool = false, recoverSavedDraft: Bool = false
    ) async throws -> (AppModel, StudioPatchDraft) {
        try #require(model == nil && !closed)
        let settings = AssistantProviderSettings(
            defaults: try resources.defaults("provider"), credentials: MemoryAssistantCredentialStore())
        settings.provider = .deterministic
        var hardware = HardwareServiceFactories.inert
        hardware.localNetworkEvidence = LocalNetworkGrantEvidence(
            directory: resources.root.appendingPathComponent("network-evidence"), bundleID: "p14b14-fixture")
        let model = AppModel(
            assistant: coordinator, assistantProviderSettings: settings,
            wing: wing, wingLifecycle: HostWingLifecycle(owner: nil), hardware: hardware,
            launchControlXLStore: JSONFileStore(
                directory: resources.root.appendingPathComponent("lcxl"), cloud: nil),
            domainStore: JSONFileStore(directory: environmentFile.deletingLastPathComponent(), cloud: nil),
            assistantConversationStore: AssistantConversationStore(
                local: LocalAssistantHistoryBackend(
                    directory: resources.root.appendingPathComponent("history"), legacyFileURL: nil), cloud: nil),
            assistantSpokenRepliesDefaults: try resources.defaults("spoken-replies"))
        // Retain before any throwing assertion or mutation can leave scheduled work behind.
        self.model = model
        try Self.requireNoProductionEntries()
        // AppIcon's existing macOS Dock mutation is permitted, outside the 14-operation audit.
        // No loadStores, preview, availability, chat load, discovery, connection or LCXL load.
        // Environments load first: an unloaded environment store refuses saves (#943).
        await model.environments.load()
        model.equipment.add(instrument)
        let environmentID = model.environments.addEnvironment(named: "Acceptance fixture environment")
        if seedGraph {
            let endpoint = StudioEndpoint(name: "Existing space", destination: .space)
            model.environments.addStudioEndpointNode(endpoint, position: .zero)
        }
        let home = StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: instrument.id, outputPort: 0)
        ])
        try await model.studioConnections.replaceHome(home, equipment: model.equipment.items)
        await model.awaitDomainScheduledSaveSnapshots()
        setupSavesJoined = true // Joined snapshots, not a durable environment-save acknowledgement.
        try #require(model.environments.activeID == environmentID)
        try #require(model.environments.active?.id == environmentID)
        try #require(model.studioConnections.connections.home == home)
        try #require(model.studioConnections.connections.temporaryMoves.isEmpty)
        // A separate store/coordinator writes the recovery fixture; the receiver has no token history.
        let writer = recoverSavedDraft
            ? AssistantCoordinator(draftStore: PendingStudioPatchStore(fileURL: file, directory: resources.root))
            : coordinator
        _ = await writer.perform(
            .buildStudioDraft(.init(sourceInstrumentIDs: [instrument.id], applicationMode: mode)),
            context: model.assistantToolContext())
        if recoverSavedDraft { await coordinator.load() }
        let built = try #require(coordinator.pendingStudioDraft)
        try requireReady(model, built)
        return (model, built)
    }

    func requireReady(_ model: AppModel, _ draft: StudioPatchDraft) throws {
        try #require(model.environments.active != nil && model.environments.activeID == draft.request.environmentID)
        try #require(setupSavesJoined && !draft.hasErrors && draft.liveReferences == [])
        try #require(model.wing === wing && wing.connection == .disconnected && wing.sessionID == nil)
        try #require(!model.isDemo && wing.transportWriteCount == 0)
        try Self.requireNoProductionEntries()
    }

    func start<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> Value
    ) throws -> Task<Value, Never> {
        try #require(!closed)
        let task = Task { await operation() }
        cancellations.append { task.cancel() }
        joins.append { _ = await task.value }
        return task
    }

    func buildAgain(
        _ model: AppModel, mode: StudioDraftApplicationMode = .append,
        destination: StudioEndpointDestination = .finalMix
    ) async throws -> StudioPatchDraft {
        // The seeded library's first device is not the fixture source wired into Home.
        try #require(model.equipment.item(instrument.id) == instrument)
        _ = await coordinator.perform(
            .buildStudioDraft(.init(
                sourceInstrumentIDs: [instrument.id], destination: destination, applicationMode: mode)),
            context: model.assistantToolContext())
        let draft = try #require(coordinator.pendingStudioDraft)
        try #require(!draft.hasErrors && draft.liveReferences == [],
                     "Validation: \(draft.validation); live references: \(String(describing: draft.liveReferences))")
        return draft
    }

    func blockPendingParent() throws {
        let parent = file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: parent)
        try Data("owned acceptance blocker".utf8).write(to: parent)
    }

    func unblockPendingParent() throws {
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @discardableResult
    func blockEnvironmentFile() throws -> URL {
        try FileManager.default.removeItem(at: environmentFile)
        try FileManager.default.createDirectory(at: environmentFile, withIntermediateDirectories: false)
        let blocker = environmentFile.appendingPathComponent("blocker")
        try Data("owned environment blocker".utf8).write(to: blocker)
        return blocker
    }

    func readPendingDraft() throws -> StudioPatchDraft {
        try JSONDecoder().decode(StudioPatchDraft.self, from: Data(contentsOf: file))
    }

    func readSavedEnvironment() throws -> RoutingEnvironment {
        struct Envelope: Decodable {
            let environments: [RoutingEnvironment]
            let activeID: RoutingEnvironment.ID?
        }
        let saved = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: environmentFile))
        return try #require(saved.environments.first { $0.id == saved.activeID })
    }

    func startAcceptance() throws -> Task<StudioPatchMergeResult?, Never> {
        let model = try #require(model)
        try #require(!closed && acceptance == nil)
        // MainActor creation and retention do not suspend. No substitute acceptance implementation.
        let task = Task { await model.acceptPendingAssistantDraft() }
        acceptance = task
        return task
    }

    static func requireNoProductionEntries() throws {
        let snapshot = ProductionAccessAudit.shared.snapshot()
        for operation in ProductionAccessAudit.Operation.allCases {
            try #require(snapshot.count(.factoryEvaluated, for: operation) == 0)
            try #require(snapshot.count(.apiEntered, for: operation) == 0)
        }
    }

    private func finish() async {
        closed = true
        acceptance?.cancel()
        for cancel in cancellations { cancel() }
        presentation.disappear()
        model?.assistantChat.cancel()
        await receiptGate.release()
        await forwarding.finish() // Release/disarm every gate, including failures before entry.
        _ = await acceptance?.value
        for join in joins { await join() }
        // All actual presentation tasks are retained by this owner, including throwing paths.
        await presentation.awaitOwnedWorkSnapshot()
        await model?.assistantChat.awaitOwnedWorkSnapshot()
        await model?.awaitDomainScheduledSaveSnapshots()
        await model?.awaitSiriEntityIndexingSnapshot()
        acceptance = nil
        cancellations.removeAll()
        joins.removeAll()
        model = nil
        // Only now may AssistantFixtureResources delete defaults and owned filesystem resources.
    }
}
