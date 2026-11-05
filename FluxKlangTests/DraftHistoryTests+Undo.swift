import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Draft undo and redo")
struct DraftUndoTests {
    typealias Fixture = DraftHistoryFixture

    static func history(depth: Int = 10, base: GraphDocument? = nil) throws -> DraftHistory {
        try DraftHistory.make(draft: DraftID("draft"), base: base ?? Fixture.base(), depth: depth)
    }

    /// Moves b0 to x = 100 + step.
    static func move(_ step: Int) throws -> [GraphEdit] {
        [.moveNode(try Fixture.nodeID("b0"), to: Fixture.point(Double(100 + step)))]
    }

    @Test(arguments: [(0, false), (1, true), (1_000, true), (1_001, false), (-1, false)])
    func depthIsValidatedInOneToOneThousand(depth: Int, valid: Bool) throws {
        if valid {
            let history = try Self.history(depth: depth)
            #expect(history.depth.value == depth)
            #expect(history.draft.edits.isEmpty && history.undoCount == 0 && history.redoCount == 0)
        } else {
            #expect(throws: DraftHistoryRefusal.depthOutOfRange(depth)) { try Self.history(depth: depth) }
        }
    }

    @Test func aNewHistoryIsBoundToItsBase() throws {
        let base = try Fixture.base()
        let history = try Self.history(base: base)
        #expect(history.draft == DraftEdits(id: try DraftID("draft"), graph: base.id, baseRevision: base.revision,
                                            edits: []))
        var duplicate = base
        duplicate.nodes.append(base.nodes[1])
        #expect(throws: DraftHistoryRefusal.duplicateBaseNode(base.nodes[1].id)) {
            try Self.history(base: duplicate)
        }
        for position in Fixture.nonFinite {
            var unplaceable = base
            unplaceable.nodes[2].position = position
            #expect(throws: DraftHistoryRefusal.invalidPosition(base.nodes[2].id)) {
                try Self.history(base: unplaceable)
            }
        }
    }

    @Test func aFullHistoryEvictsTheOldestEntriesInOrder() throws {
        let base = try Fixture.base()
        let depth = 3
        var history = try Self.history(depth: depth, base: base)
        var drafts = [history.draft]
        for step in 0..<depth {
            try history.apply(Self.move(step), on: base)
            drafts.append(history.draft)
        }
        // Unchanged gestures neither evict (when full) nor clear redo (when redo is pending).
        let full = history
        #expect(try history.apply(Self.move(depth - 1), on: base) == .unchanged)
        #expect(history == full)
        try history.undo(on: base)
        #expect(try history.apply(Self.move(depth - 2), on: base) == .unchanged)
        #expect(history.undoCount == depth - 1 && history.redoCount == 1)
        try history.redo(on: base)
        #expect(history == full)
        // Five more gestures evict drafts[0…4] oldest first; drafts[5…7] stay undoable, newest first.
        for step in depth..<depth + 5 {
            try history.apply(Self.move(step), on: base)
            drafts.append(history.draft)
            #expect(history.undoCount == depth && history.redoCount == 0)
        }
        for back in 1...depth {
            try history.undo(on: base)
            #expect(history.draft == drafts[drafts.count - 1 - back])
        }
        #expect(throws: DraftHistoryRefusal.nothingToUndo) { try history.undo(on: base) }
        #expect(drafts.count == 9 && history.draft == drafts[5])
    }

    @Test func nonFiniteGesturesAreRefusedAndRecordNothing() throws {
        let base = try Fixture.base()
        var history = try Self.history(base: base)
        try history.apply(Self.move(1), on: base)
        try history.apply([.addNode(Fixture.node("d0"))], on: base)
        try history.undo(on: base)
        let before = history
        for position in Fixture.nonFinite {
            let (nodeB0, nodeD1) = try (Fixture.nodeID("b0"), Fixture.node("d1", at: position))
            let gestures = [([GraphEdit.moveNode(nodeB0, to: position)], nodeB0), ([.addNode(nodeD1)], nodeD1.id)]
            for (gesture, id) in gestures {
                for _ in 0..<2 {
                    #expect(throws: DraftHistoryRefusal.invalidPosition(id)) { try history.apply(gesture, on: base) }
                }
            }
        }
        #expect(history == before)
        try history.redo(on: base)
        #expect(history.draft.edits == (try Self.move(1) + [.addNode(Fixture.node("d0"))]))
    }

    @Test(arguments: [1, 2, 3, 7])
    func aFullHistoryKeepsTheNewestEntries(depth: Int) throws {
        let base = try Fixture.base()
        var history = try Self.history(depth: depth, base: base)
        var drafts = [history.draft]
        for step in 0..<depth + 2 {
            #expect(try history.apply(Self.move(step), on: base) == .recorded)
            drafts.append(history.draft)
            #expect(history.undoCount == min(step + 1, depth))
        }
        for back in 1...depth {
            try history.undo(on: base)
            #expect(history.draft == drafts[drafts.count - 1 - back])
        }
        let oldest = history
        #expect(throws: DraftHistoryRefusal.nothingToUndo) { try history.undo(on: base) }
        #expect(history == oldest)
        #expect(history.redoCount == depth)
    }

    @Test func theDeepestHistoryKeepsOneThousandEntries() throws {
        let base = try Fixture.base()
        var history = try Self.history(depth: 1_000, base: base)
        for step in 0...1_000 { try history.apply(Self.move(step), on: base) }
        #expect(history.undoCount == 1_000)
        for _ in 0..<1_000 { try history.undo(on: base) }
        #expect(history.draft.edits == (try Self.move(0)))
        #expect(throws: DraftHistoryRefusal.nothingToUndo) { try history.undo(on: base) }
    }

    @Test func undoThenRedoRestoresTheExactDraft() throws {
        let base = try Fixture.base()
        var history = try Self.history(base: base)
        try history.apply([.addNode(Fixture.node("d0", at: Fixture.point(1)))], on: base)
        try history.apply([.connect(Fixture.edge("f0", "d0", "b1")), .disconnect(Fixture.edgeID("e0"))], on: base)
        try history.apply(Self.move(1), on: base)
        let latest = history
        try history.undo(on: base)
        try history.undo(on: base)
        #expect(history.draft.edits == [try .addNode(Fixture.node("d0", at: Fixture.point(1)))])
        try history.redo(on: base)
        try history.redo(on: base)
        #expect(history == latest)
        #expect(throws: DraftHistoryRefusal.nothingToRedo) { try history.redo(on: base) }
        #expect(history == latest)
    }

    @Test func aNewEditClearsRedo() throws {
        let base = try Fixture.base()
        var history = try Self.history(base: base)
        try history.apply(Self.move(1), on: base)
        try history.apply(Self.move(2), on: base)
        try history.undo(on: base)
        #expect(history.redoCount == 1)
        try history.apply([.removeNode(Fixture.nodeID("b3"))], on: base)
        let edited = history
        #expect(history.redoCount == 0)
        #expect(throws: DraftHistoryRefusal.nothingToRedo) { try history.redo(on: base) }
        #expect(history == edited)
        #expect(history.draft.edits == (try Self.move(1) + [.removeNode(Fixture.nodeID("b3"))]))
        try history.undo(on: base)
        #expect(history.draft.edits == (try Self.move(1)))
    }

    @Test func aNoOpGestureRecordsNothingAndKeepsRedo() throws {
        let base = try Fixture.base()
        var history = try Self.history(base: base)
        try history.apply(Self.move(1), on: base)
        try history.apply(Self.move(2), on: base)
        try history.undo(on: base)
        let before = history
        let edgeE0 = try Fixture.edgeID("e0")
        let noOps: [[GraphEdit]] = try [
            [], Self.move(1), [.moveNode(Fixture.nodeID("b1"), to: Fixture.point(10))],
            [.disconnect(edgeE0), .connect(base.edges[0])],
            [.addNode(Fixture.node("d0")), .removeNode(Fixture.nodeID("d0"))]
        ]
        for gesture in noOps {
            #expect(try history.apply(gesture, on: base) == .unchanged)
            #expect(history == before)
        }
        try history.redo(on: base)
        #expect(history.draft.edits == (try Self.move(2)))
    }

    @Test func anotherBaseIsRefusedAndLeavesHistoryUnchanged() throws {
        let base = try Fixture.base()
        var history = try Self.history(base: base)
        try history.apply(Self.move(1), on: base)
        try history.apply(Self.move(2), on: base)
        try history.undo(on: base)
        let before = history
        var newer = base
        newer.revision = try base.revision.next()
        var other = base
        other.id = try GraphID("other")
        let revision = DraftHistoryRefusal.baseMismatch(expected: base.revision, found: newer.revision)
        let graph = DraftHistoryRefusal.graphMismatch(expected: base.id, found: other.id)
        for (candidate, refusal) in [(newer, revision), (other, graph)] {
            #expect(throws: refusal) { try history.apply(Self.move(3), on: candidate) }
            #expect(throws: refusal) { try history.apply([], on: candidate) }
            #expect(throws: refusal) { try history.undo(on: candidate) }
            #expect(throws: refusal) { try history.redo(on: candidate) }
            #expect(history == before)
        }
    }

    /// The reviewer's probe: the bound graph ID and revision with other content is another base.
    @Test func aBaseWithTheSameRevisionButOtherContentIsRefused() throws {
        let base = try Fixture.base()
        var history = try Self.history(base: base)
        try history.apply(Self.move(1), on: base)
        try history.apply(Self.move(2), on: base)
        try history.undo(on: base)
        let before = history
        var extraNode = base, movedNode = base, extraEdge = base, fewerEdges = base
        extraNode.nodes.append(try Fixture.node("x9"))
        movedNode.nodes[3].position = Fixture.point(31)
        extraEdge.edges.append(try Fixture.edge("e9", "b0", "b3"))
        fewerEdges.edges.removeLast()
        let refusal = DraftHistoryRefusal.baseContentMismatch(base.revision)
        for candidate in [extraNode, movedNode, extraEdge, fewerEdges] {
            #expect(throws: refusal) { try history.apply(Self.move(3), on: candidate) }
            #expect(throws: refusal) { try history.apply([], on: candidate) }
            #expect(throws: refusal) { try history.undo(on: candidate) }
            #expect(throws: refusal) { try history.redo(on: candidate) }
            #expect(history == before)
        }
        // An equal base built separately (no shared storage) is the same base.
        try history.redo(on: Fixture.base())
        #expect(history.draft.edits == (try Self.move(2)))
    }

    /// A NaN never equals itself, so a base holding one could never be matched again; it is refused at creation.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func aBaseWithANonFiniteValueIsRefusedAtCreation(bad: Double) throws {
        let base = try Fixture.base()
        var gain = base
        gain.nodes[1] = try GraphNode(id: Fixture.nodeID("b1"), kind: .audioGain, label: "b1", linearGain: bad)
        #expect(throws: DraftHistoryRefusal.nonFiniteNodeValue(base.nodes[1].id)) { try Self.history(base: gain) }
        var ceiling = base
        ceiling.edges[2].feedback = EdgeFeedback(gainCeilingDb: bad)
        #expect(throws: DraftHistoryRefusal.nonFiniteEdgeValue(base.edges[2].id)) { try Self.history(base: ceiling) }
        var finite = base
        finite.nodes[1] = try GraphNode(id: Fixture.nodeID("b1"), kind: .audioGain, label: "b1", linearGain: 0.5)
        finite.edges[2].feedback = EdgeFeedback(gainCeilingDb: -6)
        finite.nodes[0].extensions = ["k": .double(bad.isNaN ? 1 : bad)]
        _ = try Self.history(base: finite)
    }

    /// A gesture that would leave a non-finite gain is refused before anything changes; finite gestures still record.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteGainsInAGestureAreRefusedWithStateUnchanged(bad: Double) throws {
        let base = try Fixture.base()
        var history = try Self.history(base: base)
        try history.apply(Self.move(1), on: base)
        try history.apply(Self.move(2), on: base)
        try history.undo(on: base)
        let before = history
        let gain = try GraphNode(id: Fixture.nodeID("d0"), kind: .audioGain, label: "d0", linearGain: bad)
        var feedback = try Fixture.edge("f0", "b3", "b0")
        feedback.feedback = EdgeFeedback(gainCeilingDb: bad)
        let refusals: [([GraphEdit], DraftHistoryRefusal)] = try [
            ([.addNode(gain)], .nonFiniteNodeValue(gain.id)),
            ([.connect(feedback)], .nonFiniteEdgeValue(feedback.id)),
            (Self.move(3) + [.addNode(Fixture.node("d1")), .addNode(gain)], .nonFiniteNodeValue(gain.id)),
            (Self.move(3) + [.connect(feedback)], .nonFiniteEdgeValue(feedback.id))
        ]
        for (gesture, refusal) in refusals {
            #expect(throws: refusal) { try history.apply(gesture, on: base) }
            #expect(throws: refusal) { try DraftEditFold.fold(gesture, onto: history.draft.edits, base: base) }
            #expect(history == before)
        }
        var finiteGain = gain
        finiteGain.linearGain = 0.5
        feedback.feedback = EdgeFeedback(gainCeilingDb: -6)
        #expect(try history.apply([.addNode(finiteGain), .connect(feedback)], on: base) == .recorded)
        #expect(history.undoCount == 2 && history.redoCount == 0)
        #expect(history.draft.edits == (try Self.move(1) + [.addNode(finiteGain), .connect(feedback)]))
        #expect(try history.apply([], on: base) == .unchanged)
        try history.undo(on: base)
        #expect(history.draft.edits == (try Self.move(1)))
    }

    /// `JSONValue` compares a NaN equal to itself, so a NaN in an extension bag does not lock the history.
    @Test func aNaNInAnExtensionBagDoesNotLockTheHistory() throws {
        var base = try Fixture.base()
        base.nodes[3].extensions = ["k": .array([.double(.nan)])]
        base.edges[0].extensions = ["k": .double(.nan)]
        var history = try Self.history(base: base)
        try history.apply(Self.move(1), on: base)
        try history.undo(on: base)
        try history.redo(on: base)
        #expect(history.draft.edits == (try Self.move(1)))
    }

    /// Only nodes and edges bind the history; document fields the fold never reads may differ.
    @Test func aBaseThatDiffersOnlyOutsideNodesAndEdgesIsAccepted() throws {
        let base = try Fixture.base()
        var history = try Self.history(base: base)
        try history.apply(Self.move(1), on: base)
        try history.apply(Self.move(2), on: base)
        var relabelled = base
        relabelled.label = "renamed"
        relabelled.requiresReview.toggle()
        relabelled.extensions = ["note": .string("x")]
        var signedZero = base
        signedZero.nodes[0].position = GraphPoint(x: -0.0, y: 0)
        for candidate in [relabelled, signedZero] {
            try history.undo(on: candidate)
            try history.redo(on: candidate)
            #expect(try history.apply(Self.move(2), on: candidate) == .unchanged)
        }
        #expect(history.draft.edits == (try Self.move(2)))
        #expect(history.undoCount == 2)
    }

    @Test func aRefusedGestureLeavesHistoryUnchanged() throws {
        let base = try Fixture.base()
        var history = try Self.history(base: base)
        try history.apply([.disconnect(Fixture.edgeID("e1"))], on: base)
        try history.apply(Self.move(1), on: base)
        try history.undo(on: base)
        let before = history
        let edgeE1 = try Fixture.edgeID("e1")
        #expect(throws: DraftHistoryRefusal.edgeIDReuse(edgeE1)) {
            try history.apply([.addNode(Fixture.node("d0")), .connect(Fixture.edge("e1", "b0", "b3"))], on: base)
        }
        #expect(throws: DraftHistoryRefusal.edit(index: 0, .missingEdge(edgeE1))) {
            try history.apply([.disconnect(edgeE1)], on: base)
        }
        #expect(history == before)
        try history.redo(on: base)
        #expect(history.draft.edits == (try [.disconnect(edgeE1)] + Self.move(1)))
    }

    @Test func theFoldedEditListIsBoundedByTheEditLimit() throws {
        let limit = ProjectGraphLimits.edits
        let base = try Fixture.wideBase(edges: limit + 1)
        var history = try Self.history(base: base)
        try history.apply(Fixture.disconnects(limit - 1), on: base)
        try history.apply(Fixture.disconnects(1, from: limit - 1), on: base)
        #expect(history.draft.edits.count == limit)
        let full = history
        #expect(throws: DraftHistoryRefusal.bounds(.exceeded(path: "$.edits", maximum: limit))) {
            try history.apply(Fixture.disconnects(1, from: limit), on: base)
        }
        #expect(history == full)
        try history.apply([.connect(base.edges[0])], on: base)
        try history.apply(Fixture.disconnects(1, from: limit), on: base)
        #expect(history.draft.edits.count == limit)
        #expect(history.undoCount == 4)
    }

    /// Seeded random gestures, undos and redos against a reference stack model:
    /// the draft always validates and applies, and undo/redo restore exact drafts.
    @Test(arguments: [4, 9, 16, 25] as [UInt64])
    func randomUndoRedoMatchesAReferenceModel(seed: UInt64) throws {
        let base = try Fixture.base()
        let depth = 5
        var history = try Self.history(depth: depth, base: base)
        var rng = DraftHistorySeededGenerator(state: seed)
        var past: [DraftEdits] = [], future: [DraftEdits] = []
        var current = history.draft
        for _ in 0..<400 {
            let before = history
            switch rng.next() % 4 {
            case 0:
                do {
                    try history.undo(on: base)
                    future.append(current)
                    let previous = past.popLast()
                    current = try #require(previous)
                } catch { #expect(past.isEmpty && history == before) }
            case 1:
                do {
                    try history.redo(on: base)
                    past.append(current)
                    let next = future.popLast()
                    current = try #require(next)
                } catch { #expect(future.isEmpty && history == before) }
            default:
                let gesture = try Fixture.randomGesture(&rng, base: base, current: base.applying(current.edits))
                do {
                    if try history.apply(gesture, on: base) == .recorded {
                        #expect(history.draft != current)
                        past = Array((past + [current]).suffix(depth))
                        future = []
                        current = history.draft
                    } else {
                        #expect(history == before)
                    }
                } catch { #expect(history == before) }
            }
            #expect(history.draft == current)
            #expect(history.undoCount == past.count && history.redoCount == future.count)
            try GraphEdit.validateBatch(history.draft.edits)
            _ = try base.applying(history.draft.edits)
        }
    }
}
