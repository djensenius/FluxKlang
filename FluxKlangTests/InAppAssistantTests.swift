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

    @Test func deletingStreamingConversationClearsBusyStateImmediately() async throws {
        let chat = AssistantChatController(
            coordinator: AssistantCoordinator(draftStore: MemoryDraftStore()),
            store: AssistantConversationStore(local: MemoryHistoryBackend(), cloud: nil),
            generator: CancellableGenerator()
        )
        chat.newConversation()
        let conversationID = try #require(chat.selectedConversationID)
        chat.composer = "Stream"
        chat.send(context: emptyContext())
        try await waitUntil { chat.selectedConversation?.messages.last?.text == "partial" }

        chat.deleteConversation(id: conversationID)

        #expect(chat.isStreaming == false)
        #expect(chat.selectedConversation == nil)
    }

    @Test func generationHistoryExcludesTheCurrentQuestion() async throws {
        let generator = RecordingGenerator()
        let chat = AssistantChatController(
            coordinator: AssistantCoordinator(draftStore: MemoryDraftStore()),
            store: AssistantConversationStore(local: MemoryHistoryBackend(), cloud: nil),
            generator: generator
        )
        chat.newConversation()
        chat.composer = "How is this wired?"
        chat.send(context: emptyContext())
        try await waitUntil { chat.selectedConversation?.messages.last?.state == .complete }

        let request = try #require(generator.latestRequest())
        #expect(request.question == "How is this wired?")
        #expect(request.recentMessages.isEmpty)
    }

    @Test func sendingWithNilSelectionReusesExistingConversation() async throws {
        let chat = AssistantChatController(
            coordinator: AssistantCoordinator(draftStore: MemoryDraftStore()),
            store: AssistantConversationStore(local: MemoryHistoryBackend(), cloud: nil),
            generator: StubGenerator(availability: .ready, text: "Ready")
        )
        chat.newConversation()
        let conversationID = try #require(chat.selectedConversationID)
        chat.selectedConversationID = nil
        chat.composer = "Continue"

        chat.send(context: emptyContext())
        try await waitUntil { chat.selectedConversation?.messages.last?.state == .complete }

        #expect(chat.selectedConversationID == conversationID)
        #expect(chat.conversations.count == 1)
    }

    @Test func noOpConversationUpdatesDoNotPersistOrReorderHistory() async throws {
        let backend = MemoryHistoryBackend()
        let chat = AssistantChatController(
            coordinator: AssistantCoordinator(draftStore: MemoryDraftStore()),
            store: AssistantConversationStore(local: backend, cloud: nil),
            generator: StubGenerator(availability: .ready, text: "Ready")
        )
        chat.newConversation()
        let olderID = try #require(chat.selectedConversationID)
        try await waitForSaveCount(1, backend: backend)
        chat.newConversation()
        try await waitForSaveCount(2, backend: backend)
        let originalOrder = chat.conversations.map(\.id)

        chat.renameConversation(id: olderID, to: "New Conversation")
        chat.renameConversation(id: olderID, to: "   ")
        try await Task.sleep(for: .milliseconds(50))

        #expect(chat.conversations.map(\.id) == originalOrder)
        #expect(await backend.saveCount == 2)
    }

    @Test func retryReusesTheExistingUserMessage() async throws {
        let generator = FailingRecordingGenerator()
        let chat = AssistantChatController(
            coordinator: AssistantCoordinator(draftStore: MemoryDraftStore()),
            store: AssistantConversationStore(local: MemoryHistoryBackend(), cloud: nil),
            generator: generator
        )
        chat.newConversation()
        chat.composer = "Try this"
        chat.send(context: emptyContext())
        try await waitUntil { chat.selectedConversation?.messages.last?.state == .failed }
        let failedID = try #require(chat.selectedConversation?.messages.last?.id)

        chat.retry(messageID: failedID, context: emptyContext())
        try await waitUntil { generator.requestCount == 2 }

        #expect(chat.selectedConversation?.messages.filter { $0.role == .user }.count == 1)
    }

    @Test func voiceStartIgnoresOverlappingRequests() async throws {
        let transcriber = CountingSpeechTranscriber()
        let voice = AssistantVoiceController(transcriber: transcriber)

        voice.start()
        voice.start()
        try await waitUntil { voice.state == .listening }

        let startCount = await transcriber.startCount
        #expect(startCount == 1)
        voice.cancel()
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
        let initialCloudSaves = await cloud.saveCount
        _ = await store.load()
        #expect(await cloud.saveCount == initialCloudSaves)

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

    private func waitForSaveCount(
        _ expectedCount: Int,
        backend: MemoryHistoryBackend
    ) async throws {
        for _ in 0..<100 {
            if await backend.saveCount == expectedCount { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AssistantTestError.persistenceTimedOut
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

private final class RecordingGenerator: AssistantGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AssistantGenerationRequest] = []

    func availability() async -> AssistantModelAvailability { .ready }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("Done"))
            continuation.finish()
        }
    }

    func latestRequest() -> AssistantGenerationRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }
}

private final class FailingRecordingGenerator: AssistantGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func availability() async -> AssistantModelAvailability { .ready }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        lock.lock()
        requests += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: AssistantTestError.generationFailed)
        }
    }
}

private enum AssistantTestError: Error {
    case generationFailed
    case persistenceTimedOut
}

private actor MemoryHistoryBackend: AssistantHistoryBackend {
    private var records: [UUID: AssistantConversationRecord] = [:]
    private(set) var saveCount = 0

    func loadRecords() async -> [AssistantConversationRecord] {
        Array(records.values)
    }

    func save(_ record: AssistantConversationRecord) async {
        records[record.id] = record
        saveCount += 1
    }

    func record(id: UUID) -> AssistantConversationRecord? {
        records[id]
    }
}

private actor CountingSpeechTranscriber: AssistantSpeechTranscribing {
    private(set) var startCount = 0

    func permissionState() async -> AssistantVoicePermissionState { .granted }
    func requestPermission() async -> AssistantVoicePermissionState { .granted }

    func start() async -> AsyncThrowingStream<AssistantTranscriptUpdate, any Error> {
        startCount += 1
        return AsyncThrowingStream { _ in }
    }

    func finish() async {}
    func cancel() async {}
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

    func permissionState() async -> AssistantVoicePermissionState { permission }
    func requestPermission() async -> AssistantVoicePermissionState { permission }

    func start() async -> AsyncThrowingStream<AssistantTranscriptUpdate, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(AssistantTranscriptUpdate(text: "Studio patch", isFinal: true))
            continuation.finish()
        }
    }

    func finish() async {}
    func cancel() async {}
}
