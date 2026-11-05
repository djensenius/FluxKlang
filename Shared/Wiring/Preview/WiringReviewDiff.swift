//
//  WiringReviewDiff.swift
//  FluxKlang
//
//  The review diff between the active graph and `active.applying(draft.edits)`.
//  It compares the two graphs, not the edit list, so edit order never matters,
//  every change appears exactly once (edges removed with their node included),
//  and a draft-added node that was later moved is only "added", at its final
//  position. Rows are grouped by kind and sorted by ID within each group.
//

/// The kind of a review row, in heading order.
enum WiringReviewChangeKind: Int, Hashable, Sendable, Comparable, CaseIterable {
    case addedNode
    case movedNode
    case removedNode
    case addedEdge
    case removedEdge

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One review row.
enum WiringReviewChange: Hashable, Sendable {
    /// A node the draft adds, as it will be activated (final position).
    case addedNode(GraphNode)
    /// An active node the draft repositions (or unplaces).
    case movedNode(NodeID, from: GraphPoint?, to: GraphPoint?)
    /// An active node the draft removes.
    case removedNode(GraphNode)
    /// An edge the draft adds.
    case addedEdge(GraphEdge)
    /// An active edge the draft removes, directly or with one of its nodes.
    case removedEdge(GraphEdge)

    var kind: WiringReviewChangeKind {
        switch self {
        case .addedNode: .addedNode
        case .movedNode: .movedNode
        case .removedNode: .removedNode
        case .addedEdge: .addedEdge
        case .removedEdge: .removedEdge
        }
    }

    /// The raw node or edge ID the row is sorted by within its kind.
    var sortID: String {
        switch self {
        case .addedNode(let node), .removedNode(let node): node.id.rawValue
        case .movedNode(let id, _, _): id.rawValue
        case .addedEdge(let edge), .removedEdge(let edge): edge.id.rawValue
        }
    }
}

/// One heading of the review: every row of a kind, sorted by ID. Never empty.
struct WiringReviewGroup: Hashable, Sendable {
    private(set) var kind: WiringReviewChangeKind
    private(set) var changes: [WiringReviewChange]

    fileprivate init(kind: WiringReviewChangeKind, changes: [WiringReviewChange]) {
        self.kind = kind
        self.changes = changes
    }
}

/// The review diff of a draft. Its size is bounded by construction: both
/// graphs pass `ProjectGraphLimits` (enforced by `applying`), so there are at
/// most 2 × nodes + 2 × edges rows.
struct WiringReviewDiff: Hashable, Sendable {
    /// Groups in `WiringReviewChangeKind` order; kinds without changes are omitted.
    private(set) var groups: [WiringReviewGroup]

    private init(groups: [WiringReviewGroup]) {
        self.groups = groups
    }

    /// Every row, group by group.
    var changes: [WiringReviewChange] { groups.flatMap(\.changes) }

    var isEmpty: Bool { groups.isEmpty }

    /// Diffs `active` against `active.applying(draft.edits)`. The draft must name
    /// this graph and revision; it is never rebased.
    static func make(active: GraphDocument, draft: DraftEdits) throws(WiringPreviewRefusal) -> WiringReviewDiff {
        guard draft.graph == active.id else { throw .draftGraphMismatch(draft: draft.graph, active: active.id) }
        guard draft.baseRevision == active.revision else {
            throw .draftBaseMismatch(draft: draft.baseRevision, active: active.revision)
        }
        let before = try uniqueNodes(active)
        let beforeEdges = try uniqueEdges(active)
        let candidate: GraphDocument
        do {
            candidate = try active.applying(draft.edits)
        } catch {
            if case .bounds(let limit) = error { throw .bounds(limit) }
            throw .draftDoesNotApply(error)
        }
        let afterIDs = Set(candidate.nodes.map(\.id))
        let afterEdgeIDs = Set(candidate.edges.map(\.id))
        let moved = Set(draft.edits.compactMap { edit -> NodeID? in
            if case .moveNode(let id, _) = edit { return id }
            return nil
        })
        var changes: [WiringReviewChange] = []
        for node in candidate.nodes {
            guard let old = before[node.id] else {
                changes.append(.addedNode(node))
                continue
            }
            if moved.contains(node.id), old.position != node.position {
                changes.append(.movedNode(node.id, from: old.position, to: node.position))
            }
        }
        changes += active.nodes.filter { !afterIDs.contains($0.id) }.map(WiringReviewChange.removedNode)
        changes += candidate.edges.filter { beforeEdges[$0.id] == nil }.map(WiringReviewChange.addedEdge)
        changes += active.edges.filter { !afterEdgeIDs.contains($0.id) }.map(WiringReviewChange.removedEdge)
        return WiringReviewDiff(groups: grouped(changes))
    }

    private static func grouped(_ changes: [WiringReviewChange]) -> [WiringReviewGroup] {
        let byKind = Dictionary(grouping: changes, by: \.kind)
        return WiringReviewChangeKind.allCases.compactMap { kind in
            guard let rows = byKind[kind], !rows.isEmpty else { return nil }
            return WiringReviewGroup(kind: kind, changes: rows.sorted { $0.sortID < $1.sortID })
        }
    }

    private static func uniqueNodes(_ graph: GraphDocument) throws(WiringPreviewRefusal) -> [NodeID: GraphNode] {
        var nodes: [NodeID: GraphNode] = [:]
        for node in graph.nodes {
            guard nodes.updateValue(node, forKey: node.id) == nil else { throw .ambiguousNode(node.id) }
        }
        return nodes
    }

    private static func uniqueEdges(_ graph: GraphDocument) throws(WiringPreviewRefusal) -> [EdgeID: GraphEdge] {
        var edges: [EdgeID: GraphEdge] = [:]
        for edge in graph.edges {
            guard edges.updateValue(edge, forKey: edge.id) == nil else { throw .ambiguousEdge(edge.id) }
        }
        return edges
    }
}
