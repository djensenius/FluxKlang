import Foundation
import Testing

@testable import FluxKlang

@MainActor
struct AssistantMixerChatTests {
    @Test func explicitSubmissionInterceptsEveryProviderBeforeRoutingAndCannotRetryAfterReload() async throws {
        for _ in AssistantProvider.allCases {
            let backend = AssistantBackendHistoryStore()
            let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
            let generator = AssistantBackendGenerator()
            let executor = AssistantRecordingMixerExecutor()
            let store = AssistantConversationStore(local: backend, cloud: nil)
            let chat = AssistantChatController(coordinator: coordinator, store: store, generator: generator)
            chat.spokenRepliesEnabled = false
            chat.mixerExecutor = executor
            chat.composer = "lower main by 3 dB"
            chat.send(context: AssistantBackendFixture.context())
            try await AssistantBackendFixture.wait { !chat.isStreaming }
            #expect(executor.commands.count == 1)
            #expect(generator.calls == 0)
            #expect(chat.selectedConversation?.messages.last?.text == "Recorded outcome, not model prose")
            let response = try #require(chat.selectedConversation?.messages.last)
            chat.retry(messageID: response.id, context: AssistantBackendFixture.context())
            #expect(executor.commands.count == 1)
            #expect(generator.calls == 0)
            let conversation = try #require(chat.selectedConversation)
            await store.save(conversation)
            let restored = AssistantChatController(coordinator: coordinator, store: store, generator: generator)
            restored.mixerExecutor = executor
            await restored.load()
            restored.retry(messageID: response.id, context: AssistantBackendFixture.context())
            #expect(executor.commands.count == 1)
        }
    }

    @Test func ambiguousMixedQuotedAndHistoricalCommandsNeverReachExecutorOrProvider() async throws {
        let executor = AssistantRecordingMixerExecutor()
        let generator = AssistantBackendGenerator()
        let backend = AssistantBackendHistoryStore()
        let chat = AssistantChatController(
            coordinator: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
            store: AssistantConversationStore(local: backend, cloud: nil), generator: generator)
        chat.spokenRepliesEnabled = false
        chat.mixerExecutor = executor
        for text in [
            "turn down volume", "lower main", "route Synth to speakers and mute main", "don't mute main",
            "\"mute main\"", "how do I mute main?"
        ] {
            chat.composer = text
            chat.send(context: AssistantBackendFixture.context())
            try await AssistantBackendFixture.wait { !chat.isStreaming }
        }
        #expect(executor.commands.isEmpty)
        #expect(generator.calls == 0)
        chat.composer = "Thanks"
        chat.send(context: AssistantBackendFixture.context())
        try await AssistantBackendFixture.wait { !chat.isStreaming }
        #expect(executor.commands.isEmpty)
        #expect(generator.calls == 1)
    }

    @Test func cancellationDoesNotReplayAndMissingExecutorIsTruthful() async throws {
        let generator = AssistantBackendGenerator()
        let chat = AssistantChatController(
            coordinator: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
            store: AssistantConversationStore(local: AssistantBackendHistoryStore(), cloud: nil), generator: generator)
        chat.spokenRepliesEnabled = false
        chat.composer = "mute main"
        chat.send(context: AssistantBackendFixture.context())
        try await AssistantBackendFixture.wait { !chat.isStreaming }
        #expect(chat.selectedConversation?.messages.last?.text.contains("not configured") == true)
        let executor = AssistantRecordingMixerExecutor()
        chat.mixerExecutor = executor
        chat.composer = "lower main by 3 dB"
        chat.send(context: AssistantBackendFixture.context())
        chat.cancel()
        try await AssistantBackendFixture.wait { chat.selectedConversation?.messages.last?.state == .complete }
        #expect(executor.commands.isEmpty)
        let response = try #require(chat.selectedConversation?.messages.last)
        chat.retry(messageID: response.id, context: AssistantBackendFixture.context())
        #expect(executor.commands.isEmpty)
        #expect(generator.calls == 0)
    }

    @Test func liveDraftRevalidationDisconnectBlocksAliasButSavedOnlyDraftRemainsOfflineAndZeroWrite() async {
        let gear = Equipment(name: "Saved", outputs: ["Out"])
        let base = AssistantBackendFixture.context(
            equipment: [gear], inputs: [.init(connector: 7, equipmentID: gear.id, outputPort: 0)])
        let context = AssistantBackendFixture.observe([WingAddress.inputName(7): .string("Alias")], context: base)
        let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
        var request = StudioWiringRequest(sourceInstrumentIDs: [gear.id])
        request.liveReferences = AssistantSourceResolver.resolve("route Alias to speakers", context: context).references
        let transport = AssistantRecordingWingTransport()
        let wing = WingController(transport: transport)
        _ = await coordinator.perform(.buildStudioDraft(request), context: context)
        _ = await coordinator.perform(.validatePendingStudioDraft, context: base)
        #expect(coordinator.pendingStudioDraft?.validation.contains { $0.code == "live-alias-changed" } == true)
        _ = await coordinator.perform(.buildStudioDraft(.init(sourceInstrumentIDs: [gear.id])), context: base)
        _ = await coordinator.perform(.validatePendingStudioDraft, context: base)
        #expect(coordinator.pendingStudioDraft?.validation.contains { $0.code == "live-alias-changed" } == false)
        #expect(wing.transportWriteCount == 0)
        #expect(await transport.writes.isEmpty)
        #expect(throws: AssistantToolAuthorizationError.denied(.writeWing)) {
            try AssistantToolAuthorizer.model.authorize(.writeWing)
        }
    }
}

@MainActor
final class AssistantRecordingMixerExecutor: AssistantMixerExecuting {
    var commands: [AssistantMixerCommand] = []
    func execute(_ command: AssistantMixerCommand, sessionID: UUID?) async -> String {
        commands.append(command)
        return "Recorded outcome, not model prose"
    }
}

actor AssistantBackendHistoryStore: AssistantHistoryBackend {
    var records: [UUID: AssistantConversationRecord] = [:]
    func loadRecords() -> [AssistantConversationRecord] { Array(records.values) }
    func save(_ record: AssistantConversationRecord) { records[record.id] = record }
}
