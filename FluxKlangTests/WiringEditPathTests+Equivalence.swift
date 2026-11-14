//
//  WiringEditPathTests+Equivalence.swift
//  FluxKlangTests
//
//  The differential proof that the edit paths agree (#101 WP3): for every
//  output/input pair of the fixtures and of seeded graphs with seeded drafts,
//  the matrix toggle, the list "Add Connection" path (pick the candidate from
//  the destination list, then compose) and the port-picker compose path give
//  equal `DraftEdits` values or equal refusals; and every remove path (the
//  matrix toggle off, and Delete, the row button and VoiceOver, which all
//  call `WiringRemoveComposer.remove`) gives the same draft, which restore undoes.
//  The list path composes the listed candidate's pair, which is the cell's
//  pair, so it is the port-picker request; the proof that the list and the
//  matrix agree is the class assertion (the listed connection is the cell's
//  state), plus the toggle-versus-picker comparison.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture
private typealias Edit = WiringEditFixture

/// SplitMix64, as in WiringComposeTests+Bulk.swift: every draw comes straight from `next()`, so every toolchain
/// sees the same graphs and drafts.
private struct EditPathGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func below(_ count: Int) -> Int { Int(next() % UInt64(count)) }

    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }

    mutating func element<Element>(of items: [Element]) -> Element? { items.isEmpty ? nil : items[below(items.count)] }
}

/// Seeded graphs (mixed signals and widths, legacy ports, shortcuts, repeated wires, feedback and conversions)
/// and seeded drafts on them, built by folding random gestures.
private enum EditPathSeeds {
    static func port(_ name: String, using random: inout EditPathGenerator) -> GraphPort {
        let direction: PortDirection = random.chance(50) ? .output : .input
        guard random.chance(80) else { return GraphPort(id: Fixture.id(name), direction: direction, signal: .midi) }
        return Fixture.audio(name, direction, random.chance(5) ? nil : (random.chance(60) ? 2 : 1))
    }

    static func graph(seed: UInt64) -> GraphDocument {
        var random = EditPathGenerator(state: seed)
        let nodes = (0..<(4 + random.below(5))).map { index -> GraphNode in
            if random.chance(8) { return Fixture.node("nod.n\(index)", .observedShortcut, ports: []) }
            let names = ["in", "out", "aux"].filter { _ in random.chance(70) }
            return Fixture.node("nod.n\(index)", ports: names.map { port($0, using: &random) }, at: Double(index))
        }
        let ports = nodes.flatMap { node in node.ports.map { PortAddress(node: node.id, port: $0.id) } }
        var edges: [GraphEdge] = []
        for index in 0..<random.below(10) {
            guard let from = random.element(of: ports), let to = random.element(of: ports) else { break }
            var edge = Fixture.edge("edg.e\(index)", from, to)
            if let repeated = random.element(of: edges), random.chance(10) {
                (edge.from, edge.to) = (repeated.from, repeated.to)
            }
            if random.chance(20) { edge.feedback = Fixture.feedback }
            if random.chance(10) { edge.conversion = random.chance(50) ? Fixture.upmix : EdgeConversion(map: [[0, 1]]) }
            edges.append(edge)
        }
        return GraphDocument(id: Fixture.graphID, nodes: nodes, edges: edges)
    }

    static func draft(on graph: GraphDocument, seed: UInt64) -> DraftEdits {
        var random = EditPathGenerator(state: seed ^ 0xD1B5_4A32_D192_ED03)
        var edits: [GraphEdit] = []
        let ports = graph.nodes.flatMap { node in node.ports.map { PortAddress(node: node.id, port: $0.id) } }
        for index in 0..<random.below(5) {
            let gesture: GraphEdit?
            switch random.below(10) {
            case 0: gesture = random.element(of: graph.nodes).map { .removeNode($0.id) }
            case 1...3: gesture = random.element(of: graph.edges).map { .disconnect($0.id) }
            case 4...5:
                gesture = random.element(of: graph.nodes).map { .moveNode($0.id, to: GraphPoint(x: 3, y: 3)) }
            default:
                guard let from = random.element(of: ports), let to = random.element(of: ports) else { continue }
                gesture = .connect(Fixture.edge("edg.d\(index)", from, to))
            }
            guard let gesture, let folded = try? DraftEditFold.fold([gesture], onto: edits, base: graph) else {
                continue
            }
            edits = folded
        }
        return Edit.draft(edits, on: graph)
    }

