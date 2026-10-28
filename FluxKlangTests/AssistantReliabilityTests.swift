import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct AssistantReliabilityTests {
    @Test func exclusiveSourceLanguageRequestsReplacement() {
        #expect(AssistantDraftIntent.requestsReplacement("Route just AstroLab to the main speakers."))
        #expect(AssistantDraftIntent.requestsReplacement("I only want AstroLab through the speakers."))
    }

    @Test func routingIntentUnderstandsDryWetAndMultipleDestinations() {
        let context = musicianRoutingContext()
        let dryWet = AssistantDraftIntent.wiringRequest(from: AssistantGenerationRequest(
            question: "Route Osmose through Evil Pet and have Evil Pet and raw Osmose both go to mains.",
            recentMessages: [],
            summary: "",
            context: context
        ))
        let splitDestinations = AssistantDraftIntent.wiringRequest(from: AssistantGenerationRequest(
            question: "Send dry Osmose to mains and Osmose through Evil Pet to Space.",
            recentMessages: [],
            summary: "",
            context: context
        ))

        #expect(dryWet?.effectChainIDs == [context.effects[0].id])
        #expect(dryWet?.includesDrySignal == true)
        #expect(dryWet?.destination == .finalMix)
        #expect(splitDestinations?.effectChainIDs.isEmpty == true)
        #expect(splitDestinations?.destination == .finalMix)
        #expect(splitDestinations?.additionalRoutes.count == 1)
        #expect(splitDestinations?.additionalRoutes[0].effectChainIDs == [context.effects[0].id])
        #expect(splitDestinations?.additionalRoutes[0].destination == .space)
    }

    @Test func incompleteRoutingIntentAsksForDestination() {
        let context = musicianRoutingContext()
        let request = AssistantGenerationRequest(
            question: "Route Osmose through Evil Pet.",
            recentMessages: [],
            summary: "",
            context: context
        )

        #expect(AssistantDraftIntent.wiringRequest(from: request) == nil)
        #expect(AssistantDraftIntent.clarification(from: request)
            == "Where should Expressive E Osmose go: Main Speakers, Space, or both?")
    }

    @Test func routingIntentPreservesEffectOrderExclusionsAndParallelTopology() {
        let context = musicianRoutingContext()
        let serial = AssistantDraftIntent.wiringRequest(from: routingRequest(
            "Route Osmose through Cosmos then Evil Pet to mains.",
            context: context
        ))
        let excluded = AssistantDraftIntent.wiringRequest(from: routingRequest(
            "Route Osmose through Evil Pet without Cosmos to mains.",
            context: context
        ))
        let parallel = AssistantDraftIntent.wiringRequest(from: routingRequest(
            "Route Osmose through Evil Pet and Cosmos in parallel to mains.",
            context: context
        ))
        let ambiguous = routingRequest(
            "Route Osmose through Evil Pet and Cosmos to mains.",
            context: context
        )

        #expect(serial?.effectChainIDs == [context.effects[1].id, context.effects[0].id])
        #expect(excluded?.effectChainIDs == [context.effects[0].id])
        #expect(excluded?.applicationMode == .append)
        #expect(parallel?.effectChainIDs == [context.effects[0].id])
        #expect(parallel?.additionalRoutes.first?.effectChainIDs == [context.effects[1].id])
        #expect(AssistantDraftIntent.wiringRequest(from: ambiguous) == nil)
        #expect(AssistantDraftIntent.clarification(from: ambiguous)
            == "Should Evil Pet and Cosmos be serial (one into the next) or parallel?")
    }

    @Test func routingIntentDistinguishesNamedOutputsFromMainSpeakers() {
        let context = musicianRoutingContext()
        let request = AssistantDraftIntent.wiringRequest(from: routingRequest(
            "Route Osmose to the Desk Speakers.",
            context: context
        ))

        #expect(request?.destination == .custom)
        #expect(request?.outputConnectors == [
            WingOutputConnector(bank: .local, index: 1),
            WingOutputConnector(bank: .local, index: 2)
        ])
    }

    @Test func routingIntentBuildsIndependentSourceScopedBranches() {
        let context = musicianRoutingContext()
        let request = AssistantDraftIntent.wiringRequest(from: routingRequest(
            "Route Flux through Cosmos and AstroLab through Evil Pet to mains.",
            context: context
        ))

        #expect(request?.sourceInstrumentIDs == [context.equipment[0].id])
        #expect(request?.effectChainIDs == [context.effects[1].id])
        #expect(request?.additionalRoutes.first?.sourceInstrumentIDs == [context.equipment[1].id])
        #expect(request?.additionalRoutes.first?.effectChainIDs == [context.effects[0].id])
    }

    @Test func modelRuntimeFailureUsesDeterministicFallback() async throws {
        let router = AssistantGeneratorRouter(
            model: FailingGenerator(),
            fallback: ReplyGenerator(text: "fallback")
        )
        var text = ""

        for try await event in router.stream(AssistantGenerationRequest(
            question: "Help",
            recentMessages: [],
            summary: "",
            context: emptyContext()
        )) {
            if case .text(let value) = event {
                text = value
            }
        }

        #expect(text == "fallback")
    }

    @Test func emptyModelResponseUsesDeterministicFallback() async throws {
        let router = AssistantGeneratorRouter(
            model: EmptyGenerator(),
            fallback: ReplyGenerator(text: "fallback")
        )
        var text = ""

        for try await event in router.stream(AssistantGenerationRequest(
            question: "Help",
            recentMessages: [],
            summary: "",
            context: emptyContext()
        )) {
            if case .text(let value) = event {
                text = value
            }
        }

        #expect(text == "fallback")
    }

    @Test func voiceTranscriberIsCreatedOnlyWhenDictationStarts() async throws {
        let transcriber = ReadyTranscriber()
        var creationCount = 0
        let voice = AssistantVoiceController {
            creationCount += 1
            return transcriber
        }

        #expect(creationCount == 0)
        voice.start()
        for _ in 0..<100 where voice.state != .listening {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(voice.state == .listening)
        #expect(creationCount == 1)
        voice.cancel()
    }

    @Test func completeWiringRequestBypassesModelConfirmation() async throws {
        let flux = Equipment(name: "SOMA Flux", outputs: ["Out L", "Out R"], isStereo: true)
        let astrolab = Equipment(name: "AstroLab 88", outputs: ["Out L", "Out R"], isStereo: true)
        let connections = GlobalStudioConnections(home: StudioHomeConnections(
            inputs: [
                StudioInputConnection(connector: 19, equipmentID: flux.id, outputPort: 0),
                StudioInputConnection(connector: 20, equipmentID: flux.id, outputPort: 1),
                StudioInputConnection(connector: 21, equipmentID: astrolab.id, outputPort: 0),
                StudioInputConnection(connector: 22, equipmentID: astrolab.id, outputPort: 1)
            ],
            outputs: [
                StudioOutputConnection(connector: 7, destinationName: "Main Speakers L"),
                StudioOutputConnection(connector: 8, destinationName: "Main Speakers R")
            ]
        ))
        let coordinator = AssistantCoordinator(draftStore: ReliabilityDraftStore())
        let generator = AssistantDraftPreflightGenerator(
            coordinator: coordinator,
            downstream: ReplyGenerator(text: "Please confirm the names.")
        )
        let context = AssistantToolContext(
            currentScreen: .assistant,
            connection: AssistantConnectionState(status: .connected, detail: nil, isDemo: false),
            equipment: [flux, astrolab],
            homeConnections: connections.home,
            effectiveConnections: connections.effectiveHome,
            activeMoves: [],
            environments: [],
            activeEnvironmentID: nil,
            presets: [],
            resources: [],
            validationIssues: [],
            graph: StudioGraph(),
            endpoints: [],
            effects: [],
            globalConnections: connections
        )
        var text = ""

        for try await event in generator.stream(AssistantGenerationRequest(
            question: "Have my Flux and AstroLab go to the main speakers in a new setup.",
            recentMessages: [],
            summary: "",
            context: context
        )) {
            if case .text(let value) = event { text = value }
        }

        #expect(!text.contains("Please confirm"))
        #expect(text.contains("SOMA Flux + AstroLab 88 → Main Speakers"))
        #expect(coordinator.pendingStudioDraft?.applicationMode == .replace)
    }

    @Test func inventoryAndFollowUpAmendmentBypassModelGuessing() async throws {
        let flux = Equipment(name: "SOMA Flux", outputs: ["Out L", "Out R"], isStereo: true)
        let astrolab = Equipment(name: "Arturia AstroLab 88", outputs: ["Out L", "Out R"], isStereo: true)
        let connections = GlobalStudioConnections(home: StudioHomeConnections(
            inputs: [
                StudioInputConnection(connector: 19, equipmentID: flux.id, outputPort: 0),
                StudioInputConnection(connector: 20, equipmentID: flux.id, outputPort: 1),
                StudioInputConnection(connector: 21, equipmentID: astrolab.id, outputPort: 0),
                StudioInputConnection(connector: 22, equipmentID: astrolab.id, outputPort: 1)
            ],
            outputs: [
                StudioOutputConnection(connector: 7, destinationName: "Main Speakers L"),
                StudioOutputConnection(connector: 8, destinationName: "Main Speakers R")
            ]
        ))
        let coordinator = AssistantCoordinator(draftStore: ReliabilityDraftStore())
        let generator = AssistantDraftPreflightGenerator(
            coordinator: coordinator,
            downstream: ReplyGenerator(text: "I do not know your gear.")
        )
        let context = AssistantToolContext(
            currentScreen: .assistant,
            connection: AssistantConnectionState(status: .connected, detail: nil, isDemo: false),
            equipment: [flux, astrolab],
            homeConnections: connections.home,
            effectiveConnections: connections.effectiveHome,
            activeMoves: [],
            environments: [],
            activeEnvironmentID: nil,
            presets: [],
            resources: [],
            validationIssues: [],
            graph: StudioGraph(),
            endpoints: [],
            effects: [],
            globalConnections: connections
        )

        let inventory = try await text(
            from: generator,
            question: "Can you list equipment?",
            context: context
        )
        _ = try await text(
            from: generator,
            question: "Have Flux go to the main speakers in a new setup.",
            context: context
        )
        let amended = try await text(
            from: generator,
            question: "What about AstroLab?",
            context: context
        )

        #expect(inventory.contains("Saved equipment (not connected-equipment detection):"))
        #expect(inventory.contains("Arturia AstroLab 88 (WING inputs 21/22)"))
        #expect(amended.contains("SOMA Flux + Arturia AstroLab 88 → Main Speakers"))
        #expect(coordinator.pendingStudioDraft?.request.sourceInstrumentIDs == [flux.id, astrolab.id])
    }

    private func emptyContext() -> AssistantToolContext {
        AssistantToolContext(
            currentScreen: .assistant,
            connection: AssistantConnectionState(status: .disconnected, detail: nil, isDemo: false),
            equipment: [],
            homeConnections: StudioHomeConnections(),
            effectiveConnections: StudioHomeConnections(),
            activeMoves: [],
            environments: [],
            activeEnvironmentID: nil,
            presets: [],
            resources: [],
            validationIssues: [],
            graph: StudioGraph(),
            endpoints: [],
            effects: [],
            globalConnections: GlobalStudioConnections()
        )
    }

    private func musicianRoutingContext() -> AssistantToolContext {
        let flux = Equipment(name: "SOMA Flux", outputs: ["Out L", "Out R"], isStereo: true)
        let astrolab = Equipment(name: "Arturia AstroLab 88", outputs: ["Out L", "Out R"], isStereo: true)
        let osmose = Equipment(name: "Expressive E Osmose", outputs: ["Out L", "Out R"], isStereo: true)
        let evilPetEquipment = Equipment(
            name: "Endorphin.es EviL Pet",
            inputs: ["In L", "In R"],
            outputs: ["Out L", "Out R"],
            isStereo: true
        )
        let evilPet = Effect(name: "Evil Pet", equipmentID: evilPetEquipment.id, isStereo: true)
        let cosmosEquipment = Equipment(
            name: "Cosmos",
            inputs: ["In L", "In R"],
            outputs: ["Out L", "Out R"],
            isStereo: true
        )
        let cosmos = Effect(name: "Cosmos", equipmentID: cosmosEquipment.id, isStereo: true)
        let connections = StudioHomeConnections(outputs: [
            StudioOutputConnection(connector: 1, destinationName: "Desk Speakers L"),
            StudioOutputConnection(connector: 2, destinationName: "Desk Speakers R"),
            StudioOutputConnection(connector: 7, destinationName: "Main Speakers L"),
            StudioOutputConnection(connector: 8, destinationName: "Main Speakers R")
        ])
        return AssistantToolContext(
            currentScreen: .assistant,
            connection: AssistantConnectionState(status: .connected, detail: nil, isDemo: false),
            equipment: [flux, astrolab, osmose, evilPetEquipment, cosmosEquipment],
            homeConnections: connections,
            effectiveConnections: connections,
            activeMoves: [],
            environments: [],
            activeEnvironmentID: nil,
            presets: [],
            resources: [],
            validationIssues: [],
            graph: StudioGraph(),
            endpoints: [],
            effects: [evilPet, cosmos],
            globalConnections: GlobalStudioConnections(home: connections)
        )
    }

    private func routingRequest(
        _ question: String,
        context: AssistantToolContext
    ) -> AssistantGenerationRequest {
        AssistantGenerationRequest(
            question: question,
            recentMessages: [],
            summary: "",
            context: context
        )
    }

    private func text(
        from generator: some AssistantGenerating,
        question: String,
        context: AssistantToolContext
    ) async throws -> String {
        var result = ""
        for try await event in generator.stream(AssistantGenerationRequest(
            question: question,
            recentMessages: [],
            summary: "",
            context: context
        )) {
            if case .text(let value) = event { result = value }
        }
        return result
    }
}

