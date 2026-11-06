//
//  WiringCandidateContext.swift
//  FluxKlang
//
//  What contract validation of a probe edge source → destination would add,
//  answered per destination from one baseline `validationErrors()` and indexes
//  built once per source. `WiringCandidate.classify` validates a graph copy per
//  pair (O(graph) each, so a whole destination list is quadratic); this context
//  restates, for one added bare edge, the contract's per-edge checks
//  (`errorsForEdge`), its first-wins duplicate-wire rule and its cycle peeling
//  (`nodesOnCycles`). Equivalence with `classify` is proved by the differential
//  tests in WiringComposeTests+Bulk.swift.
//
//  Cycles. Let L be the linked graph (edges without feedback and without edge
//  errors), C its nodes on cycles, R the nodes reachable from C and Q the nodes
//  reaching C (both include C). The peeling keeps exactly R ∩ Q (a node survives
//  iff it has a predecessor and a successor among survivors). Adding s → d:
//  with A the nodes reaching s (s included) and D the nodes reachable from d,
//  if d ∈ A (a new cycle) or s ∈ R and d ∈ Q (a bridge), the survivors become
//  (R ∪ D) ∩ (Q ∪ A); otherwise they do not change. D ∩ (Q ∪ A) is a search
//  from d restricted to Q ∪ A, run only for destinations that reach this rule.
//

/// The precomputed state for classifying bare wires from one source port. Internal: it only
/// answers `WiringConnection` values (or refusals) and cannot mint a `WiringCandidate`; the
/// candidates of a batch are built by `WiringCandidateBatch` from its answers.
struct WiringCandidateContext {
    private struct PortKey: Hashable {
        let node: NodeID
        let port: PortID
    }

    private enum Endpoint {
        case port(GraphPort)
        case unroutable(NodeID)
    }

    let source: PortAddress
    /// First occurrence of each node ID, and of each port ID within it (the contract's lookup).
    private let nodes: [NodeID: GraphNode]
    private let ports: [NodeID: [PortID: GraphPort]]
    private let sourceEndpoint: Endpoint
    /// Nodes the baseline reports with broken ports (`WiringPreviewRefusal.endpointUncheckable`).
    private let uncheckable: Set<NodeID>
    /// The first edge (in graph order) from the source to each destination address.
    private let existing: [PortKey: EdgeID]
    /// At the edge bound, the matrix may still classify existing pairs without a probe edge.
    private let atEdgeBound: Bool
    private let loops: WiringLoopIndex
    private var cycles: [NodeID: WiringConnection] = [:]

