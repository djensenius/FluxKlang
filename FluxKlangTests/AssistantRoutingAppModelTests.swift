import Foundation
import Testing
@testable import FluxKlang

@MainActor
@Suite(.serialized)
struct AssistantRoutingAppModelTests {
    private func model(fixture: AssistantRoutingFixture,
                       store: any PendingStudioPatchPersisting = RoutingTestDraftStore()) async throws -> AppModel {
        let model = AppModel(assistant: AssistantCoordinator(draftStore: store), wing: .preview())
        await model.equipment.load()
        for gear in fixture.equipment {
            if model.equipment.items.contains(where: { $0.id == gear.id }) {
                model.equipment.update(gear)
            } else {
                model.equipment.add(gear)
            }
        }
        await model.environments.load()
        _ = model.environments.addEnvironment(named: "Apple routing fixture \(UUID())")
        model.environments.add(fixture.effect)
        await model.studioConnections.load(equipment: model.equipment.items,
            environments: model.environments.environments, activeID: model.environments.activeID)
        try await model.studioConnections.replaceHome(fixture.connections.home, equipment: model.equipment.items)
        return model
    }

    @Test func naturalSiriUsesSameApplePlanAndLocalAcceptanceRetainsAllPaths() async throws {
        let fixture = AssistantRoutingFixture()
        let model = try await model(fixture: fixture)
        let before = model.environments.activeStudioGraph
        let writes = model.wing.transportWriteCount
        let interpreter = RoutingTestInterpreter()
        let spoken = await SiriDraftStudioAction.execute(request: "Tell Flux Klang to " + AssistantRoutingFixture.text,
                                                        model: model, interpreter: interpreter)
        #expect(await interpreter.requests.map(\.text) == [AssistantRoutingFixture.text])
        #expect(model.environments.activeStudioGraph == before)
        #expect(model.assistant.pendingStudioDraft?.request.additionalRoutes.count == 2)
        #expect(model.assistant.navigationTarget == .reviewPendingDraft)
        #expect(spoken.contains(fixture.osmose.name))
        #expect(spoken.contains(fixture.solar.name))
        #expect(spoken.contains(fixture.opxy.name))
        #expect(model.wing.transportWriteCount == writes)
        let result = try #require(await model.acceptPendingAssistantDraft())
        fixture.checkPaths(graph: result.graph, endpoints: result.endpoints)
        #expect(model.assistant.pendingStudioDraft == nil)
        #expect(model.wing.transportWriteCount == writes)
    }

    @Test func changedDeskGroupBeforeAcceptanceBlocksWithoutWritesOrOldConnectorReuse() async throws {
        let fixture = AssistantRoutingFixture()
        let model = try await model(fixture: fixture)
        _ = await SiriDraftStudioAction.execute(request: AssistantRoutingFixture.text,
                                               model: model, interpreter: RoutingTestInterpreter())
        let original = try #require(model.assistant.pendingStudioDraft)
        var movedOutputs = fixture.connections.home
        movedOutputs.outputs[2].connector = 1
        movedOutputs.outputs[3].connector = 2
        try await model.studioConnections.replaceHome(movedOutputs, equipment: model.equipment.items)
        let before = model.environments.activeStudioGraph
        #expect(await model.acceptPendingAssistantDraft() == nil)
        #expect(model.environments.activeStudioGraph == before)
        #expect(model.assistant.pendingStudioDraft?.id == original.id)
        #expect(model.assistant.pendingStudioDraft?.validation.contains { $0.code == "destination-changed" } == true)
        #expect(model.wing.transportWriteCount == 0)
    }

    @Test func failedSiriPreparationLeavesExistingPendingGraphAndWritesUntouched() async throws {
        let fixture = AssistantRoutingFixture()
        let model = try await model(fixture: fixture)
        _ = await SiriDraftStudioAction.execute(request: AssistantRoutingFixture.text,
                                               model: model, interpreter: RoutingTestInterpreter())
        let prior = try #require(model.assistant.pendingStudioDraft)
        let graph = model.environments.activeStudioGraph
        for interpreter in [RoutingTestInterpreter(.answer), RoutingTestInterpreter(fails: true),
                            RoutingTestInterpreter(available: .unavailable("disabled"))] {
            _ = await SiriDraftStudioAction.execute(request: AssistantRoutingFixture.text,
                                                   model: model, interpreter: interpreter)
            #expect(model.assistant.pendingStudioDraft == prior)
            #expect(model.environments.activeStudioGraph == graph)
            #expect(model.wing.transportWriteCount == 0)
        }
    }

