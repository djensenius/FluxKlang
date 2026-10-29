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

struct AssistantRoutingEvidenceRegressionTests {
    @Test func effectNameWordsCannotAuthorizeAnUnrequestedDryPath() throws {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        context.effects[0].name = "Dry Wet Delay"
        let text = "route Solar through Dry Wet Delay to mains"
        var intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["Dry Wet Delay"], destination: "mains", destinationEvidence: text,
                  processingEvidence: "Solar through Dry Wet Delay", includesDrySignal: true,
                  dryEvidence: "Solar through Dry Wet Delay")
        ])
        #expect(fixture.rejects(text: text, intent: intent, context: context))
        intent.branches[0].includesDrySignal = false
        intent.branches[0].dryEvidence = ""
        #expect(!fixture.rejects(text: text, intent: intent, context: context))
        intent.branches[0].includesDrySignal = true
        intent.branches[0].dryEvidence = "Solar dry and wet"
        #expect(!fixture.rejects(text: text + " with Solar dry and wet", intent: intent, context: context))
    }

    @Test func destinationCapitalizationDoesNotInventAnotherOutput() {
        let text = "route Osmose to mains and Solar to MAINS"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Osmose", destination: "mains", destinationEvidence: "Osmose to mains"),
            .init(source: "Solar", destination: "MAINS", destinationEvidence: "Solar to MAINS")
        ])
        #expect(!AssistantRoutingFixture().rejects(text: text, intent: intent))
    }

    @Test func completeDestinationNamesTakePrecedenceOverTheirSuffixes() {
        let text = "route Osmose to speakers and Solar to desktop speakers"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Osmose", destination: "speakers", destinationEvidence: "Osmose to speakers"),
            .init(source: "Solar", destination: "desktop speakers", destinationEvidence: "Solar to desktop speakers")
        ])
        #expect(!AssistantRoutingFixture().rejects(text: text, intent: intent))
    }
}

