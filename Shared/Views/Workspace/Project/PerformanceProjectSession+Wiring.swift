import Foundation

/// The list wiring editor's edits (#101). Each asks the existing composer first, so a refusal is its typed
/// error and nothing changes; then it makes exactly one undoable `apply`. New IDs come from the caller.
extension PerformanceProjectSession {
    enum WiringRefusal: Error, Hashable, Sendable {
        /// Extra role nodes need a role the project already has; this slice adds no roles.
        case unknownRole(RoleID)
        /// The node's connections changed after the removal was confirmed; confirm again.
        case staleRemovalPlan(NodeID)
    }

    /// Every destination of `source` in the current draft graph, grouped by connection class.
    func destinations(from source: PortAddress) throws(WiringComposeRefusal) -> WiringDestinationList {
        try WiringDraftComposer.destinations(from: source, active: base, draft: snapshot.history.draft)
    }

    /// Whether `request` is exactly the Source → Output starter pair, with no conversion or feedback.
    func isStarterPair(_ request: WiringConnectRequest) -> Bool {
        request.from == stereoEdge.from && request.to == stereoEdge.to
            && request.conversion == nil && request.feedback == nil
    }

    /// `source` while it is still an output port of a routable node in the draft graph; `nil` once an undo or
    /// another edit removed it, so the picker never asks for destinations of a missing port.
    func liveSource(_ source: PortAddress?) -> PortAddress? {
        guard let source, let node = snapshot.candidate.node(source.node), node.kind.isRoutable,
              node.port(source.port)?.direction == .output else { return nil }
        return source
    }

    /// Adds one connection as one undo step. The starter pair goes through the toggle, which reuses the
    /// canonical edge record (and ignores `request.edge`) so the toggle and the list stay consistent.
    func connect(_ request: WiringConnectRequest) throws {
        _ = try WiringDraftComposer.compose(request, into: snapshot.history.draft, active: base)
        if isStarterPair(request), !stereoConnectionEnabled {
            try setStereoConnectionEnabled(true)
            return
        }
        let edge = GraphEdge(
            id: request.edge, from: request.from, to: request.to,
            conversion: request.conversion, feedback: request.feedback
        )
        try apply([.connect(edge)])
    }

    /// Removes one connection from the draft as one undo step.
    func removeConnection(_ id: EdgeID) throws {
        _ = try WiringRemoveComposer.remove(edge: id, from: snapshot.history.draft, active: base)
        try apply([.disconnect(id)])
    }

    /// The node an extra role node for `role` would be: one port opposite the role's direction with the role's
    /// signal and channels, as `ProjectDocument` requires of role nodes.
    func roleNode(role: RoleID, id: NodeID, label: String) throws(WiringRefusal) -> GraphNode {
        guard let projectRole = project.roles.first(where: { $0.id == role }) else { throw .unknownRole(role) }
        let feedsGraph = projectRole.direction == .input
        // Named after the signal, so an audio role's port is "audio" like the starter nodes' ports.
        let port = GraphPort(
            id: PortID(rawValue: projectRole.signal.rawValue) ?? PortID(validated: "port"),
            direction: feedsGraph ? .output : .input,
            signal: projectRole.signal, channels: projectRole.channels
        )
        return GraphNode(
            id: id, kind: feedsGraph ? .roleInput : .roleOutput, label: label, role: role, ports: [port]
        )
    }

    /// Adds another node for an existing project role (for example "Output 2") as one undo step.
    @discardableResult
    func addRoleNode(role: RoleID, id: NodeID, label: String) throws -> GraphNode {
        let node = try roleNode(role: role, id: id, label: label)
        _ = try WiringNodeComposer.add(node, to: snapshot.history.draft, active: base)
        try apply([.addNode(node)])
        return node
    }

    /// What removing `node` takes with it, for the confirmation. Read-only.
    func nodeRemovalPlan(_ node: NodeID) throws(WiringNodeRefusal) -> WiringNodeRemovalPlan {
        try WiringNodeComposer.removalPlan(node: node, from: snapshot.history.draft, active: base)
    }

    /// Removes `node` and every attached connection as ONE undo step. When `confirmed` is given, refuses if the
    /// current plan differs from it, so the user never removes connections the confirmation did not name.
    func removeNode(_ node: NodeID, confirmed: WiringNodeRemovalPlan? = nil) throws {
        let plan = try nodeRemovalPlan(node)
        if let confirmed, confirmed != plan { throw WiringRefusal.staleRemovalPlan(node) }
        try apply(plan.gesture)
    }

    /// The inspector label of every node and connection of the draft graph, built once per snapshot. Items the
    /// inspector refuses are left out (the view falls back to their title).
    func inspectorLabels() -> [WiringInspectorSubject: String] {
        let graph = snapshot.candidate
        let subjects = graph.nodes.map { WiringInspectorSubject.node($0.id) } + graph.edges.map { .edge($0.id) }
        var labels: [WiringInspectorSubject: String] = [:]
        for subject in subjects {
            if let inspector = try? inspector(subject) { labels[subject] = inspector.label }
        }
        return labels
    }

    /// The inspector (facts and accessible label) of one draft node or connection.
    func inspector(_ subject: WiringInspectorSubject) throws(WiringInspectorRefusal) -> WiringInspector {
        try WiringInspector.make(subject, draft: snapshot.history.draft, active: base)
    }
}
