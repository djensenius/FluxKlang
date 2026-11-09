//
//  WiringSelectionOrder.swift
//  FluxKlang
//
//  The focus order of a draft graph (#101 WSL1): every node, then every port, then every edge, each section sorted by
//  raw-ID utf8 bytes. It reads only its arguments; nothing is drawn, focused, edited or sent.
//

/// One stop of the focus order. A port is addressed through its owning node.
enum WiringSelectionTarget: Hashable, Sendable {
    case node(NodeID)
    case port(node: NodeID, port: PortID)
    case edge(EdgeID)

    var section: WiringSelectionSection {
        switch self {
        case .node: return .nodes
        case .port: return .ports
        case .edge: return .edges
        }
    }

    /// The inspector subject of this stop. A port shares the subject of its node.
    var inspectorSubject: WiringInspectorSubject {
        switch self {
        case .node(let id): return .node(id)
        case .port(let owner, _): return .node(owner)
        case .edge(let id): return .edge(id)
        }
    }
}

/// The three contiguous parts of the order, in order.
enum WiringSelectionSection: CaseIterable, Hashable, Sendable {
    case nodes
    case ports
    case edges
}

/// The ordered stops of one graph, built once per draft edit. Nodes ascend by ID, then ports by (node ID, port ID),
/// then edges by ID, every comparison over utf8 bytes. A dangling edge is a stop; an observed shortcut is a node stop
/// with no ports; an empty graph is an empty order. Storage is targets only: labels are computed on demand.
struct WiringSelectionOrder: Hashable, Sendable {
    private(set) var targets: [WiringSelectionTarget]
    private let indexByTarget: [WiringSelectionTarget: Int]
    private let nodeEnd: Int
    private let portEnd: Int

    private init(targets: [WiringSelectionTarget], nodeEnd: Int, portEnd: Int) {
        var index: [WiringSelectionTarget: Int] = Dictionary(minimumCapacity: targets.count)
        for (position, target) in targets.enumerated() {
            index[target] = position
        }
        self.targets = targets
        self.indexByTarget = index
        self.nodeEnd = nodeEnd
        self.portEnd = portEnd
    }

    var count: Int { targets.count }

    func target(at position: Int) -> WiringSelectionTarget? {
        guard position >= 0, position < targets.count else { return nil }
        return targets[position]
    }

    /// The position of a stop, in O(1); nil when the order has no such stop.
    func position(of target: WiringSelectionTarget) -> Int? {
        indexByTarget[target]
    }

    func contains(_ target: WiringSelectionTarget) -> Bool {
        position(of: target) != nil
    }

    func range(of section: WiringSelectionSection) -> Range<Int> {
        switch section {
        case .nodes: return 0..<nodeEnd
        case .ports: return nodeEnd..<portEnd
        case .edges: return portEnd..<targets.count
        }
    }

    /// The order of `graph`, refused (before anything is allocated by the refused input) in this order: too many
    /// nodes, too many edges, too many ports on a node, a repeated node, a repeated port, a repeated edge.
    static func make(graph: GraphDocument) throws(WiringSelectionRefusal) -> WiringSelectionOrder {
        try checkNodeCount(graph)
        try checkEdgeCount(graph)
        try checkPortCounts(graph)
        try checkDuplicateNodes(graph)
        try checkDuplicatePorts(graph)
        try checkDuplicateEdges(graph)
        return build(graph)
    }

    /// The order of the draft's graph. The draft is checked first (`preview`); the graph it yields then goes through
    /// the same checks as `make(graph:)`.
    static func make(active: GraphDocument, draft: DraftEdits) throws(WiringSelectionRefusal) -> WiringSelectionOrder {
        let graph: GraphDocument
        do { graph = try WiringDraftGraph.make(active: active, draft: draft).graph } catch { throw .preview(error) }
        return try make(graph: graph)
    }

    private static func checkNodeCount(_ graph: GraphDocument) throws(WiringSelectionRefusal) {
        guard graph.nodes.count <= ProjectGraphLimits.nodes else { throw .tooManyNodes(graph.nodes.count) }
    }

