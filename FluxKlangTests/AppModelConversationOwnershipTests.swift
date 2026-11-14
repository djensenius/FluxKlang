import Foundation
import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
@MainActor
struct AppModelConversationOwnershipTests {
    @Test func assistantChatLoadsTheInjectedConversationStore() async throws {
        let isTesting = AppPersistence.isTesting
        let deniesLiveServices = AssistantServiceIsolation.deniesLiveServices
        let modelFlagDisabled = ProcessInfo.processInfo.environment["FLUXKLANG_RUN_APPLE_MODEL_TESTS"] != "1"
        let routingFlagDisabled = ProcessInfo.processInfo.environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] != "1"
        try #require(isTesting && deniesLiveServices && modelFlagDisabled && routingFlagDisabled)

        let suite = "AppModelConversationOwnership-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = URL.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let historyDirectory = directory.appendingPathComponent("history", isDirectory: true)
        let backend = LocalAssistantHistoryBackend(directory: historyDirectory)
        let conversationStore = AssistantConversationStore(local: backend, cloud: nil)
        let conversationID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let conversation = AssistantConversation(
            id: conversationID,
            title: "Injected conversation \(conversationID)",
            createdAt: timestamp,
            modifiedAt: timestamp,
            summary: "Owned local history, not the default store",
            messages: [
                AssistantMessage(
                    role: .user, text: "Restore only this payload: \(conversationID)", createdAt: timestamp)
            ])
        await conversationStore.save(conversation)

        // A fresh backend proves the seed reached the explicitly owned directory.
        let freshBackend = LocalAssistantHistoryBackend(directory: historyDirectory)
        let records = try await freshBackend.loadRecords()
        try #require(records == [AssistantConversationRecord(conversation: conversation)])

        let domainStore = JSONFileStore(
            directory: directory.appendingPathComponent("domain", isDirectory: true), cloud: nil)
        let launchControlXLStore = JSONFileStore(
            directory: directory.appendingPathComponent("launch-control-xl", isDirectory: true), cloud: nil)
        let model = AppModel(
            assistant: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
            assistantProviderSettings: AssistantProviderSettings(
                defaults: defaults, credentials: MemoryAssistantCredentialStore()),
            hardware: .inert,
            launchControlXLStore: launchControlXLStore,
            domainStore: domainStore,
            assistantConversationStore: conversationStore)

        // Load awaits availability under the actual process-selected isolation policy.
        // AppIcon and chat preferences still use existing process-selected defaults.
        await model.assistantChat.load()

        #expect(model.assistantChat.selectedConversationID == conversation.id)
        #expect(model.assistantChat.selectedConversation == conversation)
        #expect(model.assistantChat.conversations == [conversation])
        #expect(model.assistantChat.persistenceDiagnostics.isEmpty)
    }
}
