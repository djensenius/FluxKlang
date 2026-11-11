//
//  WiringInspector.swift
//  FluxKlang
//
//  A pure description of ONE selected node or edge of the draft graph (#101 WIN1): its facts, the contract
//  diagnostics that concern it and one accessible label. It reads only its arguments; a dangling wire is reported,
//  not repaired; nothing is edited, sent or activated.
//

/// What is selected: one node or one edge. A port selection maps to its node outside this model.
enum WiringInspectorSubject: Hashable, Sendable {
    case node(NodeID)
    case edge(EdgeID)
}

/// Whether the draft introduced the selected item.
enum WiringInspectorMarker: Hashable, Sendable {
    /// The item is in the active graph (a moved node stays active).
    case active
    /// The draft's edits add the node or connect the edge.
    case draft
}

/// Why an inspector cannot be made. Checked in this order: `preview` (the factory's own order), `uncheckableGraph`,
/// `subjectAbsent`.
enum WiringInspectorRefusal: Error, Hashable, Sendable {
    case preview(WiringPreviewRefusal)
    case uncheckableGraph(GraphValidationError)
    case subjectAbsent(WiringInspectorSubject)
}

struct WiringInspectorPort: Hashable, Sendable {
    let id: PortID
    let direction: PortDirection
    let signal: PortSignal
    let channels: Int?
}

/// What one end of an edge resolves to in the draft graph.
enum WiringInspectorEndState: Hashable, Sendable {
    case missingNode
    case notRoutable
    case missingPort
    case connected(direction: PortDirection, signal: PortSignal, channels: Int?)
}

struct WiringInspectorEnd: Hashable, Sendable {
    let node: NodeID
    let port: PortID
    /// The node's title, or its raw ID when the node is missing.
    let title: String
    let state: WiringInspectorEndState
}

/// The inspector of one node or edge. Inapplicable fields are nil, empty, 0 or false: a node has no ends and no
/// conversion; an edge has no `kind`, no ports and no attached edges.
struct WiringInspector: Hashable, Sendable {
    let subject: WiringInspectorSubject
    let marker: WiringInspectorMarker
    let title: String
    let kind: NodeKind?
    let ports: [WiringInspectorPort]
    let ends: [WiringInspectorEnd]
    let attachedEdges: [EdgeID]
    let feedbackCount: Int
    let hasConversion: Bool
    let problems: [WiringInspectorProblem]
    let label: String

    fileprivate struct Parts {
        let subject: WiringInspectorSubject
        let marker: WiringInspectorMarker
        let title: String
        let kind: NodeKind?
        let ports: [WiringInspectorPort]
        let ends: [WiringInspectorEnd]
        let attachedEdges: [EdgeID]
        let feedbackCount: Int
        let hasConversion: Bool
        let problems: [WiringInspectorProblem]
        let label: String
    }

    fileprivate init(_ parts: Parts) {
        subject = parts.subject
        marker = parts.marker
        title = parts.title
        kind = parts.kind
        ports = parts.ports
        ends = parts.ends
        attachedEdges = parts.attachedEdges
        feedbackCount = parts.feedbackCount
        hasConversion = parts.hasConversion
        problems = parts.problems
        label = parts.label
    }

    /// Describes `subject` on the draft graph `active.applying(draft.edits)`. Refuses, in order: the draft graph
    /// cannot be formed (`preview`), the graph's validation cannot check wires (`uncheckableGraph`), the draft
    /// graph has no such node or edge (`subjectAbsent`, an item the draft removed included).
    static func make(
        _ subject: WiringInspectorSubject, draft: DraftEdits, active: GraphDocument
    ) throws(WiringInspectorRefusal) -> WiringInspector {
        let context = try Context(draft: draft, active: active)
        switch subject {
        case .node(let id):
            guard let node = context.graph.node(id) else { throw .subjectAbsent(subject) }
            return context.inspector(node)
        case .edge(let id):
            guard let edge = context.graph.edges.first(where: { $0.id == id }) else { throw .subjectAbsent(subject) }
            return context.inspector(edge)
        }
    }

    /// Describes every node and then every edge of the draft graph, in graph order, folding and validating the
    /// draft ONCE (`make` per item would replay the whole draft for each). Each inspector equals
    /// `make(subject, draft:, active:)` for its subject; refuses as `make` does for a graph-wide reason. A repeated
    /// node ID yields one inspector, for the first such node, as `make` does.
    static func makeAll(draft: DraftEdits, active: GraphDocument) throws(WiringInspectorRefusal) -> [WiringInspector] {
        let context = try Context(draft: draft, active: active)
        var seenNodes: Set<NodeID> = []
        var seenEdges: Set<EdgeID> = []
        let nodes = context.graph.nodes.filter { seenNodes.insert($0.id).inserted }.map { context.inspector($0) }
        let edges = context.graph.edges.filter { seenEdges.insert($0.id).inserted }.map { context.inspector($0) }
        return nodes + edges
    }

