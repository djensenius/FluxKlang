import Foundation
@testable import FluxKlang

@MainActor
func withRoutingChatFixture(
    _ body: @MainActor (RoutingChatFixture) async throws -> Void
) async throws {
    try await withAssistantFixtureResources { resources in
        let owner = RoutingChatFixture(resources: resources)
        resources.onFinish { await owner.finish() }
        try await body(owner)
    }
}

@MainActor
final class RoutingChatFixture {
    let store = RoutingTestDraftStore()
    let coordinator: AssistantCoordinator
    let generator = AssistantFixtureReplyGenerator(reply: "read-only reply")
    private let resources: AssistantFixtureResources
    private var interpreter: RoutingTestInterpreter?
    private var chat: AssistantChatController?

    init(resources: AssistantFixtureResources) {
        self.resources = resources
        coordinator = AssistantCoordinator(draftStore: store)
    }

    func makeChat(
        interpreter: RoutingTestInterpreter = RoutingTestInterpreter(),
        generator: (any AssistantGenerating)? = nil
    ) throws -> AssistantChatController {
        // Own the gate before the first throwing defaults setup.
        self.interpreter = interpreter
        let chat = AssistantChatController(
            coordinator: coordinator,
            store: AssistantConversationStore(local: RoutingTestHistory(), cloud: nil),
            generator: generator ?? self.generator, actionInterpreter: interpreter,
            spokenRepliesDefaults: try resources.defaults("chat-spoken-replies"))
        self.chat = chat
        return chat
    }

    func finish() async {
        // The body has stopped submitting. Seal fake admission, disarm/release
        // gates, and join workers/producers before the wrapper removes defaults.
        generator.close()
        chat?.cancel()
        await interpreter?.finish()
        await store.finish()
        await generator.join()
        await chat?.awaitOwnedWorkSnapshot()
        chat = nil
        interpreter = nil
    }
}

actor RoutingTestInterpreter: AssistantActionInterpreting {
    var result: AssistantActionInterpretation
    var available: AssistantActionInterpreterAvailability
    var fails: Bool
    var suspend: Bool
    private var closed = false
    private(set) var requests: [AssistantActionInterpretationRequest] = []
    private var gate: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { gate != nil }
    init(_ result: AssistantActionInterpretation = .routing(AssistantRoutingFixture.intent),
         available: AssistantActionInterpreterAvailability = .available, fails: Bool = false, suspend: Bool = false) {
        self.result = result
        self.available = available
        self.fails = fails
        self.suspend = suspend
    }

    func availability() -> AssistantActionInterpreterAvailability { available }
    func interpret(_ request: AssistantActionInterpretationRequest) async throws -> AssistantActionInterpretation {
        requests.append(request)
        if suspend && !closed { await withCheckedContinuation { gate = $0 } }
        if fails { throw RoutingTestError.model }
        return result
    }
    func resume() { gate?.resume(); gate = nil }
    func finish() {
        closed = true
        suspend = false
        resume()
    }
}

actor RoutingTestDraftStore: PendingStudioPatchPersisting {
    private(set) var draft: StudioPatchDraft?
    private(set) var saves = 0
    private var pauseNext = false
    private var closed = false
    private var gates: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { !gates.isEmpty }
    var waitingSaves: Int { gates.count }
    func pauseNextSave() {
        guard !closed else { return }
        pauseNext = true
    }
    func resume() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }
    func load() -> StudioPatchDraft? { draft }
    func save(_ draft: StudioPatchDraft?) async {
        saves += 1
        if pauseNext && !closed {
            pauseNext = false
            await withCheckedContinuation { gates.append($0) }
        }
        // Unlike the validation store, assignment remains AFTER suspension.
        self.draft = draft
    }
    func finish() {
        closed = true
        pauseNext = false
        let pending = gates
        gates.removeAll()
        for gate in pending { gate.resume() }
    }
}
