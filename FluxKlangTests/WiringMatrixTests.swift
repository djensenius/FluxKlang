//
//  WiringMatrixTests.swift
//  FluxKlangTests
//
//  The wiring matrix window (#101 WP3): output ports as rows, input ports as
//  columns, each cell classified as the destination list classifies the pair
//  (one shared context per row), draft markers from the review diff, a
//  64 × 64 window bound, and toggles through the connect and remove composers
//  (a stale cell never removes a different wire; a wired cell at the edge
//  bound still shows on and toggles off).
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture
private typealias Edit = WiringEditFixture

@Suite("Wiring matrix")
struct WiringMatrixTests {
    static func window(
        _ draft: DraftEdits = Edit.draft(), active: GraphDocument = Fixture.graph
    ) throws(WiringEditRefusal) -> WiringMatrix {
        let graph = (try? active.applying(draft.edits)) ?? active
        return try WiringMatrix.window(
            rows: WiringMatrix.outputs(in: graph), columns: WiringMatrix.inputs(in: graph), active: active, draft: draft
        )
    }

    /// The cell of the named pair.
    static func cell(_ matrix: WiringMatrix, _ from: (String, String), _ to: (String, String)) -> WiringMatrixCell? {
        guard let row = matrix.rows.firstIndex(of: Fixture.address(from.0, from.1)),
              let column = matrix.columns.firstIndex(of: Fixture.address(to.0, to.1)) else { return nil }
        return matrix.cell(row: row, column: column)
    }

