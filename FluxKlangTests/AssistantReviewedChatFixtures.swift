import Foundation
@testable import FluxKlang

@MainActor
func withReviewedChatFixture(
    _ body: @MainActor (ReviewedChatFixture) async throws -> Void
) async throws {
    try await withAssistantFixtureResources { resources in
        let fixture = ReviewedChatFixture(resources: resources)
        resources.onFinish { await fixture.finish() }
        try await body(fixture)
    }
}

@MainActor
final class ReviewedChatFixture {
    let resources: AssistantFixtureResources
    private var chats: [AssistantChatController] = []
    private var generators: [AssistantFixtureReplyGenerator] = []
    private var planners: [ReviewedChatPlanner] = []
    private var interpreters: [ReviewedChatSuspendedInterpreter] = []

    init(resources: AssistantFixtureResources) {
        self.resources = resources
    }

    func replyGenerator() -> AssistantFixtureReplyGenerator {
        let generator = AssistantFixtureReplyGenerator()
        generators.append(generator)
        return generator
    }

    func makeChat(
        interpreter: any AssistantActionInterpreting, planner: any AssistantActionPlanning,
        provider: any AssistantGenerating, coordinator: AssistantCoordinator? = nil,
        store: AssistantConversationStore? = nil
    ) throws -> AssistantChatController {
        // Retain gate owners before the first throwing setup step.
        if let planner = planner as? ReviewedChatPlanner { planners.append(planner) }
        if let interpreter = interpreter as? ReviewedChatSuspendedInterpreter { interpreters.append(interpreter) }
        let defaults = try resources.defaults("spoken-\(chats.count)")
        let chat = AssistantChatController(
            coordinator: coordinator ?? AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
            store: store ?? AssistantConversationStore(local: AssistantBackendHistoryStore(), cloud: nil),
            generator: provider, actionInterpreter: interpreter, spokenRepliesDefaults: defaults)
        chats.append(chat)
        chat.actionPlanner = planner
        chat.spokenRepliesEnabled = false
        return chat
    }

    func finish() async {
        // Seal fake admission, then release all current gates permanently. Normal
        // test releases remain separate so late-effect assertions precede cancellation.
        for generator in generators { generator.close() }
        for planner in planners { planner.finishPreparation() }
        for interpreter in interpreters { await interpreter.finish() }
        for chat in chats { chat.cancel() }
        for generator in generators { await generator.join() }
        for chat in chats { await chat.awaitOwnedWorkSnapshot() }
        chats.removeAll()
        generators.removeAll()
        planners.removeAll()
        interpreters.removeAll()
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
    private var closed = false
    var isWaiting: Bool { continuation != nil }
    func availability() -> AssistantActionInterpreterAvailability { .available }
    func interpret(_ request: AssistantActionInterpretationRequest) async -> AssistantActionInterpretation {
        if request.text == "Hello" { return .answer }
        guard !closed else { return .answer }
        return await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        continuation?.resume(returning: .proposal(.init(targetMention: "Astrolab", action: .lower, amount: nil,
            addToStudio: false, evidence: .init(target: "Astrolab", action: "turn down", amount: nil, add: nil))))
        continuation = nil
    }
    func finish() {
        closed = true
        resume()
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
    private var preparationClosed = false
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    var isPreparingSuspended: Bool { preparationContinuation != nil }
    func resumePreparation() {
        preparationContinuation?.resume()
        preparationContinuation = nil
    }
    func finishPreparation() {
        preparationClosed = true
        suspendNextPrepare = false
        resumePreparation()
    }
    func prepare(_ request: AssistantActionInterpretationRequest,
                 interpretation: AssistantActionInterpretation) async -> AssistantActionPreparation {
        guard case .proposal(let intent) = interpretation else { return .answer }
        intents.append(intent)
        let suspended = suspendNextPrepare && !preparationClosed
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