    private static func checkEdgeCount(_ graph: GraphDocument) throws(WiringSelectionRefusal) {
        guard graph.edges.count <= ProjectGraphLimits.edges else { throw .tooManyEdges(graph.edges.count) }
    }

    private static func checkPortCounts(_ graph: GraphDocument) throws(WiringSelectionRefusal) {
        for node in graph.nodes where node.ports.count > ProjectGraphLimits.portsPerNode {
            throw .tooManyPorts(node: node.id, count: node.ports.count)
        }
    }

    private static func checkDuplicateNodes(_ graph: GraphDocument) throws(WiringSelectionRefusal) {
        var seen = Set<NodeID>(minimumCapacity: graph.nodes.count)
        for node in graph.nodes {
            guard seen.insert(node.id).inserted else { throw .duplicateNode(node.id) }
        }
    }

    private static func checkDuplicatePorts(_ graph: GraphDocument) throws(WiringSelectionRefusal) {
        var seen = Set<PortID>(minimumCapacity: ProjectGraphLimits.portsPerNode)
        for node in graph.nodes {
            seen.removeAll(keepingCapacity: true)
            for port in node.ports {
                guard seen.insert(port.id).inserted else { throw .duplicatePort(node: node.id, port: port.id) }
            }
        }
    }

    private static func checkDuplicateEdges(_ graph: GraphDocument) throws(WiringSelectionRefusal) {
        var seen = Set<EdgeID>(minimumCapacity: graph.edges.count)
        for edge in graph.edges {
            guard seen.insert(edge.id).inserted else { throw .duplicateEdge(edge.id) }
        }
    }

    private static func build(_ graph: GraphDocument) -> WiringSelectionOrder {
        let nodes = graph.nodes.sorted(by: { precedes($0.id, $1.id) })
        var portTotal = 0
        for node in nodes {
            portTotal += node.ports.count
        }
        var targets: [WiringSelectionTarget] = []
        targets.reserveCapacity(nodes.count + portTotal + graph.edges.count)
        for node in nodes {
            targets.append(.node(node.id))
        }
        for node in nodes {
            for port in node.ports.map(\.id).sorted(by: precedes) {
                targets.append(.port(node: node.id, port: port))
            }
        }
        let portEnd = targets.count
        for edge in graph.edges.map(\.id).sorted(by: precedes) {
            targets.append(.edge(edge))
        }
        return WiringSelectionOrder(targets: targets, nodeEnd: nodes.count, portEnd: portEnd)
    }
}

extension WiringSelectionOrder {
    /// One accessible label, computed on demand from `graph` (the graph the order was built from): a node's label,
    /// or its raw ID when the label has no utf8 bytes; a port as "<node title>, <port id>, input|output, <signal>";
    /// an edge as "wire <edge id>". Nil when the graph lacks the target. One pass over the nodes (then that node's
    /// ports) or over the edges; one call per announcement.
    static func label(of target: WiringSelectionTarget, in graph: GraphDocument) -> String? {
        switch target {
        case .edge(let id):
            for edge in graph.edges where edge.id == id {
                return "wire \(id.rawValue)"
            }
            return nil
        case .node(let id):
            for node in graph.nodes where node.id == id {
                return title(of: node)
            }
            return nil
        case .port(let owner, let portID):
            for node in graph.nodes where node.id == owner {
                for port in node.ports where port.id == portID {
                    let direction = port.direction == .input ? "input" : "output"
                    return "\(title(of: node)), \(portID.rawValue), \(direction), \(port.signal.rawValue)"
                }
                return nil
            }
            return nil
        }
    }

    private static func title(of node: GraphNode) -> String {
        node.label.utf8.isEmpty ? node.id.rawValue : node.label
    }
}

private func precedes<Tag>(_ first: ContractID<Tag>, _ second: ContractID<Tag>) -> Bool {
    first.rawValue.utf8.lexicographicallyPrecedes(second.rawValue.utf8)
}