    /// Every cell of `matrix` (over `graph`) agrees with the destination list of its row and with `classify`,
    /// up to the list's documented whole-list deviations.
    static func expectAgreesWithTheList(
        _ matrix: WiringMatrix, in graph: GraphDocument, sourceLocation: SourceLocation = #_sourceLocation
    ) -> Set<WiringDestinationClass> {
        var seen: Set<WiringDestinationClass> = []
        let ports = Set(graph.nodes.flatMap { node in node.ports.map { PortAddress(node: node.id, port: $0.id) } })
        for (rowIndex, source) in matrix.rows.enumerated() {
            let list = Result { () throws(WiringPreviewRefusal) in
                try WiringDestinationList.make(from: source, in: graph)
            }
            for (columnIndex, destination) in matrix.columns.enumerated() {
                guard let cell = matrix.cell(row: rowIndex, column: columnIndex) else {
                    Issue.record("missing cell", sourceLocation: sourceLocation)
                    continue
                }
                seen.insert(cell.connectionClass)
                #expect(cell.from == source && cell.to == destination, sourceLocation: sourceLocation)
                // The pair's first wire in graph order, by node and port IDs; a classified `existing` names it too.
                let first = graph.edges.first { edge in
                    (edge.from.node, edge.from.port, edge.to.node, edge.to.port)
                        == (source.node, source.port, destination.node, destination.port)
                }
                #expect(cell.wiredEdge == first?.id, sourceLocation: sourceLocation)
                if case .classified(.existing(let edge)) = cell.state {
                    #expect(cell.wiredEdge == edge && cell.existingEdge == edge, sourceLocation: sourceLocation)
                }
                let classified = Result { () throws(WiringPreviewRefusal) in
                    try WiringCandidate.classify(from: source, to: destination, in: graph).connection
                }
                switch list {
                case .failure(let refusal):
                    // The whole-list deviation: every cell of the row carries the list's refusal.
                    #expect(cell.state == .uncheckable(refusal), sourceLocation: sourceLocation)
                case .success(let list):
                    if let candidate = list.candidates.first(where: { $0.to == destination }) {
                        #expect(cell.state == .classified(candidate.connection), sourceLocation: sourceLocation)
                        #expect(cell.connectionClass == WiringDestinationClass(candidate.connection),
                                sourceLocation: sourceLocation)
                    } else if let row = list.group(.uncheckable)?.uncheckable.first(where: { $0.to == destination }) {
                        #expect(cell.state == .uncheckable(row.refusal), sourceLocation: sourceLocation)
                    } else {
                        // The list leaves out the source itself and addresses the graph does not declare.
                        #expect(destination == source || !ports.contains(destination),
                                "\(destination) not listed for \(source)", sourceLocation: sourceLocation)
                    }
                    switch classified {
                    case .success(let connection):
                        #expect(cell.state == .classified(connection), "\(source) → \(destination)",
                                sourceLocation: sourceLocation)
                    case .failure(let refusal):
                        #expect(cell.state == .uncheckable(refusal), "\(source) → \(destination)",
                                sourceLocation: sourceLocation)
                    }
                }
            }
        }
        return seen
    }

    @Test func cellClassesMatchTheDestinationListAndClassify() throws {
        let legacy = Fixture.with([], nodes: [Fixture.node("nod.legacy", ports: [Fixture.audio("in", .input, nil)])])
        var uncheckable = Fixture.graph
        uncheckable.requiredFeatures = [GraphDocument.constantGainFeature]
        var seen: Set<WiringDestinationClass> = []
        for graph in [Fixture.graph, WiringComposeFixture.monoLoop, legacy, uncheckable] {
            let draft = Edit.draft(on: graph)
            // Every port as a row and a column, so wrong-direction and shortcut pairs are covered too.
            let ports = graph.nodes.flatMap { node in node.ports.map { PortAddress(node: node.id, port: $0.id) } }
                + [Fixture.address("nod.ch7", "out")]
            let matrix = try WiringMatrix.window(rows: ports, columns: ports, active: graph, draft: draft)
            seen.formUnion(Self.expectAgreesWithTheList(matrix, in: graph))
        }
        #expect(seen == Set(WiringDestinationClass.allCases))
        let row = try #require(try Self.window(Edit.draft(on: uncheckable), active: uncheckable).cells.first)
        let features = [GraphDocument.constantGainFeature]
        #expect(row.state == .uncheckable(.uncheckableGraph(.invalidRequiredFeatures(features))))
    }

    @Test func rowsAreOutputsAndColumnsAreInputs() throws {
        let matrix = try Self.window()
        #expect(matrix.rows == ["nod.delay", "nod.echo", "nod.keys", "nod.mic", "nod.verb"].map {
            Fixture.address($0, "out")
        })
        #expect(matrix.columns == [
            Fixture.address("nod.delay", "in"), Fixture.address("nod.echo", "in"), Fixture.address("nod.mains", "in"),
            Fixture.address("nod.verb", "in"), Fixture.address("nod.verb", "mod")
        ])
        #expect(matrix.cells.count == 25)
        // A non-square window: cell (r, c) is rows[r] → columns[c].
        let rows = [Fixture.address("nod.keys", "out"), Fixture.address("nod.mic", "out")]
        let columns = [Fixture.address("nod.mains", "in"), Fixture.address("nod.verb", "in"),
                       Fixture.address("nod.verb", "mod")]
        let window = try WiringMatrix.window(rows: rows, columns: columns, active: Fixture.graph, draft: Edit.draft())
        for row in rows.indices {
            for column in columns.indices {
                let cell = try #require(window.cell(row: row, column: column))
                #expect(cell.from == rows[row] && cell.to == columns[column])
            }
        }
        #expect(window.cell(row: 0, column: 1)?.existingEdge == Fixture.id("edg.keys-verb"))
        #expect(window.cell(row: 1, column: 0)?.connectionClass == .needsConversion)
        #expect(window.cell(row: 2, column: 0) == nil && window.cell(row: 0, column: 3) == nil)
        #expect(window.cell(row: -1, column: 0) == nil && window.cell(row: 0, column: -1) == nil)
    }

    @Test func existingCellsCarryTheEdgeID() throws {
        // A second wire on keys → verb: the cell names the first one in graph order.
        let duplicate = Fixture.edge("edg.keys-verb-2", Fixture.address("nod.keys", "out"),
                                     Fixture.address("nod.verb", "in"))
        let graph = Fixture.with([duplicate])
        let matrix = try Self.window(Edit.draft(on: graph), active: graph)
        for edge in Fixture.graph.edges {
            let cell = try #require(Self.cell(matrix, (edge.from.node.rawValue, edge.from.port.rawValue),
                                              (edge.to.node.rawValue, edge.to.port.rawValue)))
            #expect(cell.existingEdge == edge.id && cell.isOn && cell.connectionClass == .existing)
        }
        let first = try #require(Self.cell(matrix, ("nod.keys", "out"), ("nod.verb", "in")))
        let toggled = try WiringMatrix.toggle(first, request: WiringMatrixConnect(edge: Fixture.id("edg.unused")),
                                              in: Edit.draft(on: graph), active: graph)
        #expect(toggled.edits == [.disconnect(Fixture.id("edg.keys-verb"))])
        let after = try Self.window(toggled, active: graph)
        #expect(Self.cell(after, ("nod.keys", "out"), ("nod.verb", "in"))?.existingEdge == duplicate.id)
        #expect(Self.cell(matrix, ("nod.keys", "out"), ("nod.mains", "in"))?.existingEdge == nil)
        // A mis-oriented wire: its pair is notOffered, so the cell is off although `wiredEdge` names the wire.
        let ports = [Fixture.address("nod.verb", "in"), Fixture.address("nod.keys", "out")]
        let backward = Fixture.edge("edg.backward", ports[0], ports[1])
        let skewed = Fixture.with([backward])
        let mis = try WiringMatrix.window(rows: ports, columns: ports, active: skewed, draft: Edit.draft(on: skewed))
        let wrongWay = try #require(mis.cell(row: 0, column: 1))
        #expect(wrongWay.state == .classified(.notOffered) && wrongWay.wiredEdge == backward.id)
        #expect(wrongWay.existingEdge == nil && !wrongWay.isOn)
    }

    @Test func draftMarkersComeFromTheReviewDiff() throws {
        let removed = EdgeID(validated: "edg.keys-verb")
        let request = WiringComposeFixture.request("edg.keys-mains", ("nod.keys", "out"), ("nod.mains", "in"))
        var draft = try WiringRemoveComposer.remove(edge: removed, from: Edit.draft(), active: Fixture.graph)
        draft = try WiringDraftComposer.compose(request, into: draft, active: Fixture.graph)
        let matrix = try Self.window(draft)
        let added = try #require(Self.cell(matrix, ("nod.keys", "out"), ("nod.mains", "in")))
        #expect(added.draftAdded == [request.edge] && added.willRemove.isEmpty)
        #expect(added.existingEdge == request.edge)
        let gone = try #require(Self.cell(matrix, ("nod.keys", "out"), ("nod.verb", "in")))
        #expect(gone.willRemove == [removed] && gone.draftAdded.isEmpty)
        #expect(gone.state == .classified(.valid) && !gone.isOn)
        let marked = matrix.cells.filter { !$0.draftAdded.isEmpty || !$0.willRemove.isEmpty }
        #expect(marked.count == 2)
        // Removing delay removes its two active wires with it; both are marked.
        let nodeGone = Edit.draft([.removeNode(Fixture.id("nod.delay"))])
        let withoutDelay = try WiringMatrix.window(
            rows: WiringMatrix.outputs(in: Fixture.graph), columns: WiringMatrix.inputs(in: Fixture.graph),
            active: Fixture.graph, draft: nodeGone
        )
        #expect(Self.cell(withoutDelay, ("nod.verb", "out"), ("nod.delay", "in"))?.willRemove
            == [Fixture.id("edg.verb-delay")])
        #expect(Self.cell(withoutDelay, ("nod.delay", "out"), ("nod.verb", "in"))?.willRemove
            == [Fixture.id("edg.delay-verb-fb")])
        #expect(Self.cell(withoutDelay, ("nod.delay", "out"), ("nod.verb", "in"))?.state
            == .uncheckable(.unknownNode(Fixture.id("nod.delay"))))
        // Several wires on one pair are listed by ID, whatever the edit order.
        let keysVerb = (Fixture.address("nod.keys", "out"), Fixture.address("nod.verb", "in"))
        let keysMains = (Fixture.address("nod.keys", "out"), Fixture.address("nod.mains", "in"))
        let doubled = Fixture.with([Fixture.edge("edg.dup", keysVerb.0, keysVerb.1)])
        let both = Edit.draft([
            .disconnect(removed), .disconnect(Fixture.id("edg.dup")),
            .connect(Fixture.edge("edg.z-new", keysMains.0, keysMains.1)),
            .connect(Fixture.edge("edg.a-new", keysMains.0, keysMains.1))
        ], on: doubled)
        let several = try Self.window(both, active: doubled)
        #expect(Self.cell(several, ("nod.keys", "out"), ("nod.verb", "in"))?.willRemove
            == [Fixture.id("edg.dup"), removed])
        #expect(Self.cell(several, ("nod.keys", "out"), ("nod.mains", "in"))?.draftAdded
            == [Fixture.id("edg.a-new"), Fixture.id("edg.z-new")])
    }

    @Test func windowBoundIs64By64() throws {
        let nodes = (0..<65).map { Fixture.stereo("nod.w\($0)", at: Double($0)) }
        let graph = GraphDocument(id: Fixture.graphID, nodes: nodes, edges: [])
        let draft = Edit.draft(on: graph)
        let outputs = WiringMatrix.outputs(in: graph), inputs = WiringMatrix.inputs(in: graph)
        #expect(outputs.count == 65 && inputs.count == 65)
        #expect(WiringMatrix.maximumRows == 64 && WiringMatrix.maximumColumns == 64)
        var validations = 0
        let full = try WiringMatrix.window(
            rows: Array(outputs.prefix(64)), columns: Array(inputs.prefix(64)), active: graph, draft: draft
        ) { validations += 1 }
        #expect(full.cells.count == 64 * 64)
        #expect(validations == 64)
        #expect(throws: WiringEditRefusal.windowTooLarge(rows: 65, columns: 64)) {
            try WiringMatrix.window(rows: outputs, columns: Array(inputs.prefix(64)), active: graph, draft: draft)
        }
        #expect(throws: WiringEditRefusal.windowTooLarge(rows: 64, columns: 65)) {
            try WiringMatrix.window(rows: Array(outputs.prefix(64)), columns: inputs, active: graph, draft: draft)
        }
        // The bound is checked before the draft.
        var stale = draft
        stale.baseRevision = Edit.revision(7)
        #expect(throws: WiringEditRefusal.windowTooLarge(rows: 65, columns: 0)) {
            try WiringMatrix.window(rows: outputs, columns: [], active: graph, draft: stale)
        }
        let empty = try WiringMatrix.window(rows: [], columns: inputs.prefix(3).map { $0 }, active: graph, draft: draft)
        #expect(empty.cells.isEmpty && empty.columns.count == 3)
    }

    @Test func wiredCellsAtTheEdgeBoundShowOnAndToggleOff() throws {
        let keysOut = Fixture.address("nod.keys", "out"), verbIn = Fixture.address("nod.verb", "in")
        let mainsIn = Fixture.address("nod.mains", "in")
        var graph = Fixture.graph
        // More wires on keys → verb after the fixture's own, up to exactly the bound.
        graph.edges += (graph.edges.count..<ProjectGraphLimits.edges).map {
            GraphEdge(id: Fixture.id("edg.fill-\($0)"), from: keysOut, to: verbIn)
        }
        #expect(graph.edges.count == ProjectGraphLimits.edges)
        let draft = Edit.draft(on: graph)
        let matrix = try WiringMatrix.window(rows: [keysOut], columns: [verbIn, mainsIn], active: graph, draft: draft)
        let keysVerb = Fixture.id("edg.keys-verb") as EdgeID
        let wired = try #require(matrix.cell(row: 0, column: 0))
        #expect(wired.state == .classified(.existing(keysVerb)) && wired.connectionClass == .existing)
        #expect(wired.wiredEdge == keysVerb && wired.existingEdge == keysVerb && wired.isOn)
        let open = try #require(matrix.cell(row: 0, column: 1))
        let atBound = WiringMatrixCellState.uncheckable(
            .bounds(.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges))
        )
        #expect(open.state == atBound && open.wiredEdge == nil && open.existingEdge == nil && !open.isOn)
        // `classify` calls the pair existing at the bound; the cell removes the same edge.
        #expect(try WiringCandidate.classify(from: keysOut, to: verbIn, in: graph).connection == .existing(keysVerb))
        let toggled = try WiringMatrix.toggle(wired, request: WiringMatrixConnect(edge: Fixture.id("edg.unused")),
                                              in: draft, active: graph)
        #expect(toggled == (try WiringRemoveComposer.remove(edge: keysVerb, from: draft, active: graph)))
        #expect(toggled.edits == [.disconnect(keysVerb)])
    }

    @Test func aStaleCellNeverRemovesADifferentWire() throws {
        let active = Fixture.graph
        let request = WiringMatrixConnect(edge: Fixture.id("edg.other"))
        let keysMains = WiringComposeFixture.request("edg.reuse", ("nod.keys", "out"), ("nod.mains", "in"))
        let first = try WiringDraftComposer.compose(keysMains, into: Edit.draft(), active: active)
        let cell = try #require(Self.cell(try Self.window(first), ("nod.keys", "out"), ("nod.mains", "in")))
        #expect(cell.existingEdge == keysMains.edge)
        // The ID is removed, then reused on echo → mains.
        let removed = try WiringRemoveComposer.remove(edge: keysMains.edge, from: first, active: active)
        let echoMains = WiringComposeFixture.request("edg.reuse", ("nod.echo", "out"), ("nod.mains", "in"))
        let reused = try WiringDraftComposer.compose(echoMains, into: removed, active: active)
        #expect(throws: WiringEditRefusal.staleCell(keysMains.edge)) {
            try WiringMatrix.toggle(cell, request: request, in: reused, active: active)
        }
        #expect(reused == (try WiringDraftComposer.compose(echoMains, into: Edit.draft(), active: active)))
        // Reused on keys → echo: only the destination differs, and that is stale too.
        let keysEcho = WiringComposeFixture.request("edg.reuse", ("nod.keys", "out"), ("nod.echo", "in"))
        let retargeted = try WiringDraftComposer.compose(keysEcho, into: removed, active: active)
        #expect(throws: WiringEditRefusal.staleCell(keysMains.edge)) {
            try WiringMatrix.toggle(cell, request: request, in: retargeted, active: active)
        }
        // The fresh cell removes it.
        let fresh = try #require(Self.cell(try Self.window(reused), ("nod.echo", "out"), ("nod.mains", "in")))
        #expect(try WiringMatrix.toggle(fresh, request: request, in: reused, active: active) == Edit.draft())
        // Endpoint extension bags are ignored: the same pair by IDs is not stale.
        var tagged = Fixture.address("nod.keys", "out")
        tagged.extensions = ["tag": .bool(true)]
        let bagged = Edit.draft([.connect(Fixture.edge("edg.reuse", tagged, Fixture.address("nod.mains", "in")))])
        #expect(try WiringMatrix.toggle(cell, request: request, in: bagged, active: active) == Edit.draft())

        // Reusing the ID on the same pair of nodes but different ports is stale too.
        var alternatePorts = active
        let keysIndex = try #require(alternatePorts.nodes.firstIndex { $0.id == Fixture.id("nod.keys") })
        alternatePorts.nodes[keysIndex].ports.append(Fixture.audio("out.alt", .output, 2))
        let mainsIndex = try #require(alternatePorts.nodes.firstIndex { $0.id == Fixture.id("nod.mains") })
        alternatePorts.nodes[mainsIndex].ports.append(Fixture.audio("in.alt", .input, 2))
        let original = try WiringDraftComposer.compose(
            WiringComposeFixture.request("edg.reuse", ("nod.keys", "out"), ("nod.mains", "in")),
            into: Edit.draft(), active: alternatePorts
        )
        let oldCell = try #require(Self.cell(
            try Self.window(original, active: alternatePorts), ("nod.keys", "out"), ("nod.mains", "in")
        ))
        let originalRemoved = try WiringRemoveComposer.remove(edge: Fixture.id("edg.reuse"), from: original,
                                                              active: alternatePorts)
        let portReused = try WiringDraftComposer.compose(
            WiringComposeFixture.request("edg.reuse", ("nod.keys", "out.alt"), ("nod.mains", "in.alt")),
            into: originalRemoved, active: alternatePorts
        )
        #expect(throws: WiringEditRefusal.staleCell(Fixture.id("edg.reuse"))) {
            try WiringMatrix.toggle(oldCell, request: request, in: portReused, active: alternatePorts)
        }
    }

    @Test func eachRowValidatesOnce() throws {
        let graph = Fixture.graph
        let rows = WiringMatrix.outputs(in: graph) + [Fixture.address("nod.nope", "out")]
        var validations = 0
        let matrix = try WiringMatrix.window(
            rows: rows, columns: WiringMatrix.inputs(in: graph), active: graph, draft: Edit.draft()
        ) { validations += 1 }
        #expect(validations == rows.count)
        #expect(matrix == (try WiringMatrix.window(
            rows: rows, columns: WiringMatrix.inputs(in: graph), active: graph, draft: Edit.draft()
        )))
        // The unknown row is refused as a whole, in every cell.
        let last = matrix.cells.suffix(matrix.columns.count)
        #expect(last.allSatisfy { $0.state == .uncheckable(.unknownNode(Fixture.id("nod.nope"))) })
    }

    @Test func toggleRoundTripLeavesTheDraftUnchanged() throws {
        let earlier: [GraphEdit] = [.moveNode(Fixture.id("nod.keys"), to: GraphPoint(x: 4, y: 4))]
        let draft = Edit.draft(earlier)
        let cases: [(pair: ToggleCase, request: WiringMatrixConnect)] = [
            (ToggleCase(("nod.keys", "out"), ("nod.mains", "in")), WiringMatrixConnect(edge: Fixture.id("edg.new"))),
            (ToggleCase(("nod.mic", "out"), ("nod.mains", "in")),
             WiringMatrixConnect(edge: Fixture.id("edg.new"), conversion: Fixture.upmix)),
            (ToggleCase(("nod.verb", "out"), ("nod.echo", "in")),
             WiringMatrixConnect(edge: Fixture.id("edg.new"), feedback: Fixture.feedback))
        ]
        for (pair, request) in cases {
            let (from, to) = (pair.from, pair.to)
            let off = try #require(Self.cell(try Self.window(draft), from, to))
            #expect(!off.isOn)
            let wired = try WiringMatrix.toggle(off, request: request, in: draft, active: Fixture.graph)
            #expect(wired.edits.count == earlier.count + 1)
            let cell = try #require(Self.cell(try Self.window(wired), from, to))
            #expect(cell.existingEdge == request.edge && cell.draftAdded == [request.edge])
            let back = try WiringMatrix.toggle(cell, request: request, in: wired, active: Fixture.graph)
            #expect(back == draft, "\(from) → \(to)")
        }
        // An active wire: toggled off, then restored.
        let active = try #require(Self.cell(try Self.window(draft), ("nod.echo", "out"), ("nod.verb", "in")))
        let off = try WiringMatrix.toggle(active, request: WiringMatrixConnect(edge: Fixture.id("edg.x")), in: draft,
                                          active: Fixture.graph)
        #expect(off.edits == earlier + [.disconnect(Fixture.id("edg.echo-verb"))])
        #expect(try WiringRemoveComposer.restore(edge: Fixture.id("edg.echo-verb"), into: off, active: Fixture.graph)
            == draft)
    }

    @Test func toggleAndWindowRefusalsChangeNothing() throws {
        let draft = Edit.draft()
        let matrix = try Self.window(draft)
        let request = WiringMatrixConnect(edge: Fixture.id("edg.new"))
        let disabled = try #require(Self.cell(matrix, ("nod.keys", "out"), ("nod.verb", "mod")))
        #expect(throws: WiringEditRefusal.compose(.disabled(.signalMismatch(from: .audio, to: .control)))) {
            try WiringMatrix.toggle(disabled, request: request, in: draft, active: Fixture.graph)
        }
        let mono = try #require(Self.cell(matrix, ("nod.mic", "out"), ("nod.mains", "in")))
        #expect(throws: WiringEditRefusal.compose(.conversionRequired(sourceChannels: 1, destinationChannels: 2))) {
            try WiringMatrix.toggle(mono, request: request, in: draft, active: Fixture.graph)
        }
        // A cell from an older window: its edge is already removed.
        let stale = try #require(Self.cell(matrix, ("nod.keys", "out"), ("nod.verb", "in")))
        let removed = Edit.draft([.disconnect(Fixture.id("edg.keys-verb"))])
        #expect(throws: WiringEditRefusal.notInDraftOrActive(Fixture.id("edg.keys-verb"))) {
            try WiringMatrix.toggle(stale, request: request, in: removed, active: Fixture.graph)
        }
        var staleDraft = draft
        staleDraft.baseRevision = Edit.revision(3)
        let mismatch = WiringPreviewRefusal.draftBaseMismatch(draft: Edit.revision(3), active: Fixture.graph.revision)
        #expect(throws: WiringEditRefusal.preview(mismatch)) { try Self.window(staleDraft) }
        #expect(throws: WiringEditRefusal.compose(.preview(mismatch))) {
            try WiringMatrix.toggle(mono, request: request, in: staleDraft, active: Fixture.graph)
        }
        #expect(draft == Edit.draft())
    }

    @Test func outputsAndInputsListRoutablePortsOnceInIDOrder() {
        let tap = Fixture.node("nod.tap", .observedShortcut, ports: [Fixture.audio("in", .input, 2)])
        let repeated = Fixture.node(
            "nod.keys", ports: [Fixture.audio("out", .output, 2), Fixture.audio("in", .input, 2)]
        )
        let graph = Fixture.with([], nodes: [tap, repeated])
        #expect(WiringMatrix.outputs(in: graph) == ["nod.delay", "nod.echo", "nod.keys", "nod.mic", "nod.verb"].map {
            Fixture.address($0, "out")
        })
        let inputs = WiringMatrix.inputs(in: graph)
        #expect(inputs.contains(Fixture.address("nod.keys", "in")))
        #expect(!inputs.contains(Fixture.address("nod.tap", "in")))
        #expect(inputs == inputs.sorted { ($0.node.rawValue, $0.port.rawValue) < ($1.node.rawValue, $1.port.rawValue) })
    }
}

/// A matrix cell's source and destination, as (node, port) ID strings.
private struct ToggleCase {
    var from: (String, String)
    var to: (String, String)

    init(_ from: (String, String), _ to: (String, String)) {
        self.from = from
        self.to = to
    }
}
