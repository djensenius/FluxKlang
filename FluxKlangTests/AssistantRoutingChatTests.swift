import Foundation
import Testing
@testable import FluxKlang

actor RoutingTestInterpreter: AssistantActionInterpreting {
    var result: AssistantActionInterpretation
    var available: AssistantActionInterpreterAvailability
    var fails: Bool
    var suspend: Bool
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
        if suspend { await withCheckedContinuation { gate = $0 } }
        if fails { throw RoutingTestError.model }
        return result
    }
    func resume() { gate?.resume(); gate = nil }
}

actor RoutingTestDraftStore: PendingStudioPatchPersisting {
    private(set) var draft: StudioPatchDraft?
    private(set) var saves = 0
    func load() -> StudioPatchDraft? { draft }
    func save(_ draft: StudioPatchDraft?) { self.draft = draft; saves += 1 }
}

actor RoutingTestHistory: AssistantHistoryBackend {
    func loadRecords() -> [AssistantConversationRecord] { [] }
    func save(_ record: AssistantConversationRecord) {}
}

actor RoutingTestGenerator: AssistantGenerating {
    private(set) var calls = 0
    func availability() -> AssistantModelAvailability { .ready }
    nonisolated func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await record()
                continuation.yield(.text("read-only reply"))
                continuation.finish()
            }
        }
    }
    private func record() { calls += 1 }
}

@MainActor
struct AssistantRoutingChatTests {
    private func chat(coordinator: AssistantCoordinator, interpreter: any AssistantActionInterpreting,
                      generator: any AssistantGenerating) -> AssistantChatController {
        AssistantChatController(coordinator: coordinator,
            store: AssistantConversationStore(local: RoutingTestHistory(), cloud: nil), generator: generator,
            actionInterpreter: interpreter)
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw RoutingTestError.notPrepared }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func routingWorksWithoutMixerPlannerAndBeforePreflightOrProvider() async throws {
        let fixture = AssistantRoutingFixture()
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
        let interpreter = RoutingTestInterpreter()
        let generator = RoutingTestGenerator()
        let chat = chat(coordinator: coordinator, interpreter: interpreter, generator: generator)
        chat.composer = AssistantRoutingFixture.text
        chat.send(context: fixture.context)
        try await wait { !chat.isStreaming }
        let draft = try #require(coordinator.pendingStudioDraft)
        #expect(draft.request.additionalRoutes.count == 2)
        #expect(chat.selectedConversation?.messages.last?.cards.count == 2)
        #expect(await interpreter.requests.map(\.text) == [AssistantRoutingFixture.text])
        #expect(await generator.calls == 0)
        #expect(chat.actionPlanner == nil)
    }

