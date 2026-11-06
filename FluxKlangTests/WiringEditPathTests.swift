//
//  WiringEditPathTests.swift
//  FluxKlangTests
//
//  Equivalent edit paths (#101 WP3): a drag end point, keyboard nudges and
//  numeric x/y entry give the same folded `moveNode`; every remove path gives
//  the same folded `disconnect`, and restore cancels it. Refusals change
//  nothing and the active graph is never written.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture

enum WiringEditFixture {
    static let draftID = DraftID(validated: "dft.edit")

    static func draft(_ edits: [GraphEdit] = [], on graph: GraphDocument = Fixture.graph) -> DraftEdits {
        DraftEdits(id: draftID, graph: graph.id, baseRevision: graph.revision, edits: edits)
    }

    static func grid(step: Double = 8, fineStep: Double = 1) -> WiringMoveGrid {
        guard let grid = try? WiringMoveGrid.make(step: step, fineStep: fineStep) else {
            preconditionFailure("Invalid grid \(step), \(fineStep)")
        }
        return grid
    }

    /// Folds `nudges` one at a time from `draft`.
    static func nudged(
        _ node: NodeID, _ nudges: [WiringNudge], grid: WiringMoveGrid = grid(),
        from draft: DraftEdits = draft(), active: GraphDocument = Fixture.graph
    ) throws(WiringEditRefusal) -> DraftEdits {
        var current = draft
        for nudge in nudges {
            current = try WiringMoveComposer.nudge(node, nudge, grid: grid, in: current, active: active)
        }
        return current
    }

    static func revision(_ value: Int) -> ContractRevision {
        guard let revision = try? ContractRevision(value) else { preconditionFailure("Invalid revision \(value)") }
        return revision
    }
}

private typealias Edit = WiringEditFixture

@Suite("Wiring edit paths")
struct WiringEditPathTests {
    static let keys = NodeID(validated: "nod.keys")

    @Test func dragNudgesAndNumericEntryGiveTheSameMove() throws {
        // nod.keys starts at (1, 0); two grid steps and one fine step right, one grid step up.
        let nudges = [
            WiringNudge(.rightward), WiringNudge(.rightward), WiringNudge(.rightward, fine: true), WiringNudge(.upward)
        ]
        let nudged = try Edit.nudged(Self.keys, nudges)
        let dragged = try WiringMoveComposer.move(Self.keys, x: 18, y: -8, in: Edit.draft(), active: Fixture.graph)
        let typed = try WiringMoveComposer.move(Self.keys, x: 18.0, y: -8.0, in: Edit.draft(), active: Fixture.graph)
        let expected: [GraphEdit] = [.moveNode(Self.keys, to: GraphPoint(x: 18, y: -8))]
        #expect(nudged.edits == expected)
        #expect(dragged == nudged && typed == nudged)
        try GraphEdit.validateBatch(nudged.edits)
        #expect(nudged.id == Edit.draftID && nudged.graph == Fixture.graphID)
        // Two drags are one move too, and earlier edits keep their place.
        let earlier: [GraphEdit] = [.disconnect(Fixture.id("edg.echo-verb"))]
        var draft = try WiringMoveComposer.move(Self.keys, x: 5, y: 5, in: Edit.draft(earlier), active: Fixture.graph)
        draft = try WiringMoveComposer.move(Self.keys, x: 18, y: -8, in: draft, active: Fixture.graph)
        #expect(draft.edits == earlier + expected)
        #expect(try Edit.nudged(Self.keys, nudges, from: Edit.draft(earlier)) == draft)
    }

