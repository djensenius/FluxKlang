import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct AskFluxKlangIntentTests {
    @Test func siriStagesBoundedRawRequestNavigatesAndNeverAcceptsOrWrites() {
        let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
        let model = AppModel(assistant: coordinator, wing: .preview())
        let planner = ReviewedChatPlanner()
        model.assistantChat.actionPlanner = planner
        let beforeGraph = model.environments.activeStudioGraph
        let beforeValues = model.wing.values
        let writesBefore = model.wing.transportWriteCount
        let request = "add my mother-32 and turn the volume to 50%"
        let dialog = SiriAssistantRequestAction.stage(request: request, model: model)
        #expect(model.section == .assistant)
        #expect(model.assistantChat.composer == request)
        #expect(dialog.contains("tap Send"))
        #expect(dialog.contains("no WING changes"))
        #expect(!model.assistantChat.isStreaming)
        #expect(planner.intents.isEmpty)
        #expect(planner.confirmations == 0)
        #expect(coordinator.pendingStudioDraft == nil)
        #expect(model.environments.activeStudioGraph == beforeGraph)
        #expect(model.wing.values == beforeValues)
        #expect(model.wing.transportWriteCount == writesBefore)
        let repeated = SiriAssistantRequestAction.stage(request: request, model: model)
        #expect(repeated.contains("already delivered"))
        #expect(model.assistantChat.composer == request)
        model.assistantChat.composer = ""
        #expect(SiriAssistantRequestAction.stage(request: request, model: model).contains("tap Send"))
        #expect(model.assistantChat.composer == request)
        #expect(model.wing.transportWriteCount == writesBefore)
        #expect(planner.confirmations == 0)
        let intent = AskFluxKlangIntent(request: request)
        #expect(intent.request == request)
        #expect(AskFluxKlangIntent.openAppWhenRun)
    }

    @Test func siriDoesNotReplaceUnsentTextOrTruncateOversizedRequests() {
        let model = AppModel(
            assistant: AssistantCoordinator(draftStore: AssistantBackendDraftStore()), wing: .preview())
        model.assistantChat.composer = "Keep this unsent text"
        let dialog = SiriAssistantRequestAction.stage(request: "mute Astrolab", model: model)
        #expect(dialog.contains("not replaced"))
        #expect(model.assistantChat.composer == "Keep this unsent text")
        model.assistantChat.composer = ""
        #expect(SiriAssistantRequestAction.stage(request: String(repeating: "x", count: 2_001), model: model)
            .contains("No request was staged"))
        #expect(SiriAssistantRequestAction.stage(request: " \n ", model: model).contains("No request was staged"))
        #expect(model.assistantChat.composer.isEmpty)
        #expect(model.wing.transportWriteCount == 0)
    }

    @Test func sameSiriRequestCanBeStagedAgainAfterSendWithoutAutomaticReplay() async throws {
        let planner = ReviewedChatPlanner()
        let chat = AssistantChatController(coordinator: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
            store: AssistantConversationStore(local: AssistantBackendHistoryStore(), cloud: nil),
            generator: AssistantBackendGenerator(), actionInterpreter: ReviewedChatInterpreter(result: .proposal(.init(
                targetMention: "Astrolab", action: .mute, amount: nil, addToStudio: false,
                evidence: .init(target: "Astrolab", action: "mute", amount: nil, add: nil)))))
        chat.spokenRepliesEnabled = false
        chat.actionPlanner = planner
        #expect(chat.stageSiriRequest("mute Astrolab").contains("tap Send"))
        chat.send(context: AssistantBackendFixture.context())
        try await AssistantBackendFixture.wait { !chat.isStreaming }
        #expect(planner.intents.count == 1)
        #expect(chat.stageSiriRequest("mute Astrolab").contains("tap Send"))
        #expect(planner.intents.count == 1)
        #expect(planner.confirmations == 0)
        #expect(planner.pendingReview == nil)
    }

    @Test func busySiriHandoffDoesNotCancelOrReplaceActiveSubmission() async throws {
        let interpreter = ReviewedChatSuspendedInterpreter()
        let planner = ReviewedChatPlanner()
        let chat = AssistantChatController(coordinator: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
            store: AssistantConversationStore(local: AssistantBackendHistoryStore(), cloud: nil),
            generator: AssistantBackendGenerator(), actionInterpreter: interpreter)
        chat.spokenRepliesEnabled = false
        chat.actionPlanner = planner
        chat.composer = "turn down the volume of my Astrolab"
        chat.send(context: AssistantBackendFixture.context())
        try await AssistantBackendFixture.waitAsync { await interpreter.isWaiting }
        let cancellations = planner.cancellations
        let dialog = chat.stageSiriRequest("mute mother-32")
        #expect(dialog.contains("busy"))
        #expect(chat.isStreaming)
        #expect(chat.composer.isEmpty)
        #expect(planner.cancellations == cancellations)
        await interpreter.resume()
        try await AssistantBackendFixture.wait { !chat.isStreaming }
        #expect(planner.intents.count == 1)
        #expect(planner.confirmations == 0)
        #expect(chat.stageSiriRequest("mute mother-32").contains("tap Send"))
        #expect(planner.pendingReview == nil)
        #expect(planner.confirmations == 0)
        #expect(chat.composer == "mute mother-32")
    }
}
