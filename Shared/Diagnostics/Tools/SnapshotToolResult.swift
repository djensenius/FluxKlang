//
//  SnapshotToolResult.swift
//  FluxKlang
//
//  What a snapshot tool returns: copies of snapshot facts (labels stay
//  `UntrustedLabel`), exact counts for what was left out and the snapshot's own
//  truncation record, so a clipped snapshot is never mistaken for a complete one.
//

extension NeutralSnapshot {
    /// A node without its ports, for listings.
    struct NodeSummary: Equatable, Sendable {
        let id: NodeID
        let kind: NodeKind
        let label: UntrustedLabel
        let role: RoleID?
        /// Ports the snapshot kept for this node.
        let portCount: Int
    }
}

/// One returned fact. Each case holds the snapshot's own value or a summary of it.
enum SnapshotToolItem: Equatable, Sendable {
    case nodeSummary(NeutralSnapshot.NodeSummary)
    case node(NeutralSnapshot.Node)
    case edge(NeutralSnapshot.Edge)
    case parameter(NeutralSnapshot.Parameter)
    case route(NeutralSnapshot.Route)
    case diagnostic(NeutralSnapshot.Diagnostic)

    /// The UTF-8 bytes of every ID and label string the item carries; `SnapshotToolResult.bytes` sums these.
    /// nodeSummary: id, label, role. node: id, label, role, asset, graph, and each port's id and label.
    /// edge: edge id and both endpoints' node and port ids. parameter: id and node. route: id, role, device.
    /// diagnostic: id, summary and the subject's ids.
    var byteCount: Int {
        switch self {
        case .nodeSummary(let summary):
            Self.bytes(summary.id, summary.label.text, summary.role)
        case .node(let node):
            node.ports.reduce(Self.bytes(node.id, node.label.text, node.role, node.asset, node.graph)) { total, port in
                total + Self.bytes(port.id, port.label?.text)
            }
        case .edge(let edge):
            Self.bytes(edge.id, edge.from.node, edge.from.port, edge.to.node, edge.to.port)
        case .parameter(let parameter):
            Self.bytes(parameter.id, parameter.node)
        case .route(let route):
            Self.bytes(route.id, route.role, route.device)
        case .diagnostic(let diagnostic):
            Self.bytes(diagnostic.id, diagnostic.summary.text) + Self.bytes(of: diagnostic.subject)
        }
    }

    private static func bytes(_ parts: (any CustomStringConvertible)?...) -> Int {
        parts.reduce(0) { $0 + ($1?.description.utf8.count ?? 0) }
    }

    private static func bytes(of subject: DiagnosticSubject?) -> Int {
        switch subject {
        case nil, .graph?: 0
        case .node(let id)?: bytes(id)
        case let .port(node, port)?: bytes(node, port)
        case .edge(let id)?: bytes(id)
        case .parameter(let id)?: bytes(id)
        case .route(let id)?: bytes(id)
        }
    }
}

/// A tool answer. Built only by `assemble`, which derives every count from its inputs.
///
/// - `matched`: items matching the request over the whole category, across all pages.
/// - `offset`, `limit`: the page asked for (a lookup tool reports offset 0, limit 1).
/// - `returned`: `items.count`.
/// - `trimmedByBytes`: items of the requested page left out to fit the byte cap.
/// - `omitted`: `matched - returned`: everything matching that is not in `items`, whether it lies before the
///   page, after it, or was trimmed.
/// - `nextOffset`: where to continue (`offset + returned`), or `nil` when nothing matching lies after `items`.
/// - `snapshotTruncation`: the snapshot's own record, unchanged.
/// - `bytes`: the sum of `byteCount` over `items`.
struct SnapshotToolResult: Equatable, Sendable {
    let tool: SnapshotTool
    let items: [SnapshotToolItem]
    let matched: Int
    let returned: Int
    let omitted: Int
    let offset: Int
    let limit: Int
    let trimmedByBytes: Int
    let nextOffset: Int?
    let snapshotTruncation: NeutralSnapshot.Truncation
    let bytes: Int

    private init(tool: SnapshotTool, items: [SnapshotToolItem], matched: Int, page: SnapshotToolPage,
                 snapshotTruncation: NeutralSnapshot.Truncation) {
        let available = max(0, min(page.limit, matched - page.offset))
        self.tool = tool
        self.items = items
        self.matched = matched
        returned = items.count
        omitted = matched - items.count
        offset = page.offset
        limit = page.limit
        trimmedByBytes = available - items.count
        nextOffset = page.offset + items.count < matched ? page.offset + items.count : nil
        self.snapshotTruncation = snapshotTruncation
        bytes = items.reduce(0) { $0 + $1.byteCount }
    }

    /// `items` must be a prefix of the page's items; `matched` counts the whole category. This does not enforce
    /// the byte cap: keeping `items` within it is the caller's job (the catalog is the only caller).
    static func assemble(tool: SnapshotTool, items: [SnapshotToolItem], matched: Int, page: SnapshotToolPage,
                         snapshotTruncation: NeutralSnapshot.Truncation) -> SnapshotToolResult {
        SnapshotToolResult(tool: tool, items: items, matched: matched, page: page,
                           snapshotTruncation: snapshotTruncation)
    }
}
