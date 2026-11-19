import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@MainActor
final class AppModelPendingDraftAcceptanceFixture {
    let file: URL
    let forwarding: PendingPersistenceForwarder
    let coordinator: AssistantCoordinator
    let wing = WingController(transport: InertWingTransport())
    private let resources: AssistantFixtureResources
    private var model: AppModel?
    private var acceptance: Task<StudioPatchMergeResult?, Never>?
    private var closed = false
    private(set) var setupSavesJoined = false

    private init(resources: AssistantFixtureResources) {
        self.resources = resources
        file = resources.root.appendingPathComponent("pending/draft.json")
        let store = PendingStudioPatchStore(fileURL: file, directory: resources.root)
        forwarding = PendingPersistenceForwarder(store: store)
        coordinator = AssistantCoordinator(draftStore: forwarding)
    }

    static func run(
        _ body: @MainActor (AppModelPendingDraftAcceptanceFixture) async throws -> Void
    ) async throws {
        // Admission precedes even fixture/dependency construction; host startup needs launch flags too.
        try await withAssistantFixtureResources { resources in
            try requireNoProductionEntries()
            let fixture = AppModelPendingDraftAcceptanceFixture(resources: resources)
            resources.onFinish { await fixture.finish() }
            try await body(fixture)
        }
    }

    func prepare() async throws -> (AppModel, StudioPatchDraft) {
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
            domainStore: JSONFileStore(directory: resources.root.appendingPathComponent("domain"), cloud: nil),
            assistantConversationStore: AssistantConversationStore(
                local: LocalAssistantHistoryBackend(
                    directory: resources.root.appendingPathComponent("history"), legacyFileURL: nil), cloud: nil),
            assistantSpokenRepliesDefaults: try resources.defaults("spoken-replies"))
        // Retain before any throwing assertion or mutation can leave scheduled work behind.
        self.model = model
        try Self.requireNoProductionEntries()
        // AppIcon's existing macOS Dock mutation is permitted, outside the 14-operation audit.
        // No loadStores, preview, availability, chat load, discovery, connection or LCXL load.
        let instrument = Equipment(name: "Acceptance fixture source", outputs: ["Out"])
        model.equipment.add(instrument)
        let environmentID = model.environments.addEnvironment(named: "Acceptance fixture environment")
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
        _ = await coordinator.perform(
            .buildStudioDraft(.init(sourceInstrumentIDs: [instrument.id])), context: model.assistantToolContext())
        return (model, try #require(coordinator.pendingStudioDraft))
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
        model?.assistantChat.cancel()
        await forwarding.finish() // Release/disarm every gate, including failures before entry.
        _ = await acceptance?.value
        // No view/presentation or generator stream is started by this API-only baseline.
        await model?.assistantChat.awaitOwnedWorkSnapshot()
        await model?.awaitDomainScheduledSaveSnapshots()
        await model?.awaitSiriEntityIndexingSnapshot()
        acceptance = nil
        model = nil
        // Only now may AssistantFixtureResources delete defaults and owned filesystem resources.
    }
}
