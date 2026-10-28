import Foundation
import Testing

@testable import FluxKlang

struct StudioLiveChannelBindingTests {
    private func binding(session: UUID = UUID()) -> StudioLiveChannelBinding {
        .init(
            observedSessionID: session,
            members: [
                .init(channel: 7, label: "Mother-32", sourceGroup: "LCL", sourceIndex: 2, equipmentID: nil)
            ])
    }

    private func compile(_ graph: StudioGraph, endpoints: [StudioEndpoint] = [], equipment: [Equipment] = [])
        -> StudioCompiledRouting {
        StudioSignalCompiler.compile(
            .init(
                graph: graph, endpoints: endpoints, effects: [],
                connections: GlobalStudioConnections(
                    home: StudioHomeConnections(
                        inputs: equipment.map {
                            StudioInputConnection(connector: 1, equipmentID: $0.id, outputPort: 0)
                        })), equipment: equipment, speakers: []))
    }

    @Test func addingMovingRemovingShortcutLeavesCompiledSettingsAndAllocationsIdentical() {
        let gear = Equipment(name: "Source")
        let instrument = StudioNode(kind: .instrument(gear.id), title: gear.name)
        let endpoint = StudioEndpoint(name: "Dry", destination: .finalMix)
        let destination = StudioNode(kind: .endpoint(endpoint.id), title: endpoint.name)
        var graph = StudioGraph(nodes: [instrument, destination])
        graph.connect(
            from: .init(nodeID: instrument.id, side: .output, port: 0),
            to: .init(nodeID: destination.id, side: .input, port: 0))
        let baseline = compile(graph, endpoints: [endpoint], equipment: [gear])
        #expect(!baseline.resourcePlan.allocations.isEmpty)
        let shortcut = StudioNode(kind: .liveChannel(binding()), title: "Live Mother-32")
        graph.addNode(shortcut)
        let added = compile(graph, endpoints: [endpoint], equipment: [gear])
        #expect(added.settings == baseline.settings)
        #expect(added.resourcePlan == baseline.resourcePlan)
        #expect(added.routingPlan == baseline.routingPlan)
        graph.moveNode(shortcut.id, to: .init(x: -200, y: 2000))
        #expect(compile(graph, endpoints: [endpoint], equipment: [gear]).settings == baseline.settings)
        graph.removeNode(shortcut.id)
        #expect(compile(graph, endpoints: [endpoint], equipment: [gear]).settings == baseline.settings)
    }

    @Test func shortcutHasZeroPortsAndDecodedIncidentEdgesFailClosedBeforeBusAllocation() throws {
        let live = StudioNode(kind: .liveChannel(binding()), title: "Live")
        let endpoint = StudioEndpoint(name: "Dry", destination: .finalMix)
        let destination = StudioNode(kind: .endpoint(endpoint.id), title: endpoint.name)
        let edge = StudioEdge(
            from: .init(nodeID: live.id, side: .output, port: 0),
            to: .init(nodeID: destination.id, side: .input, port: 0))
        var graph = StudioGraph(nodes: [live, destination])
        graph.connect(from: edge.from, to: edge.to)
        #expect(graph.edges.isEmpty)
        graph.connect(
            from: .init(nodeID: destination.id, side: .output, port: 0),
            to: .init(nodeID: live.id, side: .input, port: 0))
        #expect(graph.edges.isEmpty)
        graph.edges = [edge]
        let decoded = try JSONDecoder().decode(StudioGraph.self, from: JSONEncoder().encode(graph))
        let compiled = compile(decoded, endpoints: [endpoint])
        #expect(compiled.hasErrors)
        #expect(
            compiled.routingPlan.issues.contains {
                if case .nonroutableLiveChannel(let id) = $0.kind { return id == edge.id }
                return false
            })
        #expect(compiled.routingPlan.endpointPlans.allSatisfy { $0.sourceNodeIDs.isEmpty })
        #expect(compiled.resourcePlan.allocations.isEmpty)
        #expect(compiled.settings.isEmpty)
    }

    @Test func bindingAndEnvironmentCodecContainDisplayEvidenceNotAuthorization() throws {
        let saved = binding()
        let graph = StudioGraph(nodes: [.init(kind: .liveChannel(saved), title: "Live Mother-32")])
        let environment = RoutingEnvironment(name: "Live", studioGraph: graph)
        let encoded = try JSONEncoder().encode(environment)
        let decoded = try JSONDecoder().decode(RoutingEnvironment.self, from: encoded)
        #expect(decoded.studioGraph == graph)
        #expect(saved.isWellFormed)
        let json = try #require(String(data: encoded, encoding: .utf8)).lowercased()
        #expect(!json.contains("authorization"))
        #expect(!json.contains("pendingreview"))
        #expect(!json.contains("deadline"))
        let malformed = StudioLiveChannelBinding(
            observedSessionID: UUID(),
            members: [
                .init(channel: 7, label: "L", sourceGroup: nil, sourceIndex: nil, equipmentID: nil),
                .init(channel: 7, label: "R", sourceGroup: nil, sourceIndex: nil, equipmentID: nil)
            ], pairStripID: UUID())
        #expect(!malformed.isWellFormed)
    }

    @MainActor
    @Test func storeDedupesCurrentUnitRebindsOnlyReviewedEvidenceAndNeverConnectsIt() throws {
        let store = EnvironmentStore()
        let environment = store.addEnvironment(named: "Live test")
        let saved = binding()
        let first = try #require(
            store.addLiveChannelShortcut(
                saved, title: "First", environmentID: environment,
                expectedGraph: store.activeStudioGraph))
        #expect(first.added)
        let rebound = StudioLiveChannelBinding(
            observedSessionID: saved.observedSessionID,
            members: [
                .init(channel: 7, label: "Renamed", sourceGroup: "LCL", sourceIndex: 4, equipmentID: nil)
            ])
        let again = try #require(
            store.addLiveChannelShortcut(
                rebound, title: "Renamed", environmentID: environment,
                expectedGraph: store.activeStudioGraph))
        #expect(!again.added)
        #expect(again.nodeID == first.nodeID)
        #expect(store.activeStudioGraph.nodes.count == 1)
        #expect(store.activeStudioEndpoints.isEmpty)
        let gear = StudioNode(kind: .instrument(UUID()), title: "Gear")
        store.addStudioNode(gear)
        store.connectStudio(
            from: .init(nodeID: gear.id, side: .output, port: 0),
            to: .init(nodeID: first.nodeID, side: .input, port: 0))
        #expect(store.activeStudioGraph.edges.isEmpty)
        #expect(
            store.addLiveChannelShortcut(
                saved, title: "stale", environmentID: environment,
                expectedGraph: StudioGraph()) == nil)
        store.removeStudioNode(first.nodeID)
        #expect(store.activeStudioGraph.nodes == [gear])
        store.remove(environment)
    }
}
