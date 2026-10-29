import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct AssistantRoutingOwnershipTests {
    @Test(arguments: [
        "inputs and outputs for Osmose", "inputs and outputs please", "please ins and outs for Osmose?"
    ])
    func qualifiedInventoryRemainsReadOnly(text: String) async throws {
        #expect(AssistantDraftIntent.requestsInventory(text))
        #expect(!AssistantRoutingOwnership.owns(text))
        let fixture = AssistantRoutingFixture()
        let store = RoutingTestDraftStore()
        let coordinator = AssistantCoordinator(draftStore: store)
        let prior = try fixture.prepared()
        #expect(await coordinator.commitPreparedRouting(prior, expectedPending: nil,
            preparedContext: fixture.context, currentContext: fixture.context))
        let interpreter = RoutingTestInterpreter()
        let downstream = RoutingTestGenerator()
        let chat = makeChat(coordinator: coordinator, interpreter: interpreter,
            generator: AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: downstream))
        chat.composer = text
        chat.send(context: fixture.context)
        try await AssistantBackendFixture.wait { !chat.isStreaming }
        #expect(chat.selectedConversation?.messages.last?.text.contains("WING inputs") == true)
        #expect(await interpreter.requests.isEmpty)
        #expect(await downstream.calls == 0)
        #expect(coordinator.pendingStudioDraft == prior)
        #expect(await store.saves == 1)
    }

    @Test(arguments: ["Dry Synth", "Monitor", "Wet", "Desk", "Astrolab"])
    func conversationalMixerLabelsReachReviewedPlanner(label: String) async throws {
        let text = "turn down the volume of my \(label)"
        let intent = AssistantActionIntent(targetMention: label, action: .lower, amount: nil,
            addToStudio: false, evidence: .init(target: label, action: "turn down", amount: nil, add: nil))
        #expect(AssistantActionIntentValidator.clarification(for: intent, text: text) == nil)
        #expect(!AssistantRoutingOwnership.owns(text))
        if case .command = AssistantMixerIntent.parse(text) {
            Issue.record("Conversational request must not depend on the strict mixer grammar")
        }
        try await expectReviewed(text: text, intent: intent)
    }

    @Test(arguments: [
        "add my Astrolab to the studio", "include my Astrolab to my canvas",
        "please add my Astrolab to the canvas", "add my Dry Synth to the studio"
    ])
    func validatedLiveShortcutAdditionsReachReviewedPlanner(text: String) async throws {
        let label = text.contains("Dry Synth") ? "Dry Synth" : "Astrolab"
        let intent = AssistantActionIntent(targetMention: label, action: nil, amount: nil, addToStudio: true,
            evidence: .init(target: label, action: nil, amount: nil, add: text.contains("include") ? "include" : "add"))
        #expect(AssistantActionIntentValidator.clarification(for: intent, text: text) == nil)
        #expect(!AssistantRoutingOwnership.owns(text))
        try await expectReviewed(text: text, intent: intent)
    }

    @Test(arguments: [
        "inputs and outputs and route Osmose to PA", "inputs and outputs for Osmose through Evil Pet",
        "inputs and outputs please and add Osmose to PA", "add Osmose to PA",
        "add my Astrolab and Osmose to the studio", "add my Astrolab to the studio and route Osmose to PA",
        "add my Astrolab to the studio; connect Osmose to PA",
        "turn down the volume of my Dry Synth and route Osmose to PA",
        "turn down the volume of my Dry Synth through Evil Pet",
        "turn down the volume of my Dry Synth to mains",
        "use Osmose through evil pet and Solar dry and wet in parallel to mains"
    ])
    func physicalAndCompoundRequestsStayRoutingOwnedAndFailClosed(text: String) async throws {
        #expect(AssistantRoutingOwnership.owns(text))
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
        let interpreter = RoutingTestInterpreter(.answer)
        let generator = RoutingTestGenerator()
        let chat = makeChat(coordinator: coordinator, interpreter: interpreter, generator: generator)
        let planner = ReviewedChatPlanner()
        chat.actionPlanner = planner
        let legacy = AssistantRecordingMixerExecutor()
        chat.mixerExecutor = legacy
        chat.composer = text
        chat.send(context: AssistantRoutingFixture().context)
        try await AssistantBackendFixture.wait { !chat.isStreaming }
        #expect(await interpreter.requests.map(\.text) == [text])
        #expect(await generator.calls == 0)
        #expect(planner.intents.isEmpty)
        #expect(planner.confirmations == 0)
        #expect(legacy.commands.isEmpty)
        #expect(coordinator.pendingStudioDraft == nil)
    }

    private func expectReviewed(text: String, intent: AssistantActionIntent) async throws {
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
        let interpreter = RoutingTestInterpreter(.proposal(intent))
        let generator = RoutingTestGenerator()
        let chat = makeChat(coordinator: coordinator, interpreter: interpreter, generator: generator)
        let planner = ReviewedChatPlanner()
        chat.actionPlanner = planner
        let legacy = AssistantRecordingMixerExecutor()
        chat.mixerExecutor = legacy
        chat.composer = text
        chat.send(context: AssistantRoutingFixture().context)
        try await AssistantBackendFixture.wait { !chat.isStreaming }
        #expect(await interpreter.requests.map(\.text) == [text])
        #expect(planner.intents == [intent])
        #expect(planner.pendingReview != nil)
        #expect(planner.confirmations == 0)
        #expect(legacy.commands.isEmpty)
        #expect(await generator.calls == 0)
        #expect(coordinator.pendingStudioDraft == nil)
    }

    private func makeChat(coordinator: AssistantCoordinator, interpreter: RoutingTestInterpreter,
                          generator: any AssistantGenerating) -> AssistantChatController {
        let chat = AssistantChatController(coordinator: coordinator,
            store: AssistantConversationStore(local: RoutingTestHistory(), cloud: nil),
            generator: generator, actionInterpreter: interpreter)
        chat.spokenRepliesEnabled = false
        return chat
    }
}
