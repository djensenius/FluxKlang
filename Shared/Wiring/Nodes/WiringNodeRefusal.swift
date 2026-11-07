//
//  WiringNodeRefusal.swift
//  FluxKlang
//
//  Why a node add or remove composer refused. A refusal never changes the
//  draft or the active graph: the caller keeps exactly what it passed in.
//

/// Why `WiringNodeComposer` refused to add or remove a node. The checks run in the order the cases are listed
/// under each composer entry point; the first failing check is the one reported.
enum WiringNodeRefusal: Error, Hashable, Sendable {
    /// The draft does not check against the active graph (graph, base revision, ambiguous IDs, bounds,
    /// applicability), exactly as `WiringDraftGraph.make` refuses it.
    case preview(WiringPreviewRefusal)
    /// A legacy console shortcut is never routable, so it is never added to a draft.
    case observedShortcutNotRoutable(NodeID)
    /// The ID is already a node of the draft's graph, or it is an active node the draft removed and the new node
    /// differs from it: an ID is never reused with different content.
    case nodeAlreadyPresent(NodeID)
    /// The node is not in the draft's graph, including an active node the draft already removed.
    case unknownNode(NodeID)
    /// The node declares more than `ProjectGraphLimits.portsPerNode` ports.
    case portLimit(count: Int)
    /// The node declares one port ID twice; `port` is the first ID, in declaration order, that repeats an earlier one.
    case duplicatePort(node: NodeID, port: PortID)
    /// The draft's graph already has `ProjectGraphLimits.nodes` nodes.
    case tooManyNodes
    /// The draft, or the removal gesture, would exceed `ProjectGraphLimits.edits` edits.
    case tooManyEdits
    /// The draft edit fold refused the gesture (a non-finite value, a capability bound, `nodeIDReuse`, an edit list
    /// that is too long once the gesture folds in, ...).
    case fold(DraftHistoryRefusal)
}
