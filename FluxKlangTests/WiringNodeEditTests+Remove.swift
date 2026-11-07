//
//  WiringNodeEditTests+Remove.swift
//  FluxKlangTests
//
//  Removing a node (#101 WP4): the plan of attached edges, the atomic
//  disconnect-then-remove gesture, drafts that already touch the node, the
//  gesture bound at N and N+1, and a 20-node property check that a removal
//  touches nothing else and that the plan is what `remove` folds.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture
private typealias Nodes = WiringNodeEditTests

extension WiringNodeEditTests {
    static let verbEdges = [
        "edg.delay-verb-fb", "edg.echo-verb", "edg.keys-verb", "edg.mic-verb", "edg.verb-delay", "edg.verb-mains"
    ]

    /// 20 nodes in a ring, each wired to the next and the one seven ahead, plus a self-loop on n05.
    static func twentyNodes() -> GraphDocument {
        let ids = (0..<20).map { "nod.n" + padded($0) }
        let nodes = ids.map { node($0, ports: []) }
        var edges: [GraphEdge] = []
        for index in 0..<20 {
            edges.append(wire("edg.r" + padded(index), ids[index], ids[(index + 1) % 20]))
            edges.append(wire("edg.s" + padded(index), ids[index], ids[(index + 7) % 20]))
        }
        edges.append(wire("edg.loop", ids[5], ids[5]))
        return GraphDocument(id: Fixture.graphID, nodes: nodes, edges: edges)
    }

    @Test func nodePlanListsEveryAttachedEdgeAscendingByRawID() throws {
        let plan = try WiringNodeComposer.removalPlan(node: Nodes.verb, from: Nodes.draft(), active: Fixture.graph)
        #expect(plan.edgesToDisconnect.map(\.rawValue) == Nodes.verbEdges)
        #expect(plan.gesture == Nodes.disconnects(Nodes.verbEdges) + [.removeNode(Nodes.verb)])
    }

    @Test func nodeRemoveFoldsOneDisconnectPerAttachedEdgeThenTheRemoval() throws {
        let result = try WiringNodeComposer.remove(node: Nodes.verb, from: Nodes.draft(), active: Fixture.graph)
        #expect(result.edits == Nodes.disconnects(Nodes.verbEdges) + [.removeNode(Nodes.verb)])
        let graph = try Fixture.graph.applying(result.edits)
        #expect(graph.node(Nodes.verb) == nil)
        #expect(graph.nodes.count == Fixture.graph.nodes.count - 1)
        #expect(graph.edges.isEmpty)
    }

    @Test func nodeRemoveGivesEqualDraftsForBothActiveInputOrders() throws {
        var reversed = Fixture.graph
        reversed.edges.reverse()
        reversed.nodes.reverse()
        let forward = try WiringNodeComposer.remove(node: Nodes.verb, from: Nodes.draft(), active: Fixture.graph)
        let backward = try WiringNodeComposer.remove(
            node: Nodes.verb, from: Nodes.draft(on: reversed), active: reversed
        )
        #expect(forward == backward)
        let planForward = try WiringNodeComposer.removalPlan(
            node: Nodes.verb, from: Nodes.draft(), active: Fixture.graph
        )
        let planBackward = try WiringNodeComposer.removalPlan(
            node: Nodes.verb, from: Nodes.draft(on: reversed), active: reversed
        )
        #expect(planForward == planBackward)
        #expect(planBackward.edgesToDisconnect.map(\.rawValue) == Nodes.verbEdges)
    }

    @Test func nodeRemoveAppendsAfterTheExistingEditsAndDropsTheNodesOwnMove() throws {
        let other = GraphEdit.moveNode(Nodes.nodeID("nod.mic"), to: GraphPoint(x: 9, y: 9))
        let own = GraphEdit.moveNode(Nodes.keys, to: GraphPoint(x: 5, y: 5))
        let result = try WiringNodeComposer.remove(
            node: Nodes.keys, from: Nodes.draft([other, own]), active: Fixture.graph
        )
        #expect(result.edits == [other, .disconnect(Nodes.edgeID("edg.keys-verb")), .removeNode(Nodes.keys)])
    }

