import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct InAppAssistantTests {
    @Test func strictIsolationOverridesBothClosedLiveTestPurposes() {
        let modelOnly = ["FLUXKLANG_RUN_APPLE_MODEL_TESTS": "1"]
        let routingOnly = ["FLUXKLANG_QUALIFY_APPLE_ROUTING": "1"]
        #expect(FoundationModelActionInterpreter.LiveTestPurpose.model.isPermitted(environment: modelOnly))
        #expect(!FoundationModelActionInterpreter.LiveTestPurpose.model.isPermitted(environment: routingOnly))
        #expect(FoundationModelActionInterpreter.LiveTestPurpose.routing.isPermitted(environment: routingOnly))
        #expect(!FoundationModelActionInterpreter.LiveTestPurpose.routing.isPermitted(environment: modelOnly))
        #expect(!FoundationModelActionInterpreter.LiveTestPurpose.model.isPermitted(environment: [:]))
        #expect(!FoundationModelActionInterpreter.LiveTestPurpose.routing.isPermitted(environment: [:]))
        #expect(!AssistantServiceIsolation.deniesLiveServices(isTesting: false, environment: [:]))
        for var environment in [[:], modelOnly, routingOnly, modelOnly.merging(routingOnly) { first, _ in first }] {
            #expect(AssistantServiceIsolation.deniesLiveServices(isTesting: true, environment: environment))
            environment["FLUXKLANG_ISOLATED_TESTING"] = "1"
            #expect(AssistantServiceIsolation.deniesLiveServices(isTesting: false, environment: environment))
            for purpose in FoundationModelActionInterpreter.LiveTestPurpose.allCases {
                #expect(!purpose.isPermitted(environment: environment))
            }
        }
    }

    @Test func isolatedDefaultFactoriesAreNotEvaluated() async throws {
        try #require(AssistantServiceIsolation.deniesLiveServices)
        var constructions = 0
        let fallback = InAppStubGenerator(availability: .unsupportedOS, text: "fallback")
        let generator = AssistantGeneratorRouter.defaultGenerator(model: {
            constructions += 1
            return InAppStubGenerator(availability: .ready, text: "model")
        }, fallback: fallback)
        let interpreter = AssistantChatController.defaultActionInterpreter(forcesFallback: false, live: {
            constructions += 1
            return ReviewedChatInterpreter(result: .answer)
        })
        let client = URLSessionAssistantHTTPClient.defaultClient(live: {
            constructions += 1
            return InAppIsolationHTTPClient()
        })
        #expect(await generator.availability() == .unsupportedOS)
        #expect(await interpreter.availability() == .unavailable(AssistantServiceIsolation.reason))
        #expect(client == nil)
        #expect(constructions == 0)
    }

    @Test func isolatedLoadRefreshAndSpokenFallbackNeverConstructSpeech() async throws {
        try await withInAppAssistantFixture { fixture in
            try #require(AssistantServiceIsolation.deniesLiveServices)
            let backend = InAppMemoryHistoryBackend()
            var constructions = 0
            var speechCalls = 0
            let chat = AssistantChatController(
                coordinator: AssistantCoordinator(draftStore: InAppMemoryDraftStore()),
                store: AssistantConversationStore(local: backend, cloud: nil),
                spokenRepliesDefaults: try fixture.resources.defaults("spoken"),
                makeSpeech: { constructions += 1; return { _ in speechCalls += 1 } })
            fixture.chat = chat
            chat.spokenRepliesEnabled = true
            await chat.load()
            await chat.refreshAvailability()
            #expect(await backend.loadCount == 1)
            #expect(chat.modelAvailability == .unsupportedOS)
            chat.composer = "Help"
            chat.send(context: emptyContext())
            try await waitUntil { chat.selectedConversation?.messages.last?.state == .complete }
            #expect(chat.selectedConversation?.messages.last?.text.isEmpty == false)
            let planner = ReviewedChatPlanner()
            chat.actionPlanner = planner
            chat.composer = "lower channel 7 by 3 dB"
            chat.send(context: emptyContext())
            try await waitUntil { !chat.isStreaming }
            #expect(planner.intents.count == 1)
            #expect(planner.confirmations == 0)
            #expect(chat.selectedConversation?.messages.last?.text.contains("local exact-command grammar") == true)
            #expect(constructions == 0)
            #expect(speechCalls == 0)
        }
    }

    @Test func directDefaultModelAndHTTPEntriesDenyAccess() async throws {
        try #require(AssistantServiceIsolation.deniesLiveServices)
        let coordinator = AssistantCoordinator(draftStore: InAppMemoryDraftStore())
        let request = AssistantGenerationRequest(question: "Help", recentMessages: [], summary: "",
                                                 context: emptyContext())
        let generators: [any AssistantGenerating] = [
            FoundationModelAssistantGenerator(coordinator: coordinator),
            CopilotAssistantGenerator(configuration: .init(token: "offline", model: "fake"), coordinator: coordinator)
        ]
        for generator in generators {
            #expect(await generator.availability() == .deterministic)
            await #expect(throws: AssistantServiceIsolation.AccessError.self) {
                for try await _ in generator.stream(request) {}
            }
        }
        let interpreter = FoundationModelActionInterpreter()
        #expect(await interpreter.availability() == .unavailable(AssistantServiceIsolation.reason))
        await #expect(throws: FoundationModelActionInterpreter.InterpretationError.self) {
            try await interpreter.interpret(.init(text: "lower channel 7 by 3 dB"))
        }
        let url = try #require(URL(string: "https://example.invalid"))
        await #expect(throws: AssistantServiceIsolation.AccessError.self) {
            try await URLSessionAssistantHTTPClient().data(for: URLRequest(url: url))
        }
    }

    @Test func unavailableModelUsesDeterministicFallback() async throws {
        let router = AssistantGeneratorRouter(
            model: InAppStubGenerator(availability: .deviceNotEligible, text: "model"),
            fallback: InAppStubGenerator(availability: .unsupportedOS, text: "fallback")
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

    @Test func concurrentLoadsShareOneHistoryLoad() async throws {
        try await withInAppAssistantFixture { fixture in
            let backend = InAppMemoryHistoryBackend(loadDelay: .milliseconds(50))
            let chat = AssistantChatController(
                coordinator: AssistantCoordinator(draftStore: InAppMemoryDraftStore()),
                store: AssistantConversationStore(local: backend, cloud: nil),
                generator: InAppStubGenerator(availability: .ready, text: "Ready"),
                spokenRepliesDefaults: try fixture.resources.defaults("spoken")
            )
            fixture.chat = chat

            async let first: Void = chat.load()
            async let second: Void = chat.load()
            _ = await (first, second)

            #expect(await backend.loadCount == 1)
        }
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
        try await withInAppAssistantFixture { fixture in
            let coordinator = AssistantCoordinator(draftStore: InAppMemoryDraftStore())
            let store = AssistantConversationStore(local: InAppMemoryHistoryBackend(), cloud: nil)
            let generator = InAppCancellableGenerator()
            fixture.generator = generator
            let chat = AssistantChatController(
                coordinator: coordinator,
                store: store,
                generator: generator,
                spokenRepliesDefaults: try fixture.resources.defaults("spoken")
            )
            fixture.chat = chat
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
    }

    @Test func deletingStreamingConversationClearsBusyStateImmediately() async throws {
        try await withInAppAssistantFixture { fixture in
            let generator = InAppCancellableGenerator()
            fixture.generator = generator
            let chat = AssistantChatController(
                coordinator: AssistantCoordinator(draftStore: InAppMemoryDraftStore()),
                store: AssistantConversationStore(local: InAppMemoryHistoryBackend(), cloud: nil),
                generator: generator,
                spokenRepliesDefaults: try fixture.resources.defaults("spoken")
            )
            fixture.chat = chat
            chat.newConversation()
            let conversationID = try #require(chat.selectedConversationID)
            chat.composer = "Stream"
            chat.send(context: emptyContext())
            try await waitUntil { chat.selectedConversation?.messages.last?.text == "partial" }

            chat.deleteConversation(id: conversationID)

            #expect(chat.isStreaming == false)
            #expect(chat.selectedConversation == nil)
        }
    }

    @Test func generationHistoryExcludesTheCurrentQuestion() async throws {
        try await withInAppAssistantFixture { fixture in
            let generator = InAppRecordingGenerator()
            let chat = AssistantChatController(
                coordinator: AssistantCoordinator(draftStore: InAppMemoryDraftStore()),
                store: AssistantConversationStore(local: InAppMemoryHistoryBackend(), cloud: nil),
                generator: generator,
                spokenRepliesDefaults: try fixture.resources.defaults("spoken")
            )
            fixture.chat = chat
            chat.newConversation()
            chat.composer = "How is this wired?"
            chat.send(context: emptyContext())
            try await waitUntil { chat.selectedConversation?.messages.last?.state == .complete }

            let request = try #require(generator.latestRequest())
            #expect(request.question == "How is this wired?")
            #expect(request.recentMessages.isEmpty)
        }
    }

    @Test func sendingWithNilSelectionReusesExistingConversation() async throws {
        try await withInAppAssistantFixture { fixture in
            let chat = AssistantChatController(
                coordinator: AssistantCoordinator(draftStore: InAppMemoryDraftStore()),
                store: AssistantConversationStore(local: InAppMemoryHistoryBackend(), cloud: nil),
                generator: InAppStubGenerator(availability: .ready, text: "Ready"),
                spokenRepliesDefaults: try fixture.resources.defaults("spoken")
            )
            fixture.chat = chat
            chat.newConversation()
            let conversationID = try #require(chat.selectedConversationID)
            chat.selectedConversationID = nil
            chat.composer = "Continue"

            chat.send(context: emptyContext())
            try await waitUntil { chat.selectedConversation?.messages.last?.state == .complete }

            #expect(chat.selectedConversationID == conversationID)
            #expect(chat.conversations.count == 1)
        }
    }

    @Test func noOpConversationUpdatesDoNotPersistOrReorderHistory() async throws {
        try await withInAppAssistantFixture { fixture in
            let backend = InAppMemoryHistoryBackend()
            let chat = AssistantChatController(
                coordinator: AssistantCoordinator(draftStore: InAppMemoryDraftStore()),
                store: AssistantConversationStore(local: backend, cloud: nil),
                generator: InAppStubGenerator(availability: .ready, text: "Ready"),
                spokenRepliesDefaults: try fixture.resources.defaults("spoken")
            )
            fixture.chat = chat
            chat.newConversation()
            let olderID = try #require(chat.selectedConversationID)
            await chat.awaitOwnedWorkSnapshot()
            #expect(await backend.saveCount == 1)
            chat.newConversation()
            await chat.awaitOwnedWorkSnapshot()
            #expect(await backend.saveCount == 2)
            let originalOrder = chat.conversations.map(\.id)

            chat.renameConversation(id: olderID, to: "New Conversation")
            chat.renameConversation(id: olderID, to: "   ")
            await chat.awaitOwnedWorkSnapshot()

            #expect(chat.conversations.map(\.id) == originalOrder)
            #expect(await backend.saveCount == 2)
        }
    }

    @Test func retryReusesTheExistingUserMessage() async throws {
        try await withInAppAssistantFixture { fixture in
            let generator = InAppFailingRecordingGenerator()
            let chat = AssistantChatController(
                coordinator: AssistantCoordinator(draftStore: InAppMemoryDraftStore()),
                store: AssistantConversationStore(local: InAppMemoryHistoryBackend(), cloud: nil),
                generator: generator,
                spokenRepliesDefaults: try fixture.resources.defaults("spoken")
            )
            fixture.chat = chat
            chat.newConversation()
            chat.composer = "Try this"
            chat.send(context: emptyContext())
            try await waitUntil { chat.selectedConversation?.messages.last?.state == .failed }
            let failedID = try #require(chat.selectedConversation?.messages.last?.id)

            chat.retry(messageID: failedID, context: emptyContext())
            try await waitUntil { generator.requestCount == 2 }

            #expect(chat.selectedConversation?.messages.filter { $0.role == .user }.count == 1)
        }
    }

    @Test func historyMigratesSyncsAndPropagatesDeletionTombstones() async throws {
        try await withAssistantFixtureResources { resources in
            let root = resources.root
            let legacyURL = root.appendingPathComponent("legacy.json")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let legacy = AssistantConversation(title: "Legacy")
            try JSONEncoder().encode([legacy]).write(to: legacyURL)

            let local = LocalAssistantHistoryBackend(
                directory: root.appendingPathComponent("records", isDirectory: true),
                legacyFileURL: legacyURL
            )
            let cloud = InAppMemoryHistoryBackend()
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
    }

    @Test func assistantDraftPathCannotChangeWingValues() async throws {
        try await withInAppAssistantFixture { fixture in
            let resources = fixture.resources
            let coordinator = AssistantCoordinator(draftStore: InAppMemoryDraftStore())
            let settings = AssistantProviderSettings(
                defaults: try resources.defaults("provider"), credentials: MemoryAssistantCredentialStore())
            let model = AppModel(
                assistant: coordinator, assistantProviderSettings: settings, wing: .preview(),
                hardware: .inert,
                launchControlXLStore: JSONFileStore(
                    directory: resources.root.appendingPathComponent("launch-control-xl"), cloud: nil),
                domainStore: JSONFileStore(
                    directory: resources.root.appendingPathComponent("domain"), cloud: nil),
                assistantConversationStore: AssistantConversationStore(
                    local: LocalAssistantHistoryBackend(
                        directory: resources.root.appendingPathComponent("history", isDirectory: true),
                        legacyFileURL: resources.root.appendingPathComponent("absent-legacy-history.json")),
                    cloud: nil),
                assistantSpokenRepliesDefaults: try resources.defaults("spoken")
            )
            fixture.model = model
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
