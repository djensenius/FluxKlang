//
//  WiringConnectionList.swift
//  FluxKlang
//
//  The compact Connections list (#101 WCL1; phone-compact-routing.md screens 1 "Connections" and 3 "Draft
//  added"): the active graph's edges grouped by destination node, so "what feeds Mains?" is one heading, with the
//  edges a review adds (Draft badge) or removes (struck through, "Will remove"). Every destination node has a
//  section, and a section without rows says "No connections". A pure value: it reads only the active graph, the
//  review diff and the injected node presence; nothing is drawn, edited or sent. `PerformanceWiringListView`
//  draws it (#101 WCL2) with the presence `PerformanceProjectSession.connectionList()` injects.
//

/// One connection of a section. Built only by `WiringConnectionList.make(active:review:presence:)`.
struct WiringConnectionRow: Hashable, Sendable {
    /// The edge's ID. A rerouted edge ID has two rows: its old route (`willRemove`) and its new one (`draft`).
    let edge: EdgeID
    /// The source node's title.
    let sourceText: String
    /// The destination node's title (the section's title).
    let destinationText: String
    /// The short conversion text (`mono>both`); nil without a conversion.
    let conversionText: String?
    /// The long conversion label (`Mono to both sides`); nil without a conversion.
    let conversionLabel: String?
    /// `fb` for a feedback edge; nil otherwise.
    let feedbackText: String?
    let badge: WiringConnectionBadge
    /// `Vocal to Mains, audio, mono to both sides, active.`
    let accessibilityLabel: String

    /// `Vocal → Mains`.
    var routeText: String { WiringConnectionListText.route(sourceText, destinationText) }

    /// `Vocal → Mains mono>both`, `Room Verb → Tape Echo fb`. A draft row leaves the short conversion out
    /// (`Vocal → Cue`): its long label is the `detailText` line, as on mock screen 3.
    var text: String {
        WiringConnectionListText.line(
            source: sourceText, destination: destinationText, conversion: detailText == nil ? conversionText : nil,
            feedback: feedbackText
        )
    }

    /// The second line of a draft row: its long conversion label. Nil for other rows and without a conversion.
    var detailText: String? { badge == .draft ? conversionLabel : nil }

    fileprivate init(
        edge: GraphEdge, badge: WiringConnectionBadge, nodes: [NodeID: GraphNode]
    ) {
        let source = nodes[edge.from.node]
        let port = source?.port(edge.from.port)
        let texts = edge.conversion.map { WiringConnectionListText.conversion($0, sourceChannels: port?.channels) }
        self.edge = edge.id
        sourceText = source.map(\.wiringTitle) ?? edge.from.node.rawValue
        destinationText = nodes[edge.to.node].map(\.wiringTitle) ?? edge.to.node.rawValue
        conversionText = texts?.short
        conversionLabel = texts?.label
        feedbackText = edge.feedback == nil ? nil : WiringConnectionListText.feedback
        self.badge = badge
        accessibilityLabel = WiringConnectionListText.rowLabel(
            route: "\(sourceText) to \(destinationText)", port: port, conversion: texts?.label,
            feedback: edge.feedback != nil, badge: badge
        )
    }
}

/// One destination node and every connection that feeds it. Built only by `WiringConnectionList.make`.
struct WiringConnectionSection: Hashable, Sendable {
    let node: NodeID
    /// The node's label, or its raw ID when the label is empty. Case is kept; a view may style it.
    let title: String
    /// The node's inputs: `2ch`, `MIDI`, `2ch, control`, or `no inputs`.
    let signalText: String
    let presence: WiringNodePresence
    /// Ordered by source title, then edge ID (UTF-8 bytes), then the old route before the new one.
    let rows: [WiringConnectionRow]
    /// `Cue, 2 channels, Unmapped on this host, no connections.`
    let accessibilityLabel: String

    /// `Mains (2ch)`, `Cue (2ch) Unmapped`.
    var heading: String {
        WiringConnectionListText.heading(title: title, signal: signalText, presence: presence)
    }

    /// `Unmapped`, `Missing`, `Lost/Muted`, or nil when the node is ready.
    var stateSuffix: String? { presence.headingSuffix }

    /// `No connections` when the section has no rows; nil otherwise.
    var emptyText: String? { rows.isEmpty ? WiringConnectionListText.noConnections : nil }

