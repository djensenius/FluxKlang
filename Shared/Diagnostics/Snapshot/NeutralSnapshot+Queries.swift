//
//  NeutralSnapshot+Queries.swift
//  FluxKlang
//
//  Read-only lookups over a built snapshot. Collections are sorted by ID, so
//  ID lookups are binary searches.
//

import Foundation

extension NeutralSnapshot {
    func node(_ id: NodeID) -> Node? {
        Self.find(id, in: nodes, by: \.id)
    }

    func parameter(_ id: ParameterID) -> Parameter? {
        Self.find(id, in: parameters, by: \.id)
    }

    func route(_ id: RouteID) -> Route? {
        Self.find(id, in: routes, by: \.id)
    }

    /// Edges that start or end at `port` of `node`, sorted by edge ID.
    func edges(node: NodeID, port: PortID) -> [Edge] {
        let endpoint = Endpoint(node: node, port: port)
        return edges.filter { $0.touches(endpoint) }
    }

    /// Routes that cannot currently carry signal, sorted by route ID.
    var unavailableRoutes: [Route] {
        routes.filter { $0.availability != .available }
    }

    /// Diagnostics of exactly `severity`, sorted by diagnostic ID.
    func diagnostics(severity: DiagnosticSeverity) -> [Diagnostic] {
        diagnostics.filter { $0.severity == severity }
    }

    /// Whether `subject` names something kept in this snapshot.
    func contains(_ subject: DiagnosticSubject) -> Bool {
        Self.isPresent(subject, nodes: nodes, edges: edges, parameters: parameters, routes: routes)
    }

    static func isPresent(
        _ subject: DiagnosticSubject, nodes: [Node], edges: [Edge], parameters: [Parameter], routes: [Route]
    ) -> Bool {
        switch subject {
        case .graph:
            true
        case .node(let id):
            find(id, in: nodes, by: \.id) != nil
        case let .port(node, port):
            find(node, in: nodes, by: \.id)?.ports.contains { $0.id == port } == true
        case .edge(let id):
            find(id, in: edges, by: \.id) != nil
        case .parameter(let id):
            find(id, in: parameters, by: \.id) != nil
        case .route(let id):
            find(id, in: routes, by: \.id) != nil
        }
    }

    private static func find<Element, ID: Comparable>(
        _ target: ID, in sorted: [Element], by id: (Element) -> ID
    ) -> Element? {
        var low = sorted.startIndex
        var high = sorted.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            let candidate = id(sorted[middle])
            if candidate == target { return sorted[middle] }
            if candidate < target { low = middle + 1 } else { high = middle }
        }
        return nil
    }
}