    @Test func eachDirectionMovesOneGridOrFineStep() throws {
        let grid = Edit.grid(step: 8, fineStep: 0.5)
        let expected: [(WiringNudge, GraphPoint)] = [
            (WiringNudge(.leftward), GraphPoint(x: -7, y: 0)), (WiringNudge(.rightward), GraphPoint(x: 9, y: 0)),
            (WiringNudge(.upward), GraphPoint(x: 1, y: -8)), (WiringNudge(.downward), GraphPoint(x: 1, y: 8)),
            (WiringNudge(.leftward, fine: true), GraphPoint(x: 0.5, y: 0)),
            (WiringNudge(.rightward, fine: true), GraphPoint(x: 1.5, y: 0)),
            (WiringNudge(.upward, fine: true), GraphPoint(x: 1, y: -0.5)),
            (WiringNudge(.downward, fine: true), GraphPoint(x: 1, y: 0.5))
        ]
        for (nudge, point) in expected {
            let draft = try Edit.nudged(Self.keys, [nudge], grid: grid)
            #expect(draft.edits == [.moveNode(Self.keys, to: point)], "\(nudge)")
        }
        #expect(grid.step == 8 && grid.fineStep == 0.5)
        #expect(grid.distance(fine: true) == 0.5 && grid.distance(fine: false) == 8)
    }

    @Test func aMoveBackToBaseDropsTheMove() throws {
        let earlier: [GraphEdit] = [.disconnect(Fixture.id("edg.echo-verb"))]
        let out = [WiringNudge(.rightward), WiringNudge(.downward, fine: true)]
        let there = try Edit.nudged(Self.keys, out, from: Edit.draft(earlier))
        #expect(there.edits.count == 2)
        let back = try Edit.nudged(Self.keys, [WiringNudge(.leftward), WiringNudge(.upward, fine: true)], from: there)
        #expect(back == Edit.draft(earlier))
        let typedBack = try WiringMoveComposer.move(Self.keys, x: 1, y: 0, in: there, active: Fixture.graph)
        #expect(typedBack == Edit.draft(earlier))
        // Fine nudges back undo grid nudges exactly when the steps add up.
        let fineBack = [WiringNudge(.rightward)] + Array(repeating: WiringNudge(.leftward, fine: true), count: 8)
        let fine = try Edit.nudged(Self.keys, fineBack)
        #expect(fine == Edit.draft())
    }

    @Test func aMoveKeepsThePositionExtensions() throws {
        var graph = Fixture.graph
        let index = try #require(graph.nodes.firstIndex { $0.id == Self.keys })
        graph.nodes[index].position?.extensions = ["snap": .bool(true)]
        graph.nodes[index].position?.unknownFields = ["layer": .int(2)]
        let draft = Edit.draft(on: graph)
        let dragged = try WiringMoveComposer.move(Self.keys, x: 9, y: 0, in: draft, active: graph)
        let nudged = try Edit.nudged(Self.keys, [WiringNudge(.rightward)], from: draft, active: graph)
        var point = try #require(graph.nodes[index].position)
        point.x = 9
        #expect(dragged.edits == [.moveNode(Self.keys, to: point)])
        #expect(nudged == dragged)
        let back = try Edit.nudged(Self.keys, [WiringNudge(.leftward)], from: nudged, active: graph)
        #expect(back == draft)
    }

    @Test func aDraftAddedNodeMovesInItsAdd() throws {
        let comp = WiringComposeFixture.comp
        let draft = Edit.draft([.addNode(comp)])
        let moved = try Edit.nudged(comp.id, [WiringNudge(.downward)], from: draft)
        var expected = comp
        expected.position = GraphPoint(x: 10, y: 8)
        #expect(moved.edits == [.addNode(expected)])
        #expect(try WiringMoveComposer.move(comp.id, x: 10, y: 8, in: draft, active: Fixture.graph) == moved)
    }

