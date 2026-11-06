//
//  DraftHistoryRefusal.swift
//  FluxKlang
//
//  Why the draft edit fold or the draft undo history refused an operation. A
//  refused operation always leaves the draft and its history unchanged.
//

/// Why a gesture, an undo, a redo or a history creation was refused.
enum DraftHistoryRefusal: Error, Hashable, Sendable {
    /// The requested history depth is outside `DraftHistoryDepth.range`.
    case depthOutOfRange(Int)
    /// The history belongs to a different graph.
    case graphMismatch(expected: GraphID, found: GraphID)
    /// The history is bound to another base revision; it is never replayed onto a new base.
    case baseMismatch(expected: ContractRevision, found: ContractRevision)
    /// The base has the bound graph ID and revision but other nodes or edges, so it is not the base the
    /// history was built on.
    case baseContentMismatch(ContractRevision)
    /// A node position has a NaN or infinite coordinate (in a gesture, or in the base of a new history).
    case invalidPosition(NodeID)
    /// A node added by a gesture, or a base node of a new history, has a NaN or infinite `linearGain`.
    case nonFiniteNodeValue(NodeID)
    /// An edge connected by a gesture, or a base edge of a new history, has a NaN or infinite `gainCeilingDb`.
    case nonFiniteEdgeValue(EdgeID)
    /// A node added or moved by a gesture, or a base node of a new history, holds a NaN or infinite number in an
    /// extension bag or unknown member (of the node, a port or the position), at the JSON `path`.
    case nonFiniteNodeExtension(NodeID, path: String)
    /// An edge connected by a gesture, or a base edge of a new history, holds a NaN or infinite number in an
    /// extension bag or unknown member (of the edge, an endpoint, the conversion or the feedback), at `path`.
    case nonFiniteEdgeExtension(EdgeID, path: String)
    /// The base graph lists two nodes with one ID, so draft edits on it are ambiguous.
    case duplicateBaseNode(NodeID)
    /// The base graph lists two edges with one ID, so draft edits on it are ambiguous.
    case duplicateBaseEdge(EdgeID)
    /// A gesture, the folded edit list or the candidate graph exceeds `ProjectGraphLimits`.
    case bounds(ProjectGraphLimitError)
    /// The existing edit list does not apply to the base graph.
    case invalidDraft(GraphEditError)
    /// The gesture edit at `index` does not apply to the candidate graph.
    case edit(index: Int, GraphEditError)
    /// A base edge ID is connected again with a different value. Only an
    /// identical reconnect (which cancels the disconnect) is allowed.
    case edgeIDReuse(EdgeID)
    /// A base node removed in this draft is added again; the draft cannot express both.
    case nodeIDReuse(NodeID)
    /// The connect touches a base node removed in this draft.
    case endpointRemoved(edge: EdgeID, node: NodeID)
    /// There is no earlier draft state to restore.
    case nothingToUndo
    /// There is no undone draft state to restore.
    case nothingToRedo
}
