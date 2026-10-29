import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct AssistantReviewedChatTests {
    @Test func ownerUtterancesReachInterpreterBeforeMixerAndDraftPreflightWithoutExecution() async throws {
        let examples: [(String, AssistantActionIntent)] = [
            ("turn down the volume of my Astrolab", .init(targetMention: "Astrolab", action: .lower, amount: nil,
                addToStudio: false, evidence: .init(target: "Astrolab", action: "turn down", amount: nil, add: nil))),
            ("add my mother-32 and turn the volume to 50%", .init(targetMention: "mother-32", action: .setFaderPercent,
                amount: 50, addToStudio: true,
                evidence: .init(target: "mother-32", action: "turn", amount: "50%", add: "add")))
        ]
        for (text, intent) in examples {
            let interpreter = ReviewedChatInterpreter(result: .proposal(intent))
            let planner = ReviewedChatPlanner()
            let provider = AssistantBackendGenerator()
            let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
            let chat = makeChat(
                interpreter: interpreter, planner: planner, provider: provider, coordinator: coordinator)
            let legacy = AssistantRecordingMixerExecutor()
            chat.mixerExecutor = legacy
            chat.composer = text
            chat.send(context: AssistantBackendFixture.context())
            try await AssistantBackendFixture.wait { !chat.isStreaming }
            #expect(await interpreter.requests.map(\.text) == [text])
            #expect(planner.intents == [intent])
            #expect(planner.confirmations == 0)
            #expect(legacy.commands.isEmpty)
            #expect(provider.calls == 0)
            #expect(coordinator.pendingStudioDraft == nil)
            #expect(chat.selectedConversation?.messages.last?.cards == [
                .actionReview(id: try #require(planner.pendingReview?.submissionID), summary: "Review only; no changes")
            ])
        }
    }

    @Test func answerAndClarificationSkipPlanningAndDoNotCreateEmptyCards() async throws {
        for text in ["Hello", "How do I mute main?", "What does 50% mean?"] {
            let planner = ReviewedChatPlanner()
            let provider = AssistantBackendGenerator()
            let chat = makeChat(
                interpreter: ReviewedChatInterpreter(result: .answer), planner: planner, provider: provider)
            chat.composer = text
            chat.send(context: AssistantBackendFixture.context())
            try await AssistantBackendFixture.wait { !chat.isStreaming }
            #expect(provider.calls == 1)
            #expect(planner.intents.isEmpty)
            #expect(chat.selectedConversation?.messages.last?.text == "provider reply")
            #expect(chat.selectedConversation?.messages.last?.cards.isEmpty == true)
        }
        let planner = ReviewedChatPlanner()
        let provider = AssistantBackendGenerator()
        let chat = makeChat(interpreter: ReviewedChatInterpreter(result: .clarification("Which channel?")),
                            planner: planner, provider: provider)
        chat.composer = "turn it down"
        chat.send(context: AssistantBackendFixture.context())
        try await AssistantBackendFixture.wait { !chat.isStreaming }
        #expect(provider.calls == 0)
        #expect(planner.intents.isEmpty)
        #expect(chat.selectedConversation?.messages.last?.cards.isEmpty == true)
        #expect(chat.selectedConversation?.messages.last?.text == "Which channel?")
    }

    @Test func unavailableAndErrorsUseReviewedExactFallbackNeverSelectedCopilot() async throws {
        let defaultsName = "reviewed-chat-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = AssistantProviderSettings(defaults: defaults, credentials: ReviewedChatCredentials())
        settings.provider = .githubCopilot
        for fails in [false, true] {
            let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
            let apple = AssistantBackendGenerator()
            let fallback = AssistantBackendGenerator()
            let http = ReviewedChatHTTPSpy()
            let generator = ConfigurableAssistantGenerator(settings: settings, coordinator: coordinator,
                appleGenerator: apple, fallback: fallback, httpClient: http)
            let interpreter = ReviewedChatInterpreter(result: .answer,
                availability: fails ? .available : .unavailable("disabled"), fails: fails)
            let planner = ReviewedChatPlanner()
            let chat = makeChat(interpreter: interpreter, planner: planner, provider: generator)
            let legacy = AssistantRecordingMixerExecutor()
            chat.mixerExecutor = legacy
            chat.composer = "lower channel 7 by 3 dB"
            chat.send(context: AssistantBackendFixture.context())
            try await AssistantBackendFixture.wait { !chat.isStreaming }
            #expect(planner.intents.count == 1)
            #expect(planner.intents.first?.amount == 3)
            #expect(chat.selectedConversation?.messages.last?.text.contains("local exact-command grammar") == true)
            #expect(chat.selectedConversation?.messages.last?.cards.count == 1)
            chat.composer = "turn Down Synth up by 3 dB"
            chat.send(context: AssistantBackendFixture.context())
            try await AssistantBackendFixture.wait { !chat.isStreaming }
            #expect(planner.intents.count == 2)
            #expect(planner.intents.last?.action == .raise)
            #expect(planner.intents.last?.evidence.action == "up")
            for text in ["add my mother-32 and turn the volume to 50%", "make my Astrolab softer",
                         "silence Astrolab", "bring Astrolab down", "Astrolab -6",
                         "unsilence Astrolab", "attenuate Astrolab", "add my Astrolab as a live-channel shortcut"] {
                chat.composer = text
                chat.send(context: AssistantBackendFixture.context())
                try await AssistantBackendFixture.wait { !chat.isStreaming }
                #expect(planner.intents.count == 2)
                #expect(planner.pendingReview == nil)
                #expect(chat.selectedConversation?.messages.last?.text.contains("unavailable") == true)
                #expect(chat.selectedConversation?.messages.last?.cards.isEmpty == true)
            }
            #expect(apple.calls == 0)
            #expect(fallback.calls == 0)
            #expect(await http.calls == 0)
            #expect(legacy.commands.isEmpty)
            #expect(planner.confirmations == 0)
        }
    }

    @Test func unavailableSpelledDecibelActionsNeverReachProviderButQuestionsStillDo() async throws {
        for fails in [false, true] {
            let transport = AssistantRecordingWingTransport()
            let wing = WingController(transport: transport)
            let state = AssistantActionTestState(wing: wing)
            var controllerReads = 0
            let planner = AssistantActionController(controller: { controllerReads += 1; return wing },
                layout: { state.layout }, scope: { state.scope }, addShortcut: { _, _, _, _ in nil })
            let provider = AssistantBackendGenerator()
            let interpreter = ReviewedChatInterpreter(result: .answer,
                availability: fails ? .available : .unavailable("disabled"), fails: fails)
            let chat = AssistantChatController(
                coordinator: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
                store: AssistantConversationStore(local: AssistantBackendHistoryStore(), cloud: nil),
                generator: provider, actionInterpreter: interpreter)
            chat.actionPlanner = planner
            chat.spokenRepliesEnabled = false
            let legacy = AssistantRecordingMixerExecutor()
            chat.mixerExecutor = legacy
            for text in ["lower Lead by three decibels", "drop Lead by three decibels",
                         "subtract one decibel from Lead", "Lead minus three DECIBELS",
                         "lower Lead by 3 decibels", "drop Lead by 3 dB"] {
                chat.composer = text
                chat.send(context: AssistantBackendFixture.context())
                try await AssistantBackendFixture.wait { !chat.isStreaming }
                #expect(chat.selectedConversation?.messages.last?.text.contains("unavailable") == true, "\(text)")
                #expect(chat.selectedConversation?.messages.last?.text.contains("manual mixer controls") == true)
                #expect(chat.selectedConversation?.messages.last?.cards.isEmpty == true)
                #expect(provider.calls == 0)
                #expect(planner.pendingReview == nil)
            }
            for (index, text) in ["What are decibels?", "Explain decibel levels",
                                  "How do I lower Lead by three decibels?"].enumerated() {
                chat.composer = text
                chat.send(context: AssistantBackendFixture.context())
                try await AssistantBackendFixture.wait { !chat.isStreaming }
                #expect(provider.calls == index + 1)
                #expect(chat.selectedConversation?.messages.last?.text == "provider reply")
            }
            #expect(controllerReads == 0)
            #expect(await transport.queries.isEmpty)
            #expect(await transport.writes.isEmpty)
            #expect(legacy.commands.isEmpty)
            #expect(planner.pendingReview == nil)
            #expect(state.scope.graph.nodes.isEmpty)
        }
    }

    @Test func installedPlannerPreservesRoutingNamesButBlocksMixedUnavailableActions() async throws {
        let gear = Equipment(name: "Lower Synth")
        let context = AssistantBackendFixture.context(equipment: [gear],
            inputs: [.init(connector: 7, equipmentID: gear.id, outputPort: 0)])
        for fails in [false, true] {
            let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
            let provider = AssistantBackendGenerator()
            let preflight = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: provider)
            let planner = ReviewedChatPlanner()
            let interpreter = ReviewedChatInterpreter(result: .answer,
                availability: fails ? .available : .unavailable("disabled"), fails: fails)
            let chat = makeChat(interpreter: interpreter, planner: planner, provider: preflight,
                                coordinator: coordinator)
            let legacy = AssistantRecordingMixerExecutor()
            chat.mixerExecutor = legacy
            chat.composer = "route Lower Synth to speakers"
            chat.send(context: context)
            try await AssistantBackendFixture.wait { !chat.isStreaming }
            #expect(coordinator.pendingStudioDraft?.request.sourceInstrumentIDs == [gear.id])
            let original = try #require(coordinator.pendingStudioDraft)
            #expect(chat.selectedConversation?.messages.last?.text.contains("unavailable") == false)
            for suffix in ["and mute main", "; unsilence Astrolab", "and could you attenuate Astrolab",
                           "and make Astrolab softer", "and Astrolab quieter", "and set channel 7 to -10 dB"] {
                chat.composer = "route Lower Synth to speakers \(suffix)"
                chat.send(context: context)
                try await AssistantBackendFixture.wait { !chat.isStreaming }
                #expect(chat.selectedConversation?.messages.last?.text.contains("unavailable") == true)
                #expect(coordinator.pendingStudioDraft == original)
                #expect(planner.pendingReview == nil)
            }
            #expect(provider.calls == 0)
            #expect(planner.intents.isEmpty)
            #expect(planner.confirmations == 0)
            #expect(legacy.commands.isEmpty)
        }
    }

    @Test func routingAnswerUsesReviewedPreflightAndInvalidInterpretationClarifiesWithoutProvider() async throws {
        let gear = Equipment(name: "Lower Synth")
        let context = AssistantBackendFixture.context(equipment: [gear],
            inputs: [.init(connector: 7, equipmentID: gear.id, outputPort: 0)])
        for answer in [false, true] {
            let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
            let provider = AssistantBackendGenerator()
            let planner = ReviewedChatPlanner()
            let interpreter = ReviewedChatInterpreter(result: answer ? .answer
                : .clarification(AssistantActionInterpretationAdapter.invalidOutput))
            let chat = makeChat(interpreter: interpreter, planner: planner,
                provider: AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: provider),
                coordinator: coordinator)
            let legacy = AssistantRecordingMixerExecutor()
            chat.mixerExecutor = legacy
            chat.composer = "route Lower Synth to speakers"
            chat.send(context: context)
            try await AssistantBackendFixture.wait { !chat.isStreaming }
            #expect(provider.calls == 0)
            #expect(planner.intents.isEmpty)
            #expect(planner.confirmations == 0)
            #expect(legacy.commands.isEmpty)
            if answer {
                #expect(coordinator.pendingStudioDraft?.request.sourceInstrumentIDs == [gear.id])
            } else {
                #expect(coordinator.pendingStudioDraft == nil)
                #expect(chat.selectedConversation?.messages.last?.text
                    == AssistantActionInterpretationAdapter.invalidOutput)
            }
        }
    }

    @Test func cancellationAndSupersessionCannotPublishLateInterpretationOrConfirm() async throws {
        let interpreter = ReviewedChatSuspendedInterpreter()
        let planner = ReviewedChatPlanner()
        let provider = AssistantBackendGenerator()
        let chat = makeChat(interpreter: interpreter, planner: planner, provider: provider)
        chat.composer = "turn down the volume of my Astrolab"
        chat.send(context: AssistantBackendFixture.context())
        try await AssistantBackendFixture.waitAsync { await interpreter.isWaiting }
        chat.cancel()
        chat.composer = "Hello"
        chat.send(context: AssistantBackendFixture.context())
        try await AssistantBackendFixture.wait { !chat.isStreaming }
        await interpreter.resume()
        await Task.yield()
        #expect(planner.intents.isEmpty)
        #expect(planner.pendingReview == nil)
        #expect(planner.confirmations == 0)
        #expect(provider.calls == 1)
        #expect(chat.selectedConversation?.messages.last?.text == "provider reply")
    }

    @Test func latePrepareAfterCancellationIsCleanedUpWithoutCancellingANewerReview() async throws {
        for newerReview in [false, true] {
            let planner = ReviewedChatPlanner()
            planner.suspendNextPrepare = true
            planner.preserveNewerReviewOnResume = newerReview
            let chat = makeChat(interpreter: ReviewedChatInterpreter(result: .proposal(Self.intent)),
                                planner: planner, provider: AssistantBackendGenerator())
            chat.composer = "turn down the volume of my Astrolab"
            chat.send(context: AssistantBackendFixture.context())
            try await AssistantBackendFixture.wait { planner.isPreparingSuspended }
            let oldResponse = try #require(chat.selectedConversation?.messages.last?.id)
            chat.cancel()
            if newerReview {
                chat.composer = "lower Astrolab by 3 dB"
                chat.send(context: AssistantBackendFixture.context())
                try await AssistantBackendFixture.wait { !chat.isStreaming }
            }
            let expectedNewReview = planner.pendingReview?.id
            planner.resumePreparation()
            try await AssistantBackendFixture.wait {
                chat.selectedConversation?.messages.first { $0.id == oldResponse }?.state == .cancelled
            }
            #expect(planner.pendingReview?.id == expectedNewReview)
            let prepareCount = planner.intents.count
            chat.retry(messageID: oldResponse, context: AssistantBackendFixture.context())
            #expect(planner.intents.count == prepareCount)
            #expect(planner.confirmations == 0)
        }
    }

    @Test func invalidGeneratedExactCommandGetsClearlyLabelledLocalReview() async throws {
        let planner = ReviewedChatPlanner()
        let provider = AssistantBackendGenerator()
        let chat = makeChat(interpreter: ReviewedChatInterpreter(
            result: .clarification(AssistantActionInterpretationAdapter.invalidOutput)),
            planner: planner, provider: provider)
        chat.composer = "lower channel 7 by 3 dB"
        chat.send(context: AssistantBackendFixture.context())
        try await AssistantBackendFixture.wait { !chat.isStreaming }
        #expect(planner.intents.count == 1)
        #expect(chat.selectedConversation?.messages.last?.text.contains("could not be validated") == true)
        #expect(chat.selectedConversation?.messages.last?.text.contains("local exact-command grammar") == true)
        #expect(provider.calls == 0)
        #expect(planner.confirmations == 0)
    }

    @Test func uiTestFallbackInterpreterIsUnavailableWithoutCallingApple() async {
        let interpreter = AssistantChatController.defaultActionInterpreter(forcesFallback: true)
        #expect(await interpreter.availability() == .unavailable("deterministic UI-test mode"))
    }

    @Test func cancelClearAndDeleteInvalidateAnExistingReview() async throws {
        for operation in ["cancel", "clear", "delete"] {
            let planner = ReviewedChatPlanner()
            let chat = makeChat(interpreter: ReviewedChatInterpreter(result: .proposal(Self.intent)),
                                planner: planner, provider: AssistantBackendGenerator())
            chat.composer = "turn down the volume of my Astrolab"
            chat.send(context: AssistantBackendFixture.context())
            try await AssistantBackendFixture.wait { !chat.isStreaming }
            #expect(planner.pendingReview != nil)
            switch operation {
            case "cancel": chat.cancel()
            case "clear": chat.clearAll()
            default: chat.deleteConversation(id: try #require(chat.selectedConversationID))
            }
            #expect(planner.pendingReview == nil)
            #expect(planner.confirmations == 0)
        }
    }

    @Test func cancellationConversationChangesHistoryAndRetryNeverRestoreAuthority() async throws {
        let interpreter = ReviewedChatInterpreter(result: .proposal(Self.intent))
        let planner = ReviewedChatPlanner()
        let provider = AssistantBackendGenerator()
        let store = AssistantConversationStore(local: AssistantBackendHistoryStore(), cloud: nil)
        let chat = AssistantChatController(
            coordinator: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
            store: store, generator: provider, actionInterpreter: interpreter)
        chat.spokenRepliesEnabled = false
        chat.actionPlanner = planner
        chat.composer = "turn down the volume of my Astrolab"
        chat.send(context: AssistantBackendFixture.context())
        try await AssistantBackendFixture.wait { !chat.isStreaming }
        let conversation = try #require(chat.selectedConversation)
        let response = try #require(conversation.messages.last)
        await store.save(conversation)
        chat.retry(messageID: response.id, context: AssistantBackendFixture.context())
        #expect(planner.intents.count == 1)
        chat.newConversation()
        #expect(planner.pendingReview == nil)
        chat.selectedConversationID = conversation.id
        let restoredPlanner = ReviewedChatPlanner()
        let restored = AssistantChatController(
            coordinator: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
            store: store, generator: provider, actionInterpreter: interpreter)
        restored.actionPlanner = restoredPlanner
        await restored.load()
        restored.selectedConversationID = conversation.id
        restored.retry(messageID: response.id, context: AssistantBackendFixture.context())
        #expect(restoredPlanner.intents.isEmpty)
        #expect(restoredPlanner.pendingReview == nil)
        let decoded = try JSONDecoder().decode(AssistantMessage.self, from: JSONEncoder().encode(response))
        #expect(decoded.cards == response.cards)
        chat.cancel()
        chat.deleteConversation(id: conversation.id)
        chat.clearAll()
        #expect(planner.pendingReview == nil)
        #expect(planner.confirmations == 0)
        #expect(restoredPlanner.confirmations == 0)
        #expect(provider.calls == 0)
    }

    private static let intent = AssistantActionIntent(targetMention: "Astrolab", action: .lower, amount: nil,
        addToStudio: false, evidence: .init(target: "Astrolab", action: "turn down", amount: nil, add: nil))

    private func makeChat(
        interpreter: any AssistantActionInterpreting, planner: ReviewedChatPlanner,
        provider: any AssistantGenerating, coordinator: AssistantCoordinator? = nil
    ) -> AssistantChatController {
        let chat = AssistantChatController(
            coordinator: coordinator ?? AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
            store: AssistantConversationStore(local: AssistantBackendHistoryStore(), cloud: nil),
            generator: provider, actionInterpreter: interpreter)
        chat.actionPlanner = planner
        chat.spokenRepliesEnabled = false
        return chat
    }
}