    /// The conversion and feedback that resolve `connection` (a conversion of one source channel per row).
    static func attributes(for state: WiringMatrixCellState) -> (EdgeConversion?, EdgeFeedback?) {
        switch state {
        case .classified(.needsConversion(_, let rows)): (EdgeConversion(map: Array(repeating: [0], count: rows)), nil)
        case .classified(.feedbackOnly): (nil, Fixture.feedback)
        default: (nil, nil)
        }
    }
}

/// What the differential run saw, for its coverage floors.
private struct EditPathCoverage {
    var composed = 0
    var refused: Set<String> = []
    var removed = 0
    var restored = 0
    var classes: Set<WiringDestinationClass> = []
}

/// The differential run's random source and coverage.
private struct EditPathRun {
    var random: EditPathGenerator
    var coverage = EditPathCoverage()
}

/// One draft under test: the draft, the active graph, the draft's graph and each row's destination list.
private struct EditPathContext {
    var draft: DraftEdits
    var active: GraphDocument
    var graph: GraphDocument
    var lists: [PortAddress: Result<WiringDestinationList, WiringComposeRefusal>] = [:]
}

@Suite("Wiring edit path equivalence", .productionAccessAudit)
struct WiringEditPathEquivalenceTests {
    private typealias Outcome = Result<DraftEdits, WiringEditRefusal>

    private static func outcome(_ body: () throws(WiringEditRefusal) -> DraftEdits) -> Outcome {
        Result { () throws(WiringEditRefusal) in try body() }
    }

    /// The port-picker (and list) path: compose the connect, as the composer refuses it.
    private static func composed(
        _ request: WiringConnectRequest, into draft: DraftEdits, active: GraphDocument
    ) -> Outcome {
        do { return .success(try WiringDraftComposer.compose(request, into: draft, active: active)) } catch {
            return .failure(.compose(error))
        }
    }

    private static func label(_ outcome: Outcome) -> String {
        switch outcome {
        case .success: "success"
        case .failure(.compose(let refusal)): "compose." + String("\(refusal)".prefix { $0 != "(" })
        case .failure(let refusal): String("\(refusal)".prefix { $0 != "(" })
        }
    }

    /// The connect and remove paths agree on every cell of the draft's full window.
    private static func expectEquivalent(
        _ draft: DraftEdits, active: GraphDocument, run: inout EditPathRun,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let original = active
        let graph = (try? WiringDraftGraph.make(active: active, draft: draft).graph) ?? active
        let rows = Array(WiringMatrix.outputs(in: graph).prefix(WiringMatrix.maximumRows))
        let columns = Array(WiringMatrix.inputs(in: graph).prefix(WiringMatrix.maximumColumns))
        let matrix: WiringMatrix
        do {
            matrix = try WiringMatrix.window(rows: rows, columns: columns, active: active, draft: draft)
        } catch {
            expectRefusedAlike(error, draft: draft, active: active, run: &run, sourceLocation: sourceLocation)
            return
        }
        var context = EditPathContext(draft: draft, active: active, graph: graph)
        for row in rows {
            context.lists[row] = Result { () throws(WiringComposeRefusal) in
                try WiringDraftComposer.destinations(from: row, active: active, draft: draft)
            }
        }
        for cell in matrix.cells {
            expectCellAgrees(cell, context, run: &run, sourceLocation: sourceLocation)
        }
        expectRemovesAgree(context, matrix: matrix, coverage: &run.coverage, sourceLocation: sourceLocation)
        #expect(active == original, sourceLocation: sourceLocation)
    }