private actor ReliabilityDraftStore: PendingStudioPatchPersisting {
    private var draft: StudioPatchDraft?

    func load() -> StudioPatchDraft? { draft }
    func save(_ draft: StudioPatchDraft?) { self.draft = draft }
}

private struct ReplyGenerator: AssistantGenerating {
    var text: String

    func availability() async -> AssistantModelAvailability { .unsupportedOS }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.finish()
        }
    }
}

private struct FailingGenerator: AssistantGenerating {
    func availability() async -> AssistantModelAvailability { .ready }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ReliabilityTestError.generationFailed)
        }
    }
}

private struct EmptyGenerator: AssistantGenerating {
    func availability() async -> AssistantModelAvailability { .ready }

    func stream(
        _ request: AssistantGenerationRequest
    ) -> AsyncThrowingStream<AssistantStreamEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor ReadyTranscriber: AssistantSpeechTranscribing {
    func permissionState() -> AssistantVoicePermissionState { .granted }
    func requestPermission() -> AssistantVoicePermissionState { .granted }

    func start() -> AsyncThrowingStream<AssistantTranscriptUpdate, any Error> {
        AsyncThrowingStream { _ in }
    }

    func finish() {}
    func cancel() {}
}

private enum ReliabilityTestError: Error {
    case generationFailed
}