    @Test func graphChangesAfterPreparationBlockAcceptanceAndPreserveCurrentGraph() async throws {
        let fixture = AssistantRoutingFixture()
        for useEffect in [false, true] {
            let model = try await model(fixture: fixture)
            _ = await SiriDraftStudioAction.execute(request: AssistantRoutingFixture.text,
                                                   model: model, interpreter: RoutingTestInterpreter())
            let prior = try #require(model.assistant.pendingStudioDraft)
            let changed: StudioGraph
            if useEffect {
                changed = StudioGraph(nodes: [.init(kind: .effect(fixture.effect.id), title: "Now in use")])
            } else {
                let direct = StudioWiringAdvisor.build(request: .init(sourceInstrumentIDs: [fixture.solar.id]),
                    equipment: fixture.equipment, effects: [fixture.effect], connections: fixture.connections,
                    currentGraph: StudioGraph(), environmentID: model.environments.activeID)
                changed = StudioGraph(nodes: direct.fragment.nodes.map(\.node),
                                      edges: direct.fragment.edges.map(\.edge))
            }
            model.environments.replaceStudio(graph: changed, endpoints: [])
            #expect(await model.acceptPendingAssistantDraft() == nil)
            #expect(model.environments.activeStudioGraph == changed)
            #expect(model.assistant.pendingStudioDraft?.id == prior.id)
            #expect(model.assistant.pendingStudioDraft?.validation.contains {
                $0.code == "routing-graph-changed"
            } == true)
            #expect(model.wing.transportWriteCount == 0)
        }
    }

    @Test func incompatibleExistingSpeakerOrderBlocksPreparationAndRevalidation() throws {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        context.globalConnections.home.outputs[2].connector = 6
        context.globalConnections.home.outputs[3].connector = 5
        context.effectiveConnections = context.globalConnections.effectiveHome
        let draft = try fixture.prepared(context: context)
        let endpoint = StudioEndpoint(name: "Desk Speakers", destination: .custom,
                                      outputConnectors: [.init(index: 5), .init(index: 6)])
        let graph = StudioGraph(nodes: [.init(kind: .endpoint(endpoint.id), title: endpoint.name)])
        context.graph = graph
        context.endpoints = [endpoint]
        #expect(fixture.rejects(context: context))
        let refreshed = StudioWiringAdvisor.revalidate(draft, equipment: fixture.equipment,
            effects: [fixture.effect], connections: context.globalConnections, currentGraph: graph,
            currentEnvironmentID: nil, currentEndpoints: [endpoint])
        #expect(refreshed.hasErrors)
        let merged = StudioPatchDraftMerger.merge(draft, into: graph, endpoints: [endpoint],
            equipment: fixture.equipment, effects: [fixture.effect])
        let usedEndpointIDs = Set(merged.graph.edges.compactMap { edge -> UUID? in
            guard let node = merged.graph.nodes.first(where: { $0.id == edge.to.nodeID }),
                  case .endpoint(let id) = node.kind else { return nil }
            return id
        })
        let desk = try #require(merged.endpoints.first {
            $0.destination == .custom && usedEndpointIDs.contains($0.id)
        })
        #expect(desk.outputConnectors == [.init(index: 6), .init(index: 5)])
        let compiled = StudioSignalCompiler.compile(.init(graph: merged.graph, endpoints: merged.endpoints,
            effects: [fixture.effect], connections: context.globalConnections,
            equipment: fixture.equipment, speakers: []))
        #expect(!compiled.hasErrors)
    }

    @Test(arguments: [false, true])
    func compatibleLegacyMainEndpointKeepsReviewedMappingAfterMergeAndCompilation(emptyMapping: Bool) throws {
        let fixture = AssistantRoutingFixture()
        let draft = try fixture.prepared()
        let reviewed = try #require(draft.fragment.endpoints.first { $0.destination == .finalMix })
        var legacy = reviewed
        legacy.id = UUID()
        legacy.outputConnectors = emptyMapping ? [] : nil
        let graph = StudioGraph(nodes: [.init(kind: .endpoint(legacy.id), title: legacy.name)])
        var context = fixture.context
        context.graph = graph
        context.endpoints = [legacy]
        #expect(!fixture.rejects(context: context))
        var legacyEndpoints = draft.fragment.endpoints
        legacyEndpoints[try #require(legacyEndpoints.firstIndex { $0.id == reviewed.id })].outputConnectors
            = legacy.outputConnectors
        let legacyCompiled = StudioSignalCompiler.compile(.init(
            graph: StudioGraph(nodes: draft.fragment.nodes.map(\.node), edges: draft.fragment.edges.map(\.edge)),
            endpoints: legacyEndpoints, effects: [fixture.effect], connections: fixture.connections,
            equipment: fixture.equipment, speakers: []))
        #expect(!legacyCompiled.hasErrors)
        #expect(!legacyCompiled.settings.isEmpty)
        let refreshed = StudioWiringAdvisor.revalidate(draft, equipment: fixture.equipment,
            effects: [fixture.effect], connections: fixture.connections, currentGraph: graph,
            currentEnvironmentID: nil, currentEndpoints: [legacy])
        #expect(!refreshed.hasErrors)
        let merged = StudioPatchDraftMerger.merge(refreshed, into: graph, endpoints: [legacy],
            equipment: fixture.equipment, effects: [fixture.effect])
        #expect(merged.endpoints.first { $0.id == legacy.id }?.outputConnectors == reviewed.outputConnectors)
        #expect(merged.endpoints.filter { $0.destination == .finalMix }.count == 1)
        let compiled = StudioSignalCompiler.compile(.init(graph: merged.graph, endpoints: merged.endpoints,
            effects: [fixture.effect], connections: fixture.connections,
            equipment: fixture.equipment, speakers: []))
        #expect(!compiled.hasErrors)
        var moved = fixture.connections
        moved.home.outputs[4].destinationName = "Main Speakers R"
        moved.home.outputs[5].destinationName = "Main Speakers L"
        let drifted = StudioSignalCompiler.compile(.init(graph: merged.graph, endpoints: merged.endpoints,
            effects: [fixture.effect], connections: moved, equipment: fixture.equipment, speakers: []))
        #expect(drifted.hasErrors)
        #expect(drifted.settings.isEmpty)
    }

    @Test(arguments: 0...4)
    func contextChangesDuringValidationSaveBlockAcceptance(change: Int) async throws {
        let fixture = AssistantRoutingFixture()
        let store = PausingRoutingDraftStore()
        let model = try await model(fixture: fixture, store: store)
        _ = await SiriDraftStudioAction.execute(request: AssistantRoutingFixture.text,
                                               model: model, interpreter: RoutingTestInterpreter())
        let prior = try #require(model.assistant.pendingStudioDraft)
        if change == 4 {
            let endpoint = StudioEndpoint(name: "Existing endpoint", destination: .space)
            let graph = StudioGraph(nodes: [.init(kind: .endpoint(endpoint.id), title: endpoint.name)])
            model.environments.replaceStudio(graph: graph, endpoints: [endpoint])
        }
        await store.pauseNextSave()
        let acceptance = Task { await model.acceptPendingAssistantDraft() }
        defer { Task { await store.resume() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await store.isPaused) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        switch change {
        case 0:
            _ = model.environments.addEnvironment(named: "Changed during validation")
        case 1:
            let graph = StudioGraph(nodes: [.init(kind: .effect(fixture.effect.id), title: "Keep this edit")])
            model.environments.replaceStudio(graph: graph, endpoints: [])
        case 2:
            var gear = fixture.osmose
            gear.name = "Changed during validation"
            model.equipment.update(gear)
        case 3:
            model.environments.add(Effect(name: "Changed during validation"))
        default:
            var endpoints = model.environments.activeStudioEndpoints
            endpoints[0].name = "Keep this endpoint edit"
            model.environments.replaceStudio(graph: model.environments.activeStudioGraph, endpoints: endpoints)
        }
        let current = model.assistantToolContext()
        await store.resume()
        #expect(await acceptance.value == nil)
        #expect(model.environments.activeID == current.activeEnvironmentID)
        #expect(model.environments.activeStudioGraph == current.graph)
        #expect(model.environments.activeStudioEndpoints == current.endpoints)
        #expect(model.assistant.pendingStudioDraft?.id == prior.id)
        #expect(model.wing.transportWriteCount == 0)
    }

    @Test func relabeledDeskPairCannotAlsoBeUsedAsAnIndependentMainsDestination() throws {
        let fixture = AssistantRoutingFixture()
        let existing = StudioWiringAdvisor.build(
            request: .init(sourceInstrumentIDs: [fixture.opxy.id], destination: .custom,
                           outputConnectors: [.init(index: 5), .init(index: 6)]),
            equipment: fixture.equipment, effects: [fixture.effect], connections: fixture.connections,
            currentGraph: StudioGraph())
        var context = fixture.context
        context.globalConnections.home.outputs.removeAll { $0.connector == 7 || $0.connector == 8 }
        context.globalConnections.home.outputs[2].destinationName = "Main Speakers L"
        context.globalConnections.home.outputs[3].destinationName = "Main Speakers R"
        context.effectiveConnections = context.globalConnections.effectiveHome
        let text = "route Osmose to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Osmose", destination: "mains", destinationEvidence: "Osmose to mains")
        ])
        let draft = try fixture.prepared(text: text, intent: intent, context: context)
        context.graph = StudioGraph(nodes: existing.fragment.nodes.map(\.node),
                                    edges: existing.fragment.edges.map(\.edge))
        context.endpoints = existing.fragment.endpoints
        #expect(fixture.rejects(text: text, intent: intent, context: context))
        let refreshed = StudioWiringAdvisor.revalidate(draft, equipment: fixture.equipment,
            effects: [fixture.effect], connections: context.globalConnections, currentGraph: context.graph,
            currentEnvironmentID: nil, currentEndpoints: context.endpoints)
        #expect(refreshed.validation.contains { $0.code == "routing-graph-changed" })
    }

    @Test func destinationUsedByAnotherSourceCannotHideAnOmittedDestination() {
        let fixture = AssistantRoutingFixture()
        let text = "route Osmose to mains and desktop speakers and Solar to desktop speakers"
        var partial = AssistantRoutingIntent(branches: [
            .init(source: "Osmose", destination: "mains", destinationEvidence: "Osmose to mains"),
            .init(source: "Solar", destination: "desktop speakers", destinationEvidence: "Solar to desktop speakers")
        ])
        #expect(fixture.rejects(text: text, intent: partial))
        partial.branches[1].destinationEvidence = "desktop speakers and Solar to desktop speakers"
        #expect(fixture.rejects(text: text, intent: partial))
    }

    @Test(arguments: ["studio", "current"])
    func destinationQualifiersCannotDisappearIntoSetupVocabulary(qualifier: String) throws {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        context.globalConnections.home.outputs += [
            .init(connector: 1, destinationName: "\(qualifier) Speakers L"),
            .init(connector: 2, destinationName: "\(qualifier) Speakers R")
        ]
        context.effectiveConnections = context.globalConnections.effectiveHome
        let text = "route Solar to \(qualifier) speakers"
        var intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", destination: "speakers", destinationEvidence: "Solar to \(qualifier) speakers")
        ])
        #expect(fixture.rejects(text: text, intent: intent, context: context))
        intent.branches[0].destination = "\(qualifier) speakers"
        let complete = try fixture.prepared(text: text, intent: intent, context: context)
        #expect(complete.request.destination == .custom)
        #expect(complete.request.outputConnectors == [.init(index: 1), .init(index: 2)])
    }

    @Test func explicitReplacementStillAcceptsSetupVocabularyInItsActualDirective() throws {
        let fixture = AssistantRoutingFixture()
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", destination: "mains", destinationEvidence: "Solar to mains")
        ], replacesSetup: true, modeEvidence: "replace the current studio graph")
        let draft = try fixture.prepared(
            text: "replace the current studio graph and route Solar to mains", intent: intent)
        #expect(draft.applicationMode == .replace)
    }
}

