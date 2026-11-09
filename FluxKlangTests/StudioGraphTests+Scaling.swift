//
//  StudioGraphTests+Scaling.swift
//  FluxKlangTests
//
//  Behaviour-preservation and scaling tests for the studio routing planner's cycle and source queries.
//

import Foundation
import Testing
@testable import FluxKlang

extension StudioGraphTests {
    @Test func differentialPlannerMatchesLegacyOnGeneratedGraphs() {
        let sizes = [0, 1, 2, 3, 5, 8, 12, 16]
        var caseCount = 0
        var failures: [String] = []
        var withCycles = 0
        var withSources = 0
        var withSharedEndpoints = 0
        var withSharedUpstream = 0
        for size in sizes {
            for seed in 1...60 {
                let testCase = sgrCase(size: size, seed: UInt64(seed), acyclicOnly: seed % 2 == 0)
                let verdict = sgrVerdict(testCase)
                caseCount += 1
                withCycles += verdict.hasCycles ? 1 : 0
                withSources += verdict.hasSources ? 1 : 0
                withSharedEndpoints += verdict.hasTwoFedEndpoints ? 1 : 0
                withSharedUpstream += verdict.hasSharedUpstream ? 1 : 0
                failures.append(contentsOf: verdict.failures.map { "size \(size) seed \(seed): \($0)" })
            }
        }
        let expectedCases = 480
        #expect(caseCount == expectedCases)
        #expect(failures.isEmpty)
        // Floors are about 80 percent of what the seeded generator produces (173, 155, 134 and 89 of 480).
        let minimumCycles = 138
        let minimumSources = 124
        let minimumSharedEndpoints = 107
        let minimumSharedUpstream = 71
        #expect(withCycles >= minimumCycles)
        #expect(withSources >= minimumSources)
        #expect(withSharedEndpoints >= minimumSharedEndpoints)
        #expect(withSharedUpstream >= minimumSharedUpstream)
    }

    // A time limit cannot interrupt a CPU-bound loop, so on a regression this test hangs instead of failing cleanly.
    @Test(.timeLimit(.minutes(1))) func studioPlannerHandlesFortyDiamondStages() throws {
        let diamond = sgrDiamond(stages: 40)
        let plan = StudioRoutingPlanner.plan(for: diamond.graph, endpoints: [diamond.endpoint])

        let only = try #require(plan.endpointPlans.first)
        let expectedSources: Set<UUID> = [diamond.source]
        let expectedEdgeCount = 161
        let expectedPlanCount = 1
        #expect(plan.endpointPlans.count == expectedPlanCount)
        #expect(only.sourceNodeIDs == expectedSources)
        #expect(only.edgeIDs.count == expectedEdgeCount)
        #expect(plan.issues.isEmpty)
        #expect(plan.appliableEdgeIDs.count == expectedEdgeCount)
    }

    @Test func diamondChainSourcesAndEdgesAreExact() throws {
        try sgrExpectDiamond(stages: 1, edgeCount: 5)
        try sgrExpectDiamond(stages: 2, edgeCount: 9)
        try sgrExpectDiamond(stages: 3, edgeCount: 13)
    }

    @Test func selfLoopIsCyclicAndItsEdgeIsDropped() throws {
        let loop = sgrInstrument(0)
        let endpoint = StudioEndpoint(id: sgrID(3, 1), name: "E", destination: .finalMix)
        let sink = sgrEndpointNode(1, endpoint)
        let graph = StudioGraph(
            nodes: [loop, sink],
            edges: [sgrEdge(0, loop.id, loop.id), sgrEdge(1, loop.id, sink.id)]
        )

        let plan = StudioRoutingPlanner.plan(for: graph, endpoints: [endpoint])

        let only = try #require(plan.endpointPlans.first)
        let kinds = plan.issues.map(\.kind)
        let expectedKinds: [StudioRoutingIssue.Kind] = [.cycle(nodeID: loop.id), .unfinishedBranch(nodeID: loop.id)]
        #expect(kinds == expectedKinds)
        #expect(only.sourceNodeIDs.isEmpty)
        #expect(only.edgeIDs.isEmpty)
        #expect(plan.appliableEdgeIDs.isEmpty)
    }

