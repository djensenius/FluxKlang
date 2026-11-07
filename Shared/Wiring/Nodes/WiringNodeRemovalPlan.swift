//
//  WiringNodeRemovalPlan.swift
//  FluxKlang
//
//  What removing a node takes with it: every edge of the draft's graph that
//  touches the node is disconnected first, because `GraphEdit.removeNode` is
//  only valid once its attached edges are gone. The plan is a read-only
//  preview (the UI can list the wires that go with the node) and exactly what
//  `WiringNodeComposer.remove` folds.
//

/// The edges that go with a node, built only by `make`. Valid for the draft and active graph it was built from.
struct WiringNodeRemovalPlan: Hashable, Sendable {
    /// The node to remove.
    private(set) var node: NodeID
    /// The edges of the draft's graph that touch `node` (a self-loop once), ascending by raw ID bytes. Edges the
    /// draft already disconnected are absent; edges the draft connected are present (the fold drops their connect).
    private(set) var edgesToDisconnect: [EdgeID]

    private init(node: NodeID, edgesToDisconnect: [EdgeID]) {
        self.node = node
        self.edgesToDisconnect = edgesToDisconnect
    }

    /// The one gesture `remove` folds, atomically: a disconnect per attached edge, then the node's removal.
    var gesture: [GraphEdit] {
        edgesToDisconnect.map(GraphEdit.disconnect) + [.removeNode(node)]
    }

    /// The plan to remove `node` from `draft`'s graph. Refused, in this order, when the draft does not check against
    /// `active` (`preview`), the draft's graph has no such node (`unknownNode`; an active node the draft removed
    /// too) or the gesture would exceed `ProjectGraphLimits.edits` edits (`tooManyEdits`).
    static func make(
        node: NodeID, from draft: DraftEdits, active: GraphDocument
    ) throws(WiringNodeRefusal) -> WiringNodeRemovalPlan {
        let graph: GraphDocument
        do { graph = try WiringDraftGraph.make(active: active, draft: draft).graph } catch { throw .preview(error) }
        guard graph.nodes.contains(where: { $0.id == node }) else { throw .unknownNode(node) }
        let attached = graph.edges.filter { $0.from.node == node || $0.to.node == node }.map(\.id)
        guard attached.count + 1 <= ProjectGraphLimits.edits else { throw .tooManyEdits }
        return WiringNodeRemovalPlan(node: node, edgesToDisconnect: attached.sorted(by: precedes))
    }

    private static func precedes(_ first: EdgeID, _ second: EdgeID) -> Bool {
        first.rawValue.utf8.lexicographicallyPrecedes(second.rawValue.utf8)
    }
}