actor ReviewedChatInterpreter: AssistantActionInterpreting {
    let result: AssistantActionInterpretation
    let state: AssistantActionInterpreterAvailability
    let fails: Bool
    private(set) var requests: [AssistantActionInterpretationRequest] = []
    init(result: AssistantActionInterpretation, availability: AssistantActionInterpreterAvailability = .available,
         fails: Bool = false) {
        self.result = result
        self.state = availability
        self.fails = fails
    }
    func availability() -> AssistantActionInterpreterAvailability { state }
    func interpret(_ request: AssistantActionInterpretationRequest) throws -> AssistantActionInterpretation {
        requests.append(request)
        if fails { throw BackendTestError.send }
        return result
    }
}

actor ReviewedChatSuspendedInterpreter: AssistantActionInterpreting {
    private var continuation: CheckedContinuation<AssistantActionInterpretation, Never>?
    var isWaiting: Bool { continuation != nil }
    func availability() -> AssistantActionInterpreterAvailability { .available }
    func interpret(_ request: AssistantActionInterpretationRequest) async -> AssistantActionInterpretation {
        if request.text == "Hello" { return .answer }
        return await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        continuation?.resume(returning: .proposal(.init(targetMention: "Astrolab", action: .lower, amount: nil,
            addToStudio: false, evidence: .init(target: "Astrolab", action: "turn down", amount: nil, add: nil))))
        continuation = nil
    }
}

