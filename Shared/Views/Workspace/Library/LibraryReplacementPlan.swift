//
//  LibraryReplacementPlan.swift
//  FluxKlang
//
//  What "Replace with..." does to a Missing plugin node (#101 REP1; library-inspector.md "Replace with..."):
//  which edges the replacement keeps, which it drops and why, and the graph edits that carry it out. A pure value:
//  it reads a graph and a layout, never edits a draft and never bypasses a dropped edge. Ports match by port ID
//  only, and only when direction, signal and channel count are all equal. Nothing calls it yet.
//

/// The plan to replace one plugin node by a node with another layout. Built only by `make(replacing:with:as:in:)`.
struct LibraryReplacementPlan: Hashable, Sendable {
    let replacedNode: NodeID
    /// The node to add: a plugin with the layout's name and ports (in declared order), the old node's position and
    /// no capabilities.
    let replacementNode: GraphNode
    /// Edges touching the old node that the replacement takes over, ordered by edge ID (UTF-8 bytes).
    let keptEdges: [LibraryReplacementKeptEdge]
    /// Edges touching the old node that the replacement cannot take over, ordered by edge ID (UTF-8 bytes).
    let droppedEdges: [LibraryReplacementDrop]
    /// The summary line, then one line per dropped edge.
    let reviewLines: [String]
    /// `removeNode(old)`, `addNode(replacementNode)`, then one `connect` per kept edge. Dropped edges go with the
    /// old node; no edge is added between the nodes on either side of the old one.
    let graphEdits: [GraphEdit]

    var ports: [GraphPort] { replacementNode.ports }

    private init(
        old: GraphNode, replacement: GraphNode, kept: [LibraryReplacementKeptEdge],
        dropped: [LibraryReplacementDrop], name: String
    ) {
        replacedNode = old.id
        replacementNode = replacement
        keptEdges = kept
        droppedEdges = dropped
        reviewLines = [
            LibraryReplacementText.summary(replacing: old.id, name: name, kept: kept.count, dropped: dropped.count)
        ] + dropped.map(LibraryReplacementText.dropLine)
        graphEdits = [.removeNode(old.id), .addNode(replacement)] + kept.map { .connect($0.rewritten) }
    }

    /// Plans the replacement of `node` by `layout`, the new node being `replacementID`. Refused, with nothing
    /// planned, in the order of `LibraryReplacementRefusal`'s cases, except that the edit-count bound (`$.edits`)
    /// is checked last: it depends on which edges are kept. Whether the node is Missing is not checked.
    static func make(
        replacing node: NodeID, with layout: LibraryReplacementLayout, as replacementID: NodeID, in graph: GraphDocument
    ) throws(LibraryReplacementRefusal) -> LibraryReplacementPlan {
        do { try graph.checkCollectionBounds() } catch { throw .bounds(error) }
        do {
            try ProjectGraphLimits.check(
                layout.ports.count, maximum: ProjectGraphLimits.portsPerNode, path: "$.replacement.ports"
            )
        } catch { throw .bounds(error) }
        let old = try plugin(node, in: graph)
        if graph.nodes.contains(where: { $0.id == replacementID }) { throw .replacementIDInUse(replacementID) }
        var seenPorts = Set<PortID>()
        for port in layout.ports where !seenPorts.insert(port.id).inserted { throw .duplicateLayoutPort(port.id) }
        var seenEdges = Set<EdgeID>()
        let touching = graph.edges.filter { $0.from.node == node || $0.to.node == node }
        for edge in touching where !seenEdges.insert(edge.id).inserted { throw .duplicateEdge(edge.id) }

        let replacement = GraphNode(
            id: replacementID, kind: .plugin, label: layout.name, ports: layout.ports.map(\.graphPort),
            position: old.position
        )
        var kept: [LibraryReplacementKeptEdge] = []
        var dropped: [LibraryReplacementDrop] = []
        for edge in touching.sorted(by: { precedes($0.id, $1.id) }) {
            if let miss = mismatch(edge, old: old, layout: layout) {
                dropped.append(LibraryReplacementDrop(edge: edge, reason: miss.reason, text: miss.text))
            } else {
                kept.append(LibraryReplacementKeptEdge(
                    original: edge, rewritten: moved(edge, from: node, to: replacementID)
                ))
            }
        }
        try checkEditCount(kept: kept.count)
        return LibraryReplacementPlan(
            old: old, replacement: replacement, kept: kept, dropped: dropped, name: layout.name
        )
    }

