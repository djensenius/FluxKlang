//
//  WiringPreviewTests+Diff.swift
//  FluxKlangTests
//
//  The review diff (#101 WP1) between the active graph and
//  `active.applying(draft.edits)`: grouped and sorted rows, every change once,
//  edit-order independence, refusals and the ProjectGraphLimits boundary.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture

/// SplitMix64: a seeded, deterministic generator for shuffles.
private struct WiringPreviewSeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

#if os(macOS)
@Suite("Wiring review diff", .productionAccessAudit)
#else
@Suite("Wiring review diff")
#endif
struct WiringReviewDiffTests {
    static let comp = Fixture.stereo("nod.comp", at: 10)
    static let gate = Fixture.stereo("nod.gate", at: 11)
    static let keysComp = Fixture.edge("edg.keys-comp", Fixture.address("nod.keys", "out"),
                                       Fixture.address("nod.comp", "in"))
    static let compMains = Fixture.edge("edg.comp-mains", Fixture.address("nod.comp", "out"),
                                        Fixture.address("nod.mains", "in"))
    static let mainsAt = GraphPoint(x: 3, y: 4)

    /// Order-independent edits: any permutation applies to the fixture.
    static let restructure: [GraphEdit] = [
        .addNode(comp), .addNode(gate), .connect(keysComp), .connect(compMains),
        .moveNode(Fixture.id("nod.mains"), to: mainsAt), .disconnect(Fixture.id("edg.echo-verb")),
        .removeNode(Fixture.id("nod.delay"))
    ]

    static func draft(_ edits: [GraphEdit], on graph: GraphDocument = Fixture.graph) -> DraftEdits {
        DraftEdits(id: DraftID(validated: "dft.review"), graph: graph.id, baseRevision: graph.revision, edits: edits)
    }

    static func diff(_ edits: [GraphEdit], on graph: GraphDocument = Fixture.graph) throws -> WiringReviewDiff {
        try WiringReviewDiff.make(active: graph, draft: draft(edits, on: graph))
    }

    static func edge(_ id: String) -> GraphEdge {
        Fixture.graph.edges.first { $0.id.rawValue == id } ?? Fixture.graph.edges[0]
    }

    @Test func emptyDraftHasNoGroups() throws {
        let diff = try Self.diff([])
        #expect(diff.isEmpty)
        #expect(diff.groups.isEmpty && diff.changes.isEmpty)
    }

