//
//  WiringConnectionListRefusal.swift
//  FluxKlang
//
//  Why the compact Connections list cannot be made (#101 WCL1). A refusal lists nothing: no row, section or
//  presence is clamped, dropped or assumed. Nothing calls this yet.
//

/// Why `WiringConnectionList.make(active:review:presence:)` is refused. The checks run in the order the cases are
/// declared; the first failing check is the one reported.
enum WiringConnectionListRefusal: Error, Hashable, Sendable {
    /// A collection exceeds its `ProjectGraphLimits` ceiling. Checked first, before any other pass: the active
    /// graph's nodes, then its edges, then the review's added nodes, added edges and removed edges, then each
    /// active and added node's ports and capabilities (`GraphNode.checkCollectionBounds()`).
    case bounds(ProjectGraphLimitError)
    /// A node ID repeats among the active nodes followed by the review's added nodes (the first repeat in that
    /// order), so a name lookup would be ambiguous.
    case duplicateNode(NodeID)
    /// An edge end or a presence key names a node that is neither active nor added by the review. Edges are
    /// checked first, in order (active, added, removed; the from end before the to end), then the presence keys,
    /// reporting the unknown key with the least UTF-8 bytes.
    case unknownNode(NodeID)
    /// An edge ID repeats: among the active edges, among the added edges (or an added edge reuses an active ID the
    /// review does not remove), or among the removed edges. The first repeat in that order. The repeated-added and
    /// repeated-removed clauses are defensive: a `WiringReviewDiff` made by `make(active:draft:)` repeats neither.
    case duplicateEdge(EdgeID)
    /// A removed edge of the review is not an active edge with the same ID and endpoints, so the review was
    /// probably made for another active graph. The first such edge in review order. Only removed edges are checked
    /// this way: the review's moved and removed nodes are not, and a review that only adds is not checked against
    /// the active graph at all.
    case removedEdgeNotActive(EdgeID)
    /// A destination node has no injected presence; presence is never assumed. The first such node in section
    /// order.
    case presenceMissing(NodeID)
}