    fileprivate init(node: GraphNode, presence: WiringNodePresence, rows: [WiringConnectionRow]) {
        self.node = node.id
        title = node.wiringTitle
        signalText = WiringConnectionListText.inputs(node, WiringConnectionListText.signalText)
        self.presence = presence
        self.rows = rows
        accessibilityLabel = WiringConnectionListText.sectionLabel(
            title: title, signal: WiringConnectionListText.inputs(node, WiringConnectionListText.spokenSignal),
            presence: presence, rows: rows.count
        )
    }
}

/// The Connections list: one section per destination node.
struct WiringConnectionList: Hashable, Sendable {
    /// Ordered by title, then node ID, both compared as UTF-8 bytes (never `ContractID.<`, which compares
    /// `String`s, nor `String` equality, which is canonical equivalence).
    let sections: [WiringConnectionSection]

    private init(sections: [WiringConnectionSection]) {
        self.sections = sections
    }

    func section(for node: NodeID) -> WiringConnectionSection? {
        sections.first { $0.node == node }
    }

    /// The list of `active` with `review`'s added and removed edges (nil: no draft). The known nodes are the active
    /// nodes and the review's added nodes; the review's moved and removed nodes change no row (a removed node's
    /// edges are its removed edges). A section is made for every known node that is routable and has an input
    /// port, and for every node that is a row's destination. Every active edge is a row (`willRemove` when the
    /// review removes it, `none` otherwise) and every added edge is a `draft` row. `presence` must name every
    /// section's node, draft-added ones included, and only known nodes. Refused, with nothing listed, in the order
    /// of `WiringConnectionListRefusal`'s cases. Only the review's removed edges are checked against `active`; its
    /// moved and removed nodes are not, and a review that only adds is not checked against `active` at all.
    static func make(
        active: GraphDocument, review: WiringReviewDiff?, presence: [NodeID: WiringNodePresence]
    ) throws(WiringConnectionListRefusal) -> WiringConnectionList {
        let input = WiringConnectionListInput(active: active, review: review)
        try input.checkBounds()
        let nodes = try input.nodeTable()
        try input.checkEnds(nodes: nodes, presence: presence)
        let removed = try input.checkEdgeIDs()
        try input.checkRemoved()
        var rowsByNode: [NodeID: [WiringConnectionRow]] = [:]
        for edge in active.edges {
            let badge: WiringConnectionBadge = removed.contains(edge.id) ? .willRemove : .none
            rowsByNode[edge.to.node, default: []].append(WiringConnectionRow(edge: edge, badge: badge, nodes: nodes))
        }
        for edge in input.addedEdges {
            rowsByNode[edge.to.node, default: []].append(WiringConnectionRow(edge: edge, badge: .draft, nodes: nodes))
        }
        var destinations = nodes.values.filter { node in
            node.kind.isRoutable && node.ports.contains { $0.direction == .input }
        }
        let listed = Set(destinations.map(\.id))
        for id in rowsByNode.keys where !listed.contains(id) {
            if let node = nodes[id] { destinations.append(node) }
        }
        destinations.sort(by: precedes)
        var sections: [WiringConnectionSection] = []
        sections.reserveCapacity(destinations.count)
        for node in destinations {
            guard let state = presence[node.id] else { throw .presenceMissing(node.id) }
            let rows = (rowsByNode[node.id] ?? []).sorted(by: precedes)
            sections.append(WiringConnectionSection(node: node, presence: state, rows: rows))
        }
        return WiringConnectionList(sections: sections)
    }

    /// Title bytes, then node ID bytes. IDs are unique, so the order is total.
    private static func precedes(_ lhs: GraphNode, _ rhs: GraphNode) -> Bool {
        let left = lhs.wiringTitle, right = rhs.wiringTitle
        if !left.utf8.elementsEqual(right.utf8) { return left.utf8.lexicographicallyPrecedes(right.utf8) }
        return lhs.id.rawValue.utf8.lexicographicallyPrecedes(rhs.id.rawValue.utf8)
    }

    /// Source title bytes, then edge ID bytes, then badge rank (an edge ID appears at most twice: old and new).
    private static func precedes(_ lhs: WiringConnectionRow, _ rhs: WiringConnectionRow) -> Bool {
        if !lhs.sourceText.utf8.elementsEqual(rhs.sourceText.utf8) {
            return lhs.sourceText.utf8.lexicographicallyPrecedes(rhs.sourceText.utf8)
        }
        if !lhs.edge.rawValue.utf8.elementsEqual(rhs.edge.rawValue.utf8) {
            return lhs.edge.rawValue.utf8.lexicographicallyPrecedes(rhs.edge.rawValue.utf8)
        }
        return lhs.badge.rank < rhs.badge.rank
    }
}