@MainActor
struct AssistantRoutingReviewRegressionTests {
    @Test(arguments: [false, true])
    func sourceToSourceRoutesCannotBecomeParallelMainsPaths(processed: Bool) {
        let text = processed ? "route Solar through evil pet into Osmose to mains"
            : "route Osmose to Solar then to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: processed ? "Solar" : "Osmose", effects: processed ? ["evil pet"] : [],
                  destination: "mains", destinationEvidence: text,
                  processingEvidence: processed ? "Solar through evil pet" : ""),
            .init(source: processed ? "Osmose" : "Solar", destination: "mains",
                  destinationEvidence: processed ? "Osmose to mains" : text)
        ])
        let fixture = AssistantRoutingFixture()
        #expect(fixture.rejects(text: text, intent: intent))
        let grouped = "route Osmose and Solar to mains"
        #expect(!fixture.rejects(text: grouped, intent: .init(branches: [
            .init(source: "Osmose", destination: "mains", destinationEvidence: grouped),
            .init(source: "Solar", destination: "mains", destinationEvidence: grouped)
        ])))
    }

    @Test(arguments: [false, true])
    func dryInConfiguredNamesOrLiveAliasesIsNotAnOperator(live: Bool) throws {
        let fixture = AssistantRoutingFixture()
        let gear = Equipment(name: live ? "Saved Synth" : "Dry Synth")
        var context = fixture.context
        context.equipment.append(gear)
        context.globalConnections.home.inputs.append(.init(connector: 9, equipmentID: gear.id, outputPort: 0))
        context.effectiveConnections = context.globalConnections.effectiveHome
        if live {
            context = AssistantBackendFixture.observe(
                [WingAddress.inputName(9): .string("Dry Synth")], context: context)
        }
        let text = "route Dry Synth to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Dry Synth", destination: "mains", destinationEvidence: text)
        ])
        let draft = try fixture.prepared(text: text, intent: intent, context: context)
        #expect(draft.request.sourceInstrumentIDs == [gear.id])
        #expect(fixture.rejects(text: text + " with dry and wet signal", intent: intent, context: context))
    }

    @Test func excludedLiveAliasesRetainProvenanceAcrossSameSessionChanges() async throws {
        let fixture = AssistantRoutingFixture()
        let session = UUID()
        let context = AssistantBackendFixture.observe([WingAddress.inputName(3): .string("Lead")],
            context: fixture.context, session: session)
        let text = "route Osmose to mains without Lead"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Osmose", destination: "mains", destinationEvidence: "Osmose to mains")
        ], excludedMentions: ["Lead"], exclusionEvidence: ["without Lead"])
        let draft = try fixture.prepared(text: text, intent: intent, context: context)
        #expect(draft.liveReferences?.map(\.equipmentID) == [fixture.solar.id])
        let changed = AssistantBackendFixture.observe([
            WingAddress.inputName(3): .string("Other"), WingAddress.inputName(1): .string("Lead")
        ], context: context, session: session)
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
        #expect(!(await coordinator.commitPreparedRouting(draft, expectedPending: nil,
            preparedContext: context, currentContext: changed)))
        #expect(coordinator.pendingStudioDraft == nil)
    }

    @Test(arguments: [false, true])
    func cancelledSaveRestoresPriorReviewWithoutOverwritingANewerDraft(replaced: Bool) async throws {
        let fixture = AssistantRoutingFixture()
        let store = RoutingTestDraftStore()
        let coordinator = AssistantCoordinator(draftStore: store)
        let prior = try fixture.prepared()
        #expect(await coordinator.commitPreparedRouting(prior, expectedPending: nil,
            preparedContext: fixture.context, currentContext: fixture.context))
        let chat = AssistantChatController(coordinator: coordinator,
            store: AssistantConversationStore(local: RoutingTestHistory(), cloud: nil),
            generator: RoutingTestGenerator(), actionInterpreter: RoutingTestInterpreter())
        await store.pauseNextSave()
        chat.composer = AssistantRoutingFixture.text
        chat.send(context: fixture.context)
        try await AssistantBackendFixture.waitAsync { await store.isWaiting }
        chat.cancel()
        var expected = prior
        if replaced {
            expected = try fixture.prepared()
            #expect(await coordinator.commitPreparedRouting(expected, expectedPending: coordinator.pendingStudioDraft,
                preparedContext: fixture.context, currentContext: fixture.context))
        }
        await store.resume()
        try await AssistantBackendFixture.waitAsync { await store.saves >= (replaced ? 4 : 3) }
        #expect(coordinator.pendingStudioDraft == expected)
        #expect(await store.draft == expected)
        #expect(chat.selectedConversation?.messages.last?.cards.isEmpty == true)
    }
}

private actor PausingRoutingDraftStore: PendingStudioPatchPersisting {
    private var draft: StudioPatchDraft?
    private var pauses = false
    private var gate: CheckedContinuation<Void, Never>?
    var isPaused: Bool { gate != nil }
    func load() -> StudioPatchDraft? { draft }
    func pauseNextSave() { pauses = true }
    func resume() { gate?.resume(); gate = nil }
    func save(_ draft: StudioPatchDraft?) async {
        self.draft = draft
        if pauses {
            pauses = false
            await withCheckedContinuation { gate = $0 }
        }
    }
}
