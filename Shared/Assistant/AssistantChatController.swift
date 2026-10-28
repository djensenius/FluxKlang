import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AssistantChatController {
    private let store: AssistantConversationStore
    private let generator: any AssistantGenerating
    private let actionInterpreter: any AssistantActionInterpreting
    private let coordinator: AssistantCoordinator
    private var responseTask: Task<Void, Never>?
    private var activeResponseID: UUID?
    private var hasLoaded = false
    private var lastSiriRequest: String?

    /// Explicit submission-only capability, never passed to a model/provider.
    var mixerExecutor: (any AssistantMixerExecuting)?
    /// Production uses reviewed planning only; the legacy executor is never reached when this is installed.
    var actionPlanner: (any AssistantActionPlanning)?

    private(set) var conversations: [AssistantConversation] = []
    var selectedConversationID: UUID? {
        didSet {
            if selectedConversationID != oldValue { stopStreaming() }
        }
    }
    var composer = ""
    private(set) var isStreaming = false
    private(set) var modelAvailability: AssistantModelAvailability = .unsupportedOS
    private(set) var persistenceDiagnostics: [String] = []
    var suggestedPrompt: String?
    var spokenRepliesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(spokenRepliesEnabled, forKey: Self.spokenRepliesKey)
        }
    }

    @ObservationIgnored private lazy var synthesizer = AVSpeechSynthesizer()
    private static let spokenRepliesKey = "assistant.spokenReplies"
    private static var forcesFallbackForUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-test-force-fallback")
    }

    init(
        coordinator: AssistantCoordinator,
        store: AssistantConversationStore = .live(),
        generator: (any AssistantGenerating)? = nil,
        actionInterpreter: (any AssistantActionInterpreting)? = nil
    ) {
        self.coordinator = coordinator
        self.store = store
        self.actionInterpreter = actionInterpreter ?? FoundationModelActionInterpreter()
        let fallback = AssistantFallbackGenerator(coordinator: coordinator)
        if Self.forcesFallbackForUITesting {
            self.generator = AssistantDraftPreflightGenerator(
                coordinator: coordinator,
                downstream: fallback
            )
        } else if let generator {
            self.generator = AssistantDraftPreflightGenerator(
                coordinator: coordinator,
                downstream: generator
            )
        } else {
            self.generator = AssistantDraftPreflightGenerator(
                coordinator: coordinator,
                downstream: AssistantGeneratorRouter(
                    model: FoundationModelAssistantGenerator(coordinator: coordinator),
                    fallback: fallback
                )
            )
        }
        spokenRepliesEnabled = UserDefaults.standard.bool(forKey: Self.spokenRepliesKey)
    }

    var selectedConversation: AssistantConversation? {
        guard let selectedConversationID else { return conversations.first }
        return conversations.first { $0.id == selectedConversationID }
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        conversations = await store.load()
        selectedConversationID = conversations.first?.id
        persistenceDiagnostics = await store.diagnostics
        await refreshAvailability()
    }

    func refreshAvailability() async {
        modelAvailability = await generator.availability()
    }

    func newConversation() {
        let conversation = AssistantConversation()
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        Task { await store.save(conversation) }
    }

    func renameConversation(id: UUID, to title: String) {
        updateConversation(id: id) { conversation in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            conversation.title = String(trimmed.prefix(80))
        }
    }

    func deleteConversation(id: UUID) {
        stopStreaming()
        conversations.removeAll { $0.id == id }
        selectedConversationID = conversations.first?.id
        Task { await store.delete(id: id) }
    }

    func clearAll() {
        stopStreaming()
        let removed = conversations
        conversations = []
        selectedConversationID = nil
        Task { await store.clearAll(removed) }
    }

    func submitSuggestedPrompt(_ prompt: String) {
        composer = prompt
        suggestedPrompt = nil
    }

    func send(context: AssistantToolContext) {
        let question = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }
        composer = ""
        send(question: question, context: context)
    }

    /// Siri stages input only. Send uses the same Apple interpretation/review pipeline as typing.
    func stageSiriRequest(_ rawRequest: String) -> String {
        let request = rawRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, request.count <= AssistantActionInterpretationAdapter.maximumTextLength else {
            return "No request was staged. Use 1 to 2,000 characters in FluxKlang; no WING changes were made."
        }
        if request == lastSiriRequest {
            return "This request was already delivered. Review in FluxKlang; no WING changes were made."
        }
        guard !isStreaming, composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "FluxKlang is busy or has unsent text. Your text was not replaced; no WING changes were made."
        }
        actionPlanner?.cancel()
        lastSiriRequest = request
        composer = request
        return "Review in FluxKlang and tap Send to interpret your request; no WING changes were made."
    }

    func retry(messageID: UUID, context: AssistantToolContext) {
        guard let conversation = selectedConversation,
              let failedIndex = conversation.messages.firstIndex(where: { $0.id == messageID }),
              failedIndex > 0 else { return }
        // Persisted review cards are display-only and never a retry/confirmation capability.
        guard !conversation.messages[failedIndex].cards.contains(where: {
            if case .actionReview = $0 { return true }
            return false
        }) else { return }
        let question = conversation.messages[..<failedIndex].last { $0.role == .user }?.text
        guard let question, !isStreaming else { return }
        // Classify again rather than relying on ephemeral message state: this
        // also prevents replay from restored or cancelled command history.
        guard case .notMixerIntent = AssistantMixerIntent.parse(question) else { return }
        updateConversation(id: conversation.id) {
            $0.messages.remove(at: failedIndex)
        }
        send(question: question, context: context, appendingQuestion: false)
    }

    func cancel() {
        stopStreaming()
    }

    func createWiringDraft(
        sourceIDs: [Equipment.ID],
        effectIDs: [Effect.ID],
        destination: StudioEndpointDestination,
        context: AssistantToolContext
    ) {
        actionPlanner?.cancel()
        ensureConversation()
        guard let id = selectedConversationID else { return }
        Task {
            let result = await coordinator.perform(
                .buildStudioDraft(StudioWiringRequest(
                    sourceInstrumentIDs: sourceIDs,
                    effectChainIDs: effectIDs,
                    destination: destination
                )),
                context: context
            )
            let text = (try? AssistantFallbackResponder.response(
                to: .live("Build pending draft", requires: [.pendingDraft]),
                groundedBy: [result]
            )) ?? "A pending Studio draft is ready for review."
            let cards = Self.cards(for: coordinator.pendingStudioDraft)
            updateConversation(id: id) {
                $0.messages.append(AssistantMessage(role: .assistant, text: text, cards: cards))
            }
            SiriEntityIntegration.donateDraft(
                sourceIDs: sourceIDs,
                effectIDs: effectIDs,
                destination: destination,
                context: context
            )
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func send(
        question: String,
        context: AssistantToolContext,
        appendingQuestion: Bool = true
    ) {
        ensureConversation()
        guard let conversationID = selectedConversationID else { return }
        let userMessage = AssistantMessage(role: .user, text: question)
        let responseID = UUID()
        updateConversation(id: conversationID) {
            if appendingQuestion {
                $0.messages.append(userMessage)
            }
            $0.messages.append(AssistantMessage(
                id: responseID,
                role: .assistant,
                text: "",
                state: .streaming
            ))
            if $0.title == "New Conversation" {
                $0.title = String(question.prefix(48))
            }
        }
        let conversation = conversations.first { $0.id == conversationID }
        let request = AssistantGenerationRequest(
            question: question,
            recentMessages: Array(conversation?.messages.dropLast(2) ?? []),
            summary: conversation?.summary ?? "",
            context: context
        )
        actionPlanner?.cancel()
        isStreaming = true
        activeResponseID = responseID
        responseTask = Task {
            if let actionPlanner {
                do {
                    let handled = try await handleReviewedSubmission(
                        question: question, context: context, planner: actionPlanner,
                        conversationID: conversationID, responseID: responseID)
                    if handled { return }
                } catch {
                    finishResponse(conversationID: conversationID, responseID: responseID, state: .cancelled)
                    return
                }
            } else {
                // Compatibility for isolated legacy tests/callers without a planning service.
                switch AssistantMixerIntent.parse(question) {
                case .clarification(let text):
                    apply(.text(text), conversationID: conversationID, responseID: responseID)
                    finishResponse(conversationID: conversationID, responseID: responseID, state: .complete)
                    return
                case .command(let command):
                    let text: String
                    if Task.isCancelled {
                        text = "No mixer command was started: submission was cancelled."
                    } else if let mixerExecutor {
                        text = await mixerExecutor.execute(command, sessionID: context.liveWing.sessionID)
                    } else {
                        text = "No changes: live mixer execution is not configured."
                    }
                    apply(.text(text), conversationID: conversationID, responseID: responseID)
                    // Always retain the truthful outcome even if cancelled after SET.
                    finishResponse(conversationID: conversationID, responseID: responseID, state: .complete)
                    return
                case .notMixerIntent: break
                }
            }
            do {
                for try await event in generator.stream(request) {
                    try Task.checkCancellation()
                    apply(event, conversationID: conversationID, responseID: responseID)
                }
                finishResponse(conversationID: conversationID, responseID: responseID, state: .complete)
            } catch is CancellationError {
                finishResponse(conversationID: conversationID, responseID: responseID, state: .cancelled)
            } catch {
                updateConversation(id: conversationID) { conversation in
                    guard let index = conversation.messages.firstIndex(where: { $0.id == responseID })
                    else { return }
                    conversation.messages[index].state = .failed
                    if conversation.messages[index].text.isEmpty {
                        conversation.messages[index].text = error.localizedDescription
                    }
                }
                if activeResponseID == responseID {
                    activeResponseID = nil
                    isStreaming = false
                    responseTask = nil
                }
            }
        }
    }

    private func handleReviewedSubmission(
        question: String, context: AssistantToolContext, planner: any AssistantActionPlanning,
        conversationID: UUID, responseID: UUID
    ) async throws -> Bool {
        let request = AssistantActionInterpretationRequest(text: question, liveContext: context.liveWing)
        let (interpretation, notice) = try await interpretAction(request)
        try Task.checkCancellation()
        guard activeResponseID == responseID else { throw CancellationError() }
        let preparation: AssistantActionPreparation
        switch interpretation {
        case .answer: return false
        case .clarification(let text): preparation = .clarification(text)
        case .proposal:
            preparation = await planner.prepare(request, interpretation: interpretation)
        }
        try Task.checkCancellation()
        guard activeResponseID == responseID else { throw CancellationError() }
        switch preparation {
        case .answer: return false
        case .clarification(let text):
            apply(.text(text), conversationID: conversationID, responseID: responseID)
        case .review(let review):
            let text = [notice, review.summary].compactMap { $0 }.joined(separator: "\n\n")
            apply(.text(text), conversationID: conversationID, responseID: responseID)
            apply(.cards([.actionReview(id: review.id, summary: review.summary)]),
                  conversationID: conversationID, responseID: responseID)
        }
        finishResponse(conversationID: conversationID, responseID: responseID, state: .complete)
        return true
    }

    private func interpretAction(
        _ request: AssistantActionInterpretationRequest
    ) async throws -> (AssistantActionInterpretation, String?) {
        let reason: String
        switch await actionInterpreter.availability() {
        case .available:
            do {
                return (try await actionInterpreter.interpret(request), nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reason = "on-device interpretation failed (\(String(error.localizedDescription.prefix(160))))"
            }
        case .unavailable(let message): reason = message
        }
        try Task.checkCancellation()
        return (AssistantActionInterpretationAdapter.fallback(request, reason: reason),
                "Apple command understanding is unavailable: \(String(reason.prefix(240))). "
                    + "This preview used the local exact-command grammar. No changes were made.")
    }

    private func apply(
        _ event: AssistantStreamEvent,
        conversationID: UUID,
        responseID: UUID
    ) {
        updateStreamingConversation(id: conversationID) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == responseID })
            else { return }
            switch event {
            case .text(let text):
                conversation.messages[index].text = text
            case .cards(let cards):
                conversation.messages[index].cards = cards
            }
        }
    }

    private func finishResponse(
        conversationID: UUID,
        responseID: UUID,
        state: AssistantMessage.State
    ) {
        var spokenText: String?
        updateConversation(id: conversationID) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == responseID })
            else { return }
            conversation.messages[index].state = state
            conversation.summary = Self.summary(for: conversation.messages)
            spokenText = conversation.messages[index].text
        }
        guard activeResponseID == responseID else { return }
        activeResponseID = nil
        isStreaming = false
        responseTask = nil
        if state == .complete, spokenRepliesEnabled, let spokenText, !spokenText.isEmpty {
            synthesizer.speak(AVSpeechUtterance(string: spokenText))
        }
    }

    private func stopStreaming() {
        actionPlanner?.cancel()
        responseTask?.cancel()
        activeResponseID = nil
        responseTask = nil
        isStreaming = false
    }

    private func ensureConversation() {
        if let selectedConversationID,
           conversations.contains(where: { $0.id == selectedConversationID }) {
            return
        }
        guard let conversation = conversations.first else {
            newConversation()
            return
        }
        selectedConversationID = conversation.id
    }

    private func updateConversation(
        id: UUID,
        mutation: (inout AssistantConversation) -> Void
    ) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let original = conversations[index]
        var conversation = original
        mutation(&conversation)
        guard conversation != original else { return }
        conversation.modifiedAt = Date()
        conversations[index] = conversation
        conversations.sort { $0.modifiedAt > $1.modifiedAt }
        Task { await store.save(conversation) }
    }

    private func updateStreamingConversation(
        id: UUID,
        mutation: (inout AssistantConversation) -> Void
    ) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        mutation(&conversations[index])
    }
}

extension AssistantChatController {
    private static func summary(for messages: [AssistantMessage]) -> String {
        messages.suffix(12).map {
            "\($0.role.rawValue): \(String($0.text.prefix(240)))"
        }.joined(separator: "\n").suffix(1_800).description
    }

    private static func cards(for draft: StudioPatchDraft?) -> [AssistantCard] {
        guard let draft else { return [] }
        var result: [AssistantCard] = [
            .wiring(
                summary: draft.logicalRoutingSummary.map(\.value),
                cableInstructions: draft.cableInstructions.map(\.instruction.value)
            ),
            .pendingDraft(
                id: draft.id,
                summary: draft.logicalRoutingSummary.map(\.value).joined(separator: "\n"),
                hasErrors: draft.hasErrors
            )
        ]
        if !draft.validation.isEmpty {
            result.append(.conflicts(draft.validation.map(\.message)))
        }
        return result
    }
}
