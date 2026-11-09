//
//  StudioGraphTests+ScalingCycles.swift
//  FluxKlangTests
//
//  Hand-built cycle and duplicate-issue cases for the studio routing planner's cycle and source queries.
//

import Foundation
import Testing
@testable import FluxKlang

extension StudioGraphTests {
    // A cycle that does not contain the entry node A. A time limit cannot interrupt a CPU-bound loop, so if the
    // walk's seen guard is removed the run hangs until the harness timeout: that proves a hang, not a clean
    // failure, and no timing-free kill exists for this mutant.
    @Test(.timeLimit(.minutes(1))) func cycleBehindAnEntryNodeTerminates() throws {
        let entry = sgrInstrument(0)
        let first = sgrEffect(1)
        let second = sgrEffect(2)
        let endpoint = StudioEndpoint(id: sgrID(3, 3), name: "E", destination: .finalMix)
        let sink = sgrEndpointNode(3, endpoint)
        let graph = StudioGraph(
            nodes: [entry, first, second, sink],
            edges: [
                sgrEdge(0, entry.id, first.id), sgrEdge(1, first.id, second.id),
                sgrEdge(2, second.id, first.id), sgrEdge(3, second.id, sink.id)
            ]
        )

        let plan = StudioRoutingPlanner.plan(for: graph, endpoints: [endpoint])

        let only = try #require(plan.endpointPlans.first)
        let cycleKinds = Set(plan.issues.map(\.kind).filter { kind in
            if case .cycle = kind { return true }
            return false
        })
        let expectedKinds: Set<StudioRoutingIssue.Kind> = [.cycle(nodeID: first.id), .cycle(nodeID: second.id)]
        #expect(cycleKinds == expectedKinds)
        #expect(only.sourceNodeIDs.isEmpty)
        #expect(only.edgeIDs.isEmpty)
        #expect(plan.appliableEdgeIDs.isEmpty)
    }

    // A cyclic endpoint fed by a non-cyclic source: the feeder wire enters a cyclic node, so it is dropped.
    // Kills M25 (the to-side filter removed would give the endpoint the source X); the differential also kills it.
    @Test func cyclicEndpointWithNonCyclicFeederGetsNoSources() throws {
        let feeder = sgrInstrument(0)
        let loopEffect = sgrEffect(1)
        let endpoint = StudioEndpoint(id: sgrID(3, 2), name: "E", destination: .finalMix)
        let sink = sgrEndpointNode(2, endpoint)
        let graph = StudioGraph(
            nodes: [feeder, loopEffect, sink],
            edges: [
                sgrEdge(0, feeder.id, sink.id), sgrEdge(1, sink.id, loopEffect.id), sgrEdge(2, loopEffect.id, sink.id)
            ]
        )

        let plan = StudioRoutingPlanner.plan(for: graph, endpoints: [endpoint])

        let planCount = plan.endpointPlans.count
        let expectedPlanCount = 1
        #expect(planCount == expectedPlanCount)
        let only = try #require(plan.endpointPlans.first)
        let cycleKinds = Set(plan.issues.map(\.kind).filter { kind in
            if case .cycle = kind { return true }
            return false
        })
        let expectedKinds: Set<StudioRoutingIssue.Kind> = [.cycle(nodeID: sink.id), .cycle(nodeID: loopEffect.id)]
        #expect(cycleKinds == expectedKinds)
        #expect(only.sourceNodeIDs.isEmpty)
        #expect(only.edgeIDs.isEmpty)
        #expect(plan.appliableEdgeIDs.isEmpty)
    }

