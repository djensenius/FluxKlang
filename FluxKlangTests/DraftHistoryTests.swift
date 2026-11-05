import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// A seeded SplitMix64 generator; deterministic for a seed.
struct DraftHistorySeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Graph fixtures shared by the draft fold and undo suites.
enum DraftHistoryFixture {
    static func nodeID(_ raw: String) throws -> NodeID { try NodeID(raw) }
    static func edgeID(_ raw: String) throws -> EdgeID { try EdgeID(raw) }

    static func point(_ along: Double) -> GraphPoint { GraphPoint(x: along, y: 0) }

    /// Positions with one NaN or infinite coordinate; `GraphDocument.applying` accepts them, the fold refuses them.
    static let nonFinite: [GraphPoint] = [.nan, .infinity, -.infinity].flatMap { bad in
        [GraphPoint(x: bad, y: 0), GraphPoint(x: 0, y: bad)]
    }

    static func node(_ raw: String, at position: GraphPoint? = nil) throws -> GraphNode {
        try GraphNode(
            id: nodeID(raw), kind: .plugin, label: raw,
            ports: [
                GraphPort(id: PortID("i"), direction: .input, signal: .audio, channels: 2),
                GraphPort(id: PortID("o"), direction: .output, signal: .audio, channels: 2)
            ],
            position: position
        )
    }

    static func edge(_ raw: String, _ from: String, _ to: String, map: [[Int]]? = nil) throws -> GraphEdge {
        try GraphEdge(
            id: edgeID(raw),
            from: PortAddress(node: nodeID(from), port: PortID("o")),
            to: PortAddress(node: nodeID(to), port: PortID("i")),
            conversion: map.map { EdgeConversion(map: $0) }
        )
    }

    /// Nodes b0…b3 at x = 0, 10, 20, 30 wired b0→b1 (e0), b1→b2 (e1), b2→b3 (e2); revision 3.
    static func base(extraEdges: [GraphEdge] = []) throws -> GraphDocument {
        try GraphDocument(
            id: GraphID("g"), revision: ContractRevision(3),
            nodes: (0..<4).map { try node("b\($0)", at: point(Double($0) * 10)) },
            edges: [edge("e0", "b0", "b1"), edge("e1", "b1", "b2"), edge("e2", "b2", "b3")] + extraEdges
        )
    }

    /// Edge order is not semantic; an identical reconnect keeps a base edge in place.
    static func canonical(_ graph: GraphDocument) -> GraphDocument {
        var graph = graph
        graph.edges.sort { $0.id < $1.id }
        return graph
    }

    /// Folds each gesture in turn, checking every intermediate list validates.
    static func fold(_ gestures: [[GraphEdit]], base: GraphDocument) throws -> [GraphEdit] {
        var edits: [GraphEdit] = []
        for gesture in gestures {
            edits = try DraftEditFold.fold(gesture, onto: edits, base: base)
            try GraphEdit.validateBatch(edits)
        }
        return edits
    }

    /// Applies each gesture edit one at a time, or nil when any refuses.
    static func sequential(_ edits: [GraphEdit], on graph: GraphDocument) -> GraphDocument? {
        var graph = graph
        for edit in edits {
            guard let next = try? graph.applying([edit]) else { return nil }
            graph = next
        }
        return graph
    }