    @Test func anUnplacedNodeIsPlacedByDragButNotNudged() throws {
        var graph = Fixture.graph
        let index = try #require(graph.nodes.firstIndex { $0.id == Self.keys })
        graph.nodes[index].position = nil
        let draft = Edit.draft(on: graph)
        #expect(throws: WiringEditRefusal.unplacedNode(Self.keys)) {
            try Edit.nudged(Self.keys, [WiringNudge(.rightward)], from: draft, active: graph)
        }
        let placed = try WiringMoveComposer.move(Self.keys, x: 3, y: 4, in: draft, active: graph)
        #expect(placed.edits == [.moveNode(Self.keys, to: GraphPoint(x: 3, y: 4))])
        #expect(try Edit.nudged(Self.keys, [WiringNudge(.rightward, fine: true)], from: placed, active: graph).edits
            == [.moveNode(Self.keys, to: GraphPoint(x: 4, y: 4))])
    }

    @Test func moveRefusalsChangeNothing() throws {
        let draft = Edit.draft([.disconnect(Fixture.id("edg.echo-verb"))])
        let active = Fixture.graph
        for (horizontal, vertical) in [(Double.nan, 0), (0, Double.infinity), (-Double.infinity, 1)] {
            #expect(throws: WiringEditRefusal.nonFinitePosition(Self.keys)) {
                try WiringMoveComposer.move(Self.keys, x: horizontal, y: vertical, in: draft, active: active)
            }
        }
        let ghost = NodeID(validated: "nod.ghost")
        #expect(throws: WiringEditRefusal.unknownNode(ghost)) {
            try WiringMoveComposer.move(ghost, x: 1, y: 1, in: draft, active: active)
        }
        #expect(throws: WiringEditRefusal.unknownNode(ghost)) {
            try Edit.nudged(ghost, [WiringNudge(.upward)], from: draft)
        }
        // A node the draft removes is not in the draft's graph.
        let removed = Edit.draft([.removeNode(Self.keys)])
        #expect(throws: WiringEditRefusal.unknownNode(Self.keys)) {
            try WiringMoveComposer.move(Self.keys, x: 1, y: 1, in: removed, active: active)
        }
        // A nudge that overflows a coordinate.
        let huge = try WiringMoveComposer.move(Self.keys, x: .greatestFiniteMagnitude, y: 0, in: draft, active: active)
        #expect(throws: WiringEditRefusal.nonFinitePosition(Self.keys)) {
            let grid = Edit.grid(step: .greatestFiniteMagnitude)
            return try Edit.nudged(Self.keys, [WiringNudge(.rightward)], grid: grid, from: huge)
        }
        var stale = draft
        stale.baseRevision = Edit.revision(7)
        let mismatch = WiringPreviewRefusal.draftBaseMismatch(draft: Edit.revision(7), active: active.revision)
        #expect(throws: WiringEditRefusal.preview(mismatch)) {
            try WiringMoveComposer.move(Self.keys, x: 1, y: 1, in: stale, active: active)
        }
        #expect(throws: WiringEditRefusal.preview(mismatch)) {
            try Edit.nudged(Self.keys, [WiringNudge(.upward, fine: true)], from: stale)
        }
        #expect(draft == Edit.draft([.disconnect(Fixture.id("edg.echo-verb"))]) && active == Fixture.graph)
    }

    @Test func aFoldRefusalIsReportedAsIs() throws {
        var graph = Fixture.graph
        let index = try #require(graph.nodes.firstIndex { $0.id == Self.keys })
        graph.nodes[index].position?.extensions = ["bad": .double(.nan)]
        let path = "$.nodes[\(Self.keys)].position.extensions.bad"
        #expect(throws: WiringEditRefusal.fold(.nonFiniteNodeExtension(Self.keys, path: path))) {
            try WiringMoveComposer.move(Self.keys, x: 2, y: 0, in: Edit.draft(on: graph), active: graph)
        }
    }

    @Test func invalidGridsAreRefused() throws {
        let bad: [Double] = [0, -1, -0.0, .nan, .infinity, -.infinity, -.leastNonzeroMagnitude]
        for value in bad {
            #expect(throws: WiringEditRefusal.invalidGrid) { try WiringMoveGrid.make(step: value, fineStep: 1) }
            #expect(throws: WiringEditRefusal.invalidGrid) { try WiringMoveGrid.make(step: 1, fineStep: value) }
        }
        let tiny = try WiringMoveGrid.make(step: .leastNonzeroMagnitude, fineStep: .greatestFiniteMagnitude)
        #expect(tiny.step == .leastNonzeroMagnitude && tiny.fineStep == .greatestFiniteMagnitude)
    }

    @Test func removingAnActiveEdgeDisconnectsIt() throws {
        let edge = EdgeID(validated: "edg.keys-verb")
        let earlier: [GraphEdit] = [.moveNode(Self.keys, to: GraphPoint(x: 2, y: 2))]
        let removed = try WiringRemoveComposer.remove(edge: edge, from: Edit.draft(earlier), active: Fixture.graph)
        #expect(removed.edits == earlier + [.disconnect(edge)])
        try GraphEdit.validateBatch(removed.edits)
        let review = try WiringReviewDiff.make(active: Fixture.graph, draft: removed)
        #expect(review.changes.contains(.removedEdge(try #require(Fixture.graph.edges.first { $0.id == edge }))))
    }

    @Test func removingADraftAddedEdgeFoldsItsConnectAway() throws {
        let earlier: [GraphEdit] = [.disconnect(Fixture.id("edg.echo-verb"))]
        let request = WiringComposeFixture.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"))
        let composed = try WiringDraftComposer.compose(request, into: Edit.draft(earlier), active: Fixture.graph)
        #expect(composed.edits.count == 2)
        let removed = try WiringRemoveComposer.remove(edge: request.edge, from: composed, active: Fixture.graph)
        #expect(removed == Edit.draft(earlier))
    }

    @Test func restoreReAddsTheIdenticalEdgeAndCancelsTheDisconnect() throws {
        let edge = EdgeID(validated: "edg.mic-verb")
        let earlier: [GraphEdit] = [.moveNode(Self.keys, to: GraphPoint(x: 2, y: 2))]
        let removed = try WiringRemoveComposer.remove(edge: edge, from: Edit.draft(earlier), active: Fixture.graph)
        let restored = try WiringRemoveComposer.restore(edge: edge, into: removed, active: Fixture.graph)
        #expect(restored == Edit.draft(earlier))
        let candidate = try Fixture.graph.applying(restored.edits)
        #expect(candidate.edges.first { $0.id == edge } == Fixture.graph.edges.first { $0.id == edge })
        // Restoring again: the edge is back in the draft's graph.
        #expect(throws: WiringEditRefusal.notInDraftOrActive(edge)) {
            try WiringRemoveComposer.restore(edge: edge, into: restored, active: Fixture.graph)
        }
    }

    @Test func removeAndRestoreRefusalsChangeNothing() throws {
        let active = Fixture.graph
        let edge = EdgeID(validated: "edg.keys-verb"), ghost = EdgeID(validated: "edg.ghost")
        let removed = Edit.draft([.disconnect(edge)])
        #expect(throws: WiringEditRefusal.notInDraftOrActive(edge)) {
            try WiringRemoveComposer.remove(edge: edge, from: removed, active: active)
        }
        #expect(throws: WiringEditRefusal.unknownEdge(ghost)) {
            try WiringRemoveComposer.remove(edge: ghost, from: removed, active: active)
        }
        #expect(throws: WiringEditRefusal.unknownEdge(ghost)) {
            try WiringRemoveComposer.restore(edge: ghost, into: removed, active: active)
        }
        // A draft-added edge is not an active edge: nothing to restore once it is gone.
        #expect(throws: WiringEditRefusal.unknownEdge(Fixture.id("edg.keys-mains"))) {
            try WiringRemoveComposer.restore(edge: Fixture.id("edg.keys-mains"), into: removed, active: active)
        }
        // Removed with its node: the remove is refused, and so is a restore onto the removed node.
        let nodeGone = Edit.draft([.removeNode(Self.keys)])
        #expect(throws: WiringEditRefusal.notInDraftOrActive(edge)) {
            try WiringRemoveComposer.remove(edge: edge, from: nodeGone, active: active)
        }
        #expect(throws: WiringEditRefusal.fold(.endpointRemoved(edge: edge, node: Self.keys))) {
            try WiringRemoveComposer.restore(edge: edge, into: nodeGone, active: active)
        }
        var stale = removed
        stale.baseRevision = Edit.revision(9)
        let mismatch = WiringPreviewRefusal.draftBaseMismatch(draft: Edit.revision(9), active: active.revision)
        #expect(throws: WiringEditRefusal.preview(mismatch)) {
            try WiringRemoveComposer.remove(edge: Fixture.id("edg.mic-verb"), from: stale, active: active)
        }
        #expect(throws: WiringEditRefusal.preview(mismatch)) {
            try WiringRemoveComposer.restore(edge: edge, into: stale, active: active)
        }
        #expect(removed == Edit.draft([.disconnect(edge)]) && active == Fixture.graph)
    }
}
