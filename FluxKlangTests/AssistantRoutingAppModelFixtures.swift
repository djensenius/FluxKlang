import Foundation
import Testing
@testable import FluxKlang

@MainActor
func withRoutingAppModelFixture(
    assignsBeforePause: Bool = false,
    _ body: @MainActor (RoutingAppModelFixture) async throws -> Void
) async throws {
    try await withAssistantFixtureResources { resources in
        let owner = RoutingAppModelFixture(resources: resources, assignsBeforePause: assignsBeforePause)
        resources.onFinish { await owner.finish() }
        try await body(owner)
    }
}

@MainActor
func withRoutingAppModel(
    fixture: AssistantRoutingFixture,
    assignsBeforePause: Bool = false,
    _ body: @MainActor (AppModel, RoutingAppModelFixture) async throws -> Void
) async throws {
    try await withRoutingAppModelFixture(assignsBeforePause: assignsBeforePause) { owner in
        try await owner.withModel(fixture: fixture) { model in
            try await body(model, owner)
        }
    }
}

// Family-only ownership: complete teardown is registered before any throwing/async setup.
@MainActor
final class RoutingAppModelFixture {
    let store: RoutingAppModelDraftStore
    let coordinator: AssistantCoordinator
    private let resources: AssistantFixtureResources
    private let generator = AssistantFixtureReplyGenerator(reply: "read-only reply")
    private var model: AppModel?
    private var chat: AssistantChatController?
    private var closed = false
    private var cancellations: [@MainActor () -> Void] = []
    private var joins: [@MainActor () async -> Void] = []

    init(resources: AssistantFixtureResources, assignsBeforePause: Bool) {
        self.resources = resources
        store = RoutingAppModelDraftStore(assignsBeforePause: assignsBeforePause)
        coordinator = AssistantCoordinator(draftStore: store)
    }

    func withModel(
        fixture: AssistantRoutingFixture,
        _ body: @MainActor (AppModel) async throws -> Void
    ) async throws {
        let settings = AssistantProviderSettings(
            defaults: try resources.defaults("provider"), credentials: MemoryAssistantCredentialStore())
        settings.provider = .deterministic
        let model = AppModel(
            assistant: coordinator, assistantProviderSettings: settings, wing: .preview(), hardware: .inert,
            launchControlXLStore: JSONFileStore(
                directory: resources.root.appendingPathComponent("launch-control-xl"), cloud: nil),
            domainStore: JSONFileStore(directory: resources.root.appendingPathComponent("domain"), cloud: nil),
            assistantConversationStore: history("model"),
            assistantSpokenRepliesDefaults: try resources.defaults("model-spoken-replies"))
        // Retain before loads/mutations schedule saves, including a throwing replaceHome.
        self.model = model
        await model.equipment.load()
        for gear in fixture.equipment {
            if model.equipment.items.contains(where: { $0.id == gear.id }) {
                model.equipment.update(gear)
            } else {
                model.equipment.add(gear)
            }
        }
        await model.environments.load()
        _ = model.environments.addEnvironment(named: "Apple routing fixture \(UUID())")
        model.environments.add(fixture.effect)
        await model.studioConnections.load(equipment: model.equipment.items,
            environments: model.environments.environments, activeID: model.environments.activeID)
        try await model.studioConnections.replaceHome(fixture.connections.home, equipment: model.equipment.items)
        try await body(model)
    }

    func makeChat() throws -> AssistantChatController {
        let chat = AssistantChatController(
            coordinator: coordinator, store: history("chat"), generator: generator,
            actionInterpreter: RoutingTestInterpreter(),
            spokenRepliesDefaults: try resources.defaults("chat-spoken-replies"))
        self.chat = chat
        return chat
    }

    private func history(_ label: String) -> AssistantConversationStore {
        AssistantConversationStore(local: LocalAssistantHistoryBackend(
            directory: resources.root.appendingPathComponent("\(label)-history", isDirectory: true),
            legacyFileURL: resources.root.appendingPathComponent("\(label)-absent-legacy-history.json")),
            cloud: nil)
    }

    func start<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> Value
    ) throws -> Task<Value, Never> {
        try #require(!closed)
        // MainActor admission/create/retention has no suspension or later throwing assertion.
        let task = Task { await operation() }
        cancellations.append { task.cancel() }
        joins.append { _ = await task.value }
        return task
    }

    func finish() async {
        closed = true
        generator.close()
        for cancel in cancellations { cancel() }
        chat?.cancel()
        model?.assistantChat.cancel()
        await store.finish()
        await generator.join()
        for join in joins { await join() }
        // These are finite owner snapshots after producers are sealed, not global/durable barriers.
        await chat?.awaitOwnedWorkSnapshot()
        await model?.assistantChat.awaitOwnedWorkSnapshot()
        await model?.awaitDomainScheduledSaveSnapshots()
        await model?.awaitSiriEntityIndexingSnapshot()
        joins.removeAll()
        cancellations.removeAll()
        chat = nil
        model = nil
        // No timeout can return early and authorize resource deletion without completed joins.
    }
}

// RoutingTestDraftStore assigns AFTER suspension; the validation store assigns BEFORE.
// Normal resume releases only the oldest waiter and preserves future pause behavior.
actor RoutingAppModelDraftStore: PendingStudioPatchPersisting {
    private(set) var draft: StudioPatchDraft?
    private let assignsBeforePause: Bool
    private var pauseNext = false
    private var closed = false
    private var gates: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { !gates.isEmpty }
    var waitingSaves: Int { gates.count }

    init(assignsBeforePause: Bool) {
        self.assignsBeforePause = assignsBeforePause
    }

    func load() -> StudioPatchDraft? { draft }
    func pauseNextSave() {
        guard !closed else { return }
        pauseNext = true
    }

    func resume() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }

    func save(_ draft: StudioPatchDraft?) async {
        if assignsBeforePause { self.draft = draft }
        if pauseNext && !closed {
            pauseNext = false
            await withCheckedContinuation { gates.append($0) }
        }
        if !assignsBeforePause { self.draft = draft }
    }

    func finish() {
        // Disarm even when teardown precedes gate entry; cancellation alone cannot resume a continuation.
        closed = true
        pauseNext = false
        let pending = gates
        gates.removeAll()
        for gate in pending { gate.resume() }
    }
}