    /// A random edit; three times in four it is drawn from IDs that make it plausible on `current`.
    /// About one position in ten is non-finite.
    static func randomEdit(
        _ rng: inout DraftHistorySeededGenerator, base: GraphDocument, current: GraphDocument
    ) throws -> GraphEdit {
        let nodes = ["b0", "b1", "b2", "b3", "d0", "d1", "d2", "ghost"]
        let edges = ["e0", "e1", "e2", "f0", "f1", "f2"]
        let positions: [GraphPoint?] = [nil, point(0), point(10), point(20), point(5), point(40)]
        func pick<T>(_ values: [T]) -> T { values[Int(rng.next() % UInt64(values.count))] }
        func position() -> GraphPoint? { rng.next() % 10 == 0 ? pick(nonFinite) : pick(positions) }
        let plausible = rng.next() % 4 != 0
        func pick(_ pool: [String], where wanted: (String) -> Bool) -> String {
            let narrowed = pool.filter(wanted)
            return plausible && !narrowed.isEmpty ? pick(narrowed) : pick(pool)
        }
        let present = Set(current.nodes.map(\.id.rawValue))
        let wired = Set(current.edges.map(\.id.rawValue))
        switch rng.next() % 20 {
        case 0..<5: return try .addNode(node(pick(nodes) { !present.contains($0) && !$0.hasPrefix("b") },
                                                 at: position()))
        case 5..<9: return try .moveNode(nodeID(pick(nodes) { present.contains($0) }), to: position())
        case 9..<11: return try .removeNode(nodeID(pick(nodes) { present.contains($0) }))
        case 11..<17:
            let id = try edgeID(pick(edges) { !wired.contains($0) })
            if rng.next() % 4 != 0, let original = base.edges.first(where: { $0.id == id }) {
                return .connect(original)
            }
            let (from, to) = (pick(nodes) { present.contains($0) }, pick(nodes) { present.contains($0) })
            return try .connect(edge(id.rawValue, from, to, map: rng.next() % 4 == 0 ? [[0]] : nil))
        default: return try .disconnect(edgeID(pick(edges) { wired.contains($0) }))
        }
    }

    static func randomGesture(
        _ rng: inout DraftHistorySeededGenerator, base: GraphDocument, current: GraphDocument
    ) throws -> [GraphEdit] {
        let count = rng.next() % 4 == 0 ? Int(rng.next() % 3) + 2 : 1
        var current = current
        var gesture: [GraphEdit] = []
        for _ in 0..<count {
            let edit = try randomEdit(&rng, base: base, current: current)
            current = (try? current.applying([edit])) ?? current
            gesture.append(edit)
        }
        return gesture
    }

    /// A base of `count` dangling edges g0, g1, … between two absent nodes.
    static func wideBase(edges count: Int) throws -> GraphDocument {
        try GraphDocument(id: GraphID("g"), revision: ContractRevision(3),
                          edges: (0..<count).map { try edge("g\($0)", "x", "y") })
    }

    /// Disconnects base edges g`start`, g`start + 1`, … in base order (cheap to apply).
    static func disconnects(_ count: Int, from start: Int = 0) throws -> [GraphEdit] {
        try (start..<start + count).map { try .disconnect(edgeID("g\($0)")) }
    }

    /// `count` dangling connects f0, f1, … between two absent nodes.
    static func connects(_ count: Int, from start: Int = 0) throws -> [GraphEdit] {
        try (start..<start + count).map { try .connect(edge("f\($0)", "x", "y")) }
    }
}

@Suite("Draft edit fold")
struct DraftHistoryTests {
    typealias Fixture = DraftHistoryFixture

    @Test func addMoveMoveRemoveFoldsToEmpty() throws {
        let base = try Fixture.base()
        let nodeD0 = try Fixture.nodeID("d0")
        let gestures: [[GraphEdit]] = try [
            [.addNode(Fixture.node("d0", at: Fixture.point(1)))],
            [.moveNode(nodeD0, to: Fixture.point(2))], [.moveNode(nodeD0, to: nil)], [.removeNode(nodeD0)]
        ]
        #expect(try Fixture.fold(gestures, base: base).isEmpty)
        #expect(try DraftEditFold.fold(gestures.flatMap { $0 }, onto: [], base: base).isEmpty)
    }

    @Test func secondMoveReplacesFirstInPlace() throws {
        let base = try Fixture.base()
        let (nodeB0, nodeB1) = try (Fixture.nodeID("b0"), Fixture.nodeID("b1"))
        let edits = try Fixture.fold([
            [.moveNode(nodeB0, to: Fixture.point(5))], [.moveNode(nodeB1, to: nil)],
            [.moveNode(nodeB0, to: Fixture.point(7))]
        ], base: base)
        #expect(edits == [.moveNode(nodeB0, to: Fixture.point(7)), .moveNode(nodeB1, to: nil)])
    }

    @Test func moveBackToBasePositionDropsTheMove() throws {
        let base = try Fixture.base()
        let nodeB1 = try Fixture.nodeID("b1")
        let edits = try Fixture.fold(
            [[.moveNode(nodeB1, to: Fixture.point(5))], [.moveNode(nodeB1, to: Fixture.point(10))]], base: base
        )
        #expect(edits.isEmpty)
        #expect(try DraftEditFold.fold([.moveNode(nodeB1, to: Fixture.point(10))], onto: [], base: base).isEmpty)
    }

