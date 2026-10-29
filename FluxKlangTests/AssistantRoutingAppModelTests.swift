import Foundation
import Testing
@testable import FluxKlang

@MainActor
@Suite(.serialized)
struct AssistantRoutingAppModelTests {
    private func model(fixture: AssistantRoutingFixture) async throws -> AppModel {
        let model = AppModel(assistant: AssistantCoordinator(draftStore: RoutingTestDraftStore()), wing: .preview())
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
}
