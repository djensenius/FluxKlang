import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct AssistantRoutingNameEvidenceTests {
    @Test(arguments: [false, true], [false, true])
    func savedNamesWithoutInitialLiveMatchesAreRechecked(excluded: Bool, atCommit: Bool) async throws {
        let fixture = AssistantRoutingFixture()
        let session = UUID()
        let context = AssistantBackendFixture.observe([:], context: fixture.context, session: session)
        let text = "route Osmose to mains" + (excluded ? " without Solar" : "")
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Osmose", destination: "mains", destinationEvidence: "Osmose to mains")
        ], excludedMentions: excluded ? ["Solar"] : [], exclusionEvidence: excluded ? ["without Solar"] : [])
        let prepared = try fixture.prepared(text: text, intent: intent, context: context)
        let draft = try JSONDecoder().decode(StudioPatchDraft.self, from: JSONEncoder().encode(prepared))
        #expect(draft.liveReferences?.isEmpty == true)
        let changed = AssistantBackendFixture.observe([
            WingAddress.inputName(excluded ? 1 : 3): .string(excluded ? "Solar" : "Osmose")
        ], context: context, session: session)
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
        if atCommit {
            #expect(!(await coordinator.commitPreparedRouting(draft, expectedPending: nil,
                preparedContext: context, currentContext: changed)))
            #expect(coordinator.pendingStudioDraft == nil)
        } else {
            #expect(await coordinator.commitPreparedRouting(draft, expectedPending: nil,
                preparedContext: context, currentContext: context))
            let result = await coordinator.perform(.validatePendingStudioDraft, context: changed)
            guard case .pendingDraft(let refreshed?) = result else {
                Issue.record("Expected a revalidated draft")
                return
            }
            #expect(refreshed.hasErrors)
        }
    }

    @Test(arguments: [false, true])
    func configuredOrLiveOperatorNamesCannotDisappearFromSourceCoverage(live: Bool) {
        let fixture = AssistantRoutingFixture()
        let dry = Equipment(name: live ? "First Synth" : "Dry")
        let wet = Equipment(name: live ? "Second Synth" : "Wet")
        var context = fixture.context
        context.equipment += [dry, wet]
        context.globalConnections.home.inputs += [
            .init(connector: 9, equipmentID: dry.id, outputPort: 0),
            .init(connector: 10, equipmentID: wet.id, outputPort: 0)
        ]
        context.effectiveConnections = context.globalConnections.effectiveHome
        if live {
            context = AssistantBackendFixture.observe([
                WingAddress.inputName(9): .string("Dry"), WingAddress.inputName(10): .string("Wet")
            ], context: context)
        }
        let text = "route Solar and Dry and Wet through evil pet to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains", destinationEvidence: text,
                  processingEvidence: "Solar and Dry and Wet through evil pet", includesDrySignal: true,
                  dryEvidence: "Solar and Dry and Wet through evil pet")
        ])
        #expect(fixture.rejects(text: text, intent: intent, context: context))
    }

    @Test func destinationTraversalCannotMoveAfterTheRequestedEffect() {
        let text = "route Solar through mains then into evil pet"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains",
                  destinationEvidence: "Solar through mains",
                  processingEvidence: "Solar through mains then into evil pet")
        ])
        #expect(AssistantRoutingFixture().rejects(text: text, intent: intent))
    }

    @Test func effectNamesCannotAuthorizeReplacingTheGraph() {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        context.effects[0].name = "Replace Setup"
        let text = "route Solar through Replace Setup to mains"
        var intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["Replace Setup"], destination: "mains", destinationEvidence: text,
                  processingEvidence: "Solar through Replace Setup")
        ], replacesSetup: true, modeEvidence: "Replace Setup")
        guard case .clarification = AssistantRoutingInterpretationAdapter.validate(intent, text: text) else {
            Issue.record("An effect name is not replacement authorization")
            return
        }
        #expect(fixture.rejects(text: text, intent: intent, context: context))
        intent.replacesSetup = false
        intent.modeEvidence = ""
        #expect(!fixture.rejects(text: text, intent: intent, context: context))
        intent.replacesSetup = true
        intent.modeEvidence = "replace the current studio graph"
        #expect(!fixture.rejects(text: intent.modeEvidence + " and " + text, intent: intent, context: context))
    }

    @Test(arguments: ["followed by", "followed  by", "then"])
    func serialSourceOperandsCannotBecomeSeparateRoutes(serial: String) {
        let fixture = AssistantRoutingFixture()
        let text = "route Solar through evil pet \(serial) Osmose to mains"
        var intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains", destinationEvidence: text,
                  processingEvidence: "Solar through evil pet"),
            .init(source: "Osmose", destination: "mains", destinationEvidence: "Osmose to mains")
        ])
        #expect(fixture.rejects(text: text, intent: intent))
        let coordinated = "route Solar through evil pet to mains and Osmose to mains"
        intent.branches[0].destinationEvidence = "Solar through evil pet to mains"
        #expect(!fixture.rejects(text: coordinated, intent: intent))
    }

    @Test(arguments: [false, true], [false, true])
    func configuredEffectNamesCannotDisappearAsOperators(parallel: Bool, aliased: Bool) {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        let names = parallel ? ["Parallel"] : ["Dry", "Wet"]
        context.effects += names.map {
            .init(id: UUID(), name: $0 + (aliased ? " Delay" : ""), equipmentID: nil)
        }
        let suffix = parallel ? "Parallel dry and wet" : "Dry then Wet"
        let text = "route Solar through evil pet then \(suffix) to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains", destinationEvidence: text,
                  processingEvidence: "Solar through evil pet", includesDrySignal: true, dryEvidence: text)
        ])
        #expect(fixture.rejects(text: text, intent: intent, context: context))
        context.effects[0].name = "Dry Wet Delay"
        let complete = "route Solar through Dry Wet Delay to mains"
        let valid = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["Dry Wet Delay"], destination: "mains", destinationEvidence: complete,
                  processingEvidence: "Solar through Dry Wet Delay")
        ])
        #expect(!fixture.rejects(text: complete, intent: valid, context: context))
    }

    @Test func alreadyUsedEffectAliasesCannotBecomeDryOperatorsInSerialPositions() {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        context.effects[0].name = "Dry Wet Delay"
        let text = "route Solar through Dry Wet Delay then Dry then Wet to mains"
        var intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["Dry Wet Delay"], destination: "mains", destinationEvidence: text,
                  processingEvidence: "Solar through Dry Wet Delay", includesDrySignal: true, dryEvidence: text)
        ])
        #expect(fixture.rejects(text: text, intent: intent, context: context))
        let explicitBlend = "route Solar through Dry Wet Delay to mains with Solar dry and wet"
        intent.branches[0].destinationEvidence = "Solar through Dry Wet Delay to mains"
        intent.branches[0].dryEvidence = "Solar dry and wet"
        #expect(!fixture.rejects(text: explicitBlend, intent: intent, context: context))
    }

    @Test(arguments: ["the", "my", "a", "an"])
    func sourceOperandArticlesCannotHideInstrumentTraversal(article: String) {
        let text = "route Solar into \(article) Osmose to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", destination: "mains", destinationEvidence: text),
            .init(source: "Osmose", destination: "mains", destinationEvidence: text)
        ])
        #expect(AssistantRoutingFixture().rejects(text: text, intent: intent))
    }

    @Test func questionsAboutIncludedDraftSourcesReachProviderWithoutAmending() async throws {
        let fixture = AssistantRoutingFixture()
        let store = RoutingTestDraftStore()
        let coordinator = AssistantCoordinator(draftStore: store)
        let prior = try fixture.prepared()
        #expect(await coordinator.commitPreparedRouting(prior, expectedPending: nil,
            preparedContext: fixture.context, currentContext: fixture.context))
        let generator = RoutingTestGenerator()
        let preflight = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: generator)
        let request = AssistantGenerationRequest(question: "Does the pending draft include Solar?",
            recentMessages: [], summary: "", context: fixture.context)
        var reply = ""
        for try await event in preflight.stream(request) {
            if case .text(let text) = event { reply += text }
        }
        #expect(await generator.calls == 1)
        #expect(reply == "read-only reply")
        #expect(coordinator.pendingStudioDraft == prior)
        #expect(await store.saves == 1)
    }

    @Test(arguments: [
        "both through evil pet and directly", "through evil pet and directly",
        "both through evil pet and also directly", "both directly and through evil pet",
        "through evil pet and straight", "through evil pet & directly", "through evil pet + directly",
        "directly & through evil pet", "directly + through evil pet"
    ])
    func explicitProcessedAndDirectPathsCannotLoseTheDirectLeg(path: String) {
        let text = "route Solar \(path) to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains", destinationEvidence: text,
                  processingEvidence: "Solar \(path)")
        ])
        #expect(AssistantRoutingFixture().rejects(text: text, intent: intent))
        let processedOnly = "route Solar through evil pet directly to mains"
        let single = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains", destinationEvidence: processedOnly,
                  processingEvidence: "Solar through evil pet")
        ])
        #expect(!AssistantRoutingFixture().rejects(text: processedOnly, intent: single))
    }

    @Test(arguments: [false, true])
    func completeSourceAndDestinationNamesTakePrecedenceOverEffectAliases(destination: Bool) {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        context.equipment[0].name = "Dry Synth"
        context.effects.append(.init(id: UUID(), name: destination ? "Desktop Delay" : "Dry Delay", equipmentID: nil))
        let source = destination ? "Solar" : "Dry Synth"
        let output = destination ? "desktop speakers" : "mains"
        let text = "route \(source) to \(output)"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: source, destination: output, destinationEvidence: text)
        ])
        #expect(!fixture.rejects(text: text, intent: intent, context: context))
    }

    @Test func independentlyCoordinatedProcessedAndDirectSourcesRemainSeparate() {
        let text = "route Solar through evil pet and Osmose directly to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains", destinationEvidence: text,
                  processingEvidence: "Solar through evil pet"),
            .init(source: "Osmose", destination: "mains", destinationEvidence: "Osmose directly to mains")
        ])
        #expect(!AssistantRoutingFixture().rejects(text: text, intent: intent))
    }

    @Test func serialDryInputAndWetOutputDoNotAuthorizeParallelDelivery() {
        let text = "send Solar dry signal through evil pet then wet signal to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains", destinationEvidence: text,
                  processingEvidence: "Solar dry signal through evil pet", includesDrySignal: true, dryEvidence: text)
        ])
        #expect(AssistantRoutingFixture().rejects(text: text, intent: intent))
    }

    @Test func sourceFanoutCannotBecomeIndependentMainsBranches() {
        let text = "route Osmose to both Solar and mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Osmose", destination: "mains", destinationEvidence: text),
            .init(source: "Solar", destination: "mains", destinationEvidence: text)
        ])
        #expect(AssistantRoutingFixture().rejects(text: text, intent: intent))
    }

    @Test func coordinatedDirectLegAfterSerialEffectsCannotDisappear() {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        let echo = Equipment(name: "Echo", inputs: ["In"], outputs: ["Out"])
        context.equipment.append(echo)
        context.effects.append(.init(name: "Echo", equipmentID: echo.id, isStereo: false))
        context.globalConnections.home.inputs.append(.init(connector: 9, equipmentID: echo.id, outputPort: 0))
        context.globalConnections.home.outputs.append(.init(connector: 1, equipmentID: echo.id, inputPort: 0))
        context.effectiveConnections = context.globalConnections.effectiveHome
        let text = "route Solar through evil pet then Echo and directly to mains"
        var intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet", "Echo"], destination: "mains", destinationEvidence: text,
                  processingEvidence: "Solar through evil pet then Echo")
        ])
        #expect(fixture.rejects(text: text, intent: intent, context: context))
        let processed = "route Solar through evil pet then Echo directly to mains"
        intent.branches[0].destinationEvidence = processed
        #expect(!fixture.rejects(text: processed, intent: intent, context: context))
    }

    @Test(arguments: [false, true])
    func destinationQualifiersCannotDisappearIntoDryWetOperators(configured: Bool) throws {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        if configured {
            context.globalConnections.home.outputs += [
                .init(connector: 1, destinationName: "Dry Speakers L"),
                .init(connector: 2, destinationName: "Dry Speakers R")
            ]
            context.effectiveConnections = context.globalConnections.effectiveHome
        }
        let text = "route Solar through evil pet dry and wet to Dry Speakers"
        var intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "Speakers", destinationEvidence: text,
                  processingEvidence: "Solar through evil pet", includesDrySignal: true, dryEvidence: text)
        ])
        #expect(fixture.rejects(text: text, intent: intent, context: context))
        intent.branches[0].destination = "Dry Speakers"
        if configured {
            let draft = try fixture.prepared(text: text, intent: intent, context: context)
            #expect(draft.request.outputConnectors == [.init(index: 1), .init(index: 2)])
        } else {
            #expect(fixture.rejects(text: text, intent: intent, context: context))
        }
    }

    @Test(arguments: [false, true])
    func completeEffectNamesDoNotCountAsDestinationOccurrences(grouped: Bool) {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        context.effects[0].name = "Main Speakers Delay"
        let output = grouped ? "desktop speakers" : "Main Speakers"
        let clause = "Solar through Main Speakers Delay to \(output)"
        var intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["Main Speakers Delay"], destination: output, destinationEvidence: clause,
                  processingEvidence: "Solar through Main Speakers Delay")
        ])
        let text = "route " + clause + (grouped ? " and Osmose to Main Speakers" : "")
        if grouped {
            intent.branches.append(.init(source: "Osmose", destination: "Main Speakers",
                                         destinationEvidence: "Osmose to Main Speakers"))
        }
        #expect(!fixture.rejects(text: text, intent: intent, context: context))
        let repeated = text + " and " + output
        intent.branches[0].destinationEvidence = repeated
        #expect(fixture.rejects(text: repeated, intent: intent, context: context))
    }

    @Test(arguments: [
        "route Osmose and Signal to mains", "route Signal and Osmose to mains",
        "route Osmose and Signal and Solar to mains", "Signal and Osmose to mains",
        "my Signal & Osmose to mains"
    ])
    func unknownCoordinatedSourceOperandsCannotDisappear(text: String) {
        var intent = AssistantRoutingIntent(branches: [
            .init(source: "Osmose", destination: "mains", destinationEvidence: text)
        ])
        if text.contains("Solar") {
            intent.branches.append(.init(source: "Solar", destination: "mains", destinationEvidence: text))
        }
        #expect(AssistantRoutingFixture().rejects(text: text, intent: intent))
    }

    @Test(arguments: ["then Signal", "followed by Signal", "then my Signal"])
    func unknownSerialEffectOperandsCannotDisappear(continuation: String) {
        let text = "route Solar through evil pet \(continuation) to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains",
                  destinationEvidence: text, processingEvidence: "Solar through evil pet")
        ])
        #expect(AssistantRoutingFixture().rejects(text: text, intent: intent))
    }

    @Test(arguments: ["and Solar directly", "and just directly", "and Solar just directly"])
    func repeatedSourceOrFillerCannotHideTheDirectLeg(continuation: String) {
        let text = "route Solar through evil pet \(continuation) to mains"
        let destination = continuation.contains("Solar") ? String(continuation.dropFirst(4)) + " to mains" : text
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains",
                  destinationEvidence: destination, processingEvidence: "Solar through evil pet")
        ])
        #expect(AssistantRoutingFixture().rejects(text: text, intent: intent))
    }
}