    /// Graph- and source-level refusals, in the order `classify` checks them: the baseline
    /// validation (bounds, then a graph the contract cannot check), an uncheckable source node, no
    /// probe ID, an unknown source node or (on a routable node) port, and a graph already at the edge
    /// bound (`classify` names an unknown source there too, from its wire-exists retry). `onValidate`
    /// only observes the one baseline `validationErrors()` call (a test seam); it cannot supply errors.
    init(
        source: PortAddress, in graph: GraphDocument, onValidate: () -> Void,
        allowsExistingAtEdgeBound: Bool = false
    ) throws(WiringPreviewRefusal) {
        onValidate()
        let baseline = try WiringCandidateClassifier.checked(WiringCandidateClassifier.validationErrors(of: graph))
        uncheckable = Set(baseline.compactMap(WiringCandidateClassifier.uncheckableNode))
        if uncheckable.contains(source.node) { throw .endpointUncheckable(node: source.node) }
        let probe = try WiringCandidateClassifier.probeID(avoiding: graph.edges)
        var nodes: [NodeID: GraphNode] = [:]
        for node in graph.nodes where nodes[node.id] == nil { nodes[node.id] = node }
        let ports = nodes.mapValues { node in
            Dictionary(node.ports.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        self.source = source
        self.nodes = nodes
        self.ports = ports
        sourceEndpoint = try Self.resolve(source, nodes: nodes, ports: ports)
        atEdgeBound = allowsExistingAtEdgeBound && graph.edges.count == ProjectGraphLimits.edges
        if !atEdgeBound {
            var widened = graph
            widened.edges.append(GraphEdge(id: probe, from: source, to: source))
            do { try widened.checkCollectionBounds() } catch { throw .bounds(error) }
        }
        var existing: [PortKey: EdgeID] = [:]
        var links: [(NodeID, NodeID)] = []
        for edge in graph.edges {
            if edge.from.node == source.node, edge.from.port == source.port {
                let key = PortKey(node: edge.to.node, port: edge.to.port)
                if existing[key] == nil { existing[key] = edge.id }
            }
            if edge.feedback == nil, Self.isClean(edge, nodes: nodes, ports: ports) {
                links.append((edge.from.node, edge.to.node))
            }
        }
        self.existing = existing
        loops = WiringLoopIndex(links: links, source: source.node)
    }

    /// The bare wire source → `destination`, or its refusal. At exactly 16,384 edges wired pairs keep their
    /// classification; every non-wired cell is `.uncheckable(.bounds)`. `classify` differs only for non-wired
    /// pairs with uncheckable or unknown endpoints.
    mutating func connection(to destination: PortAddress) throws(WiringPreviewRefusal) -> WiringConnection {
        let key = PortKey(node: destination.node, port: destination.port)
        if uncheckable.contains(destination.node) {
            try refuseNonWiredAtEdgeBound(key)
            throw .endpointUncheckable(node: destination.node)
        }
        let target: Endpoint
        do {
            target = try Self.resolve(destination, nodes: nodes, ports: ports)
        } catch {
            try refuseNonWiredAtEdgeBound(key)
            throw error
        }
        let output: GraphPort, input: GraphPort
        switch (sourceEndpoint, target) {
        case (.unroutable(let node), _), (_, .unroutable(let node)):
            try refuseNonWiredAtEdgeBound(key)
            return .notRoutable(node)
        case (.port(let from), .port(let to)): (output, input) = (from, to)
        }
        guard output.direction == .output, input.direction == .input else {
            try refuseNonWiredAtEdgeBound(key)
            return .notOffered
        }
        if let edge = existing[key] { return .existing(edge) }
        guard output.signal == input.signal else {
            try refuseNonWiredAtEdgeBound(key)
            return .disabled(.signalMismatch(from: output.signal, to: input.signal))
        }
        if output.signal == .audio, output.hasValidChannels, input.hasValidChannels,
           let width = output.channels, let rows = input.channels, width != rows {
            try refuseNonWiredAtEdgeBound(key)
            return .needsConversion(sourceChannels: width, destinationChannels: rows)
        }
        let connection = cycles[destination.node] ?? loops.connection(to: destination.node)
        cycles[destination.node] = connection
        try refuseNonWiredAtEdgeBound(key)
        return connection
    }

    private func refuseNonWiredAtEdgeBound(_ key: PortKey) throws(WiringPreviewRefusal) {
        if atEdgeBound, existing[key] == nil { throw edgeBoundRefusal }
    }

    private var edgeBoundRefusal: WiringPreviewRefusal {
        .bounds(.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges))
    }

    /// The contract's endpoint lookup: a missing node is unknown; a port that is missing on a
    /// routable node is unknown; any port on an observed shortcut is not routable.
    private static func resolve(
        _ address: PortAddress, nodes: [NodeID: GraphNode], ports: [NodeID: [PortID: GraphPort]]
    ) throws(WiringPreviewRefusal) -> Endpoint {
        guard let node = nodes[address.node] else { throw .unknownNode(address.node) }
        guard node.kind.isRoutable else { return .unroutable(node.id) }
        guard let port = ports[address.node]?[address.port] else { throw .unknownPort(address) }
        return .port(port)
    }

    /// Whether the contract reports no error for `edge` itself (it then links its nodes when it has no feedback).
    private static func isClean(
        _ edge: GraphEdge, nodes: [NodeID: GraphNode], ports: [NodeID: [PortID: GraphPort]]
    ) -> Bool {
        guard case .port(let output)? = try? resolve(edge.from, nodes: nodes, ports: ports),
              case .port(let input)? = try? resolve(edge.to, nodes: nodes, ports: ports),
              output.direction == .output, input.direction == .input, output.signal == input.signal else {
            return false
        }
        guard output.signal == .audio, output.hasValidChannels, input.hasValidChannels,
              let width = output.channels, let rows = input.channels else { return edge.conversion == nil }
        guard let conversion = edge.conversion else { return width == rows }
        return conversion.map.count == rows && conversion.map.contains { !$0.isEmpty }
            && conversion.map.allSatisfy { $0.allSatisfy { (0..<width).contains($0) } }
    }
}

/// Reachability of the linked graph around one source node; see the file header.
private struct WiringLoopIndex {
    let source: NodeID
    let successors: [NodeID: [NodeID]]
    /// R ∩ Q: what the baseline reports as `cycleWithoutFeedback`.
    let looping: Set<NodeID>
    /// R and Q.
    let fromLoops: Set<NodeID>
    let toLoops: Set<NodeID>
    /// A: the nodes that reach the source, the source included.
    let ancestors: Set<NodeID>
    /// Q ∪ A, and R ∩ (Q ∪ A).
    let towardLoopsOrSource: Set<NodeID>
    let reachedTowardLoopsOrSource: Set<NodeID>

