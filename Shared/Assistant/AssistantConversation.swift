import Foundation

struct AssistantConversation: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var summary: String
    var messages: [AssistantMessage]

    init(
        id: UUID = UUID(),
        title: String = "New Conversation",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        summary: String = "",
        messages: [AssistantMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.summary = summary
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, modifiedAt, summary, messages
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        messages = try container.decodeIfPresent([AssistantMessage].self, forKey: .messages) ?? []
    }
}

struct AssistantMessage: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Hashable, Sendable {
        case user
        case assistant
    }

    enum State: String, Codable, Hashable, Sendable {
        case complete
        case streaming
        case cancelled
        case failed
    }

    var id: UUID
    var role: Role
    var text: String
    var createdAt: Date
    var state: State
    var cards: [AssistantCard]

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        state: State = .complete,
        cards: [AssistantCard] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.state = state
        self.cards = cards
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, createdAt, state, cards
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .complete
        cards = try container.decodeIfPresent([AssistantCard].self, forKey: .cards) ?? []
    }
}

enum AssistantCard: Codable, Hashable, Sendable {
    case help(topic: AssistantHelpTopic, title: String, overview: String)
    case wiring(summary: [String], cableInstructions: [String])
    case conflicts([String])
    case moves([String])
    case pendingDraft(id: UUID, summary: String, hasErrors: Bool)
}

struct AssistantConversationRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var conversation: AssistantConversation?
    var modifiedAt: Date
    var deletedAt: Date?

    init(conversation: AssistantConversation) {
        id = conversation.id
        self.conversation = conversation
        modifiedAt = conversation.modifiedAt
        deletedAt = nil
    }

    init(tombstone id: UUID, deletedAt: Date) {
        self.id = id
        conversation = nil
        modifiedAt = deletedAt
        self.deletedAt = deletedAt
    }
}

enum AssistantModelAvailability: Equatable, Sendable {
    case ready
    case deviceNotEligible
    case intelligenceDisabled
    case modelNotReady
    case unsupportedOS
    case failed(String)

    var title: String {
        switch self {
        case .ready: "On-device model ready"
        case .deviceNotEligible: "This device is not eligible"
        case .intelligenceDisabled: "Apple Intelligence is turned off"
        case .modelNotReady: "The on-device model is not ready"
        case .unsupportedOS: "On-device generation requires OS 27"
        case .failed: "On-device model unavailable"
        }
    }

    var usesFallback: Bool { self != .ready }
}

struct AssistantGenerationRequest: Sendable {
    var question: String
    var recentMessages: [AssistantMessage]
    var summary: String
    var context: AssistantToolContext
}

enum AssistantStreamEvent: Sendable {
    case text(String)
    case cards([AssistantCard])
}

protocol AssistantGenerating: Sendable {
    func availability() async -> AssistantModelAvailability
    func stream(_ request: AssistantGenerationRequest) -> AsyncThrowingStream<AssistantStreamEvent, any Error>
}