actor RoutingTestDraftStore: PendingStudioPatchPersisting {
    private(set) var draft: StudioPatchDraft?
    private(set) var saves = 0
    private var pauseNext = false
    private var gates: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { !gates.isEmpty }
    var waitingSaves: Int { gates.count }
    func pauseNextSave() { pauseNext = true }
    func resume() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }
    func load() -> StudioPatchDraft? { draft }
    func save(_ draft: StudioPatchDraft?) async {
        saves += 1
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { gates.append($0) }
        }
        self.draft = draft
    }
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

    @Test(arguments: ["inputs and outputs", "ins and outs", "please inputs and outputs?"])
    func standaloneInventoryBypassesRoutingWithoutChangingPendingDraft(question: String) async throws {
        let fixture = AssistantRoutingFixture()
        let store = RoutingTestDraftStore()
        let coordinator = AssistantCoordinator(draftStore: store)
        let prior = try fixture.prepared()
        #expect(await coordinator.commitPreparedRouting(prior, expectedPending: nil,
            preparedContext: fixture.context, currentContext: fixture.context))
        let downstream = RoutingTestGenerator()
        let interpreter = RoutingTestInterpreter()
        let preflight = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: downstream)
        let chat = chat(coordinator: coordinator, interpreter: interpreter, generator: preflight)
        chat.composer = question
        chat.send(context: fixture.context)
        try await wait { !chat.isStreaming }
        #expect(chat.selectedConversation?.messages.last?.text.contains("WING inputs") == true)
        #expect(await interpreter.requests.isEmpty)
        #expect(await downstream.calls == 0)
        #expect(coordinator.pendingStudioDraft == prior)
        #expect(await store.saves == 1)
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
                         "also Solar", "and OP-XY", "what about Osmose", "Rewire Osmose to Space"] {
            let request = AssistantGenerationRequest(question: question,
                recentMessages: [.init(role: .user, text: AssistantRoutingFixture.text)],
                summary: "", context: fixture.context)
            for try await _ in preflight.stream(request) {}
            #expect(coordinator.pendingStudioDraft == prior)
            #expect(await store.saves == 1)
        }
    }

    @Test func dryEvidenceCannotStealAnotherSourcesTrailingDirective() {
        let fixture = AssistantRoutingFixture()
        let text = "Solar through evil pet to mains and Osmose to desktop speakers "
            + "with dry and wet signal in parallel"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains",
                  destinationEvidence: "Solar through evil pet to mains", processingEvidence: "Solar through evil pet",
                  includesDrySignal: true, dryEvidence: text),
            .init(source: "Osmose", destination: "desktop speakers", destinationEvidence: "Osmose to desktop speakers")
        ])
        #expect(fixture.rejects(text: text, intent: intent))
    }

    @Test func serialOrderMustBeBetweenEffectsAndParallelEffectsMustClarify() {
        let fixture = AssistantRoutingFixture()
        let device = Equipment(name: "Echo", inputs: ["In"], outputs: ["Out"])
        let echo = Effect(name: "Echo", equipmentID: device.id, isStereo: false)
        var context = fixture.context
        context.equipment.append(device)
        context.effects.append(echo)
        context.globalConnections.home.inputs.append(.init(connector: 9, equipmentID: device.id, outputPort: 0))
        context.globalConnections.home.outputs.append(.init(connector: 1, equipmentID: device.id, inputPort: 0))
        context.effectiveConnections = context.globalConnections.effectiveHome
        for parallel in [false, true] {
            let text = parallel ? "Solar dry and wet through evil pet and Echo in parallel then to mains"
                : "Solar through evil pet and Echo then to mains"
            let intent = AssistantRoutingIntent(branches: [
                .init(source: "Solar", effects: ["evil pet", "Echo"], destination: "mains",
                      destinationEvidence: text, processingEvidence: text,
                      includesDrySignal: parallel, dryEvidence: parallel ? text : "")
            ])
            #expect(fixture.rejects(text: text, intent: intent, context: context))
        }
        let serial = "Solar through evil pet then Echo to mains with Solar dry and wet in parallel"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet", "Echo"], destination: "mains",
                  destinationEvidence: "Solar through evil pet then Echo to mains",
                  processingEvidence: "Solar through evil pet then Echo", includesDrySignal: true,
                  dryEvidence: "Solar dry and wet in parallel")
        ])
        #expect(!fixture.rejects(text: serial, intent: intent, context: context))
    }

    @Test(arguments: ["into", "through"])
    func reversedProcessingOperandsCannotStageTheOppositePath(_ operation: String) {
        let text = "route evil pet \(operation) Solar to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains",
                  destinationEvidence: "Solar to mains", processingEvidence: "evil pet \(operation) Solar")
        ])
        #expect(AssistantRoutingFixture().rejects(text: text, intent: intent))
    }

    @Test(arguments: ["Desk", "Wet", "Dry Synth", "Monitor"], [false, true])
    func exactMixerTargetLabelsDoNotGrantRoutingOwnership(label: String, unavailable: Bool) async throws {
        let gear = Equipment(name: "Saved Synth")
        let context = AssistantBackendFixture.observe([
            WingAddress.name(.channel, 7): .string(label),
            WingAddress.channelSourceGroup(7): .string("LCL"),
            WingAddress.channelSourceIndex(7): .int(7)
        ], context: AssistantBackendFixture.context(equipment: [gear], inputs: [
            .init(connector: 7, equipmentID: gear.id, outputPort: 0)
        ]))
        let text = label == "Desk" ? "mute \(label)" : "lower \(label) by 3 dB"
        let intent = AssistantActionIntent(targetMention: label, action: label == "Desk" ? .mute : .lower,
            amount: label == "Desk" ? nil : 3, addToStudio: false,
            evidence: .init(target: label, action: label == "Desk" ? "mute" : "lower",
                            amount: label == "Desk" ? nil : "3 dB", add: nil))
        let interpreter = RoutingTestInterpreter(.proposal(intent),
            available: unavailable ? .unavailable("disabled") : .available)
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
        let generator = RoutingTestGenerator()
        let chat = chat(coordinator: coordinator, interpreter: interpreter, generator: generator)
        let planner = ReviewedChatPlanner()
        chat.actionPlanner = planner
        chat.composer = text
        chat.send(context: context)
        try await wait { !chat.isStreaming }
        #expect(planner.intents.count == 1)
        #expect(planner.pendingReview != nil)
        #expect(coordinator.pendingStudioDraft == nil)
        chat.composer = text + " and route Saved Synth to speakers"
        chat.send(context: context)
        try await wait { !chat.isStreaming }
        #expect(planner.intents.count == 1)
        #expect(planner.confirmations == 0)
        #expect(coordinator.pendingStudioDraft == nil)
        #expect(await generator.calls == 0)
    }

    @Test func exclusionsCannotAbsorbAPositiveRoutingClause() {
        let text = "route OP-XY to mains and Osmose to mains without Solar"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "OP-XY", destination: "mains", destinationEvidence: "OP-XY to mains")
        ], excludedMentions: ["Osmose", "Solar"],
            exclusionEvidence: ["Osmose to mains without Solar", "without Solar"])
        #expect(AssistantRoutingFixture().rejects(text: text, intent: intent))
    }

    @Test func serialSourcesCannotBecomeIndependentDirectPaths() {
        let text = "route Osmose into Solar to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Osmose", destination: "mains", destinationEvidence: text),
            .init(source: "Solar", destination: "mains", destinationEvidence: text)
        ])
        let fixture = AssistantRoutingFixture()
        #expect(fixture.rejects(text: text, intent: intent))
        let direct = "route Osmose into mains"
        #expect(!fixture.rejects(text: direct, intent: .init(branches: [
            .init(source: "Osmose", destination: "mains", destinationEvidence: direct)
        ])))
    }

    @Test(arguments: [false, true])
    func supersededRoutingSaveCannotPublishSuccess(replaced: Bool) async throws {
        let fixture = AssistantRoutingFixture()
        let store = RoutingTestDraftStore()
        let coordinator = AssistantCoordinator(draftStore: store)
        let generator = RoutingTestGenerator()
        let chat = chat(coordinator: coordinator, interpreter: RoutingTestInterpreter(), generator: generator)
        await store.pauseNextSave()
        chat.composer = AssistantRoutingFixture.text
        chat.send(context: fixture.context)
        try await wait { await store.isWaiting }
        var replacement: StudioPatchDraft?
        if replaced {
            let draft = try fixture.prepared()
            #expect(await coordinator.commitPreparedRouting(draft, expectedPending: coordinator.pendingStudioDraft,
                preparedContext: fixture.context, currentContext: fixture.context))
            replacement = draft
        } else {
            await coordinator.discardPendingStudioDraft()
        }
        await store.resume()
        try await wait { !chat.isStreaming }
        #expect(coordinator.pendingStudioDraft == replacement)
        #expect(chat.selectedConversation?.messages.last?.cards.isEmpty == true)
        #expect(chat.selectedConversation?.messages.last?.text.contains("Created a review-only") == false)
        #expect(await generator.calls == 0)
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