    @Test func badDisabledErrorPartialAnswerAndMonoMisclassificationNeverMutateOrFallThrough() async throws {
        let fixture = AssistantRoutingFixture()
        var partial = AssistantRoutingFixture.intent
        partial.branches.removeLast()
        let mono = AssistantActionIntent(targetMention: "Osmose", action: .lower, amount: nil, addToStudio: false,
            evidence: .init(target: "Osmose", action: "use", amount: nil, add: nil))
        let interpreters: [RoutingTestInterpreter] = [
            .init(.answer), .init(.proposal(mono)), .init(.clarification("Which route?")), .init(.routing(partial)),
            .init(available: .unavailable("disabled")), .init(fails: true)
        ]
        for interpreter in interpreters {
            let store = RoutingTestDraftStore()
            let coordinator = AssistantCoordinator(draftStore: store)
            let prior = try fixture.prepared()
            #expect(await coordinator.commitPreparedRouting(prior, expectedPending: nil,
                preparedContext: fixture.context, currentContext: fixture.context))
            let generator = RoutingTestGenerator()
            let chat = chat(coordinator: coordinator, interpreter: interpreter, generator: generator)
            chat.composer = AssistantRoutingFixture.text
            chat.send(context: fixture.context)
            try await wait { !chat.isStreaming }
            #expect(coordinator.pendingStudioDraft == prior)
            #expect(await store.saves == 1)
            #expect(await generator.calls == 0)
            #expect(chat.selectedConversation?.messages.last?.cards.isEmpty == true)
        }
    }

    @Test func mixedRoutingAndLiveFaderRequestCannotCommitAPartialRoutingDraft() async throws {
        let fixture = AssistantRoutingFixture()
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
        let prior = try fixture.prepared()
        #expect(await coordinator.commitPreparedRouting(prior, expectedPending: nil,
            preparedContext: fixture.context, currentContext: fixture.context))
        let generator = RoutingTestGenerator()
        let chat = chat(coordinator: coordinator, interpreter: RoutingTestInterpreter(), generator: generator)
        chat.composer = AssistantRoutingFixture.text + " and set Astrolab volume to 50%"
        chat.send(context: fixture.context)
        try await wait { !chat.isStreaming }
        #expect(coordinator.pendingStudioDraft == prior)
        #expect(await generator.calls == 0)
        #expect(chat.selectedConversation?.messages.last?.cards.isEmpty == true)
    }

    @Test func cancellationAndChangedConfigurationFenceLateInterpretationBeforeCommit() async throws {
        let fixture = AssistantRoutingFixture()
        for cancelled in [false, true] {
            let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
            let prior = try fixture.prepared()
            #expect(await coordinator.commitPreparedRouting(prior, expectedPending: nil,
                preparedContext: fixture.context, currentContext: fixture.context))
            let interpreter = RoutingTestInterpreter(suspend: true)
            let generator = RoutingTestGenerator()
            let chat = chat(coordinator: coordinator, interpreter: interpreter, generator: generator)
            var current = fixture.context
            chat.currentRoutingContext = { current }
            chat.composer = AssistantRoutingFixture.text
            chat.send(context: fixture.context)
            try await wait { await interpreter.isWaiting }
            if cancelled { chat.cancel() } else {
                current.globalConnections.home.outputs[2].connector = 1
                current.effectiveConnections = current.globalConnections.effectiveHome
            }
            await interpreter.resume()
            try await wait { !chat.isStreaming }
            await Task.yield()
            #expect(coordinator.pendingStudioDraft == prior)
            #expect(await generator.calls == 0)
        }
    }

    @Test func sharedCommitGuardPreservesSameIDUpdatedPendingAndIgnoresSnapshotClockTicks() async throws {
        let fixture = AssistantRoutingFixture()
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
        let original = try fixture.prepared()
        var current = fixture.context
        current.liveWing.capturedAt = Date()
        #expect(await coordinator.commitPreparedRouting(original, expectedPending: nil,
            preparedContext: fixture.context, currentContext: current))
        var updated = original
        updated.createdAt = original.createdAt.addingTimeInterval(1)
        #expect(await coordinator.commitPreparedRouting(updated, expectedPending: original,
            preparedContext: fixture.context, currentContext: current))
        #expect(!(await coordinator.commitPreparedRouting(original, expectedPending: original,
            preparedContext: fixture.context, currentContext: current)))
        #expect(coordinator.pendingStudioDraft == updated)
    }

    @Test func directLegacyPreflightAndModelDraftToolCannotBypassRoutingPreparation() async throws {
        let fixture = AssistantRoutingFixture()
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
        let downstream = RoutingTestGenerator()
        let preflight = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: downstream)
        for try await _ in preflight.stream(.init(question: AssistantRoutingFixture.text,
                                                  recentMessages: [], summary: "", context: fixture.context)) {}
        #expect(await downstream.calls == 0)
        #expect(coordinator.pendingStudioDraft == nil)
        #if canImport(FoundationModels)
        if #available(iOS 27, macOS 27, *) {
            let tool = AssistantDraftFoundationTool(question: AssistantRoutingFixture.text, context: fixture.context,
                                                   coordinator: coordinator, authorizer: .model)
            _ = try await tool.call(arguments: .init(
                sourceNames: ["Osmose"], effectNames: ["Evil Pet"], destination: "mains"))
            #expect(coordinator.pendingStudioDraft == nil)
        }
        #endif
    }

    @Test func ordinaryQuestionsStillReachReadOnlyProvider() async throws {
        let generator = RoutingTestGenerator()
        let chat = chat(coordinator: AssistantCoordinator(draftStore: RoutingTestDraftStore()),
                        interpreter: RoutingTestInterpreter(.answer), generator: generator)
        chat.composer = "How do I route instruments to speakers?"
        chat.send(context: AssistantRoutingFixture().context)
        try await wait { !chat.isStreaming }
        #expect(await generator.calls == 1)
        #expect(chat.selectedConversation?.messages.last?.text == "read-only reply")
    }

    @Test func legacyRetryAndReadOnlyFallbackCannotReplacePriorDraft() async throws {
        let fixture = AssistantRoutingFixture()
        let store = RoutingTestDraftStore()
        let coordinator = AssistantCoordinator(draftStore: store)
        let prior = try fixture.prepared()
        #expect(await coordinator.commitPreparedRouting(prior, expectedPending: nil,
            preparedContext: fixture.context, currentContext: fixture.context))
        let fallback = AssistantFallbackGenerator(coordinator: coordinator)
        let preflight = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: fallback)
        for question in ["try again", "It is connected now, try again.", "How do I connect Osmose to speakers?",
                         "also Solar", "and OP-XY", "what about Osmose"] {
            let request = AssistantGenerationRequest(question: question,
                recentMessages: [.init(role: .user, text: AssistantRoutingFixture.text)],
                summary: "", context: fixture.context)
            for try await _ in preflight.stream(request) {}
            #expect(coordinator.pendingStudioDraft == prior)
            #expect(await store.saves == 1)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] == "1"))
    func optInNativeOwnerAndPriorMonoQualification() async throws {
        let interpreter = FoundationModelActionInterpreter()
        #expect(await interpreter.availability() == .available)
        let routing = try await interpreter.interpret(.init(text: AssistantRoutingFixture.text))
        #expect(routing == .routing(AssistantRoutingFixture.intent))
        print("Native owner interpretation: \(routing)")
        if case .routing(let intent) = routing {
            let fixture = AssistantRoutingFixture()
            let draft = try fixture.prepared(intent: intent)
            let refreshed = StudioWiringAdvisor.revalidate(draft, equipment: fixture.equipment,
                effects: [fixture.effect], connections: fixture.connections,
                currentGraph: StudioGraph(), currentEnvironmentID: nil)
            let merged = StudioPatchDraftMerger.merge(refreshed, into: StudioGraph(), endpoints: [],
                equipment: fixture.equipment, effects: [fixture.effect])
            fixture.checkPaths(graph: merged.graph, endpoints: merged.endpoints)
        }
        for text in ["turn down the volume of my Astrolab", "add my mother-32 and turn the volume to 50%"] {
            let result = try await interpreter.interpret(.init(text: text))
            print("Native mono interpretation: \(text): \(result)")
            guard case .proposal(let proposal) = result else {
                Issue.record("Expected mono proposal: \(result)")
                continue
            }
            if text.contains("mother") {
                #expect(proposal.targetMention == "mother-32")
                #expect(proposal.action == .setFaderPercent)
                #expect(proposal.amount == 50)
                #expect(proposal.addToStudio)
            } else {
                #expect(proposal.targetMention == "Astrolab")
                #expect(proposal.action == .lower)
                #expect(proposal.amount == nil)
            }
        }
    }
}