    @Test func threeNodeRingIsFullyCyclic() throws {
        let first = sgrEffect(0)
        let second = sgrEffect(1)
        let third = sgrEffect(2)
        let endpoint = StudioEndpoint(id: sgrID(3, 3), name: "E", destination: .finalMix)
        let sink = sgrEndpointNode(3, endpoint)
        let graph = StudioGraph(
            nodes: [first, second, third, sink],
            edges: [
                sgrEdge(0, first.id, second.id), sgrEdge(1, second.id, third.id),
                sgrEdge(2, third.id, first.id), sgrEdge(3, first.id, sink.id)
            ]
        )

        let plan = StudioRoutingPlanner.plan(for: graph, endpoints: [endpoint])

        let only = try #require(plan.endpointPlans.first)
        let cycleKinds = Set(plan.issues.map(\.kind).filter { kind in
            if case .cycle = kind { return true }
            return false
        })
        let expectedKinds: Set<StudioRoutingIssue.Kind> = [
            .cycle(nodeID: first.id), .cycle(nodeID: second.id), .cycle(nodeID: third.id)
        ]
        #expect(cycleKinds == expectedKinds)
        #expect(only.sourceNodeIDs.isEmpty)
        #expect(plan.appliableEdgeIDs.isEmpty)
    }

    // Verdict: kills no mutant. Duplicate wires are absorbed by the edge and source sets in the old and new walk alike.
    @Test func duplicateEdgesDoNotChangeSources() throws {
        let source = sgrInstrument(0)
        let middle = sgrEffect(1)
        let endpoint = StudioEndpoint(id: sgrID(3, 2), name: "E", destination: .finalMix)
        let sink = sgrEndpointNode(2, endpoint)
        let edges = [
            sgrEdge(0, source.id, middle.id), sgrEdge(1, source.id, middle.id),
            sgrEdge(2, middle.id, sink.id), sgrEdge(3, middle.id, sink.id),
            sgrEdge(4, source.id, sink.id)
        ]
        let graph = StudioGraph(nodes: [source, middle, sink], edges: edges)

        let plan = StudioRoutingPlanner.plan(for: graph, endpoints: [endpoint])

        let only = try #require(plan.endpointPlans.first)
        let expectedSources: Set<UUID> = [source.id]
        let expectedEdges = Set(edges.map(\.id))
        let expectedEdgeCount = 5
        #expect(only.sourceNodeIDs == expectedSources)
        #expect(only.edgeIDs == expectedEdges)
        #expect(only.edgeIDs.count == expectedEdgeCount)
        #expect(plan.issues.isEmpty)
    }

    // Verdict: kills no mutant. A wire to an unknown node is dropped before the walk; it pins the unchanged behaviour.
    @Test func unknownEndpointEdgeIsIgnored() throws {
        let source = sgrInstrument(0)
        let endpoint = StudioEndpoint(id: sgrID(3, 1), name: "E", destination: .finalMix)
        let sink = sgrEndpointNode(1, endpoint)
        let kept = sgrEdge(0, source.id, sink.id)
        let dangling = sgrEdge(1, source.id, sgrID(9, 0))
        let graph = StudioGraph(nodes: [source, sink], edges: [kept, dangling])

        let plan = StudioRoutingPlanner.plan(for: graph, endpoints: [endpoint])

        let only = try #require(plan.endpointPlans.first)
        let kinds = plan.issues.map(\.kind)
        let expectedKinds: [StudioRoutingIssue.Kind] = [.missingNode(edgeID: dangling.id)]
        let expectedSources: Set<UUID> = [source.id]
        let expectedEdges: Set<UUID> = [kept.id]
        #expect(kinds == expectedKinds)
        #expect(only.sourceNodeIDs == expectedSources)
        #expect(only.edgeIDs == expectedEdges)
        #expect(plan.appliableEdgeIDs == expectedEdges)
    }

    // Two wires with the same ID both point at a missing node, so the planner records the same issue kind twice.
    @Test func duplicateIssueKindsAreReportedOnce() throws {
        let source = sgrInstrument(0)
        let endpoint = StudioEndpoint(id: sgrID(3, 1), name: "E", destination: .finalMix)
        let sink = sgrEndpointNode(1, endpoint)
        let kept = sgrEdge(0, source.id, sink.id)
        let dangling = sgrEdge(1, source.id, sgrID(9, 0))
        let graph = StudioGraph(nodes: [source, sink], edges: [kept, dangling, dangling])

        let plan = StudioRoutingPlanner.plan(for: graph, endpoints: [endpoint])

        let kinds = plan.issues.map(\.kind)
        let expectedKinds: [StudioRoutingIssue.Kind] = [.missingNode(edgeID: dangling.id)]
        #expect(kinds == expectedKinds)
    }
}
