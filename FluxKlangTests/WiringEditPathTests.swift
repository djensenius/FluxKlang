//
//  WiringEditPathTests.swift
//  FluxKlangTests
//
//  Equivalent edit paths (#101 WP3): a drag end point, keyboard nudges and
//  numeric x/y entry give the same folded `moveNode`, normalized to 1e-12
//  layout unit and snapped to an off-grid base; every remove path gives the
//  same folded `disconnect`, and restore cancels it. Refusals change nothing
//  and the active graph is never written.
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

    /// Folds `nudges` one at a time while retaining the gesture's offset state.
    static func nudged(
        _ node: NodeID, _ nudges: [WiringNudge], grid: WiringMoveGrid = grid(),
        from draft: DraftEdits = draft(), active: GraphDocument = Fixture.graph
    ) throws(WiringEditRefusal) -> DraftEdits {
        var state = WiringMoveState(draft: draft)
        for nudge in nudges {
            state = try WiringMoveComposer.nudge(node, nudge, grid: grid, in: state, active: active)
        }
        return state.draft
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

    /// The fixture graph with nod.keys at (`horizontal`, `vertical`).
    static func keys(at horizontal: Double, _ vertical: Double = 0) throws -> GraphDocument {
        var graph = Fixture.graph
        let index = try #require(graph.nodes.firstIndex { $0.id == keys })
        graph.nodes[index].position = GraphPoint(x: horizontal, y: vertical)
        return graph
    }

    /// The x of nod.keys's move in `draft`, or `nil` without one.
    static func movedX(_ draft: DraftEdits) -> Double? {
        for case .moveNode(keys, let point?) in draft.edits { return point.x }
        return nil
    }

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

    @Test func fineNudgesNumericEntryAndDragShareOneNormalization() throws {
        let graph = try Self.keys(at: 0)
        let draft = Edit.draft(on: graph)
        let typed = try WiringMoveComposer.move(Self.keys, x: 0.3, y: 0, in: draft, active: graph)
        let dragged = try WiringMoveComposer.move(Self.keys, x: 0.30000000000000004, y: 0, in: draft, active: graph)
        #expect(typed == dragged && Self.movedX(typed) == 0.3)
        // 0.1 + 0.2 (one fine, one grid nudge) is 0.30000000000000004 unnormalized; both land on 0.3's grid point.
        let grid = Edit.grid(step: 0.2, fineStep: 0.1)
        let stepped = try Edit.nudged(Self.keys, [WiringNudge(.rightward, fine: true), WiringNudge(.rightward)],
                                      grid: grid, from: draft, active: graph)
        #expect(stepped == typed)
        // Each nudge lands where typing its target lands.
        var nudged = draft
        for expected in [0.1, 0.2, 0.3] {
            let target = (Self.movedX(nudged) ?? 0) + 0.1
            let entry = try WiringMoveComposer.move(Self.keys, x: target, y: 0, in: nudged, active: graph)
            nudged = try Edit.nudged(Self.keys, [WiringNudge(.rightward, fine: true)], grid: grid, from: nudged,
                                     active: graph)
            #expect(nudged == entry && Self.movedX(nudged) == expected)
        }
        #expect(nudged == typed)
    }

    @Test func largeCoordinateNudgesPreserveSubULPOffsetsAndFoldBack() throws {
        let coordinate = 1e12
        let graph = try Self.keys(at: coordinate, coordinate)
        let draft = Edit.draft(on: graph)
        let grid = Edit.grid(step: 0.1, fineStep: 0.1)
        let right = try Edit.nudged(
            Self.keys, Array(repeating: WiringNudge(.rightward, fine: true), count: 10),
            grid: grid, from: draft, active: graph
        )
        let typed = try WiringMoveComposer.move(Self.keys, x: coordinate + 1, y: coordinate, in: draft,
                                                active: graph)
        #expect(right == typed)
        #expect(Self.movedX(right) == coordinate + 1)

        let back = try Edit.nudged(
            Self.keys, Array(repeating: WiringNudge(.leftward, fine: true), count: 10),
            grid: grid, from: right, active: graph
        )
        #expect(back == draft)
    }

    @Test func largeCoordinateFineNudgesAccumulateAcrossCallsAndReverse() throws {
        let coordinate = 1e12
        let graph = try Self.keys(at: coordinate, coordinate)
        let draft = Edit.draft(on: graph)
        let grid = Edit.grid(step: 0.1, fineStep: 0.00005)
        var state = WiringMoveState(draft: draft)
        for index in 0..<10 {
            state = try WiringMoveComposer.nudge(
                Self.keys, WiringNudge(.rightward, fine: true), grid: grid, in: state, active: graph
            )
            if index == 0 { #expect(state.draft == draft) }
        }

        let typed = try WiringMoveComposer.move(Self.keys, x: coordinate + 0.0005, y: coordinate,
                                                in: WiringMoveState(draft: draft), active: graph)
        #expect(state.draft == typed.draft)
        #expect(Self.movedX(state.draft) == coordinate + 0.0005)

        for _ in 0..<10 {
            state = try WiringMoveComposer.nudge(
                Self.keys, WiringNudge(.leftward, fine: true), grid: grid, in: state, active: graph
            )
        }
        #expect(state.draft == draft)
    }

    @Test func largeCoordinateOrdinaryAndFineNudgesAccumulateAndReverse() throws {
        let coordinate = 1e12
        let graph = try Self.keys(at: coordinate, coordinate)
        let draft = Edit.draft(on: graph)
        let grid = Edit.grid(step: 0.0001, fineStep: 0.00005)
        var state = WiringMoveState(draft: draft)
        let outward = Array(repeating: WiringNudge(.rightward), count: 6)
            + Array(repeating: WiringNudge(.rightward, fine: true), count: 4)
        for nudge in outward {
            state = try WiringMoveComposer.nudge(Self.keys, nudge, grid: grid, in: state, active: graph)
        }
        let typed = try WiringMoveComposer.move(Self.keys, x: coordinate + 0.0008, y: coordinate,
                                                in: WiringMoveState(draft: draft), active: graph)
        #expect(state.draft == typed.draft)

        let inward = Array(repeating: WiringNudge(.leftward, fine: true), count: 4)
            + Array(repeating: WiringNudge(.leftward), count: 6)
        for nudge in inward {
            state = try WiringMoveComposer.nudge(Self.keys, nudge, grid: grid, in: state, active: graph)
        }
        #expect(state.draft == draft)
    }

    @Test func numericMoveResetsTheKeyboardOffsetAnchor() throws {
        let coordinate = 1e12
        let graph = try Self.keys(at: coordinate, coordinate)
        let draft = Edit.draft(on: graph)
        let grid = Edit.grid(step: 0.1, fineStep: 0.00005)
        var state = WiringMoveState(draft: draft)
        state = try WiringMoveComposer.nudge(
            Self.keys, WiringNudge(.rightward, fine: true), grid: grid, in: state, active: graph
        )
        state = try WiringMoveComposer.move(Self.keys, x: coordinate + 0.0005, y: coordinate,
                                            in: state, active: graph)
        let numeric = state.draft
        for _ in 0..<10 {
            state = try WiringMoveComposer.nudge(
                Self.keys, WiringNudge(.leftward, fine: true), grid: grid, in: state, active: graph
            )
        }
        let fresh = try Edit.nudged(
            Self.keys, Array(repeating: WiringNudge(.leftward, fine: true), count: 10),
            grid: grid, from: numeric, active: graph
        )
        #expect(state.draft == fresh)
    }

    @Test func stateCreatedFromMovedDraftAnchorsAtTheDraftPosition() throws {
        let coordinate = 1e12
        let graph = try Self.keys(at: coordinate, coordinate)
        let initialPosition = GraphPoint(x: coordinate + 1, y: coordinate)
        let draft = Edit.draft([.moveNode(Self.keys, to: initialPosition)], on: graph)
        let grid = Edit.grid(step: 0.1, fineStep: 0.00005)
        var state = WiringMoveState(draft: draft)
        for _ in 0..<10 {
            state = try WiringMoveComposer.nudge(
                Self.keys, WiringNudge(.rightward, fine: true), grid: grid, in: state, active: graph
            )
        }

        let typed = try WiringMoveComposer.move(
            Self.keys, x: initialPosition.x + 0.0005, y: coordinate, in: draft, active: graph
        )
        #expect(state.draft == typed)
        #expect(Self.movedX(state.draft) == initialPosition.x + 0.0005)
    }

    @Test func nudgeOutsideDecimalRangeFallsBackToCoordinateArithmetic() throws {
        let coordinate = 1e200
        let graph = try Self.keys(at: coordinate, coordinate)
        let draft = Edit.draft(on: graph)
        let distance = 1e190
        let grid = Edit.grid(step: distance, fineStep: distance)
        let nudged = try Edit.nudged(Self.keys, [WiringNudge(.rightward)], grid: grid, from: draft, active: graph)
        let typed = try WiringMoveComposer.move(Self.keys, x: coordinate + distance, y: coordinate,
                                                in: draft, active: graph)
        #expect(nudged == typed)
        #expect(Self.movedX(nudged) == coordinate + distance)
    }

    @Test func aReturnToAnOffGridBaseDropsTheMove() throws {
        for (base, step) in [(0.1, 8.0), (0.3, 1), (0.1, 0.2)] {
            let graph = try Self.keys(at: base, base)
            let draft = Edit.draft(on: graph)
            let grid = Edit.grid(step: step, fineStep: step)
            let there = try Edit.nudged(Self.keys, [WiringNudge(.rightward), WiringNudge(.downward)], grid: grid,
                                        from: draft, active: graph)
            #expect(there.edits.count == 1, "\(base) ± \(step)")
            let back = try Edit.nudged(Self.keys, [WiringNudge(.leftward), WiringNudge(.upward, fine: true)],
                                       grid: grid, from: there, active: graph)
            #expect(back == draft, "\(base) ± \(step)")
        }
        let fractional = try Self.keys(at: 0.123456789, 0.234567891)
        let fractionalDraft = Edit.draft(on: fractional)
        let tenth = Edit.grid(step: 0.1, fineStep: 0.1)
        let right = try Edit.nudged(Self.keys, [WiringNudge(.rightward)], grid: tenth, from: fractionalDraft,
                                    active: fractional)
        #expect(try Edit.nudged(Self.keys, [WiringNudge(.leftward)], grid: tenth, from: right,
                                active: fractional) == fractionalDraft)
        // Numeric entry within the base's decimal rounding cell snaps to it too.
        let graph = try Self.keys(at: 0.1, 0.3)
        let draft = Edit.draft(on: graph)
        #expect(try WiringMoveComposer.move(Self.keys, x: 0.1 + 1e-13, y: 0.3 + 1e-13, in: draft,
                                           active: graph) == draft)
        let target = 0.1 + 1.0 / 1024
        let near = try WiringMoveComposer.move(Self.keys, x: target, y: 0.3, in: draft, active: graph)
        #expect(near.edits == [.moveNode(Self.keys, to: GraphPoint(x: target, y: 0.3))])
    }

    @Test func coordinatesRoundHalfAwayFromZeroOntoTheResolution() throws {
        #expect(WiringMoveComposer.resolution == 1e-12)
        let graph = try Self.keys(at: 5)
        let draft = Edit.draft(on: graph)
        let cases: [(Double, Double)] = [
            (WiringMoveComposer.resolution / 2, WiringMoveComposer.resolution),
            (-WiringMoveComposer.resolution / 2, -WiringMoveComposer.resolution),
            (WiringMoveComposer.resolution * 1.5, WiringMoveComposer.resolution * 2),
            (2.0 + 1.0 / 4096, 2.0 + 1.0 / 4096),
            (0x1p42 + 0.25, 0x1p42 + 0.25), (-0x1p50, -0x1p50)
        ]
        for (value, expected) in cases {
            let moved = try WiringMoveComposer.move(Self.keys, x: value, y: value, in: draft, active: graph)
            #expect(moved.edits == [.moveNode(Self.keys, to: GraphPoint(x: expected, y: expected))], "\(value)")
        }
        // A small negative coordinate rounds to +0, never -0.
        let zero = try WiringMoveComposer.move(Self.keys, x: -WiringMoveComposer.resolution / 4, y: 1, in: draft,
                                               active: graph)
        #expect(Self.movedX(zero)?.sign == .plus)
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
        // Still in the draft's graph is checked before the active lookup: a draft-added edge is not restorable.
        let request = WiringComposeFixture.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"))
        let added = try WiringDraftComposer.compose(request, into: Edit.draft(), active: active)
        #expect(throws: WiringEditRefusal.notInDraftOrActive(request.edge)) {
            try WiringRemoveComposer.restore(edge: request.edge, into: added, active: active)
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