    @Test func twoNodeCycleDropsBothNodesButKeepsDisconnectedBranch() throws {
        let first = sgrEffect(0)
        let second = sgrEffect(1)
        let source = sgrInstrument(2)
        let middle = sgrEffect(3)
        let endpoint = StudioEndpoint(id: sgrID(3, 4), name: "E", destination: .finalMix)
        let sink = sgrEndpointNode(4, endpoint)
        let keptFirst = sgrEdge(2, source.id, middle.id)
        let keptSecond = sgrEdge(3, middle.id, sink.id)
        let graph = StudioGraph(
            nodes: [first, second, source, middle, sink],
            edges: [sgrEdge(0, first.id, second.id), sgrEdge(1, second.id, first.id), keptFirst, keptSecond]
        )

        let plan = StudioRoutingPlanner.plan(for: graph, endpoints: [endpoint])

        let only = try #require(plan.endpointPlans.first)
        let kinds = Set(plan.issues.map(\.kind))
        let expectedKinds: Set<StudioRoutingIssue.Kind> = [
            .cycle(nodeID: first.id), .cycle(nodeID: second.id),
            .unfinishedBranch(nodeID: first.id), .unfinishedBranch(nodeID: second.id)
        ]
        let expectedSources: Set<UUID> = [source.id]
        let expectedEdges: Set<UUID> = [keptFirst.id, keptSecond.id]
        let expectedIssueCount = 4
        #expect(kinds == expectedKinds)
        #expect(plan.issues.count == expectedIssueCount)
        #expect(only.sourceNodeIDs == expectedSources)
        #expect(only.edgeIDs == expectedEdges)
        #expect(plan.appliableEdgeIDs == expectedEdges)
    }

    @Test func emptyAndSingleNodeGraphs() throws {
        let empty = StudioRoutingPlanner.plan(for: StudioGraph(), endpoints: [])
        #expect(empty.endpointPlans.isEmpty)
        #expect(empty.issues.isEmpty)
        #expect(empty.appliableEdgeIDs.isEmpty)

        let endpoint = StudioEndpoint(id: sgrID(3, 0), name: "E", destination: .finalMix)
        let single = StudioRoutingPlanner.plan(
            for: StudioGraph(nodes: [sgrEndpointNode(0, endpoint)]),
            endpoints: [endpoint]
        )
        let only = try #require(single.endpointPlans.first)
        let expectedPlanCount = 1
        #expect(single.endpointPlans.count == expectedPlanCount)
        #expect(only.sourceNodeIDs.isEmpty)
        #expect(only.edgeIDs.isEmpty)
        #expect(single.issues.isEmpty)
    }
}

// MARK: - Deterministic builders

private struct SGRng {
    var state: UInt64

