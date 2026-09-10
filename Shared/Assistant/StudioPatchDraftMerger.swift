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
        var graph = currentGraph
        var endpoints = currentEndpoints
        var nodeIDMap: [StudioNode.ID: StudioNode.ID] = [:]
        var addedNodes = 0

        for draftNode in draft.fragment.nodes {
            guard isValid(draftNode.node.kind, equipmentIDs: equipmentIDs, effectIDs: effectIDs, draft: draft) else {
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
            graph.connect(from: from, to: to)
            addedEdges += 1
        }
        return StudioPatchMergeResult(
            graph: graph,
            endpoints: endpoints,
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
        }
    }
}
