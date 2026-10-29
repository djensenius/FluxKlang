import CoreGraphics
import Foundation
import Testing
@testable import FluxKlang

struct StudioWiringAdvisorLayoutTests {
    @Test func advisorPlacesMultipleSourcesAndEffectChainWithoutOverlaps() {
        let sources = (0..<4).map { Equipment(name: "Source \($0)", outputs: ["Out"]) }
        let effects = (0..<5).map { Effect(name: "Effect \($0)") }
        let draft = StudioWiringAdvisor.build(
            request: StudioWiringRequest(
                sourceInstrumentIDs: sources.map(\.id), effectChainIDs: effects.map(\.id), applicationMode: .replace
            ),
            equipment: sources, effects: effects,
            connections: GlobalStudioConnections(), currentGraph: StudioGraph()
        )

        #expect(draft.fragment.nodes.count == 10)
        expectNoOverlap(draft.fragment.nodes.map(\.node))
    }

    @Test func advisorAppendPreservesCustomPositionsAndAvoidsEveryOccupiedLane() {
        let source = Equipment(name: "Source", outputs: ["Out"])
        let effect = Effect(name: "New Effect")
        let sourceNode = StudioNode(
            kind: .instrument(source.id), title: source.name, position: CGPoint(x: -400, y: -300)
        )
        let blocker = StudioNode(
            kind: .effect(UUID()), title: "Custom Gear", position: StudioCanvasGeometry.gearPosition(at: 0)
        )
        let movedControl = StudioNode(
            kind: .endpoint(UUID()), title: "Moved Control", position: StudioCanvasGeometry.gearPosition(at: 1)
        )
        let graph = StudioGraph(nodes: [sourceNode, blocker, movedControl])
        let savedPositions = graph.nodes.map(\.position)
        let draft = StudioWiringAdvisor.build(
            request: StudioWiringRequest(sourceInstrumentIDs: [source.id], effectChainIDs: [effect.id]),
            equipment: [source], effects: [effect], connections: GlobalStudioConnections(), currentGraph: graph
        )
        let reused = draft.fragment.nodes.first { $0.node.id == sourceNode.id }
        let added = draft.fragment.nodes.filter { !$0.reusesExistingNode }.map(\.node)

        #expect(reused?.reusesExistingNode == true)
        #expect(reused?.node.position == sourceNode.position)
        #expect(graph.nodes.map(\.position) == savedPositions)
        #expect(added.first { $0.kind == .effect(effect.id) }?.position == StudioCanvasGeometry.gearPosition(at: 2))
        expectNoOverlap(graph.nodes + added)
    }

    @Test func advisorReaddsDeletedMiddleSourceInItsFreeSlotWithoutMovingSurvivors() throws {
        let sources = (0..<3).map { Equipment(name: "Source \($0)", outputs: ["Out"]) }
        let request = StudioWiringRequest(sourceInstrumentIDs: sources.map(\.id))
        let first = StudioWiringAdvisor.build(
            request: request, equipment: sources, effects: [],
            connections: GlobalStudioConnections(), currentGraph: StudioGraph()
        )
        var graph = StudioGraph(nodes: first.fragment.nodes.map(\.node))
        let removed = try #require(graph.nodes.first { $0.kind == .instrument(sources[1].id) })
        graph.removeNode(removed.id)
        let survivors = graph.nodes
        let next = StudioWiringAdvisor.build(
            request: request, equipment: sources, effects: [],
            connections: GlobalStudioConnections(), currentGraph: graph
        )
        let readded = try #require(next.fragment.nodes.first { $0.node.kind == removed.kind })

        #expect(!readded.reusesExistingNode)
        #expect(readded.node.position == removed.position)
        for survivor in survivors {
            #expect(next.fragment.nodes.first { $0.node.id == survivor.id }?.node.position == survivor.position)
        }
        expectNoOverlap(next.fragment.nodes.map(\.node))
    }

    @Test func advisorMultipleRoutesReserveEarlierDraftPositionsAndReuseSharedSource() {
        let sources = (0..<2).map { Equipment(name: "Source \($0)", outputs: ["Out"]) }
        let effects = (0..<3).map { Effect(name: "Effect \($0)") }
        let draft = StudioWiringAdvisor.build(
            request: StudioWiringRequest(
                sourceInstrumentIDs: [sources[0].id], effectChainIDs: [effects[0].id, effects[1].id],
                additionalRoutes: [StudioWiringRoute(
                    sourceInstrumentIDs: sources.map(\.id), effectChainIDs: [effects[2].id], destination: .space
                )],
                applicationMode: .replace
            ),
            equipment: sources, effects: effects,
            connections: GlobalStudioConnections(), currentGraph: StudioGraph()
        )

        #expect(draft.fragment.nodes.count == 7)
        #expect(draft.fragment.nodes.filter { $0.node.kind == .instrument(sources[0].id) }.count == 1)
        #expect(draft.fragment.endpoints.count == 2)
        expectNoOverlap(draft.fragment.nodes.map(\.node))
    }

    private func expectNoOverlap(_ nodes: [StudioNode]) {
        for index in nodes.indices {
            for other in nodes.dropFirst(index + 1) {
                #expect(!StudioCanvasGeometry.cardRect(center: nodes[index].position).intersects(
                    StudioCanvasGeometry.cardRect(center: other.position)
                ))
            }
        }
    }
}
