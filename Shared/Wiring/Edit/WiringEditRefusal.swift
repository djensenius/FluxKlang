//
//  WiringEditRefusal.swift
//  FluxKlang
//
//  Why a wiring edit path (move, remove, restore, matrix window or toggle)
//  refused. A refusal never changes the draft or the active graph: the caller
//  keeps exactly what it passed in.
//

/// Why `WiringMoveComposer`, `WiringRemoveComposer` or `WiringMatrix` refused.
enum WiringEditRefusal: Error, Hashable, Sendable {
    /// A move target (drag end point, numeric entry, or the result of a nudge) has a NaN or infinite coordinate.
    case nonFinitePosition(NodeID)
    /// A grid step or fine step is NaN, infinite, zero or negative.
    case invalidGrid
    /// The node is not in the draft's graph.
    case unknownNode(NodeID)
    /// A nudge needs a current position, and the node in the draft's graph has none (it is unplaced). Drag and
    /// numeric entry place it instead.
    case unplacedNode(NodeID)
    /// The edge ID names no edge of the active graph or of the draft's graph.
    case unknownEdge(EdgeID)
    /// The edge is known, but not where the path needs it: a remove of an active edge the draft already removes,
    /// or a restore of an edge that is not an active edge the draft removes (it is still in the draft's graph).
    case notInDraftOrActive(EdgeID)
    /// The matrix window asks for more than `WiringMatrix.maximumRows` rows or `maximumColumns` columns.
    case windowTooLarge(rows: Int, columns: Int)
    /// The connect composer refused the matrix toggle on.
    case compose(WiringComposeRefusal)
    /// The draft edit fold refused the move, remove or restore.
    case fold(DraftHistoryRefusal)
    /// The draft does not check against the active graph (graph, base revision, ambiguous IDs, bounds,
    /// applicability), exactly as `WiringReviewDiff.make` refuses it.
    case preview(WiringPreviewRefusal)
}
