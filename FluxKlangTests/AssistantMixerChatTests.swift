import Foundation
import Testing

@testable import FluxKlang

@Suite(.productionAccessAudit)
@MainActor
struct AssistantMixerChatTests {
    @Test func missingPlannerFailsClosedForEveryProviderAndCannotRetryAfterReload() async throws {
        for provider in AssistantProvider.allCases {
            try await withAssistantMixerChatFixture { fixture in
                let backend = AssistantBackendHistoryStore()
                let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
                let apple = fixture.makeGenerator()
                let fallback = fixture.makeGenerator()
                let http = AssistantMixerHTTPSpy()
                let defaults = try fixture.resources.defaults("provider")
                let settings = AssistantProviderSettings(
                    defaults: defaults, credentials: AssistantMixerTestCredentials())
                settings.provider = provider
                let generator = ConfigurableAssistantGenerator(settings: settings, coordinator: coordinator,
                    appleGenerator: apple, fallback: fallback, httpClient: http)
                let executor = AssistantRecordingMixerExecutor()
                let store = AssistantConversationStore(local: backend, cloud: nil)
                let chat = fixture.own(AssistantChatController(
                    coordinator: coordinator, store: store, generator: generator,
                    spokenRepliesDefaults: try fixture.resources.defaults("spoken")))
                chat.spokenRepliesEnabled = false
                chat.mixerExecutor = executor
                chat.composer = "lower main by 3 dB"
                chat.send(context: AssistantBackendFixture.context())
                try await AssistantBackendFixture.wait { !chat.isStreaming }
                await chat.awaitOwnedWorkSnapshot()
                #expect(executor.commands.isEmpty)
                #expect(apple.calls == 0)
                #expect(fallback.calls == 0)
                #expect(await http.calls == 0)
                #expect(coordinator.pendingStudioDraft == nil)
                #expect(chat.selectedConversation?.messages.last?.text
                    == "No changes: reviewed action planning is not configured.")
                let response = try #require(chat.selectedConversation?.messages.last)
                chat.retry(messageID: response.id, context: AssistantBackendFixture.context())
                #expect(executor.commands.isEmpty)
                #expect(apple.calls == 0)
                #expect(fallback.calls == 0)
                #expect(await http.calls == 0)
                #expect(coordinator.pendingStudioDraft == nil)
                let conversation = try #require(chat.selectedConversation)
                await store.save(conversation)
                await chat.awaitOwnedWorkSnapshot()
                let restored = fixture.own(AssistantChatController(
                    coordinator: coordinator, store: store, generator: generator,
                    spokenRepliesDefaults: try fixture.resources.defaults("restored-spoken")))
                restored.mixerExecutor = executor
                await restored.load()
                restored.retry(messageID: response.id, context: AssistantBackendFixture.context())
                #expect(executor.commands.isEmpty)
                await fixture.complete()
                #expect(executor.commands.isEmpty)
                #expect(apple.calls == 0)
                #expect(fallback.calls == 0)
                #expect(await http.calls == 0)
            }
        }
    }

    @Test func ambiguousMixedQuotedAndHistoricalCommandsNeverReachExecutorOrProvider() async throws {
        try await withAssistantMixerChatFixture { fixture in
            let executor = AssistantRecordingMixerExecutor()
            let generator = fixture.makeGenerator()
            let backend = AssistantBackendHistoryStore()
            let chat = fixture.own(AssistantChatController(
                coordinator: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
                store: AssistantConversationStore(local: backend, cloud: nil), generator: generator,
                actionInterpreter: RoutingTestInterpreter(available: .unavailable("deterministic test")),
                spokenRepliesDefaults: try fixture.resources.defaults("spoken")))
            chat.spokenRepliesEnabled = false
            chat.mixerExecutor = executor
            for text in [
                "turn down volume", "lower main", "route Synth to speakers and mute main", "don't mute main",
                "\"mute main\"", "how do I mute main?"
            ] {
                chat.composer = text
                chat.send(context: AssistantBackendFixture.context())
                try await AssistantBackendFixture.wait { !chat.isStreaming }
                await chat.awaitOwnedWorkSnapshot()
            }
            #expect(executor.commands.isEmpty)
            #expect(generator.calls == 0)
            chat.composer = "Thanks"
            chat.send(context: AssistantBackendFixture.context())
            try await AssistantBackendFixture.wait { !chat.isStreaming }
            await fixture.complete()
            #expect(executor.commands.isEmpty)
            #expect(generator.calls == 1)
        }
    }

    @Test func allUnsafeMixerCasesBlockEveryProviderAndMakeZeroActualTransportWrites() async throws {
        try await withAssistantMixerChatFixture { fixture in
            let transport = AssistantRecordingWingTransport()
            let wing = fixture.makeWing(transport: transport)
            await wing.connect(host: "192.0.2.10")
            let generator = fixture.makeGenerator()
            let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
            let chat = fixture.own(AssistantChatController(coordinator: coordinator,
                store: AssistantConversationStore(local: AssistantBackendHistoryStore(), cloud: nil),
                generator: generator,
                actionInterpreter: RoutingTestInterpreter(available: .unavailable("deterministic test")),
                spokenRepliesDefaults: try fixture.resources.defaults("spoken")))
            chat.spokenRepliesEnabled = false
            chat.mixerExecutor = AssistantMixerExecutor(controller: { wing }, layout: { FaderLayout() })
            var context = AssistantBackendFixture.context()
            context.liveWing.sessionID = wing.sessionID
            for text in AssistantMixerRejectionCases.texts {
                chat.composer = text
                chat.send(context: context)
                try await AssistantBackendFixture.wait { !chat.isStreaming }
                await chat.awaitOwnedWorkSnapshot()
                #expect(await transport.writes.isEmpty)
                #expect(wing.transportWriteCount == 0)
                #expect(generator.calls == 0)
                #expect(coordinator.pendingStudioDraft == nil)
            }
            await fixture.complete()
            #expect(await transport.writes.isEmpty)
            #expect(wing.transportWriteCount == 0)
            #expect(generator.calls == 0)
            #expect(coordinator.pendingStudioDraft == nil)
        }
    }

    @Test func punctuationSeparatedMixerClausesPreserveExistingDraftAndNeverReachProviderOrTransport() async throws {
        try await withAssistantMixerChatFixture { fixture in
            let synth = Equipment(name: "Synth")
            let prior = Equipment(name: "Prior")
            let context = AssistantBackendFixture.context(equipment: [synth, prior], inputs: [
                .init(connector: 7, equipmentID: synth.id, outputPort: 0),
                .init(connector: 8, equipmentID: prior.id, outputPort: 0)
            ])
            let transport = AssistantRecordingWingTransport()
            let wing = fixture.makeWing(transport: transport)
            await wing.connect(host: "192.0.2.10")
            let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
            _ = await coordinator.perform(.buildStudioDraft(.init(sourceInstrumentIDs: [prior.id])), context: context)
            let pending = coordinator.pendingStudioDraft
            let provider = fixture.makeGenerator()
            let chat = fixture.own(AssistantChatController(coordinator: coordinator,
                store: AssistantConversationStore(local: AssistantBackendHistoryStore(), cloud: nil),
                generator: provider,
                actionInterpreter: RoutingTestInterpreter(available: .unavailable("deterministic test")),
                spokenRepliesDefaults: try fixture.resources.defaults("spoken")))
            chat.spokenRepliesEnabled = false
            chat.mixerExecutor = AssistantMixerExecutor(controller: { wing }, layout: { FaderLayout() })
            for boundary in [".", ":", "&", "!", "?", "—"] {
                chat.composer = "route Synth to speakers\(boundary) mute main"
                chat.send(context: context)
                try await AssistantBackendFixture.wait { !chat.isStreaming }
                await chat.awaitOwnedWorkSnapshot()
                #expect(chat.selectedConversation?.messages.last?.text.contains("No draft was changed") == true)
                #expect(provider.calls == 0)
                #expect(coordinator.pendingStudioDraft == pending)
                #expect(wing.transportWriteCount == 0)
                #expect(await transport.writes.isEmpty)
            }
            await fixture.complete()
            #expect(provider.calls == 0)
            #expect(coordinator.pendingStudioDraft == pending)
            #expect(wing.transportWriteCount == 0)
            #expect(await transport.writes.isEmpty)
        }
    }

    @Test func ordinaryHelpInventoryAndRoutingWithMixerWordsKeepTheirHandlingAndNeverExecuteMixer() async throws {
        try await withAssistantMixerChatFixture { fixture in
            let gear = Equipment(name: "Lower Synth")
            let context = AssistantBackendFixture.context(equipment: [gear],
                inputs: [.init(connector: 7, equipmentID: gear.id, outputPort: 0)])
            let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
            let generator = fixture.makeGenerator()
            let executor = AssistantRecordingMixerExecutor()
            let chat = fixture.own(AssistantChatController(coordinator: coordinator,
                store: AssistantConversationStore(local: AssistantBackendHistoryStore(), cloud: nil),
                generator: generator,
                actionInterpreter: RoutingTestInterpreter(available: .unavailable("deterministic test")),
                spokenRepliesDefaults: try fixture.resources.defaults("spoken")))
            chat.spokenRepliesEnabled = false
            chat.mixerExecutor = executor
            for text in ["help me set up my studio", "list equipment named Volume", "route Lower Synth to speakers"] {
                chat.composer = text
                chat.send(context: context)
                try await AssistantBackendFixture.wait { !chat.isStreaming }
                await chat.awaitOwnedWorkSnapshot()
                #expect(executor.commands.isEmpty)
            }
            await fixture.complete()
            #expect(executor.commands.isEmpty)
            #expect(generator.calls == 1)
            #expect(coordinator.pendingStudioDraft == nil)
            #expect(chat.selectedConversation?.messages.last?.text.contains("No draft was changed") == true)
        }
    }

    @Test func cancellationDoesNotReplayAndMissingExecutorIsTruthful() async throws {
        try await withAssistantMixerChatFixture { fixture in
            let generator = fixture.makeGenerator()
            let chat = fixture.own(AssistantChatController(
                coordinator: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
                store: AssistantConversationStore(local: AssistantBackendHistoryStore(), cloud: nil),
                generator: generator,
                spokenRepliesDefaults: try fixture.resources.defaults("spoken")))
            chat.spokenRepliesEnabled = false
            chat.composer = "mute main"
            chat.send(context: AssistantBackendFixture.context())
            try await AssistantBackendFixture.wait { !chat.isStreaming }
            await chat.awaitOwnedWorkSnapshot()
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
            await fixture.complete()
            #expect(chat.selectedConversation?.messages.last?.state == .complete)
            #expect(executor.commands.isEmpty)
            #expect(generator.calls == 0)
        }
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
private func withAssistantMixerChatFixture(
    _ body: @MainActor (AssistantMixerChatFixture) async throws -> Void
) async throws {
    try await withAssistantFixtureResources { resources in
        let fixture = AssistantMixerChatFixture(resources: resources)
        resources.onFinish { await fixture.finish() }
        try await body(fixture)
    }
}

@MainActor
private final class AssistantMixerChatFixture {
    let resources: AssistantFixtureResources
    private var generators: [AssistantFixtureReplyGenerator] = []
    private var chats: [AssistantChatController] = []
    private var transport: AssistantRecordingWingTransport?
    private var wing: WingController?

    init(resources: AssistantFixtureResources) {
        self.resources = resources
    }

    func makeGenerator() -> AssistantFixtureReplyGenerator {
        let generator = AssistantFixtureReplyGenerator()
        generators.append(generator)
        return generator
    }

    func own(_ chat: AssistantChatController) -> AssistantChatController {
        chats.append(chat)
        return chat
    }

    func makeWing(transport: AssistantRecordingWingTransport) -> WingController {
        self.transport = transport
        let wing = WingController(transport: transport)
        self.wing = wing
        return wing
    }

    func complete() async {
        // Finish the submitted producers/history without cancelling expected state.
        // Only then seal/join the separate fake workers, before final assertions.
        for chat in chats { await chat.awaitOwnedWorkSnapshot() }
        for generator in generators { await generator.join() }
    }

    func finish() async {
        for generator in generators { generator.close() }
        for chat in chats { chat.cancel() }
        // This family arms no transport gates and launches no separate caller tasks.
        for generator in generators { await generator.join() }
        for chat in chats { await chat.awaitOwnedWorkSnapshot() }
        await wing?.disconnect()
        chats.removeAll()
        generators.removeAll()
        wing = nil
        transport = nil
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

private struct AssistantMixerTestCredentials: AssistantCredentialStore {
    func value(for account: String) -> String? { "offline-test-token" }
    func setValue(_ value: String, for account: String) throws {}
    func removeValue(for account: String) throws {}
}

private actor AssistantMixerHTTPSpy: AssistantHTTPClient {
    private(set) var calls = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        throw BackendTestError.send
    }
}
