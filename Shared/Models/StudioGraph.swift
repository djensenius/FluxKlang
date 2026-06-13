//
//  StudioGraph.swift
//  FluxKlang
//
//  A semantic signal-flow graph for the redesigned studio workflow. Unlike the
//  WING-oriented `ChainGraph`, these nodes are user concepts: instruments,
//  effects, and controllable endpoints/stems. The WING-specific buses, returns
//  and channels are compiler details layered underneath this model.
//

import CoreGraphics
import Foundation

/// The simple controls every generated endpoint/stem may expose.
enum StudioEndpointControl: String, Codable, Hashable, Sendable, CaseIterable {
    case volume
    case mute
    case labelColor
    case metering
}

/// Where an endpoint ultimately lands.
enum StudioEndpointDestination: String, Codable, Hashable, Sendable, CaseIterable {
    case finalMix
    case space
    case custom
}

/// A controllable destination/stem on the semantic canvas.
struct StudioEndpoint: Identifiable, Codable, Hashable, Sendable {
    static let defaultControls: Set<StudioEndpointControl> = [.volume, .mute, .labelColor, .metering]

    var id: UUID
    var name: String
    var destination: StudioEndpointDestination
    var controls: Set<StudioEndpointControl>
    /// Stable, UI-level color token. The actual SwiftUI color is resolved by the view layer.
    var colorName: String?
    /// Space endpoints can be positioned independently.
    var placement: VoicePlacement?

    init(
        id: UUID = UUID(),
        name: String,
        destination: StudioEndpointDestination,
        controls: Set<StudioEndpointControl> = StudioEndpoint.defaultControls,
        colorName: String? = nil,
        placement: VoicePlacement? = nil
    ) {
        self.id = id
        self.name = name
        self.destination = destination
        self.controls = controls
        self.colorName = colorName
        self.placement = placement
    }
}

/// What a semantic studio node represents.
enum StudioNodeKind: Codable, Hashable, Sendable {
    case instrument(Equipment.ID)
    case effect(Effect.ID)
    case endpoint(StudioEndpoint.ID)
}

/// A node placed on the studio canvas.
struct StudioNode: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: StudioNodeKind
    var title: String
    var position: CGPoint

    init(id: UUID = UUID(), kind: StudioNodeKind, title: String, position: CGPoint = .zero) {
        self.id = id
        self.kind = kind
        self.title = title
        self.position = position
    }
}

enum StudioPortSide: String, Codable, Hashable, Sendable {
    case input
    case output
}

struct StudioPortRef: Codable, Hashable, Sendable {
    var nodeID: UUID
    var side: StudioPortSide
    var port: Int
}

struct StudioEdge: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var from: StudioPortRef
    var to: StudioPortRef

    init(id: UUID = UUID(), from: StudioPortRef, to: StudioPortRef) {
        self.id = id
        self.from = from
        self.to = to
    }
}

/// The freeform semantic graph: nodes plus user-drawn wires.
struct StudioGraph: Codable, Hashable, Sendable {
    var nodes: [StudioNode]
    var edges: [StudioEdge]

    init(nodes: [StudioNode] = [], edges: [StudioEdge] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    func node(_ id: UUID) -> StudioNode? {
        nodes.first { $0.id == id }
    }
}

extension StudioGraph {
    mutating func addNode(_ node: StudioNode) {
        nodes.append(node)
    }

    mutating func moveNode(_ id: StudioNode.ID, to position: CGPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].position = position
    }

    mutating func removeNode(_ id: StudioNode.ID) {
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.from.nodeID == id || $0.to.nodeID == id }
    }

    /// Connects output -> input. Fan-out and fan-in are both allowed; exact
    /// duplicate wires are ignored so the same branch is not compiled twice.
    mutating func connect(from origin: StudioPortRef, to destination: StudioPortRef) {
        guard origin.side == .output, destination.side == .input else { return }
        guard !edges.contains(where: { $0.from == origin && $0.to == destination }) else { return }
        edges.append(StudioEdge(from: origin, to: destination))
    }

    mutating func removeEdge(_ id: StudioEdge.ID) {
        edges.removeAll { $0.id == id }
    }
}

