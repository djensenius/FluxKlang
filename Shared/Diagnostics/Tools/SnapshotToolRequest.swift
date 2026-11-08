//
//  SnapshotToolRequest.swift
//  FluxKlang
//
//  The six read-only snapshot tools and their bounded arguments. Arguments are
//  plain text and numbers; they are validated, never trusted, by
//  `SnapshotToolCatalog.run`.
//

/// Which tool a request or result belongs to.
enum SnapshotTool: Equatable, Sendable, CaseIterable {
    case listNodes
    case node
    case edges
    case parameter
    case routes
    case diagnostics
}

/// A window over the matching items: skip `offset`, then take at most `limit`.
struct SnapshotToolPage: Equatable, Sendable {
    var offset: Int
    var limit: Int
}

/// Equality compares every text argument by its UTF-8 bytes, because the identity of a snapshot item is its bytes:
/// `String ==` would treat "\u{e9}" and "e\u{301}" as one id.
enum SnapshotToolRequest: Equatable, Sendable {
    /// Node summaries in node ID order.
    case listNodes(SnapshotToolPage)
    /// One node with its ports.
    case node(id: String)
    /// Edges that start or end at the port, in edge ID order.
    case edges(node: String, port: String, page: SnapshotToolPage)
    case parameter(id: String)
    /// Routes in route ID order; `nil` keeps every availability.
    case routes(availability: NeutralSnapshot.RouteAvailability?, page: SnapshotToolPage)
    /// Diagnostics of exactly this severity, in diagnostic ID order.
    case diagnostics(severity: DiagnosticSeverity, page: SnapshotToolPage)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.listNodes(leftPage), .listNodes(rightPage)):
            leftPage == rightPage
        case let (.node(leftNode), .node(rightNode)):
            leftNode.utf8.elementsEqual(rightNode.utf8)
        case let (.edges(leftNode, leftPort, leftPage), .edges(rightNode, rightPort, rightPage)):
            leftNode.utf8.elementsEqual(rightNode.utf8)
                && leftPort.utf8.elementsEqual(rightPort.utf8)
                && leftPage == rightPage
        case let (.parameter(leftID), .parameter(rightID)):
            leftID.utf8.elementsEqual(rightID.utf8)
        case let (.routes(leftAvailability, leftPage), .routes(rightAvailability, rightPage)):
            leftAvailability == rightAvailability && leftPage == rightPage
        case let (.diagnostics(leftSeverity, leftPage), .diagnostics(rightSeverity, rightPage)):
            leftSeverity == rightSeverity && leftPage == rightPage
        default:
            false
        }
    }

    var tool: SnapshotTool {
        switch self {
        case .listNodes: .listNodes
        case .node: .node
        case .edges: .edges
        case .parameter: .parameter
        case .routes: .routes
        case .diagnostics: .diagnostics
        }
    }
}

/// The bounds a tool run keeps: UTF-8 bytes per result and the largest page `limit`.
/// Built only by the throwing `make` or `standard`; `run` validates them again where they are used.
struct SnapshotToolLimits: Equatable, Sendable {
    static let maximumBytesBounds = 1...16_384
    static let maximumPageLimitBounds = 1...64
    static let standard = SnapshotToolLimits(
        uncheckedMaximumBytes: maximumBytesBounds.upperBound,
        uncheckedMaximumPageLimit: maximumPageLimitBounds.upperBound
    )

    let maximumBytes: Int
    let maximumPageLimit: Int

    private init(uncheckedMaximumBytes: Int, uncheckedMaximumPageLimit: Int) {
        maximumBytes = uncheckedMaximumBytes
        maximumPageLimit = uncheckedMaximumPageLimit
    }

    static func make(maximumBytes: Int, maximumPageLimit: Int) throws(SnapshotToolRefusal) -> SnapshotToolLimits {
        let limits = SnapshotToolLimits(
            uncheckedMaximumBytes: maximumBytes, uncheckedMaximumPageLimit: maximumPageLimit
        )
        try limits.validate()
        return limits
    }

    func validate() throws(SnapshotToolRefusal) {
        guard Self.maximumBytesBounds.contains(maximumBytes),
              Self.maximumPageLimitBounds.contains(maximumPageLimit) else {
            throw .invalidToolLimits(maximumBytes: maximumBytes, maximumPageLimit: maximumPageLimit)
        }
    }
}