    @Test func rowsAreGroupedByKindAndSortedByID() throws {
        let diff = try Self.diff(Self.restructure)
        let delay = try #require(Fixture.graph.node(Fixture.id("nod.delay")))
        #expect(diff.groups.map(\.kind) == WiringReviewChangeKind.allCases)
        #expect(diff.groups.map(\.changes) == [
            [.addedNode(Self.comp), .addedNode(Self.gate)],
            [.movedNode(Fixture.id("nod.mains"), from: GraphPoint(x: 3, y: 0), to: Self.mainsAt)],
            [.removedNode(delay)],
            [.addedEdge(Self.compMains), .addedEdge(Self.keysComp)],
            [.removedEdge(Self.edge("edg.delay-verb-fb")), .removedEdge(Self.edge("edg.echo-verb")),
             .removedEdge(Self.edge("edg.verb-delay"))]
        ])
        #expect(diff.changes.count == 9)
        #expect(Set(diff.changes).count == diff.changes.count)
        #expect(diff.changes.allSatisfy { change in diff.groups.contains { $0.kind == change.kind } })
    }

    @Test func shuffledEditsGiveTheSameDiff() throws {
        let expected = try Self.diff(Self.restructure)
        var generator = WiringPreviewSeededGenerator(state: 0x5EED_0101)
        var reordered = 0
        for _ in 0..<24 {
            let edits = Self.restructure.shuffled(using: &generator)
            if edits != Self.restructure { reordered += 1 }
            #expect(try Self.diff(edits) == expected)
        }
        #expect(try Self.diff(Self.restructure.reversed()) == expected)
        #expect(reordered > 20)
    }

    @Test func movedDraftAddedNodeIsOnlyAddedAtItsFinalPosition() throws {
        let final = GraphPoint(x: 5, y: 5)
        var moved = Self.comp
        moved.position = final
        let diff = try Self.diff([.addNode(Self.comp), .moveNode(Self.comp.id, to: final), .connect(Self.keysComp)])
        #expect(diff.changes == [.addedNode(moved), .addedEdge(Self.keysComp)])
        let unplaced = try Self.diff([.addNode(Self.comp), .moveNode(Self.comp.id, to: nil)])
        var bare = Self.comp
        bare.position = nil
        #expect(unplaced.changes == [.addedNode(bare)])
    }

    @Test func movesThatChangeNothingAreNotRows() throws {
        let mains = Fixture.id("nod.mains") as NodeID
        #expect(try Self.diff([.moveNode(mains, to: GraphPoint(x: 3, y: 0))]).isEmpty)
        #expect(try Self.diff([.moveNode(mains, to: nil)]).changes
            == [.movedNode(mains, from: GraphPoint(x: 3, y: 0), to: nil)])
        // An unmoved node whose position never equals itself (NaN) is not reported.
        var nan = Fixture.graph
        nan.nodes[0].position = GraphPoint(x: .nan, y: 0)
        #expect(try Self.diff([.disconnect(Fixture.id("edg.echo-verb"))], on: nan).changes
            == [.removedEdge(Self.edge("edg.echo-verb"))])
        // Nor is an untouched edge whose record never equals itself (NaN feedback gain).
        let feedback = try #require(nan.edges.firstIndex { $0.id.rawValue == "edg.delay-verb-fb" })
        nan.edges[feedback].feedback?.gainCeilingDb = .nan
        #expect(try Self.diff([.disconnect(Fixture.id("edg.echo-verb"))], on: nan).changes
            == [.removedEdge(Self.edge("edg.echo-verb"))])
    }

    @Test func eachChangeAppearsExactlyOnce() throws {
        let verbDelay = Self.edge("edg.verb-delay")
        let delay = try #require(Fixture.graph.node(Fixture.id("nod.delay")))
        let diff = try Self.diff([.disconnect(verbDelay.id), .removeNode(delay.id)])
        #expect(diff.changes == [
            .removedNode(delay), .removedEdge(Self.edge("edg.delay-verb-fb")), .removedEdge(verbDelay)
        ])
        let moveThenRemove = [GraphEdit.moveNode(delay.id, to: nil), .removeNode(delay.id)]
        #expect(throws: WiringPreviewRefusal.draftDoesNotApply(.contradictoryNode(delay.id))) {
            try Self.diff(moveThenRemove)
        }
        // A node ID never survives with a new record: removing and re-adding it is contradictory.
        var rebuilt = delay
        rebuilt.ports = [Fixture.audio("in", .input, 1)]
        #expect(throws: WiringPreviewRefusal.draftDoesNotApply(.contradictoryNode(delay.id))) {
            try Self.diff([.removeNode(delay.id), .addNode(rebuilt)])
        }
    }

    /// Copilot round 1: removing nod.echo cascades edg.echo-verb, and the draft then connects that ID again on a
    /// new route. Both routes are rows. The other ways to reconnect the ID (connecting first, a plain reconnect
    /// without a node removal, and the old route back) do not apply, so no draft keeps an ID with a hidden route.
    @Test func cascadeRemovedEdgeReconnectedUnderItsIDShowsBothRoutes() throws {
        let echo = try #require(Fixture.graph.node(Fixture.id("nod.echo")))
        let old = Self.edge("edg.echo-verb")
        let rerouted = Fixture.edge("edg.echo-verb", Fixture.address("nod.keys", "out"),
                                    Fixture.address("nod.mains", "in"))
        let diff = try Self.diff([.removeNode(echo.id), .connect(rerouted)])
        #expect(diff.groups.map(\.kind) == [.removedNode, .addedEdge, .removedEdge])
        #expect(diff.changes == [.removedNode(echo), .addedEdge(rerouted), .removedEdge(old)])
        #expect(throws: WiringPreviewRefusal.draftDoesNotApply(.edgeExists(old.id))) {
            try Self.diff([.connect(rerouted), .removeNode(echo.id)])
        }
        #expect(throws: WiringPreviewRefusal.draftDoesNotApply(.contradictoryEdge(old.id))) {
            try Self.diff([.disconnect(old.id), .connect(rerouted)])
        }
        #expect(throws: WiringPreviewRefusal.draftDoesNotApply(.contradictoryEdge(old.id))) {
            try Self.diff([.disconnect(old.id), .connect(old)])
        }
        #expect(throws: WiringPreviewRefusal.draftDoesNotApply(.contradictoryNode(echo.id))) {
            try Self.diff([.removeNode(echo.id), .connect(old)])
        }
    }

    /// A reconnect that keeps one endpoint is still a new route, in any applicable edit order; the removed node's
    /// other edge is only removed.
    @Test func reconnectKeepingOneEndpointShowsBothRoutes() throws {
        let delay = try #require(Fixture.graph.node(Fixture.id("nod.delay")))
        let mains = Fixture.id("nod.mains") as NodeID
        let rerouted = Fixture.edge("edg.verb-delay", Fixture.address("nod.verb", "out"),
                                    Fixture.address("nod.echo", "in"))
        let expected: [WiringReviewChange] = [
            .movedNode(mains, from: GraphPoint(x: 3, y: 0), to: Self.mainsAt), .removedNode(delay),
            .addedEdge(rerouted), .removedEdge(Self.edge("edg.delay-verb-fb")),
            .removedEdge(Self.edge("edg.verb-delay"))
        ]
        let move = GraphEdit.moveNode(mains, to: Self.mainsAt)
        let orders: [[GraphEdit]] = [
            [.removeNode(delay.id), .connect(rerouted), move], [move, .removeNode(delay.id), .connect(rerouted)],
            [.removeNode(delay.id), move, .connect(rerouted)]
        ]
        for edits in orders {
            #expect(try Self.diff(edits).changes == expected)
        }
    }

    @Test func nodeAndEdgeSharingARawIDAreSeparateRows() throws {
        let shared = Fixture.stereo("x.shared", at: 12)
        let wire = Fixture.edge("x.shared", Fixture.address("nod.keys", "out"), Fixture.address("x.shared", "in"))
        let added = try Self.diff([.addNode(shared), .connect(wire)])
        #expect(added.changes == [.addedNode(shared), .addedEdge(wire)])
        #expect(added.groups.map(\.kind) == [.addedNode, .addedEdge])
        let active = try Fixture.graph.applying([.addNode(shared), .connect(wire)])
        let removed = try Self.diff([.removeNode(shared.id)], on: active)
        #expect(removed.changes == [.removedNode(shared), .removedEdge(wire)])
    }

    @Test func draftsForAnotherGraphOrRevisionAreRefused() throws {
        var other = Self.draft(Self.restructure)
        other.graph = GraphID(validated: "gph.other")
        #expect(throws: WiringPreviewRefusal.draftGraphMismatch(draft: other.graph, active: Fixture.graphID)) {
            try WiringReviewDiff.make(active: Fixture.graph, draft: other)
        }
        var stale = Self.draft(Self.restructure)
        stale.baseRevision = try ContractRevision(7)
        #expect(throws: WiringPreviewRefusal.draftBaseMismatch(draft: stale.baseRevision, active: .initial)) {
            try WiringReviewDiff.make(active: Fixture.graph, draft: stale)
        }
    }

    @Test func draftsThatDoNotApplyAreRefused() {
        #expect(throws: WiringPreviewRefusal.draftDoesNotApply(.missingEdge(Fixture.id("edg.ghost")))) {
            try Self.diff([.disconnect(Fixture.id("edg.ghost"))])
        }
        #expect(throws: WiringPreviewRefusal.draftDoesNotApply(.nodeExists(Fixture.id("nod.keys")))) {
            try Self.diff([.addNode(Fixture.graph.nodes[0])])
        }
    }

    @Test func ambiguousActiveIdentitiesAreRefused() {
        let twinNode = Fixture.with([], nodes: [Fixture.stereo("nod.echo", at: 20)])
        #expect(throws: WiringPreviewRefusal.ambiguousNode(Fixture.id("nod.echo"))) {
            try Self.diff([], on: twinNode)
        }
        let twinEdge = Fixture.with([Self.edge("edg.verb-mains")])
        #expect(throws: WiringPreviewRefusal.ambiguousEdge(Fixture.id("edg.verb-mains"))) {
            try Self.diff([], on: twinEdge)
        }
    }

    @Test func diffSizeIsBoundedAtNAndNPlusOne() throws {
        let empty = GraphDocument(id: Fixture.graphID)
        let adds = (0...ProjectGraphLimits.edits).map { index in
            GraphEdit.addNode(Fixture.stereo("nod.n\(index)", at: Double(index)))
        }
        let atLimit = try Self.diff(Array(adds.prefix(ProjectGraphLimits.edits)), on: empty)
        #expect(atLimit.changes.count == ProjectGraphLimits.edits)
        #expect(atLimit.groups.count == 1)
        let ids = atLimit.changes.map(\.sortID)
        #expect(ids == ids.sorted())
        #expect(ids.first == "nod.n0" && ids.last == "nod.n999")
        #expect(throws: WiringPreviewRefusal.bounds(.exceeded(path: "$.edits", maximum: ProjectGraphLimits.edits))) {
            try Self.diff(adds, on: empty)
        }
        // Node bound: the active graph holds N - 1 (or N) nodes and the draft adds one.
        var full = empty
        full.nodes = adds.prefix(ProjectGraphLimits.nodes - 1).compactMap { edit -> GraphNode? in
            if case .addNode(let node) = edit { return node }
            return nil
        }
        let extra = GraphEdit.addNode(Fixture.stereo("nod.extra", at: 0))
        #expect(try Self.diff([extra], on: full).changes.count == 1)
        full.nodes.append(Fixture.stereo("nod.last", at: 0))
        #expect(throws: WiringPreviewRefusal.bounds(.exceeded(path: "$.nodes", maximum: ProjectGraphLimits.nodes))) {
            try Self.diff([extra], on: full)
        }
    }
}