/// A planned endpoint/stem, before it is lowered into concrete WING settings.
struct StudioEndpointPlan: Identifiable, Hashable, Sendable {
    var endpoint: StudioEndpoint
    var nodeID: StudioNode.ID
    var sourceNodeIDs: Set<StudioNode.ID>
    var edgeIDs: Set<StudioEdge.ID>

    var id: StudioEndpoint.ID { endpoint.id }
}

struct StudioRoutingIssue: Identifiable, Hashable, Sendable {
    enum Severity: String, Hashable, Sendable {
        case warning
        case error
    }

    enum Kind: Hashable, Sendable {
        case missingNode(edgeID: StudioEdge.ID)
        case invalidDirection(edgeID: StudioEdge.ID)
        case missingEndpoint(nodeID: StudioNode.ID, endpointID: StudioEndpoint.ID)
        case unfinishedBranch(nodeID: StudioNode.ID)
        case cycle(nodeID: StudioNode.ID)
    }

    var severity: Severity
    var kind: Kind
    var message: String

    var id: String {
        "\(severity.rawValue)-\(message)-\(kind)"
    }
}

struct StudioRoutingPlan: Hashable, Sendable {
    var endpointPlans: [StudioEndpointPlan]
    var issues: [StudioRoutingIssue]
    var appliableEdgeIDs: Set<StudioEdge.ID>

    var hasErrors: Bool { issues.contains { $0.severity == .error } }
    var hasWarnings: Bool { issues.contains { $0.severity == .warning } }
}