    /// A draft that does not check is refused alike by every path.
    private static func expectRefusedAlike(
        _ error: WiringEditRefusal, draft: DraftEdits, active: GraphDocument, run: inout EditPathRun,
        sourceLocation: SourceLocation
    ) {
        guard case .preview(let refusal) = error else {
            Issue.record("window: \(error)", sourceLocation: sourceLocation)
            return
        }
        let request = WiringConnectRequest(edge: Fixture.id("edg.any"), from: Fixture.address("nod.a", "out"),
                                           to: Fixture.address("nod.b", "in"))
        #expect(composed(request, into: draft, active: active) == .failure(.compose(.preview(refusal))),
                sourceLocation: sourceLocation)
        for edge in active.edges {
            #expect(outcome { () throws(WiringEditRefusal) in
                try WiringRemoveComposer.remove(edge: edge.id, from: draft, active: active)
            } == .failure(.preview(refusal)), sourceLocation: sourceLocation)
        }
        run.coverage.refused.insert("window.preview")
    }

    /// The matrix toggle, the list path and the port picker agree on `cell`.
    private static func expectCellAgrees(
        _ cell: WiringMatrixCell, _ context: EditPathContext, run: inout EditPathRun, sourceLocation: SourceLocation
    ) {
        let (draft, active) = (context.draft, context.active)
        run.coverage.classes.insert(cell.connectionClass)
        var (conversion, feedback) = EditPathSeeds.attributes(for: cell.state)
        if run.random.chance(15) { (conversion, feedback) = (nil, nil) }
        if run.random.chance(10) { conversion = Fixture.upmix }
        if run.random.chance(10) { feedback = Fixture.feedback }
        let reused = run.random.chance(5) ? context.graph.edges.first?.id : nil
        let edge = reused ?? Fixture.id("edg.path")
        let request = WiringMatrixConnect(edge: edge, conversion: conversion, feedback: feedback)
        let toggled = outcome { () throws(WiringEditRefusal) in
            try WiringMatrix.toggle(cell, request: request, in: draft, active: active)
        }
        let picker = composed(
            WiringConnectRequest(edge: edge, from: cell.from, to: cell.to, conversion: conversion, feedback: feedback),
            into: draft, active: active
        )
        if let listed = try? context.lists[cell.from]?.get().candidates.first(where: { $0.to == cell.to }) {
            // The list path's request is the picker's exactly when the candidate is the cell's pair.
            #expect(listed.from == cell.from, "\(cell.from) → \(cell.to)", sourceLocation: sourceLocation)
            #expect(WiringMatrixCellState.classified(listed.connection) == cell.state, sourceLocation: sourceLocation)
        } else {
            #expect(cell.connectionClass == .uncheckable, sourceLocation: sourceLocation)
        }
        if let existing = cell.existingEdge {
            let removed = outcome { () throws(WiringEditRefusal) in
                try WiringRemoveComposer.remove(edge: existing, from: draft, active: active)
            }
            #expect(toggled == removed, "\(cell.from) → \(cell.to)", sourceLocation: sourceLocation)
            if case .classified = cell.state {
                #expect(picker == .failure(.compose(.existing(existing))), sourceLocation: sourceLocation)
            } else {
                // A wired `.uncheckable` cell (`wiredEdge`): the picker cannot classify the pair either.
                #expect(cell.wiredEdge == existing, sourceLocation: sourceLocation)
            }
        } else {
            #expect(toggled == picker, "\(cell.from) → \(cell.to)", sourceLocation: sourceLocation)
        }
        if case .success(let result) = toggled {
            #expect((try? GraphEdit.validateBatch(result.edits)) != nil, sourceLocation: sourceLocation)
            run.coverage.composed += 1
        } else {
            run.coverage.refused.insert(label(toggled))
        }
    }

    /// Every edge of the draft's graph: the matrix toggle off of its cell (when it is the cell's edge) equals
    /// `remove`; removing an active edge and restoring it gives the draft back.
    private static func expectRemovesAgree(
        _ context: EditPathContext, matrix: WiringMatrix, coverage: inout EditPathCoverage,
        sourceLocation: SourceLocation
    ) {
        let (draft, graph, active) = (context.draft, context.graph, context.active)
        let request = WiringMatrixConnect(edge: Fixture.id("edg.unused"))
        for edge in graph.edges {
            let removed = outcome { () throws(WiringEditRefusal) in
                try WiringRemoveComposer.remove(edge: edge.id, from: draft, active: active)
            }
            for cell in matrix.cells where cell.existingEdge == edge.id {
                #expect(outcome { () throws(WiringEditRefusal) in
                    try WiringMatrix.toggle(cell, request: request, in: draft, active: active)
                } == removed, sourceLocation: sourceLocation)
            }
            guard case .success(let result) = removed else {
                coverage.refused.insert("remove." + label(removed))
                continue
            }
            coverage.removed += 1
            #expect((try? GraphEdit.validateBatch(result.edits)) != nil, sourceLocation: sourceLocation)
            #expect((try? active.applying(result.edits))?.edges.contains { $0.id == edge.id } == false,
                    sourceLocation: sourceLocation)
            if active.edges.contains(edge) {
                #expect(result.edits == draft.edits + [.disconnect(edge.id)], sourceLocation: sourceLocation)
                #expect(outcome { () throws(WiringEditRefusal) in
                    try WiringRemoveComposer.restore(edge: edge.id, into: result, active: active)
                } == .success(draft), sourceLocation: sourceLocation)
                coverage.restored += 1
            } else {
                #expect(result.edits == draft.edits.filter { $0 != .connect(edge) }, sourceLocation: sourceLocation)
            }
        }
    }

    @Test func pathsAgreeOnTheFixtures() throws {
        var run = EditPathRun(random: EditPathGenerator(state: 101))
        let keysMains = WiringComposeFixture.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"))
        let added = try WiringDraftComposer.compose(keysMains, into: Edit.draft(), active: Fixture.graph)
        var stale = Edit.draft()
        stale.baseRevision = Edit.revision(5)
        let drafts = [
            Edit.draft(), added, stale,
            Edit.draft([.disconnect(Fixture.id("edg.keys-verb")), .removeNode(Fixture.id("nod.delay"))]),
            Edit.draft([.addNode(WiringComposeFixture.comp)])
        ]
        for draft in drafts {
            Self.expectEquivalent(draft, active: Fixture.graph, run: &run)
        }
        let loop = WiringComposeFixture.monoLoop
        Self.expectEquivalent(Edit.draft(on: loop), active: loop, run: &run)
        let coverage = run.coverage
        #expect(coverage.classes.isSuperset(of: [.valid, .needsConversion, .feedbackOnly, .existing, .disabled]))
        #expect(coverage.composed > 5 && coverage.removed > 10 && coverage.restored > 5)
        #expect(coverage.refused.isSuperset(of: [
            "window.preview", "compose.conversionRequired", "compose.feedbackRequired", "compose.conversionNotNeeded",
            "compose.feedbackNotNeeded", "compose.disabled"
        ]))
    }

    @Test func pathsAgreeOnSeededGraphsAndDrafts() {
        var run = EditPathRun(random: EditPathGenerator(state: 0x5EED))
        for seed in UInt64(1)...60 {
            let graph = EditPathSeeds.graph(seed: seed)
            Self.expectEquivalent(EditPathSeeds.draft(on: graph, seed: seed), active: graph, run: &run)
        }
        let coverage = run.coverage
        #expect(coverage.classes.isSuperset(of: [.valid, .needsConversion, .feedbackOnly, .existing, .disabled,
                                                 .uncheckable]))
        #expect(coverage.composed > 50 && coverage.removed > 50 && coverage.restored > 20)
        #expect(coverage.refused.isSuperset(of: [
            "compose.conversionRequired", "compose.feedbackRequired", "compose.conversionNotNeeded",
            "compose.feedbackNotNeeded", "compose.disabled", "compose.preview", "compose.connectDoesNotApply"
        ]))
    }

    @Test func fractionalLargeCoordinateNudgesMatchNumericEntry() throws {
        let coordinate = 1_000_000_000_000.0001
        let graph = try WiringEditPathTests.keys(at: coordinate, coordinate)
        let draft = Edit.draft(on: graph)
        let cases: [(step: Double, expected: Double)] = [
            (0.000062, 1_000_000_000_000.000244140625),
            (0.1, 1_000_000_000_000.10009765625)
        ]
        for (step, expected) in cases {
            let grid = Edit.grid(step: step, fineStep: step)
            let nudged = try Edit.nudged(
                WiringEditPathTests.keys, [WiringNudge(.rightward, fine: true)], grid: grid,
                from: draft, active: graph
            )
            let numeric = try WiringMoveComposer.move(
                WiringEditPathTests.keys, x: coordinate + step, y: coordinate, in: draft, active: graph
            )
            #expect(nudged == numeric, "step \(step)")
            #expect(WiringEditPathTests.movedX(nudged) == expected, "step \(step)")
        }
    }

    @Test func binaryRepresentableNudgesMatchNumericEntryAcrossMagnitudes() throws {
        var random = EditPathGenerator(state: 0x7d36_5a91_42c8_b10f)
        let steps: [Double] = [0.5, 0.25, 0x1p-14, 1, 2, 8]
        for index in 0..<64 {
            let exponent = -3 + 16 * Double(index) / 63
            let magnitude = pow(10, exponent)
            let coordinate = random.next() & 1 == 0 ? magnitude : -magnitude
            let step = steps[random.below(steps.count)]
            let graph = try WiringEditPathTests.keys(at: coordinate, coordinate)
            let draft = Edit.draft(on: graph)
            let grid = Edit.grid(step: 8, fineStep: step)
            let nudged = try Edit.nudged(
                WiringEditPathTests.keys, [WiringNudge(.rightward, fine: true)], grid: grid,
                from: draft, active: graph
            )
            let numeric = try WiringMoveComposer.move(
                WiringEditPathTests.keys, x: coordinate + step, y: coordinate, in: draft, active: graph
            )
            #expect(nudged == numeric, "coordinate \(coordinate), step \(step)")
        }
    }

    @Test func offGridBaseFoldsFromNumericAndMovedDraftPositions() throws {
        let base = (x: 0.1234567891234, y: 0.2345678912345)
        let graph = try WiringEditPathTests.keys(at: base.x, base.y)
        let draft = Edit.draft(on: graph)
        #expect(try WiringMoveComposer.move(WiringEditPathTests.keys, x: base.x, y: base.y,
                                             in: draft, active: graph) == draft)
        let moved = try WiringMoveComposer.move(WiringEditPathTests.keys, x: 4, y: 5, in: draft, active: graph)
        #expect(try WiringMoveComposer.move(WiringEditPathTests.keys, x: base.x, y: base.y,
                                             in: moved, active: graph) == draft)
    }

    @Test func doubleAccumulationCannotLoseAHalfULPNudge() throws {
        let tenthGraph = try WiringEditPathTests.keys(at: 0), tenthDraft = Edit.draft(on: tenthGraph)
        let tenths = try Edit.nudged(
            WiringEditPathTests.keys, Array(repeating: WiringNudge(.rightward, fine: true), count: 10),
            grid: Edit.grid(step: 0.1, fineStep: 0.1), from: tenthDraft, active: tenthGraph
        )
        #expect(WiringEditPathTests.movedX(tenths) == 1)

        let midpointGraph = try WiringEditPathTests.keys(at: 0)
        let midpointDraft = Edit.draft(on: midpointGraph)
        let midpointGrid = Edit.grid(step: 0.1, fineStep: 0.000000000000023809523809523804)
        var midpointState = WiringMoveState(draft: midpointDraft)
        for _ in 0..<21 {
            midpointState = try WiringMoveComposer.nudge(
                WiringEditPathTests.keys, WiringNudge(.rightward, fine: true),
                grid: midpointGrid, in: midpointState, active: midpointGraph
            )
        }
        #expect(midpointState.draft == midpointDraft)

        let base = 1e12 + 0.0001220703125
        let graph = try WiringEditPathTests.keys(at: base, base)
        let draft = Edit.draft(on: graph)
        let step = 0.000006103515625
        let grid = Edit.grid(step: 0.1, fineStep: step)
        var state = WiringMoveState(draft: draft)
        for _ in 0..<10 {
            state = try WiringMoveComposer.nudge(
                WiringEditPathTests.keys, WiringNudge(.rightward, fine: true), grid: grid, in: state, active: graph
            )
        }
        let numeric = try WiringMoveComposer.move(
            WiringEditPathTests.keys, x: base + 0.00006103515625, y: base, in: draft, active: graph
        )
        #expect(state.draft == numeric)
        for _ in 0..<10 {
            state = try WiringMoveComposer.nudge(
                WiringEditPathTests.keys, WiringNudge(.leftward, fine: true), grid: grid, in: state, active: graph
            )
        }
        #expect(state.draft == draft)
    }

    @Test func halfULPNudgesMatchNumericTiesToEven() throws {
        let halfULP = 0x1p-31
        let cases: [(Double, WiringNudgeDirection)] = [
            (0x1p22, .rightward), (0x1p22 + 0x1p-29, .leftward),
            (0x1p22 + 0x1p-30, .rightward), (0x1p22 + 0x1p-30, .leftward)
        ]
        for (coordinate, direction) in cases {
            let graph = try WiringEditPathTests.keys(at: coordinate)
            let draft = Edit.draft(on: graph), grid = Edit.grid(step: halfULP, fineStep: halfULP)
            let nudge = try WiringMoveComposer.nudge(
                WiringEditPathTests.keys, WiringNudge(direction), grid: grid,
                in: WiringMoveState(draft: draft), active: graph
            )
            let sign = direction == .rightward ? 1.0 : -1.0
            let numeric = try WiringMoveComposer.move(
                WiringEditPathTests.keys, x: coordinate + sign * halfULP, y: 0, in: draft, active: graph
            )
            #expect(nudge.draft == numeric)
        }
    }

    @Test func underflowingCoordinatesQuantizeToSignedZeroOrTheNearestGridPoint() throws {
        let threshold = 5e-13
        let values = [1e-129, -1e-300, Double.leastNonzeroMagnitude, threshold.nextDown,
                      -threshold.nextUp, threshold, threshold.nextUp, -threshold, (-threshold).nextDown,
                      (-threshold).nextUp]
        for base in [0.0, 1e-13] {
            let graph = try WiringEditPathTests.keys(at: base)
            let draft = Edit.draft(on: graph)
            for value in values {
                let expected = abs(value) < threshold ? base : (value < 0 ? -1e-12 : 1e-12)
                let moved = try WiringMoveComposer.move(
                    WiringEditPathTests.keys, x: value, y: 0, in: draft, active: graph
                )
                #expect(moved == (expected == base ? draft : try WiringMoveComposer.move(
                    WiringEditPathTests.keys, x: expected, y: 0, in: draft, active: graph
                )), "\(base), \(value)")
            }
        }
    }
}
