import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct InAppAssistantTests {
    @Test func unavailableModelUsesDeterministicFallback() async throws {
        let router = AssistantGeneratorRouter(
            model: StubGenerator(availability: .deviceNotEligible, text: "model"),
            fallback: StubGenerator(availability: .unsupportedOS, text: "fallback")
        )
        let request = AssistantGenerationRequest(
            question: "Help",
            recentMessages: [],
            summary: "",
            context: emptyContext()
        )

        var text = ""
        for try await event in router.stream(request) {
            if case .text(let value) = event {
                text = value
            }
        }

        #expect(text == "fallback")
    }

    @Test func modelToolAuthorizationNeverPermitsWingWrites() throws {
        let authorizer = AssistantToolAuthorizer.model

        #expect(throws: Never.self) {
            try authorizer.authorize(.help)
            try authorizer.authorize(.inspect)
            try authorizer.authorize(.buildPendingDraft)
        }
        #expect(throws: AssistantToolAuthorizationError.denied(.writeWing)) {
            try authorizer.authorize(.writeWing)
        }
    }

    @Test func cancellingStreamingResponseMarksVisibleMessageCancelled() async throws {
        let coordinator = AssistantCoordinator(draftStore: MemoryDraftStore())
        let store = AssistantConversationStore(
            local: MemoryHistoryBackend(),
            cloud: nil
        )
        let chat = AssistantChatController(
            coordinator: coordinator,
            store: store,
            generator: CancellableGenerator()
        )
        chat.newConversation()
        chat.composer = "Stream"
        chat.send(context: emptyContext())
        try await waitUntil {
            chat.selectedConversation?.messages.last?.text == "partial"
        }

        chat.cancel()
        try await waitUntil {
            chat.selectedConversation?.messages.last?.state == .cancelled
        }

        #expect(chat.isStreaming == false)
    }

    @Test func historyMigratesSyncsAndPropagatesDeletionTombstones() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-history-\(UUID().uuidString)", isDirectory: true)
        let legacyURL = root.appendingPathComponent("legacy.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = AssistantConversation(title: "Legacy")
        try JSONEncoder().encode([legacy]).write(to: legacyURL)

        let local = LocalAssistantHistoryBackend(
            directory: root.appendingPathComponent("records", isDirectory: true),
            legacyFileURL: legacyURL
        )
        let cloud = MemoryHistoryBackend()
        let store = AssistantConversationStore(local: local, cloud: cloud)

        let loaded = await store.load()
        #expect(loaded.map(\.id) == [legacy.id])
        #expect(await cloud.record(id: legacy.id)?.conversation?.title == "Legacy")

        await store.delete(id: legacy.id, at: Date(timeIntervalSince1970: 500))
        let afterDelete = await store.load()
        #expect(afterDelete.isEmpty)
        #expect(await cloud.record(id: legacy.id)?.deletedAt != nil)
    }

    @Test func voiceControllerSurfacesDeniedAndGrantedPermissionStates() async throws {
        let denied = AssistantVoiceController(
            transcriber: StubSpeechTranscriber(permission: .denied)
        )
        denied.start()
        try await waitUntil {
            if case .failed = denied.state { return true }
            return false
        }
        #expect(denied.permission == .denied)

        let granted = AssistantVoiceController(
            transcriber: StubSpeechTranscriber(permission: .granted)
        )
        granted.start()
        try await waitUntil {
            granted.transcript == "Studio patch"
        }
        #expect(granted.permission == .granted)
        #expect(granted.isFinal)
    }

    @Test func assistantDraftPathCannotChangeWingValues() async throws {
        let coordinator = AssistantCoordinator(draftStore: MemoryDraftStore())
        let model = AppModel(assistant: coordinator, wing: .preview())
        let synth = model.equipment.items[0]
        _ = model.environments.addEnvironment(named: "Assistant Safety")
        try await model.studioConnections.replaceHome(
            StudioHomeConnections(inputs: [
                StudioInputConnection(connector: 1, equipmentID: synth.id, outputPort: 0)
            ]),
            equipment: model.equipment.items
        )
        let before = model.wing.values

        model.assistantChat.createWiringDraft(
            sourceIDs: [synth.id],
            effectIDs: [],
            destination: .finalMix,
            context: model.assistantToolContext()
        )
        try await waitUntil { coordinator.pendingStudioDraft != nil }

        #expect(model.wing.values == before)
    }

    private func emptyContext() -> AssistantToolContext {
        AssistantToolContext(
            currentScreen: .assistant,
            connection: AssistantConnectionState(status: .disconnected, detail: nil, isDemo: false),
            equipment: [],
            homeConnections: StudioHomeConnections(),
            effectiveConnections: StudioHomeConnections(),
            activeMoves: [],
            environments: [],
            activeEnvironmentID: nil,
            presets: [],
            resources: [],
            validationIssues: [],
            graph: StudioGraph(),
            endpoints: [],
            effects: [],
            globalConnections: GlobalStudioConnections()
        )
    }
}

private struct StubGenerator: AssistantGenerating {
    let availabilityValue: AssistantModelAvailability
    let text: String

    init(availability: AssistantModelAvailability, text: String) {
        availabilityValue = availability
        self.text = text
    }

    func availability() async -> AssistantModelAvailability {
        availabilityValue
    }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.finish()
        }
    }
}

private struct CancellableGenerator: AssistantGenerating {
    func availability() async -> AssistantModelAvailability { .ready }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.text("partial"))
                do {
                    try await Task.sleep(for: .seconds(30))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor MemoryHistoryBackend: AssistantHistoryBackend {
    private var records: [UUID: AssistantConversationRecord] = [:]

    func loadRecords() -> [AssistantConversationRecord] {
        Array(records.values)
    }

    func save(_ record: AssistantConversationRecord) {
        records[record.id] = record
    }

    func record(id: UUID) -> AssistantConversationRecord? {
        records[id]
    }
}

private actor MemoryDraftStore: PendingStudioPatchPersisting {
    private var draft: StudioPatchDraft?

    func load() -> StudioPatchDraft? { draft }
    func save(_ draft: StudioPatchDraft?) { self.draft = draft }
}

private actor StubSpeechTranscriber: AssistantSpeechTranscribing {
    let permission: AssistantVoicePermissionState

    init(permission: AssistantVoicePermissionState) {
        self.permission = permission
    }

    func permissionState() -> AssistantVoicePermissionState { permission }
    func requestPermission() -> AssistantVoicePermissionState { permission }

    func start() -> AsyncThrowingStream<AssistantTranscriptUpdate, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(AssistantTranscriptUpdate(text: "Studio patch", isFinal: true))
            continuation.finish()
        }
    }

    func finish() {}
    func cancel() {}
}