enum StudioRoutingPlanner {
    static func plan(for graph: StudioGraph, endpoints: [StudioEndpoint]) -> StudioRoutingPlan {
        let endpointByID = Dictionary(endpoints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let nodeByID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let validEdges = graph.edges.filter { edge in
            edge.from.side == .output && edge.to.side == .input &&
                nodeByID[edge.from.nodeID] != nil && nodeByID[edge.to.nodeID] != nil
        }
        let outgoing = Dictionary(grouping: validEdges, by: \.from.nodeID)
        let incoming = Dictionary(grouping: validEdges, by: \.to.nodeID)
        let context = PlannerGraphContext(
            incoming: incoming,
            outgoing: outgoing,
            nodeByID: nodeByID,
            endpointByID: endpointByID
        )

        var issues = structuralIssues(for: graph, endpointByID: endpointByID, nodeByID: nodeByID)
        var endpointPlans: [StudioEndpointPlan] = []

        for node in graph.nodes {
            guard case .endpoint(let endpointID) = node.kind,
                  let endpoint = endpointByID[endpointID] else { continue }
            var visited: Set<StudioNode.ID> = []
            var edgeIDs: Set<StudioEdge.ID> = []
            let sourceIDs = sourceNodes(
                reaching: node.id,
                context: context,
                visited: &visited,
                edgeIDs: &edgeIDs,
                issues: &issues
            )
            endpointPlans.append(StudioEndpointPlan(
                endpoint: endpoint,
                nodeID: node.id,
                sourceNodeIDs: sourceIDs,
                edgeIDs: edgeIDs
            ))
        }

        var reachabilityCache: [StudioNode.ID: Bool] = [:]
        for node in graph.nodes where hasOutputIntent(node) && !isEndpoint(node) {
            var visiting: Set<StudioNode.ID> = []
            if !reachesEndpoint(
                from: node.id,
                context: context,
                visiting: &visiting,
                cache: &reachabilityCache,
                issues: &issues
            ) {
                issues.append(.warning(
                    .unfinishedBranch(nodeID: node.id),
                    "\(node.title) does not reach an endpoint yet."
                ))
            }
        }

        return StudioRoutingPlan(
            endpointPlans: endpointPlans,
            issues: uniqued(issues),
            appliableEdgeIDs: Set(endpointPlans.flatMap(\.edgeIDs))
        )
    }

    private static func structuralIssues(
        for graph: StudioGraph,
        endpointByID: [StudioEndpoint.ID: StudioEndpoint],
        nodeByID: [StudioNode.ID: StudioNode]
    ) -> [StudioRoutingIssue] {
        var issues: [StudioRoutingIssue] = []
        for edge in graph.edges {
            if edge.from.side != .output || edge.to.side != .input {
                issues.append(.error(.invalidDirection(edgeID: edge.id), "A wire is not output to input."))
            }
            if nodeByID[edge.from.nodeID] == nil || nodeByID[edge.to.nodeID] == nil {
                issues.append(.error(.missingNode(edgeID: edge.id), "A wire points at a missing node."))
            }
        }
        for node in graph.nodes {
            if case .endpoint(let endpointID) = node.kind, endpointByID[endpointID] == nil {
                issues.append(.error(
                    .missingEndpoint(nodeID: node.id, endpointID: endpointID),
                    "\(node.title) points at a missing endpoint."
                ))
            }
        }
        return issues
    }

    private static func sourceNodes(
        reaching nodeID: StudioNode.ID,
        context: PlannerGraphContext,
        visited: inout Set<StudioNode.ID>,
        edgeIDs: inout Set<StudioEdge.ID>,
        issues: inout [StudioRoutingIssue]
    ) -> Set<StudioNode.ID> {
        guard let node = context.nodeByID[nodeID] else { return [] }
        guard !visited.contains(nodeID) else {
            issues.append(.warning(.cycle(nodeID: nodeID), "\(node.title) is part of a cycle."))
            return []
        }
        let edges = context.incoming[nodeID] ?? []
        if edges.isEmpty {
            return isEndpoint(node) ? [] : [nodeID]
        }
        visited.insert(nodeID)
        var sources: Set<StudioNode.ID> = []
        for edge in edges {
            edgeIDs.insert(edge.id)
            sources.formUnion(sourceNodes(
                reaching: edge.from.nodeID,
                context: context,
                visited: &visited,
                edgeIDs: &edgeIDs,
                issues: &issues
            ))
        }
        visited.remove(nodeID)
        return sources
    }

    private static func reachesEndpoint(
        from nodeID: StudioNode.ID,
        context: PlannerGraphContext,
        visiting: inout Set<StudioNode.ID>,
        cache: inout [StudioNode.ID: Bool],
        issues: inout [StudioRoutingIssue]
    ) -> Bool {
        if let cached = cache[nodeID] { return cached }
        guard let node = context.nodeByID[nodeID] else { return false }
        if case .endpoint(let endpointID) = node.kind {
            let valid = context.endpointByID[endpointID] != nil
            cache[nodeID] = valid
            return valid
        }
        guard !visiting.contains(nodeID) else {
            issues.append(.warning(.cycle(nodeID: nodeID), "\(node.title) is part of a cycle."))
            return false
        }
        visiting.insert(nodeID)
        let reaches = (context.outgoing[nodeID] ?? []).contains { edge in
            reachesEndpoint(
                from: edge.to.nodeID,
                context: context,
                visiting: &visiting,
                cache: &cache,
                issues: &issues
            )
        }
        visiting.remove(nodeID)
        cache[nodeID] = reaches
        return reaches
    }

    private static func hasOutputIntent(_ node: StudioNode) -> Bool {
        !isEndpoint(node)
    }

    private static func isEndpoint(_ node: StudioNode) -> Bool {
        if case .endpoint = node.kind { return true }
        return false
    }

    private static func uniqued(_ issues: [StudioRoutingIssue]) -> [StudioRoutingIssue] {
        var seen: Set<StudioRoutingIssue.Kind> = []
        var result: [StudioRoutingIssue] = []
        for issue in issues where !seen.contains(issue.kind) {
            seen.insert(issue.kind)
            result.append(issue)
        }
        return result
    }
}

private struct PlannerGraphContext {
    var incoming: [StudioNode.ID: [StudioEdge]]
    var outgoing: [StudioNode.ID: [StudioEdge]]
    var nodeByID: [StudioNode.ID: StudioNode]
    var endpointByID: [StudioEndpoint.ID: StudioEndpoint]
}

private extension StudioRoutingIssue {
    static func warning(_ kind: Kind, _ message: String) -> StudioRoutingIssue {
        StudioRoutingIssue(severity: .warning, kind: kind, message: message)
    }

    static func error(_ kind: Kind, _ message: String) -> StudioRoutingIssue {
        StudioRoutingIssue(severity: .error, kind: kind, message: message)
    }
}
