import Foundation

enum StudioPatchDraftMerger {
    static func merge(
        _ draft: StudioPatchDraft,
        into currentGraph: StudioGraph,
        endpoints currentEndpoints: [StudioEndpoint],
        equipment: [Equipment],
        effects: [Effect]
    ) -> StudioPatchMergeResult {
        let equipmentIDs = Set(equipment.map(\.id))
        let effectIDs = Set(effects.map(\.id))
        let normalized = StudioEndpointNormalizer.normalize(graph: currentGraph, endpoints: currentEndpoints)
        var graph = draft.applicationMode == .replace ? StudioGraph() : normalized.graph
        var endpoints = draft.applicationMode == .replace ? [] : normalized.endpoints
        var nodeIDMap: [StudioNode.ID: StudioNode.ID] = [:]
        var addedNodes = 0

        for draftNode in draft.fragment.nodes {
            guard isValid(draftNode.node.kind, equipmentIDs: equipmentIDs, effectIDs: effectIDs, draft: draft) else {
                continue
            }
            if case .endpoint(let endpointID) = draftNode.node.kind,
               let endpoint = draft.fragment.endpoints.first(where: { $0.id == endpointID }),
               let existing = StudioEndpointNormalizer.matchingNode(
                   for: endpoint,
                   graph: graph,
                   endpoints: endpoints
               ) {
                nodeIDMap[draftNode.node.id] = existing.id
                if case .endpoint(let existingID) = existing.kind,
                   let index = endpoints.firstIndex(where: { $0.id == existingID }),
                   endpoints[index].outputConnectors == nil {
                    endpoints[index].outputConnectors = endpoint.outputConnectors
                }
                continue
            }
            if let existing = graph.nodes.first(where: { $0.kind == draftNode.node.kind }) {
                nodeIDMap[draftNode.node.id] = existing.id
            } else {
                graph.addNode(draftNode.node)
                nodeIDMap[draftNode.node.id] = draftNode.node.id
                addedNodes += 1
            }
        }
        for endpoint in draft.fragment.endpoints where !endpoints.contains(where: { $0.id == endpoint.id }) {
            guard graph.nodes.contains(where: { $0.kind == .endpoint(endpoint.id) }) else { continue }
            endpoints.append(endpoint)
        }

        var addedEdges = 0
        for draftEdge in draft.fragment.edges {
            guard let fromID = nodeIDMap[draftEdge.edge.from.nodeID],
                  let toID = nodeIDMap[draftEdge.edge.to.nodeID],
                  fromID != toID else { continue }
            let from = StudioPortRef(nodeID: fromID, side: .output, port: draftEdge.edge.from.port)
            let to = StudioPortRef(nodeID: toID, side: .input, port: draftEdge.edge.to.port)
            guard !graph.edges.contains(where: { $0.from == from && $0.to == to }) else { continue }
            graph.edges.append(StudioEdge(id: draftEdge.edge.id, from: from, to: to))
            addedEdges += 1
        }
        let result = StudioEndpointNormalizer.normalize(graph: graph, endpoints: endpoints)
        return StudioPatchMergeResult(
            graph: result.graph,
            endpoints: result.endpoints,
            addedNodeCount: addedNodes,
            addedEdgeCount: addedEdges
        )
    }

    private static func isValid(
        _ kind: StudioNodeKind,
        equipmentIDs: Set<Equipment.ID>,
        effectIDs: Set<Effect.ID>,
        draft: StudioPatchDraft
    ) -> Bool {
        switch kind {
        case .instrument(let id): equipmentIDs.contains(id)
        case .effect(let id): effectIDs.contains(id)
        case .endpoint(let id): draft.fragment.endpoints.contains { $0.id == id }
        case .liveChannel: false
        }
    }
}
