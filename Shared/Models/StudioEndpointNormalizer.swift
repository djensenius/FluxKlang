import Foundation

struct NormalizedStudioEndpoints: Hashable, Sendable {
    var graph: StudioGraph
    var endpoints: [StudioEndpoint]
}

enum StudioEndpointNormalizer {
    static func normalize(
        graph: StudioGraph,
        endpoints: [StudioEndpoint]
    ) -> NormalizedStudioEndpoints {
        let endpointByID = Dictionary(endpoints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var canonicalNodeByKey: [String: StudioNode.ID] = [:]
        var nodeRemap: [StudioNode.ID: StudioNode.ID] = [:]
        var retainedNodes: [StudioNode] = []

        for node in graph.nodes {
            guard case .endpoint(let endpointID) = node.kind,
                  let endpoint = endpointByID[endpointID],
                  let key = mergeKey(for: endpoint) else {
                retainedNodes.append(node)
                continue
            }
            if let canonicalNodeID = canonicalNodeByKey[key] {
                nodeRemap[node.id] = canonicalNodeID
            } else {
                canonicalNodeByKey[key] = node.id
                retainedNodes.append(node)
            }
        }

        var seenEdges: Set<StudioEdgeKey> = []
        let edges = graph.edges.compactMap { edge -> StudioEdge? in
            var updated = edge
            updated.from.nodeID = nodeRemap[updated.from.nodeID] ?? updated.from.nodeID
            updated.to.nodeID = nodeRemap[updated.to.nodeID] ?? updated.to.nodeID
            let key = StudioEdgeKey(from: updated.from, to: updated.to)
            return seenEdges.insert(key).inserted ? updated : nil
        }
        let normalizedGraph = StudioGraph(nodes: retainedNodes, edges: edges)
        let referencedEndpointIDs = Set(retainedNodes.compactMap { node -> StudioEndpoint.ID? in
            guard case .endpoint(let endpointID) = node.kind else { return nil }
            return endpointID
        })
        var seenEndpoints: Set<StudioEndpoint.ID> = []
        let normalizedEndpoints = endpoints.filter {
            referencedEndpointIDs.contains($0.id) && seenEndpoints.insert($0.id).inserted
        }
        return NormalizedStudioEndpoints(graph: normalizedGraph, endpoints: normalizedEndpoints)
    }

    static func matchingNode(
        for endpoint: StudioEndpoint,
        graph: StudioGraph,
        endpoints: [StudioEndpoint]
    ) -> StudioNode? {
        if endpoint.destination == .finalMix {
            let matchingIDs = Set(endpoints.filter {
                $0.destination == .finalMix && $0.name.caseInsensitiveCompare(endpoint.name) == .orderedSame
                    && ($0.explicitOutputConnectors == nil || endpoint.explicitOutputConnectors == nil
                        || $0.explicitOutputConnectors == endpoint.explicitOutputConnectors)
            }.map(\.id))
            return graph.nodes.first {
                if case .endpoint(let id) = $0.kind { return matchingIDs.contains(id) }
                return false
            }
        }
        guard let key = mergeKey(for: endpoint) else { return nil }
        let matchingIDs = Set(endpoints.compactMap {
            mergeKey(for: $0) == key ? $0.id : nil
        })
        return graph.nodes.first {
            guard case .endpoint(let endpointID) = $0.kind else { return false }
            return matchingIDs.contains(endpointID)
        }
    }

    private static func mergeKey(for endpoint: StudioEndpoint) -> String? {
        switch endpoint.destination {
        case .finalMix:
            let name = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let connectors = endpoint.explicitOutputConnectors?.map(\.label).joined(separator: ",") ?? "unspecified"
            return "\(endpoint.destination.rawValue)|\(name)|\(connectors)"
        case .custom:
            let connectors = (endpoint.outputConnectors ?? []).map(\.label).joined(separator: ",")
            return connectors.isEmpty ? nil : "\(endpoint.destination.rawValue)|\(connectors)"
        case .space:
            return nil
        }
    }
}

private struct StudioEdgeKey: Hashable {
    var from: StudioPortRef
    var to: StudioPortRef
}