    mutating func next() -> UInt64 {
        let multiplier: UInt64 = 6_364_136_223_846_793_005
        let increment: UInt64 = 1_442_695_040_888_963_407
        state = state &* multiplier &+ increment
        return state &>> 33
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

func sgrID(_ space: UInt8, _ index: Int) -> UUID {
    let high = UInt8((index >> 8) & 0xFF)
    let low = UInt8(index & 0xFF)
    return UUID(uuid: (space, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, high, low))
}

func sgrInstrument(_ index: Int) -> StudioNode {
    StudioNode(id: sgrID(1, index), kind: .instrument(sgrID(5, index)), title: "N\(index)")
}

func sgrEffect(_ index: Int) -> StudioNode {
    StudioNode(id: sgrID(1, index), kind: .effect(sgrID(4, index)), title: "N\(index)")
}

func sgrEndpointNode(_ index: Int, _ endpoint: StudioEndpoint) -> StudioNode {
    StudioNode(id: sgrID(1, index), kind: .endpoint(endpoint.id), title: "N\(index)")
}

func sgrEdge(_ index: Int, _ from: UUID, _ to: UUID) -> StudioEdge {
    StudioEdge(
        id: sgrID(2, index),
        from: StudioPortRef(nodeID: from, side: .output, port: 0),
        to: StudioPortRef(nodeID: to, side: .input, port: 0)
    )
}

private struct SGRDiamond {
    var graph: StudioGraph
    var endpoint: StudioEndpoint
    var source: UUID
}

// Source -> k stages of (two parallel effects joined by an effect) -> endpoint: 3k + 2 nodes, 4k + 1 edges.
private func sgrDiamond(stages: Int) -> SGRDiamond {
    let source = sgrInstrument(0)
    let endpoint = StudioEndpoint(id: sgrID(3, 0), name: "E", destination: .finalMix)
    var nodes = [source]
    var edges: [StudioEdge] = []
    var previous = source.id
    for stage in 1...stages {
        let left = sgrEffect(3 * stage - 2)
        let right = sgrEffect(3 * stage - 1)
        let join = sgrEffect(3 * stage)
        nodes.append(contentsOf: [left, right, join])
        for (from, to) in [(previous, left.id), (previous, right.id), (left.id, join.id), (right.id, join.id)] {
            edges.append(sgrEdge(edges.count, from, to))
        }
        previous = join.id
    }
    let sink = sgrEndpointNode(3 * stages + 1, endpoint)
    nodes.append(sink)
    edges.append(sgrEdge(edges.count, previous, sink.id))
    return SGRDiamond(graph: StudioGraph(nodes: nodes, edges: edges), endpoint: endpoint, source: source.id)
}

private func sgrExpectDiamond(stages: Int, edgeCount: Int) throws {
    let diamond = sgrDiamond(stages: stages)
    let plan = StudioRoutingPlanner.plan(for: diamond.graph, endpoints: [diamond.endpoint])
    let only = try #require(plan.endpointPlans.first)
    let expectedSources: Set<UUID> = [diamond.source]
    #expect(only.sourceNodeIDs == expectedSources)
    #expect(only.edgeIDs.count == edgeCount)
    #expect(plan.appliableEdgeIDs.count == edgeCount)
    #expect(plan.issues.isEmpty)
}

private struct SGRCase {
    var graph: StudioGraph
    var endpoints: [StudioEndpoint]
}

private func sgrAppendEdge(_ edges: inout [StudioEdge], from: UUID, to: UUID, rng: inout SGRng) {
    var target = to
    if rng.below(12) == 0 { target = sgrID(9, edges.count) }
    var edge = sgrEdge(edges.count, from, target)
    if rng.below(10) == 0 { edge.to.side = .output }
    edges.append(edge)
    if rng.below(6) == 0 {
        var copy = edge
        copy.id = sgrID(2, edges.count)
        edges.append(copy)
    }
}

private func sgrNodes(
    size: Int,
    forcedEndpoints: Bool,
    rng: inout SGRng
) -> (nodes: [StudioNode], endpoints: [StudioEndpoint]) {
    var nodes: [StudioNode] = []
    var endpoints: [StudioEndpoint] = []
    for index in 0..<size {
        let forced = forcedEndpoints && index >= size - 2
        let roll = rng.below(6)
        if forced || roll >= 4 {
            let endpoint = StudioEndpoint(id: sgrID(3, index), name: "E\(index)", destination: .finalMix)
            if forced || roll == 4 { endpoints.append(endpoint) }
            nodes.append(sgrEndpointNode(index, endpoint))
        } else if roll >= 2 {
            nodes.append(sgrEffect(index))
        } else {
            nodes.append(sgrInstrument(index))
        }
    }
    return (nodes, endpoints)
}

private func sgrCase(size: Int, seed: UInt64, acyclicOnly: Bool) -> SGRCase {
    var rng = SGRng(state: seed &* 7_919 &+ UInt64(size))
    let forcedEndpoints = acyclicOnly && size >= 5
    let built = sgrNodes(size: size, forcedEndpoints: forcedEndpoints, rng: &rng)
    var nodes = built.nodes
    var edges: [StudioEdge] = []
    for index in 0..<size {
        for _ in 0..<rng.below(4) {
            if acyclicOnly {
                guard index > 0 else { break }
                let from = nodes[rng.below(index)].id
                sgrAppendEdge(&edges, from: from, to: nodes[index].id, rng: &rng)
            } else {
                let from = nodes[rng.below(size)].id
                sgrAppendEdge(&edges, from: from, to: nodes[rng.below(size)].id, rng: &rng)
            }
        }
    }
    if forcedEndpoints {
        for sink in nodes[(size - 2)...] {
            let upstream = nodes[rng.below(size - 2)].id
            sgrAppendEdge(&edges, from: nodes[0].id, to: sink.id, rng: &rng)
            sgrAppendEdge(&edges, from: upstream, to: sink.id, rng: &rng)
        }
    }
    if size >= 3 { nodes.append(sgrInstrument(size)) }
    return SGRCase(graph: StudioGraph(nodes: nodes, edges: edges), endpoints: built.endpoints)
}

// MARK: - Verbatim copy of the legacy algorithm (only `private static` became file-private free functions)

private struct SGRContext {
    var incoming: [StudioNode.ID: [StudioEdge]]
    var nodeByID: [StudioNode.ID: StudioNode]
}

private func sgrIsEndpoint(_ node: StudioNode) -> Bool {
    if case .endpoint = node.kind { return true }
    return false
}

private func sgrCycleIssue(_ nodeID: StudioNode.ID, _ title: String) -> StudioRoutingIssue {
    StudioRoutingIssue(
        severity: .error,
        kind: .cycle(nodeID: nodeID),
        message: "\(title) is part of an unsupported feedback cycle."
    )
}

private func sgrIsCycle(_ kind: StudioRoutingIssue.Kind) -> Bool {
    if case .cycle = kind { return true }
    return false
}

private func referenceCyclicNodes(in nodes: [StudioNode], edges: [StudioEdge]) -> Set<StudioNode.ID> {
    let outgoing = Dictionary(grouping: edges, by: \.from.nodeID)
    return Set(nodes.compactMap { node in
        referenceReaches(
            node.id,
            from: node.id,
            outgoing: outgoing,
            visited: [],
            requiresEdge: true
        ) ? node.id : nil
    })
}

private func referenceReaches(
    _ target: StudioNode.ID,
    from current: StudioNode.ID,
    outgoing: [StudioNode.ID: [StudioEdge]],
    visited: Set<StudioNode.ID>,
    requiresEdge: Bool
) -> Bool {
    if !requiresEdge, current == target { return true }
    guard !visited.contains(current) else { return false }
    let nextVisited = visited.union([current])
    return (outgoing[current] ?? []).contains {
        referenceReaches(
            target,
            from: $0.to.nodeID,
            outgoing: outgoing,
            visited: nextVisited,
            requiresEdge: false
        )
    }
}

private func referenceSourceNodes(
    reaching nodeID: StudioNode.ID,
    context: SGRContext,
    visited: inout Set<StudioNode.ID>,
    edgeIDs: inout Set<StudioEdge.ID>,
    issues: inout [StudioRoutingIssue]
) -> Set<StudioNode.ID> {
    guard let node = context.nodeByID[nodeID], node.kind.isRoutable else { return [] }
    guard !visited.contains(nodeID) else {
        issues.append(sgrCycleIssue(nodeID, node.title))
        return []
    }
    let edges = context.incoming[nodeID] ?? []
    if edges.isEmpty {
        return sgrIsEndpoint(node) ? [] : [nodeID]
    }
    visited.insert(nodeID)
    var sources: Set<StudioNode.ID> = []
    for edge in edges {
        edgeIDs.insert(edge.id)
        sources.formUnion(referenceSourceNodes(
            reaching: edge.from.nodeID,
            context: context,
            visited: &visited,
            edgeIDs: &edgeIDs,
            issues: &issues
        ))
    }
    visited.remove(nodeID)
    return sources
}

private struct SGRReference {
    var cyclic: Set<StudioNode.ID>
    var plans: [StudioEndpointPlan]
    var cycleIssues: [StudioRoutingIssue]
    var sourceIssues: [StudioRoutingIssue]
}

private func referencePlan(graph: StudioGraph, endpoints: [StudioEndpoint]) -> SGRReference {
    let endpointByID = Dictionary(endpoints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let nodeByID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let structurallyValidEdges = graph.edges.filter { edge in
        edge.from.side == .output && edge.to.side == .input &&
            nodeByID[edge.from.nodeID]?.kind.isRoutable == true &&
            nodeByID[edge.to.nodeID]?.kind.isRoutable == true
    }
    let cyclic = referenceCyclicNodes(in: graph.nodes, edges: structurallyValidEdges)
    let validEdges = structurallyValidEdges.filter {
        !cyclic.contains($0.from.nodeID) && !cyclic.contains($0.to.nodeID)
    }
    let incoming = Dictionary(grouping: validEdges, by: \.to.nodeID)
    let context = SGRContext(incoming: incoming, nodeByID: nodeByID)
    var issues: [StudioRoutingIssue] = []
    let cycleIssues = cyclic.compactMap { nodeID in
        nodeByID[nodeID].map { sgrCycleIssue(nodeID, $0.title) }
    }
    var plans: [StudioEndpointPlan] = []
    for node in graph.nodes {
        guard case .endpoint(let endpointID) = node.kind, let endpoint = endpointByID[endpointID] else { continue }
        var visited: Set<StudioNode.ID> = []
        var edgeIDs: Set<StudioEdge.ID> = []
        let sourceIDs = referenceSourceNodes(
            reaching: node.id,
            context: context,
            visited: &visited,
            edgeIDs: &edgeIDs,
            issues: &issues
        )
        plans.append(StudioEndpointPlan(
            endpoint: endpoint,
            nodeID: node.id,
            sourceNodeIDs: sourceIDs,
            edgeIDs: edgeIDs
        ))
    }
    return SGRReference(cyclic: cyclic, plans: plans, cycleIssues: cycleIssues, sourceIssues: issues)
}

private struct SGRVerdict {
    var failures: [String] = []
    var hasCycles = false
    var hasSources = false
    var hasTwoFedEndpoints = false
    var hasSharedUpstream = false
}

private func sgrVerdict(_ testCase: SGRCase) -> SGRVerdict {
    let plan = StudioRoutingPlanner.plan(for: testCase.graph, endpoints: testCase.endpoints)
    let reference = referencePlan(graph: testCase.graph, endpoints: testCase.endpoints)
    var verdict = SGRVerdict()
    let newCycles = plan.issues.filter { sgrIsCycle($0.kind) }
    let plansEqual = plan.endpointPlans == reference.plans
    let newKinds = Set(newCycles.map(\.kind))
    let referenceKinds = Set(reference.cyclic.map { StudioRoutingIssue.Kind.cycle(nodeID: $0) })
    let referenceAppliable = Set(reference.plans.flatMap(\.edgeIDs))
    let kindsEqual = newKinds == referenceKinds
    let appliableEqual = plan.appliableEdgeIDs == referenceAppliable
    let issuesEqual = Set(newCycles) == Set(reference.cycleIssues) && newCycles.count == reference.cycleIssues.count
    if !plansEqual { verdict.failures.append("endpoint plans differ") }
    if !kindsEqual { verdict.failures.append("cycle kinds differ") }
    if !issuesEqual { verdict.failures.append("cycle issues differ") }
    if !appliableEqual { verdict.failures.append("appliable edges differ") }
    if !reference.sourceIssues.isEmpty { verdict.failures.append("legacy source walk reported an issue") }
    verdict.hasCycles = !reference.cyclic.isEmpty
    verdict.hasSources = reference.plans.contains { !$0.sourceNodeIDs.isEmpty }
    verdict.hasTwoFedEndpoints = reference.plans.filter { !$0.edgeIDs.isEmpty }.count >= 2
    // Two endpoints that both reach an edge share a non-leaf upstream node (the edge's target has an input).
    var seenEdges: Set<StudioEdge.ID> = []
    for plan in reference.plans {
        for edgeID in plan.edgeIDs where !seenEdges.insert(edgeID).inserted {
            verdict.hasSharedUpstream = true
        }
    }
    return verdict
}