@MainActor
final class ReviewedChatPlanner: AssistantActionPlanning {
    var pendingReview: AssistantActionReview?
    var latestResult: AssistantActionResult?
    var intents: [AssistantActionIntent] = []
    var confirmations = 0
    var cancellations = 0
    var suspendNextPrepare = false
    var preserveNewerReviewOnResume = false
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    var isPreparingSuspended: Bool { preparationContinuation != nil }
    func resumePreparation() {
        preparationContinuation?.resume()
        preparationContinuation = nil
    }
    func prepare(_ request: AssistantActionInterpretationRequest,
                 interpretation: AssistantActionInterpretation) async -> AssistantActionPreparation {
        guard case .proposal(let intent) = interpretation else { return .answer }
        intents.append(intent)
        let suspended = suspendNextPrepare
        if suspended {
            suspendNextPrepare = false
            await withCheckedContinuation { preparationContinuation = $0 }
        }
        let review = AssistantActionReview(id: UUID(), submissionID: request.submissionID, stage: .ready,
            targetMention: intent.targetMention, candidates: [], selectedCandidateID: nil, target: nil,
            faderChanges: [], addsLiveShortcut: intent.addToStudio, suggestedAmountDB: nil,
            expiresAt: Date().addingTimeInterval(60), summary: "Review only; no changes", warnings: [])
        if !suspended || !preserveNewerReviewOnResume || pendingReview == nil { pendingReview = review }
        return .review(review)
    }
    func selectCandidate(reviewID: UUID, candidateID: String) async -> AssistantActionPreparation { .answer }
    func confirm(reviewID: UUID) async -> AssistantActionResult {
        confirmations += 1
        return .init(id: UUID(), reviewID: reviewID, localStatus: .notRequested, shortcutNodeID: nil,
                     members: [], message: "Unexpected confirmation")
    }
    func cancel() { cancellations += 1; pendingReview = nil }
}

private struct ReviewedChatCredentials: AssistantCredentialStore {
    func value(for account: String) -> String? { "offline-test-token" }
    func setValue(_ value: String, for account: String) throws {}
    func removeValue(for account: String) throws {}
}

private actor ReviewedChatHTTPSpy: AssistantHTTPClient {
    private(set) var calls = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        throw BackendTestError.send
    }
}