    /// The draft graph, its validation and the IDs the draft introduced, computed once and shared by `make` and
    /// `makeAll` so a single inspector and a batch one cannot diverge.
    private struct Context {
        let graph: GraphDocument
        let errors: [GraphValidationError]
        let addedNodes: Set<NodeID>
        let connectedEdges: Set<EdgeID>

        init(draft: DraftEdits, active: GraphDocument) throws(WiringInspectorRefusal) {
            graph = try WiringInspector.draftGraph(active: active, draft: draft)
            errors = graph.validationErrors()
            if let blocking = errors.first(where: { WiringInspectorProblem.classify($0).scope == .uncheckable }) {
                throw .uncheckableGraph(blocking)
            }
            var nodes: Set<NodeID> = []
            var edges: Set<EdgeID> = []
            for edit in draft.edits {
                switch edit {
                case .addNode(let node): nodes.insert(node.id)
                case .connect(let edge): edges.insert(edge.id)
                case .disconnect, .removeNode, .moveNode: break
                }
            }
            addedNodes = nodes
            connectedEdges = edges
        }

        func inspector(_ node: GraphNode) -> WiringInspector {
            let marker: WiringInspectorMarker = addedNodes.contains(node.id) ? .draft : .active
            return WiringInspector.nodeInspector(node, in: graph, errors: errors, marker: marker)
        }

        func inspector(_ edge: GraphEdge) -> WiringInspector {
            let marker: WiringInspectorMarker = connectedEdges.contains(edge.id) ? .draft : .active
            return WiringInspector.edgeInspector(edge, in: graph, errors: errors, marker: marker)
        }
    }

    private static func draftGraph(
        active: GraphDocument, draft: DraftEdits
    ) throws(WiringInspectorRefusal) -> GraphDocument {
        do throws(WiringPreviewRefusal) {
            return try WiringDraftGraph.make(active: active, draft: draft).graph
        } catch {
            throw .preview(error)
        }
    }

    private static func title(of node: GraphNode) -> String {
        node.label.utf8.isEmpty ? node.id.rawValue : node.label
    }

    private static func nodeInspector(
        _ node: GraphNode, in graph: GraphDocument, errors: [GraphValidationError], marker: WiringInspectorMarker
    ) -> WiringInspector {
        let title = title(of: node)
        let attached = graph.edges.filter { $0.from.node == node.id || $0.to.node == node.id }
        let attachedIDs = attached.map(\.id).sorted { $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8) }
        let ports = node.ports.map { port in
            WiringInspectorPort(id: port.id, direction: port.direction, signal: port.signal, channels: port.channels)
        }
        let feedback = attached.filter { $0.feedback != nil }.count
        let problems = WiringInspectorProblem.problems(
            errors, subject: .node(node.id), attached: attachedIDs, title: title
        )
        let facts = WiringInspectorLabel.NodeFacts(
            title: title, kind: node.kind, marker: marker,
            inputs: ports.filter { $0.direction == .input }.count,
            outputs: ports.filter { $0.direction == .output }.count,
            connections: attachedIDs.count, feedback: feedback, problems: problems.count
        )
        return WiringInspector(Parts(
            subject: .node(node.id), marker: marker, title: title, kind: node.kind, ports: ports, ends: [],
            attachedEdges: attachedIDs, feedbackCount: feedback, hasConversion: false, problems: problems,
            label: WiringInspectorLabel.node(facts)
        ))
    }

    private static func edgeInspector(
        _ edge: GraphEdge, in graph: GraphDocument, errors: [GraphValidationError], marker: WiringInspectorMarker
    ) -> WiringInspector {
        let source = end(of: edge.from, in: graph)
        let destination = end(of: edge.to, in: graph)
        let problems = WiringInspectorProblem.problems(
            errors, subject: .edge(edge.id), attached: [], title: edge.id.rawValue
        )
        let label = WiringInspectorLabel.edge(from: source, to: destination, marker: marker, problems: problems.count)
        return WiringInspector(Parts(
            subject: .edge(edge.id), marker: marker, title: edge.id.rawValue, kind: nil, ports: [],
            ends: [source, destination], attachedEdges: [], feedbackCount: edge.feedback == nil ? 0 : 1,
            hasConversion: edge.conversion != nil, problems: problems, label: label
        ))
    }

    private static func end(of address: PortAddress, in graph: GraphDocument) -> WiringInspectorEnd {
        guard let node = graph.node(address.node) else {
            return WiringInspectorEnd(
                node: address.node, port: address.port, title: address.node.rawValue, state: .missingNode
            )
        }
        let title = title(of: node)
        guard node.kind.isRoutable else {
            return WiringInspectorEnd(node: address.node, port: address.port, title: title, state: .notRoutable)
        }
        guard let port = node.port(address.port) else {
            return WiringInspectorEnd(node: address.node, port: address.port, title: title, state: .missingPort)
        }
        let state = WiringInspectorEndState.connected(
            direction: port.direction, signal: port.signal, channels: port.channels
        )
        return WiringInspectorEnd(node: address.node, port: address.port, title: title, state: state)
    }
}