    @Test func movingADraftAddedNodeRewritesItsAdd() throws {
        let base = try Fixture.base()
        let nodeD0 = try Fixture.nodeID("d0")
        let added = try Fixture.fold([[.addNode(Fixture.node("d0", at: Fixture.point(1)))],
                                      [.addNode(Fixture.node("d1"))]], base: base)
        let moved = try DraftEditFold.fold([.moveNode(nodeD0, to: Fixture.point(9))], onto: added, base: base)
        #expect(moved == [try .addNode(Fixture.node("d0", at: Fixture.point(9))), try .addNode(Fixture.node("d1"))])
        let unplaced = try DraftEditFold.fold([.moveNode(nodeD0, to: nil)], onto: moved, base: base)
        #expect(unplaced == [try .addNode(Fixture.node("d0")), try .addNode(Fixture.node("d1"))])
    }

    @Test func removingADraftAddedNodeDropsItsAddMovesAndConnects() throws {
        let base = try Fixture.base()
        let nodeD0 = try Fixture.nodeID("d0")
        let edits = try Fixture.fold([
            [.addNode(Fixture.node("d0")), .addNode(Fixture.node("d1"))],
            [.connect(Fixture.edge("f0", "d0", "b0"))], [.connect(Fixture.edge("f1", "d1", "d0"))],
            [.connect(Fixture.edge("f2", "b1", "b3"))], [.moveNode(nodeD0, to: Fixture.point(3))], [.removeNode(nodeD0)]
        ], base: base)
        #expect(edits == [try .addNode(Fixture.node("d1")), try .connect(Fixture.edge("f2", "b1", "b3"))])
    }

    @Test func removingABaseNodeDropsItsMoveAndDraftConnectsAndRecordsTheRemoval() throws {
        let base = try Fixture.base()
        let nodeB1 = try Fixture.nodeID("b1")
        let edgeE2 = try Fixture.edgeID("e2")
        let edits = try Fixture.fold([
            [.moveNode(nodeB1, to: Fixture.point(4))], [.connect(Fixture.edge("f0", "b1", "b3"))],
            [.connect(Fixture.edge("f1", "b0", "b3"))], [.disconnect(edgeE2)], [.removeNode(nodeB1)]
        ], base: base)
        #expect(edits == [try .connect(Fixture.edge("f1", "b0", "b3")), .disconnect(edgeE2), .removeNode(nodeB1)])
        let applied = try base.applying(edits)
        #expect(applied.edges.map(\.id.rawValue) == ["f1"])
        #expect(applied.nodes.map(\.id.rawValue) == ["b0", "b2", "b3"])
    }

    @Test func disconnectingADraftAddedEdgeDropsItsConnect() throws {
        let base = try Fixture.base()
        let edits = try Fixture.fold([
            [.connect(Fixture.edge("f0", "b0", "b2"))], [.connect(Fixture.edge("f1", "b0", "b3"))],
            [.disconnect(Fixture.edgeID("f0"))]
        ], base: base)
        #expect(edits == [try .connect(Fixture.edge("f1", "b0", "b3"))])
    }

    @Test func disconnectThenIdenticalReconnectFoldsToEmpty() throws {
        let base = try Fixture.base()
        let edgeE1 = try Fixture.edgeID("e1")
        let gestures: [[GraphEdit]] = [[.disconnect(edgeE1)], [.connect(base.edges[1])]]
        #expect(try Fixture.fold(gestures, base: base).isEmpty)
        #expect(try DraftEditFold.fold([.disconnect(edgeE1), .connect(base.edges[1])], onto: [], base: base).isEmpty)
    }