/// The list's inputs, with the review's added nodes, added edges and removed edges taken out once, and its
/// checks in refusal order.
private struct WiringConnectionListInput {
    let active: GraphDocument
    let addedNodes: [GraphNode]
    let addedEdges: [GraphEdge]
    let removedEdges: [GraphEdge]

    init(active: GraphDocument, review: WiringReviewDiff?) {
        self.active = active
        var addedNodes: [GraphNode] = [], addedEdges: [GraphEdge] = [], removedEdges: [GraphEdge] = []
        for change in review?.changes ?? [] {
            switch change {
            case .addedNode(let node): addedNodes.append(node)
            case .addedEdge(let edge): addedEdges.append(edge)
            case .removedEdge(let edge): removedEdges.append(edge)
            case .movedNode, .removedNode: break
            }
        }
        self.addedNodes = addedNodes
        self.addedEdges = addedEdges
        self.removedEdges = removedEdges
    }

    func checkBounds() throws(WiringConnectionListRefusal) {
        do {
            typealias Limits = ProjectGraphLimits
            try Limits.check(active.nodes.count, maximum: Limits.nodes, path: "$.nodes")
            try Limits.check(active.edges.count, maximum: Limits.edges, path: "$.edges")
            try Limits.check(addedNodes.count, maximum: Limits.nodes, path: "$review.addedNodes")
            try Limits.check(addedEdges.count, maximum: Limits.edges, path: "$review.addedEdges")
            try Limits.check(removedEdges.count, maximum: Limits.edges, path: "$review.removedEdges")
            for node in active.nodes + addedNodes { try node.checkCollectionBounds() }
        } catch { throw .bounds(error) }
    }

    func nodeTable() throws(WiringConnectionListRefusal) -> [NodeID: GraphNode] {
        var nodes: [NodeID: GraphNode] = [:]
        nodes.reserveCapacity(active.nodes.count + addedNodes.count)
        for node in active.nodes + addedNodes {
            guard nodes.updateValue(node, forKey: node.id) == nil else { throw .duplicateNode(node.id) }
        }
        return nodes
    }

    func checkEnds(
        nodes: [NodeID: GraphNode], presence: [NodeID: WiringNodePresence]
    ) throws(WiringConnectionListRefusal) {
        for edge in active.edges + addedEdges + removedEdges {
            for id in [edge.from.node, edge.to.node] where nodes[id] == nil { throw .unknownNode(id) }
        }
        var least: NodeID?
        for id in presence.keys where nodes[id] == nil {
            if let current = least, !id.rawValue.utf8.lexicographicallyPrecedes(current.rawValue.utf8) { continue }
            least = id
        }
        if let least { throw .unknownNode(least) }
    }

    /// Returns the removed edge IDs.
    func checkEdgeIDs() throws(WiringConnectionListRefusal) -> Set<EdgeID> {
        var activeIDs = Set<EdgeID>(), addedIDs = Set<EdgeID>(), removedIDs = Set<EdgeID>()
        for edge in active.edges {
            guard activeIDs.insert(edge.id).inserted else { throw .duplicateEdge(edge.id) }
        }
        let removing = Set(removedEdges.map(\.id))
        for edge in addedEdges {
            guard addedIDs.insert(edge.id).inserted else { throw .duplicateEdge(edge.id) }
            if activeIDs.contains(edge.id), !removing.contains(edge.id) { throw .duplicateEdge(edge.id) }
        }
        for edge in removedEdges {
            guard removedIDs.insert(edge.id).inserted else { throw .duplicateEdge(edge.id) }
        }
        return removedIDs
    }

    /// Runs after `checkEdgeIDs`, so active edge IDs are unique. Endpoints are compared, not whole records: a record
    /// with a NaN feedback ceiling never equals itself.
    func checkRemoved() throws(WiringConnectionListRefusal) {
        var activeEdges: [EdgeID: GraphEdge] = [:]
        activeEdges.reserveCapacity(active.edges.count)
        for edge in active.edges { activeEdges[edge.id] = edge }
        for edge in removedEdges {
            guard let old = activeEdges[edge.id], old.from == edge.from, old.to == edge.to else {
                throw .removedEdgeNotActive(edge.id)
            }
        }
    }
}