    init(links: [(NodeID, NodeID)], source: NodeID) {
        var successors: [NodeID: [NodeID]] = [:], predecessors: [NodeID: [NodeID]] = [:]
        for (from, to) in links {
            successors[from, default: []].append(to)
            predecessors[to, default: []].append(from)
        }
        self.source = source
        self.successors = successors
        fromLoops = Self.unpeeled(successors: successors, predecessors: predecessors)
        toLoops = Self.unpeeled(successors: predecessors, predecessors: successors)
        looping = fromLoops.intersection(toLoops)
        ancestors = Self.reachable(from: source, along: predecessors) { _ in true }
        towardLoopsOrSource = toLoops.union(ancestors)
        reachedTowardLoopsOrSource = fromLoops.intersection(towardLoopsOrSource)
    }

    /// The class of a bare, error-free wire source → `destination` (no other class applies).
    func connection(to destination: NodeID) -> WiringConnection {
        let closesCycle = ancestors.contains(destination)
        let bridges = fromLoops.contains(source) && toLoops.contains(destination)
        if closesCycle || bridges {
            let reached = Self.reachable(from: destination, along: successors) { towardLoopsOrSource.contains($0) }
            let added = reachedTowardLoopsOrSource.union(reached).subtracting(looping)
            if !added.isEmpty { return .feedbackOnly(cycle: added.sorted()) }
        }
        // Mirrors the classifier: a wire between nodes that already loop adds no error.
        if looping.contains(source), looping.contains(destination) {
            return .feedbackOnly(cycle: Set([source, destination]).sorted())
        }
        return .valid
    }

    /// Nodes that survive repeatedly removing nodes without a predecessor: with
    /// (successors, predecessors) these are the nodes reachable from a cycle; swapped, the nodes reaching one.
    private static func unpeeled(
        successors: [NodeID: [NodeID]], predecessors: [NodeID: [NodeID]]
    ) -> Set<NodeID> {
        var remaining = Set(successors.keys).union(predecessors.keys)
        var count = predecessors.mapValues(\.count)
        var queue = remaining.filter { count[$0, default: 0] == 0 }
        while let node = queue.popFirst() {
            remaining.remove(node)
            for next in successors[node] ?? [] {
                count[next, default: 0] -= 1
                if count[next] == 0 { queue.insert(next) }
            }
        }
        return remaining
    }

    /// `start` and every node reachable from it along `edges` through nodes that pass `allowed`.
    private static func reachable(
        from start: NodeID, along edges: [NodeID: [NodeID]], allowed: (NodeID) -> Bool
    ) -> Set<NodeID> {
        var found: Set<NodeID> = [start]
        var stack = [start]
        while let node = stack.popLast() {
            for next in edges[node] ?? [] where allowed(next) && found.insert(next).inserted {
                stack.append(next)
            }
        }
        return found
    }
}