    @Test(arguments: [(("b0", "b3"), nil), (("b1", "b3"), nil), (("b0", "b2"), nil), (("b1", "b2"), [[1], [0]])] as
          [((String, String), [[Int]]?)])
    func reconnectingABaseEdgeWithAnotherValueIsRefused(ends: (String, String), map: [[Int]]?) throws {
        let base = try Fixture.base()
        let edgeE1 = try Fixture.edgeID("e1")
        let edits = try Fixture.fold([[.disconnect(edgeE1)]], base: base)
        #expect(throws: DraftHistoryRefusal.edgeIDReuse(edgeE1)) {
            try DraftEditFold.fold([.connect(Fixture.edge("e1", ends.0, ends.1, map: map))], onto: edits, base: base)
        }
    }

    @Test func reusingTheIDOfABaseEdgeRemovedWithItsNodeIsRefused() throws {
        let base = try Fixture.base()
        let (nodeB3, edgeE2) = try (Fixture.nodeID("b3"), Fixture.edgeID("e2"))
        let edits = try Fixture.fold([[.removeNode(nodeB3)]], base: base)
        #expect(throws: DraftHistoryRefusal.edgeIDReuse(edgeE2)) {
            try DraftEditFold.fold([.connect(Fixture.edge("e2", "b0", "b1"))], onto: edits, base: base)
        }
        #expect(throws: DraftHistoryRefusal.endpointRemoved(edge: edgeE2, node: nodeB3)) {
            try DraftEditFold.fold([.connect(base.edges[2])], onto: edits, base: base)
        }
    }

    @Test func connectingToARemovedBaseNodeIsRefused() throws {
        let base = try Fixture.base()
        let (nodeB2, edgeF0) = try (Fixture.nodeID("b2"), Fixture.edgeID("f0"))
        let edits = try Fixture.fold([[.removeNode(nodeB2)]], base: base)
        #expect(throws: DraftHistoryRefusal.endpointRemoved(edge: edgeF0, node: nodeB2)) {
            try DraftEditFold.fold([.connect(Fixture.edge("f0", "b0", "b2"))], onto: edits, base: base)
        }
        #expect(throws: DraftHistoryRefusal.endpointRemoved(edge: edgeF0, node: nodeB2)) {
            try DraftEditFold.fold([.connect(Fixture.edge("f0", "b2", "b0"))], onto: edits, base: base)
        }
    }

    @Test func addingARemovedBaseNodeAgainIsRefused() throws {
        let base = try Fixture.base()
        let nodeB2 = try Fixture.nodeID("b2")
        let edits = try Fixture.fold([[.removeNode(nodeB2)]], base: base)
        #expect(throws: DraftHistoryRefusal.nodeIDReuse(nodeB2)) {
            try DraftEditFold.fold([.addNode(Fixture.node("b2", at: Fixture.point(20)))], onto: edits, base: base)
        }
    }

    @Test func removingADraftNodeDisconnectsBaseEdgesThatDangledOntoIt() throws {
        let base = try Fixture.base(extraEdges: [Fixture.edge("e9", "b0", "d0"), Fixture.edge("e8", "d0", "b3")])
        let nodeD0 = try Fixture.nodeID("d0")
        let gestures: [[GraphEdit]] = try [[.addNode(Fixture.node("d0"))], [.removeNode(nodeD0)]]
        let edits = try Fixture.fold(gestures, base: base)
        #expect(edits == [try .disconnect(Fixture.edgeID("e8")), try .disconnect(Fixture.edgeID("e9"))])
        let sequential = try #require(Fixture.sequential(gestures.flatMap { $0 }, on: base))
        #expect(Fixture.canonical(try base.applying(edits)) == Fixture.canonical(sequential))
    }

    @Test func editsThatDoNotApplyAreRefusedWithTheirIndex() throws {
        let base = try Fixture.base()
        let (nodeB0, ghost, edgeE0, gone) = try (Fixture.nodeID("b0"), Fixture.nodeID("ghost"), Fixture.edgeID("e0"),
                                         Fixture.edgeID("gone"))
        let valid = GraphEdit.moveNode(nodeB0, to: nil)
        let cases: [(GraphEdit, GraphEditError)] = try [
            (.addNode(Fixture.node("b1")), .nodeExists(Fixture.nodeID("b1"))), (.moveNode(ghost, to: nil),
            .missingNode(ghost)), (.removeNode(ghost), .missingNode(ghost)), (.connect(base.edges[0]),
            .edgeExists(edgeE0)), (.disconnect(gone), .missingEdge(gone))
        ]
        for (edit, error) in cases {
            #expect(throws: DraftHistoryRefusal.edit(index: 1, error)) {
                try DraftEditFold.fold([valid, edit], onto: [], base: base)
            }
        }
    }

    @Test func aDraftThatDoesNotApplyIsRefused() throws {
        let base = try Fixture.base()
        let ghost = try Fixture.nodeID("ghost")
        #expect(throws: DraftHistoryRefusal.invalidDraft(.missingNode(ghost))) {
            try DraftEditFold.fold([], onto: [.removeNode(ghost)], base: base)
        }
    }

    @Test func aBaseWithDuplicateIDsIsRefused() throws {
        var nodes = try Fixture.base()
        nodes.nodes.append(nodes.nodes[0])
        #expect(throws: DraftHistoryRefusal.duplicateBaseNode(try Fixture.nodeID("b0"))) {
            try DraftEditFold.fold([], onto: [], base: nodes)
        }
        let edges = try Fixture.base(extraEdges: [Fixture.edge("e1", "b0", "b3")])
        #expect(throws: DraftHistoryRefusal.duplicateBaseEdge(try Fixture.edgeID("e1"))) {
            try DraftEditFold.fold([], onto: [], base: edges)
        }
    }

    @Test func gesturesAreBoundedByTheEditLimit() throws {
        let limit = ProjectGraphLimits.edits
        let base = try Fixture.wideBase(edges: limit + 1)
        let full = try DraftEditFold.fold(Fixture.disconnects(limit), onto: [], base: base)
        #expect(full.count == limit)
        #expect(throws: DraftHistoryRefusal.bounds(.exceeded(path: "$.gesture", maximum: limit))) {
            try DraftEditFold.fold(Fixture.disconnects(limit + 1), onto: [], base: base)
        }
        #expect(throws: DraftHistoryRefusal.bounds(.exceeded(path: "$.edits", maximum: limit))) {
            try DraftEditFold.fold(Fixture.disconnects(1, from: limit), onto: full, base: base)
        }
    }

    @Test func candidateNodesAndEdgesAreBoundedAfterEveryEdit() throws {
        var base = try Fixture.base()
        base.edges = []
        base.nodes += try (4..<ProjectGraphLimits.nodes - 1).map { try Fixture.node("b\($0)") }
        let (nodeD0, nodeD1) = try (Fixture.node("d0"), Fixture.node("d1"))
        #expect(try DraftEditFold.fold([.addNode(nodeD0)], onto: [], base: base).count == 1)
        let nodes = DraftHistoryRefusal.bounds(.exceeded(path: "$.nodes", maximum: ProjectGraphLimits.nodes))
        #expect(throws: nodes) { try DraftEditFold.fold([.addNode(nodeD0), .addNode(nodeD1), .removeNode(nodeD1.id)],
                                                        onto: [], base: base) }
        base.nodes = []
        base.edges = try (0..<ProjectGraphLimits.edges - 1).map { try Fixture.edge("g\($0)", "x", "y") }
        let one = try DraftEditFold.fold(Fixture.connects(1), onto: [], base: base)
        #expect(one.count == 1)
        let edges = DraftHistoryRefusal.bounds(.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges))
        #expect(throws: edges) {
            try DraftEditFold.fold(Fixture.connects(2) + [.disconnect(Fixture.edgeID("f1"))], onto: [], base: base)
        }
    }

    /// `applying` an added node over a per-node limit fails, so the fold refuses it when it is added, before a
    /// later remove in the gesture can normalize it away. A node exactly at the limit is accepted. A node over
    /// both limits reports its ports first, as `applying` does.
    @Test(arguments: ["ports", "capabilities", "both"])
    func addedNodesAreBoundedByThePerNodeLimitsEvenWhenRemovedInTheGesture(kind: String) throws {
        let base = try Fixture.base()
        let reported = kind == "capabilities" ? kind : "ports"
        let limit = reported == "ports" ? ProjectGraphLimits.portsPerNode : ProjectGraphLimits.capabilities
        func node(_ excess: Int) throws -> GraphNode {
            var node = try Fixture.node("d0")
            if kind != "capabilities" {
                node.ports = Array(repeating: node.ports[0], count: ProjectGraphLimits.portsPerNode + excess)
            }
            guard kind != "ports" else { return node }
            // Required and advisory capabilities count together; neither half alone is over the limit.
            let count = ProjectGraphLimits.capabilities + excess
            node.requiredCapabilities = Array(repeating: try CapabilityID("cap.one"), count: count - count / 2)
            node.advisoryCapabilities = Array(repeating: try CapabilityID("cap.two"), count: count / 2)
            return node
        }
        let (over, atLimit) = try (node(1), node(0))
        let exceeded = ProjectGraphLimitError.exceeded(path: "$.nodes[d0].\(reported)", maximum: limit)
        #expect(throws: GraphEditError.bounds(exceeded)) { try base.applying([.addNode(over)]) }
        var history = try DraftHistory.make(draft: DraftID("draft"), base: base, depth: 10)
        try history.apply([.moveNode(Fixture.nodeID("b0"), to: nil)], on: base)
        let before = history
        let (removeD0, moveB1) = try (GraphEdit.removeNode(over.id), GraphEdit.moveNode(Fixture.nodeID("b1"), to: nil))
        for gesture: [GraphEdit] in [[.addNode(over)], [.addNode(over), removeD0], [moveB1, .addNode(over), removeD0]] {
            #expect(throws: DraftHistoryRefusal.bounds(exceeded)) { try history.apply(gesture, on: base) }
            #expect(throws: DraftHistoryRefusal.bounds(exceeded)) {
                try DraftEditFold.fold(gesture, onto: before.draft.edits, base: base)
            }
        }
        #expect(history == before)
        #expect(try history.apply([.addNode(atLimit), removeD0], on: base) == .unchanged)
        #expect(try history.apply([.addNode(atLimit)], on: base) == .recorded)
        #expect(history.draft.edits == before.draft.edits + [.addNode(atLimit)])
    }

    @Test(arguments: DraftHistoryFixture.nonFinite)
    func nonFinitePositionsAreRefusedOnAddAndMove(position: GraphPoint) throws {
        let base = try Fixture.base()
        let (nodeB1, nodeD0) = try (Fixture.nodeID("b1"), Fixture.nodeID("d0"))
        let edits = try Fixture.fold([[.addNode(Fixture.node("d0", at: Fixture.point(1)))]], base: base)
        // `applying` takes the position; only `validate()` would refuse it, so the fold must.
        #expect((try? base.applying(edits + [.moveNode(nodeB1, to: position)])) != nil)
        #expect(throws: DraftHistoryRefusal.invalidPosition(nodeD0)) {
            try DraftEditFold.fold([.addNode(Fixture.node("d0", at: position))], onto: [], base: base)
        }
        for id in [nodeB1, nodeD0] {
            #expect(throws: DraftHistoryRefusal.invalidPosition(id)) {
                try DraftEditFold.fold([.moveNode(id, to: Fixture.point(3)), .moveNode(id, to: position)],
                                       onto: edits, base: base)
            }
        }
        #expect(DraftEditFold.isFinite(nil) && DraftEditFold.isFinite(Fixture.point(-1e308)))
        #expect(!DraftEditFold.isFinite(position))
    }

    /// Seeded random gestures: every accepted fold validates, applies, and equals
    /// applying the gesture edits one at a time; a gesture that cannot apply
    /// one edit at a time is always refused.
    @Test(arguments: [1, 2, 3, 5, 8, 13, 21, 34] as [UInt64])
    func randomGesturesFoldToTheSequentialGraph(seed: UInt64) throws {
        let base = try Fixture.base()
        var rng = DraftHistorySeededGenerator(state: seed)
        var edits: [GraphEdit] = []
        var sequential = base
        var accepted = 0, foldOnly = 0, shrank = 0, nonFinite = 0
        for _ in 0..<300 {
            let gesture = try Fixture.randomGesture(&rng, base: base, current: sequential)
            let expected = Fixture.sequential(gesture, on: sequential)
            do {
                let folded = try DraftEditFold.fold(gesture, onto: edits, base: base)
                try GraphEdit.validateBatch(folded)
                let applied = try base.applying(folded)
                let graph = try #require(expected, "fold accepted \(gesture) that does not apply in turn")
                #expect(Fixture.canonical(applied) == Fixture.canonical(graph))
                if folded.count < edits.count { shrank += 1 }
                edits = folded
                sequential = graph
                accepted += 1
            } catch let refusal as DraftHistoryRefusal {
                switch refusal {
                case .invalidPosition: nonFinite += 1
                case .edgeIDReuse, .nodeIDReuse, .endpointRemoved: foldOnly += expected == nil ? 0 : 1
                default: #expect(expected == nil, "refused \(gesture) with \(refusal)")
                }
            }
        }
        // Coverage floor: the seeds accept many gestures, shrink the list and hit fold-only refusals.
        #expect(accepted > 100)
        #expect(shrank > 20)
        #expect(foldOnly > 0)
        #expect(nonFinite > 0)
    }
}
