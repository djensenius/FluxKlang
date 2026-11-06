//
//  DraftHistory.swift
//  FluxKlang
//
//  A bounded undo/redo history of one draft's folded edit list, bound to the
//  base graph revision the draft edits. Keyboard bindings, persistence and
//  checkpoints belong to other owners (#101, #62); this is the model only.
//

/// How many undo steps a draft history keeps; the caller chooses it in 1…1000.
struct DraftHistoryDepth: Hashable, Sendable {
    static let range = 1...1_000

    let value: Int

    private init(validated value: Int) {
        self.value = value
    }

    static func make(_ value: Int) throws(DraftHistoryRefusal) -> DraftHistoryDepth {
        guard range.contains(value) else { throw .depthOutOfRange(value) }
        return DraftHistoryDepth(validated: value)
    }
}

/// What a gesture did to the draft.
enum DraftGestureOutcome: Hashable, Sendable {
    /// The folded edit list changed; one undo entry was recorded and redo cleared.
    case recorded
    /// The folded edit list is unchanged; no undo entry was recorded.
    case unchanged
}

/// The folded edits of one draft with bounded undo and redo. One gesture is
/// one undo entry; when the history is full the oldest entry is dropped.
///
/// The history is bound to the base it was created on: its graph ID, its
/// revision, and its nodes and edges, compared by value equality (`==`, so
/// Double fields compare numerically: -0.0 equals +0.0; this is not a byte
/// comparison). The document label, `requiresReview`, capabilities, required
/// features and extensions are not compared, because the fold does not read
/// them. Any other base is refused and the history is never replayed onto it.
/// A base with a NaN or infinite position, `linearGain` or `gainCeilingDb`, or with one
/// nested in a node's or edge's extension bags or unknown members, is refused at creation.
/// A NaN never equals itself (in `JSONValue` too) and would lock the history; ±∞ is refused
/// because `JSONValue` cannot encode a non-finite number (encoding throws), and for
/// consistency with the position and gain rules.
///
/// Drafts are equal by their folded edit lists, not by the graphs they produce:
/// base edges keep their original slot, so edge order can differ from applying
/// the gestures one at a time. Checkpoints and saves (#62) must compare drafts
/// by content, not by bytes. Draft-added node and edge IDs can be reused after
/// their add or connect folds away, so ID-keyed selection (#101) can name a
/// different item after undo or redo.
struct DraftHistory: Hashable, Sendable {
    /// The current draft. Its edits always pass `GraphEdit.validateBatch` and
    /// apply to the base graph it is bound to.
    private(set) var draft: DraftEdits
    let depth: DraftHistoryDepth
    /// Earlier drafts, oldest first; at most `depth.value`.
    private var undoStack: [DraftEdits]
    /// Undone drafts, the next redo last. Undo and redo together hold at most `depth.value`.
    private var redoStack: [DraftEdits]
    /// The bound base's nodes and edges. Value equality on them (rather than a digest) has no collisions
    /// and costs nothing when the caller passes the same base value, which shares storage with these copies.
    private let baseNodes: [GraphNode]
    private let baseEdges: [GraphEdge]

    private init(draft: DraftEdits, depth: DraftHistoryDepth, base: GraphDocument) {
        self.draft = draft
        self.depth = depth
        baseNodes = base.nodes
        baseEdges = base.edges
        undoStack = []
        redoStack = []
    }

    /// An empty draft on `base` with an injected history depth in 1…1000.
    static func make(
        draft id: DraftID, base: GraphDocument, depth: Int
    ) throws(DraftHistoryRefusal) -> DraftHistory {
        let depth = try DraftHistoryDepth.make(depth)
        _ = try DraftEditFold.fold([], onto: [], base: base)
        // A NaN position never equals itself, so such a base could not be recognised again.
        for node in base.nodes where !DraftEditFold.isFinite(node.position) { throw .invalidPosition(node.id) }
        for node in base.nodes where !DraftEditFold.isFiniteValue(node.linearGain) {
            throw .nonFiniteNodeValue(node.id)
        }
        for edge in base.edges where !DraftEditFold.isFiniteValue(edge.feedback?.gainCeilingDb) {
            throw .nonFiniteEdgeValue(edge.id)
        }
        // `JSONValue` equality never matches a NaN with itself either, so extension bags are scanned too.
        for node in base.nodes {
            if let path = DraftEditFold.nonFiniteNumber(in: node) {
                throw .nonFiniteNodeExtension(node.id, path: "$.nodes[\(node.id)]" + path)
            }
        }
        for edge in base.edges {
            if let path = DraftEditFold.nonFiniteNumber(in: edge) {
                throw .nonFiniteEdgeExtension(edge.id, path: "$.edges[\(edge.id)]" + path)
            }
        }
        let draft = DraftEdits(id: id, graph: base.id, baseRevision: base.revision, edits: [])
        return DraftHistory(draft: draft, depth: depth, base: base)
    }

    var undoCount: Int { undoStack.count }
    var redoCount: Int { redoStack.count }

    /// Folds one gesture into the draft. A changed edit list records one undo
    /// entry and clears redo; an unchanged list records nothing.
    @discardableResult
    mutating func apply(
        _ gesture: [GraphEdit], on base: GraphDocument
    ) throws(DraftHistoryRefusal) -> DraftGestureOutcome {
        try checkBound(to: base)
        let folded = try DraftEditFold.fold(gesture, onto: draft.edits, base: base)
        guard folded != draft.edits else { return .unchanged }
        undoStack.append(draft)
        if undoStack.count > depth.value {
            undoStack.removeFirst(undoStack.count - depth.value)
        }
        redoStack.removeAll()
        draft.edits = folded
        return .recorded
    }

    /// Restores the draft before the latest recorded gesture.
    mutating func undo(on base: GraphDocument) throws(DraftHistoryRefusal) {
        try checkBound(to: base)
        guard let previous = undoStack.popLast() else { throw .nothingToUndo }
        redoStack.append(draft)
        draft = previous
    }

    /// Restores the draft the latest undo replaced.
    mutating func redo(on base: GraphDocument) throws(DraftHistoryRefusal) {
        try checkBound(to: base)
        guard let next = redoStack.popLast() else { throw .nothingToRedo }
        undoStack.append(draft)
        draft = next
    }

    private func checkBound(to base: GraphDocument) throws(DraftHistoryRefusal) {
        guard base.id == draft.graph else { throw .graphMismatch(expected: draft.graph, found: base.id) }
        guard base.revision == draft.baseRevision else {
            throw .baseMismatch(expected: draft.baseRevision, found: base.revision)
        }
        guard base.nodes == baseNodes, base.edges == baseEdges else { throw .baseContentMismatch(base.revision) }
    }
}
