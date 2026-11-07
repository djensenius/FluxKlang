//
//  WiringNodeComposer.swift
//  FluxKlang
//
//  Add-node and remove-node gestures are meant to go through this composer; no
//  caller exists in this slice. It folds ONE gesture into the draft. Adding
//  folds one `GraphEdit.addNode`; removing folds a `disconnect` for every
//  attached edge and then the `removeNode`, as one atomic array. The active graph
//  is only read, and nothing is activated, persisted or published.
//

/// Adds and removes nodes in drafts. Pure and deterministic; the result is a new `DraftEdits` value.
enum WiringNodeComposer {
    /// `draft` with `node` added. Refused, with nothing changed, in this order: the draft does not check against
    /// `active` (`preview`); the node is a legacy console shortcut (`observedShortcutNotRoutable`); its ID is a
    /// node of the draft's graph, or an active node the draft removed and the new node differs from it
    /// (`nodeAlreadyPresent`); more than 256 ports (`portLimit`); a repeated port ID (`duplicatePort`); the
    /// draft's graph is at 4,096 nodes (`tooManyNodes`); the draft is at 4,096 edits (`tooManyEdits`); the fold
    /// refuses (`fold`, for example `nodeIDReuse` when the node equals the active node the draft removed).
    static func add(
        _ node: GraphNode, to draft: DraftEdits, active: GraphDocument
    ) throws(WiringNodeRefusal) -> DraftEdits {
        let graph = try draftGraph(draft, active: active)
        guard node.kind.isRoutable else { throw .observedShortcutNotRoutable(node.id) }
        guard !isPresent(node, in: graph, active: active) else { throw .nodeAlreadyPresent(node.id) }
        guard node.ports.count <= ProjectGraphLimits.portsPerNode else { throw .portLimit(count: node.ports.count) }
        if let port = firstRepeatedPort(of: node) { throw .duplicatePort(node: node.id, port: port) }
        guard graph.nodes.count + 1 <= ProjectGraphLimits.nodes else { throw .tooManyNodes }
        guard draft.edits.count + 1 <= ProjectGraphLimits.edits else { throw .tooManyEdits }
        return try fold([.addNode(node)], into: draft, active: active)
    }

    /// What `remove` takes with the node: the attached edges, ascending by raw ID. Read-only; the same refusals as
    /// `remove` before the fold.
    static func removalPlan(
        node: NodeID, from draft: DraftEdits, active: GraphDocument
    ) throws(WiringNodeRefusal) -> WiringNodeRemovalPlan {
        try WiringNodeRemovalPlan.make(node: node, from: draft, active: active)
    }

    /// `draft` without `node`: a disconnect for each attached edge, then the removal, folded as one atomic gesture.
    /// Refused, with nothing changed, when the draft does not check against `active` (`preview`), the draft's graph
    /// has no such node (`unknownNode`), the gesture exceeds 4,096 edits (`tooManyEdits`) or the fold refuses
    /// (`fold`, for example `bounds` when the draft's own edits plus the gesture exceed 4,096).
    static func remove(
        node: NodeID, from draft: DraftEdits, active: GraphDocument
    ) throws(WiringNodeRefusal) -> DraftEdits {
        let plan = try removalPlan(node: node, from: draft, active: active)
        return try fold(plan.gesture, into: draft, active: active)
    }

    private static func draftGraph(
        _ draft: DraftEdits, active: GraphDocument
    ) throws(WiringNodeRefusal) -> GraphDocument {
        do { return try WiringDraftGraph.make(active: active, draft: draft).graph } catch { throw .preview(error) }
    }

    /// Whether adding `node` would reuse an ID: it is in the draft's graph, or the active graph has it (the draft
    /// removed it) with other content.
    private static func isPresent(_ node: GraphNode, in graph: GraphDocument, active: GraphDocument) -> Bool {
        if graph.nodes.contains(where: { $0.id == node.id }) { return true }
        guard let original = active.nodes.first(where: { $0.id == node.id }) else { return false }
        return original != node
    }

    private static func firstRepeatedPort(of node: GraphNode) -> PortID? {
        var seen: Set<PortID> = []
        for port in node.ports where !seen.insert(port.id).inserted { return port.id }
        return nil
    }

    private static func fold(
        _ gesture: [GraphEdit], into draft: DraftEdits, active: GraphDocument
    ) throws(WiringNodeRefusal) -> DraftEdits {
        let edits: [GraphEdit]
        do { edits = try DraftEditFold.fold(gesture, onto: draft.edits, base: active) } catch { throw .fold(error) }
        var folded = draft
        folded.edits = edits
        return folded
    }
}
