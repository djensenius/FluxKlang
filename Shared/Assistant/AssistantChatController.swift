import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AssistantChatController {
    private let store: AssistantConversationStore
    private let generator: any AssistantGenerating
    private let coordinator: AssistantCoordinator
    private var responseTask: Task<Void, Never>?
    private var hasLoaded = false

    private(set) var conversations: [AssistantConversation] = []
    var selectedConversationID: UUID?
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

    private let synthesizer = AVSpeechSynthesizer()
    private static let spokenRepliesKey = "assistant.spokenReplies"

    init(
        coordinator: AssistantCoordinator,
        store: AssistantConversationStore = .live(),
        generator: (any AssistantGenerating)? = nil
    ) {
        self.coordinator = coordinator
        self.store = store
        let fallback = AssistantFallbackGenerator(coordinator: coordinator)
        self.generator = generator ?? AssistantGeneratorRouter(
            model: FoundationModelAssistantGenerator(coordinator: coordinator),
            fallback: fallback
        )
        spokenRepliesEnabled = UserDefaults.standard.bool(forKey: Self.spokenRepliesKey)
    }

    var selectedConversation: AssistantConversation? {
        guard let selectedConversationID else { return conversations.first }
        return conversations.first { $0.id == selectedConversationID }
    }

    func load() async {
        guard !hasLoaded else { return }
        conversations = await store.load()
        selectedConversationID = conversations.first?.id
        persistenceDiagnostics = await store.diagnostics
        modelAvailability = await generator.availability()
        hasLoaded = true
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

    func retry(messageID: UUID, context: AssistantToolContext) {
        guard let conversation = selectedConversation,
              let failedIndex = conversation.messages.firstIndex(where: { $0.id == messageID }),
              failedIndex > 0 else { return }
        let question = conversation.messages[..<failedIndex].last { $0.role == .user }?.text
        guard let question else { return }
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
        isStreaming = true
        responseTask = Task {
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
                isStreaming = false
                responseTask = nil
            }
        }
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
        isStreaming = false
        responseTask = nil
        if state == .complete, spokenRepliesEnabled, let spokenText, !spokenText.isEmpty {
            synthesizer.speak(AVSpeechUtterance(string: spokenText))
        }
    }

    private func stopStreaming() {
        responseTask?.cancel()
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