    @Test func nodeRemoveOfANodeWithNoEdgesFoldsOnlyTheRemoval() throws {
        let plan = try WiringNodeComposer.removalPlan(node: Nodes.shortcut, from: Nodes.draft(), active: Fixture.graph)
        #expect(plan.edgesToDisconnect.isEmpty)
        let result = try WiringNodeComposer.remove(node: Nodes.shortcut, from: Nodes.draft(), active: Fixture.graph)
        #expect(result.edits == [.removeNode(Nodes.shortcut)])
    }

    @Test func nodeRemoveListsASelfLoopOnce() throws {
        let loop = Fixture.edge("edg.self", Fixture.address("nod.verb", "out"), Fixture.address("nod.verb", "in"))
        let active = Fixture.with([loop])
        let plan = try WiringNodeComposer.removalPlan(node: Nodes.verb, from: Nodes.draft(on: active), active: active)
        #expect(plan.edgesToDisconnect.filter { $0 == loop.id }.count == 1)
        #expect(plan.edgesToDisconnect.count == Nodes.verbEdges.count + 1)
    }

    @Test func nodeRemoveSkipsAnEdgeTheDraftAlreadyDisconnected() throws {
        let already = GraphEdit.disconnect(Nodes.edgeID("edg.keys-verb"))
        let draft = Nodes.draft([already])
        let plan = try WiringNodeComposer.removalPlan(node: Nodes.verb, from: draft, active: Fixture.graph)
        #expect(plan.edgesToDisconnect.map(\.rawValue) == Nodes.verbEdges.filter { $0 != "edg.keys-verb" })
        let result = try WiringNodeComposer.remove(node: Nodes.verb, from: draft, active: Fixture.graph)
        #expect(result.edits.first == already)
        #expect(result.edits.count == 1 + plan.edgesToDisconnect.count + 1)
    }

    @Test func nodeRemoveFoldsAwayADraftAddedEdgeWithoutDisconnectingIt() throws {
        let added = Fixture.edge("edg.new", Fixture.address("nod.keys", "out"), Fixture.address("nod.mains", "in"))
        let draft = Nodes.draft([.connect(added)])
        let mains = Nodes.nodeID("nod.mains")
        let plan = try WiringNodeComposer.removalPlan(node: mains, from: draft, active: Fixture.graph)
        #expect(plan.edgesToDisconnect.map(\.rawValue) == ["edg.new", "edg.verb-mains"])
        let result = try WiringNodeComposer.remove(node: mains, from: draft, active: Fixture.graph)
        #expect(result.edits == [.disconnect(Nodes.edgeID("edg.verb-mains")), .removeNode(mains)])
    }

    @Test func nodeRemoveOfADraftAddedNodeLeavesTheDraftItStartedFrom() throws {
        let existing = GraphEdit.moveNode(Nodes.keys, to: GraphPoint(x: 5, y: 5))
        let start = Nodes.draft([existing])
        let node = Nodes.node("nod.new")
        let added = try WiringNodeComposer.add(node, to: start, active: Fixture.graph)
        #expect(try WiringNodeComposer.remove(node: node.id, from: added, active: Fixture.graph) == start)
        let wire = Fixture.edge("edg.new", Fixture.address("nod.new", "out"), Fixture.address("nod.mains", "in"))
        var wired = added
        wired.edits = try DraftEditFold.fold([.connect(wire)], onto: added.edits, base: Fixture.graph)
        #expect(wired.edits == [existing, .addNode(node), .connect(wire)])
        #expect(try WiringNodeComposer.remove(node: node.id, from: wired, active: Fixture.graph) == start)
    }

