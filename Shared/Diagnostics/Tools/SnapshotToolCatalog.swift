//
//  SnapshotToolCatalog.swift
//  FluxKlang
//
//  The executor of the six read-only tools. It reads one `NeutralSnapshot`
//  through its public queries and stored arrays, takes everything by value and
//  keeps no state, so a refusal cannot have changed anything.
//

enum SnapshotToolCatalog {
    /// Identifier arguments are 1...128 UTF-8 bytes.
    static let identifierBytes = 1...ContractID<NodeTag>.maximumLength

    /// Runs one request. The checks run in this order and the first failing one is reported: the tool limits,
    /// the identifier arguments (first argument first), the page `limit`, the page `offset`, whether the
    /// identifier exists (`notFound`), and last whether the first item fits the byte cap (`resultTooLarge`).
    /// Items are the snapshot's own order (by ID). Page items beyond the byte cap are trimmed from the end.
    static func run(
        _ request: SnapshotToolRequest, on snapshot: NeutralSnapshot, limits: SnapshotToolLimits
    ) throws(SnapshotToolRefusal) -> SnapshotToolResult {
        try limits.validate()
        switch request {
        case .listNodes(let page):
            try validate(page, maximumOffset: snapshot.limits.nodes, limits: limits)
            let summaries = snapshot.nodes.map { SnapshotToolItem.nodeSummary(summary(of: $0)) }
            return try answer(.listNodes, summaries, page: page, snapshot: snapshot, limits: limits)
        // The whole node is one item, so a node with many ports or a long label can alone exceed the byte cap;
        // the answer is then `resultTooLarge` (there is no partial node).
        case .node(let text):
            let id: NodeID = try parse(text, .nodeID)
            guard let node = snapshot.node(id) else { throw .notFound }
            return try answer(.node, [.node(node)], page: Self.lookupPage, snapshot: snapshot, limits: limits)
        case let .edges(nodeText, portText, page):
            let node: NodeID = try parse(nodeText, .nodeID)
            let port: PortID = try parse(portText, .portID)
            try validate(page, maximumOffset: snapshot.limits.edges, limits: limits)
            guard snapshot.node(node)?.ports.contains(where: { $0.id == port }) == true else { throw .notFound }
            let items = snapshot.edges(node: node, port: port).map { SnapshotToolItem.edge($0) }
            return try answer(.edges, items, page: page, snapshot: snapshot, limits: limits)
        case .parameter(let text):
            let id: ParameterID = try parse(text, .parameterID)
            guard let parameter = snapshot.parameter(id) else { throw .notFound }
            return try answer(.parameter, [.parameter(parameter)], page: Self.lookupPage, snapshot: snapshot,
                              limits: limits)
        case let .routes(availability, page):
            try validate(page, maximumOffset: snapshot.limits.routes, limits: limits)
            let items = snapshot.routes.filter { availability == nil || $0.availability == availability }
                .map { SnapshotToolItem.route($0) }
            return try answer(.routes, items, page: page, snapshot: snapshot, limits: limits)
        case let .diagnostics(severity, page):
            try validate(page, maximumOffset: snapshot.limits.diagnostics, limits: limits)
            let items = snapshot.diagnostics(severity: severity).map { SnapshotToolItem.diagnostic($0) }
            return try answer(.diagnostics, items, page: page, snapshot: snapshot, limits: limits)
        }
    }

    private static let lookupPage = SnapshotToolPage(offset: 0, limit: 1)

    private static func summary(of node: NeutralSnapshot.Node) -> NeutralSnapshot.NodeSummary {
        NeutralSnapshot.NodeSummary(
            id: node.id, kind: node.kind, label: node.label, role: node.role, portCount: node.ports.count
        )
    }

    /// The byte length is checked before any identifier is built from the text.
    private static func parse<Tag: ContractIDTag>(
        _ text: String, _ field: SnapshotToolRefusal.Field
    ) throws(SnapshotToolRefusal) -> ContractID<Tag> {
        guard identifierBytes.contains(text.utf8.count), let id = ContractID<Tag>(rawValue: text) else {
            throw .invalidIdentifier(field)
        }
        return id
    }

    /// The category cap may be zero or below in a snapshot built with non-positive limits: only offset 0 is valid.
    private static func validate(
        _ page: SnapshotToolPage, maximumOffset: Int, limits: SnapshotToolLimits
    ) throws(SnapshotToolRefusal) {
        guard (1...limits.maximumPageLimit).contains(page.limit) else { throw .limitOutOfRange(page.limit) }
        guard (0...max(0, maximumOffset)).contains(page.offset) else { throw .pageOutOfRange(page.offset) }
    }

    /// Slices the page out of `matching`, then keeps the longest prefix that fits the byte cap.
    private static func answer(
        _ tool: SnapshotTool, _ matching: [SnapshotToolItem], page: SnapshotToolPage, snapshot: NeutralSnapshot,
        limits: SnapshotToolLimits
    ) throws(SnapshotToolRefusal) -> SnapshotToolResult {
        var kept: [SnapshotToolItem] = []
        var total = 0
        for item in matching.dropFirst(page.offset).prefix(page.limit) {
            let size = item.byteCount
            guard total + size <= limits.maximumBytes else {
                if kept.isEmpty { throw .resultTooLarge(size) }
                break
            }
            total += size
            kept.append(item)
        }
        return SnapshotToolResult.assemble(
            tool: tool, items: kept, matched: matching.count, page: page, snapshotTruncation: snapshot.truncation
        )
    }
}
