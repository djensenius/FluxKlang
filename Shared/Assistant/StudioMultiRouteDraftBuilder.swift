import Foundation

enum StudioMultiRouteDraftBuilder {
    // swiftlint:disable:next function_parameter_count
    static func combine(
        _ drafts: [StudioPatchDraft],
        request: StudioWiringRequest,
        equipment: [Equipment],
        effects: [Effect],
        currentGraph: StudioGraph,
        environmentID: RoutingEnvironment.ID?
    ) -> StudioPatchDraft {
        var graph = StudioGraph()
        var endpoints: [StudioEndpoint] = []
        for draft in drafts {
            var appendDraft = draft
            appendDraft.applicationMode = .append
            let merged = StudioPatchDraftMerger.merge(
                appendDraft,
                into: graph,
                endpoints: endpoints,
                equipment: equipment,
                effects: effects
            )
            graph = merged.graph
            endpoints = merged.endpoints
        }
        let signature = routeSignature(request, environmentID: environmentID)
        let currentKinds = Set(currentGraph.nodes.map(\.kind))
        let nodes = graph.nodes.map { node in
            StudioDraftNode(
                reference: reference(for: node.kind),
                node: node,
                reusesExistingNode: currentKinds.contains(node.kind)
            )
        }
        let edges = graph.edges.map { edge in
            StudioDraftEdge(
                reference: "edge:\(edge.from.nodeID)->\(edge.to.nodeID)|\(signature)",
                edge: edge
            )
        }
        return StudioPatchDraft(
            id: stableUUID("multi-draft|\(signature)"),
            createdAt: Date(),
            request: StudioPatchRequest(
                environmentID: environmentID,
                sourceInstrumentIDs: request.sourceInstrumentIDs,
                effectChainIDs: request.effectChainIDs,
                destination: request.destination,
                includesDrySignal: request.includesDrySignal,
                outputConnectors: request.outputConnectors,
                additionalRoutes: request.additionalRoutes
            ),
            fragment: StudioGraphFragment(nodes: nodes, edges: edges, endpoints: endpoints),
            cableInstructions: unique(drafts.flatMap(\.cableInstructions), by: \.id),
            logicalRoutingSummary: unique(drafts.flatMap(\.logicalRoutingSummary), by: \.value),
            validation: unique(drafts.flatMap(\.validation), by: \.code),
            applicationMode: request.applicationMode
        )
    }

    private static func routeSignature(
        _ request: StudioWiringRequest,
        environmentID: RoutingEnvironment.ID?
    ) -> String {
        let primary = StudioWiringRoute(
            sourceInstrumentIDs: request.sourceInstrumentIDs,
            effectChainIDs: request.effectChainIDs,
            destination: request.destination,
            includesDrySignal: request.includesDrySignal,
            outputConnectors: request.outputConnectors
        )
        return ([primary] + request.additionalRoutes).map { route in
            [
                route.sourceInstrumentIDs.map(\.uuidString).joined(separator: ","),
                route.effectChainIDs.map(\.uuidString).joined(separator: ","),
                route.destination.rawValue,
                route.includesDrySignal.description,
                route.outputConnectors?.map(\.label).joined(separator: ",") ?? ""
            ].joined(separator: ":")
        }.joined(separator: "|") + "|\(environmentID?.uuidString ?? "no-environment")"
    }

    private static func reference(for kind: StudioNodeKind) -> String {
        switch kind {
        case .instrument(let id): "instrument:\(id.uuidString)"
        case .effect(let id): "effect:\(id.uuidString)"
        case .endpoint(let id): "endpoint:\(id.uuidString)"
        }
    }

    private static func unique<Value, Key: Hashable>(
        _ values: [Value],
        by keyPath: KeyPath<Value, Key>
    ) -> [Value] {
        var seen: Set<Key> = []
        return values.filter { seen.insert($0[keyPath: keyPath]).inserted }
    }

    private static func stableUUID(_ value: String) -> UUID {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in value.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x100000001b3
        }
        var raw = withUnsafeBytes(of: first.bigEndian, Array.init)
            + withUnsafeBytes(of: second.bigEndian, Array.init)
        raw[6] = (raw[6] & 0x0f) | 0x50
        raw[8] = (raw[8] & 0x3f) | 0x80
        return UUID(uuid: (
            raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
            raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]
        ))
    }
}