    @Test func nodeRemoveRefusesAnUnknownNodeAndAnActiveNodeTheDraftAlreadyRemoved() throws {
        let missing = Nodes.nodeID("nod.never")
        #expect(Nodes.removeRefusal(missing, from: Nodes.draft()) == .unknownNode(missing))
        let removed = try WiringNodeComposer.remove(node: Nodes.shortcut, from: Nodes.draft(), active: Fixture.graph)
        #expect(Nodes.removeRefusal(Nodes.shortcut, from: removed) == .unknownNode(Nodes.shortcut))
        #expect(Nodes.planRefusal(missing, from: Nodes.draft()) == .unknownNode(missing))
    }

    @Test func nodeRemoveRefusesAStaleDraftWithTheDraftAndActiveRevisions() throws {
        let (stale, active) = try Nodes.stale()
        let mismatch = try Nodes.mismatch()
        #expect(Nodes.removeRefusal(Nodes.verb, from: stale, active: active) == mismatch)
    }

    @Test func nodeRemoveAcceptsFortyNinetyFiveAttachedEdgesAndRefusesFortyNinetySix() throws {
        let below = Nodes.large(nodes: 2, edges: 4_095)
        let hub = Nodes.nodeID("nod.a")
        let result = try WiringNodeComposer.remove(node: hub, from: Nodes.draft(on: below), active: below)
        #expect(result.edits.count == 4_096)
        #expect(result.edits.last == .removeNode(hub))
        #expect(result.edits.first == .disconnect(Nodes.edgeID("edg.00000")))
        #expect(result.edits.dropLast().last == .disconnect(Nodes.edgeID("edg.04094")))
        let full = Nodes.large(nodes: 2, edges: 4_096)
        #expect(Nodes.removeRefusal(hub, from: Nodes.draft(on: full), active: full) == .tooManyEdits)
        #expect(Nodes.planRefusal(hub, from: Nodes.draft(on: full), active: full) == .tooManyEdits)
    }

    @Test func nodeRemoveReportsTheFoldsBoundWhenTheDraftsOwnEditsPushTheListOverTheLimit() throws {
        var active = Nodes.large(nodes: 3, edges: 4_095)
        active.edges.append(Nodes.wire("edg.zz", "nod.b", "nod.n00002"))
        let draft = Nodes.draft([.disconnect(Nodes.edgeID("edg.zz"))], on: active)
        let hub = Nodes.nodeID("nod.a")
        let limit = ProjectGraphLimitError.exceeded(path: "$.edits", maximum: 4_096)
        #expect(Nodes.removeRefusal(hub, from: draft, active: active) == .fold(.bounds(limit)))
    }

    @Test func nodeRemoveInTwentyNodesTouchesNothingElseAndThePlanIsWhatItFolds() throws {
        let active = Nodes.twentyNodes()
        for node in active.nodes {
            let plan = try WiringNodeComposer.removalPlan(node: node.id, from: Nodes.draft(on: active), active: active)
            let attached = active.edges.filter { $0.from.node == node.id || $0.to.node == node.id }.map(\.id).sorted()
            #expect(plan.edgesToDisconnect == attached, "\(node.id)")
            let result = try WiringNodeComposer.remove(node: node.id, from: Nodes.draft(on: active), active: active)
            #expect(result.edits == plan.gesture, "\(node.id)")
            var expected = active
            expected.nodes.removeAll { $0.id == node.id }
            expected.edges.removeAll { $0.from.node == node.id || $0.to.node == node.id }
            #expect(try active.applying(result.edits) == expected, "\(node.id)")
        }
        let loopPlan = try WiringNodeComposer.removalPlan(
            node: Nodes.nodeID("nod.n00005"), from: Nodes.draft(on: active), active: active
        )
        #expect(loopPlan.edgesToDisconnect.filter { $0.rawValue == "edg.loop" }.count == 1)
    }
}