    /// `removeNode`, `addNode` and one `connect` per kept edge must fit one `GraphEdit` batch.
    private static func checkEditCount(kept: Int) throws(LibraryReplacementRefusal) {
        do {
            try ProjectGraphLimits.check(2 + kept, maximum: ProjectGraphLimits.edits, path: "$.edits")
        } catch { throw .bounds(error) }
    }

    /// Whether the picker should offer `layout`: at least one edge touching `node` is kept, or none touches it.
    /// Refused as `make` is.
    static func isCompatible(
        _ layout: LibraryReplacementLayout, replacing node: NodeID, as replacementID: NodeID, in graph: GraphDocument
    ) throws(LibraryReplacementRefusal) -> Bool {
        let plan = try make(replacing: node, with: layout, as: replacementID, in: graph)
        return !plan.keptEdges.isEmpty || plan.droppedEdges.isEmpty
    }

    /// The compatible layouts, ordered by key (UTF-8 bytes; equal keys keep their given order). Refused as `make`
    /// is, for any layout.
    static func compatibleLayouts(
        _ layouts: [LibraryReplacementLayout], replacing node: NodeID, as replacementID: NodeID, in graph: GraphDocument
    ) throws(LibraryReplacementRefusal) -> [LibraryReplacementLayout] {
        var compatible: [(offset: Int, layout: LibraryReplacementLayout)] = []
        for (offset, layout) in layouts.enumerated()
        where try isCompatible(layout, replacing: node, as: replacementID, in: graph) {
            compatible.append((offset, layout))
        }
        compatible.sort { lhs, rhs in
            if lhs.layout.key.utf8.elementsEqual(rhs.layout.key.utf8) { return lhs.offset < rhs.offset }
            return lhs.layout.key.utf8.lexicographicallyPrecedes(rhs.layout.key.utf8)
        }
        return compatible.map(\.layout)
    }

    /// The plugin to replace, after the node checks of `LibraryReplacementRefusal`.
    private static func plugin(_ node: NodeID, in graph: GraphDocument) throws(LibraryReplacementRefusal) -> GraphNode {
        var seenNodes = Set<NodeID>()
        for other in graph.nodes where !seenNodes.insert(other.id).inserted { throw .duplicateNode(other.id) }
        guard let old = graph.nodes.first(where: { $0.id == node }) else { throw .unknownNode(node) }
        guard old.kind == .plugin else { throw .notAPlugin(node) }
        var seenPorts = Set<PortID>()
        for port in old.ports where !seenPorts.insert(port.id).inserted {
            throw .duplicatePort(PortAddress(node: node, port: port.id))
        }
        return old
    }

    /// The first failing end of `edge` on the old node (`from`, then `to`), or nil when every such end matches.
    private static func mismatch(
        _ edge: GraphEdge, old: GraphNode, layout: LibraryReplacementLayout
    ) -> (reason: LibraryReplacementDropReason, text: String)? {
        for end in [edge.from, edge.to] where end.node == old.id {
            if let miss = mismatch(end.port, old: old, layout: layout) { return miss }
        }
        return nil
    }

    /// An undeclared old port cannot be compared, so it counts as missing.
    private static func mismatch(
        _ id: PortID, old: GraphNode, layout: LibraryReplacementLayout
    ) -> (reason: LibraryReplacementDropReason, text: String)? {
        guard let was = old.port(id), let now = layout.ports.first(where: { $0.id == id }) else {
            return (.portMissing, LibraryReplacementText.portMissing(id))
        }
        if now.direction != was.direction {
            return (.directionChanged, LibraryReplacementText.directionChanged(id, now: now.direction))
        }
        if now.signal != was.signal {
            return (.signalChanged, LibraryReplacementText.signalChanged(id, now: now.signal, was: was.signal))
        }
        if now.channels != was.channels {
            return (.channelsChanged, LibraryReplacementText.channelsChanged(id, now: now.channels, was: was.channels))
        }
        return nil
    }

    /// `edge` with each endpoint on `old` moved to `new`; the port, the edge ID and every other field stay.
    private static func moved(_ edge: GraphEdge, from old: NodeID, to new: NodeID) -> GraphEdge {
        var result = edge
        if result.from.node == old { result.from.node = new }
        if result.to.node == old { result.to.node = new }
        return result
    }

    /// UTF-8 bytes of the raw IDs (never `ContractID <`, which compares `String`s by Unicode).
    private static func precedes(_ lhs: EdgeID, _ rhs: EdgeID) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }
}
