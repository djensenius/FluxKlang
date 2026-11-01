import CoreGraphics
import Foundation

/// Read-only adaptation retains the exact original bytes separately from interpreted intent.
/// Neither the result nor successful structural validation confers activation authority.
struct StudioGraphImport: Sendable {
    let graph: GraphDocument
    let originalGraph: Data
    let originalEndpoints: Data?
}

/// Reads the existing StudioGraph/StudioEndpoint Codable wire format, without linking
/// legacy assistant, console or app services. Unknown legacy members remain inert evidence.
enum StudioGraphNeutralAdapter {
    static func adapt(
        graphData: Data, endpointsData: Data? = nil, id: GraphID
    ) throws -> StudioGraphImport {
        try ProjectGraphLimits.checkBytes(graphData)
        if let endpointsData { try ProjectGraphLimits.checkBytes(endpointsData) }
        let legacy = try ContractCoding.decode(LegacyGraph.self, from: graphData)
        let original = try ContractCoding.decode(JSONValue.self, from: graphData)
        if case .object(let fields) = original, fields["contract"] != nil || fields["version"] != nil {
            throw ImportError.versionedInput
        }
        let endpoints = try endpointsData.map { try ContractCoding.decode([LegacyEndpoint].self, from: $0) } ?? []
        guard Set(endpoints.map(\.id)).count == endpoints.count else { throw ImportError.duplicateEndpoint }
        try ProjectGraphLimits.check(
            endpoints.count, maximum: ProjectGraphLimits.projectRecords, path: "legacy.endpoints"
        )
        try ProjectGraphLimits.check(legacy.nodes.count, maximum: ProjectGraphLimits.nodes, path: "legacy.nodes")
        try ProjectGraphLimits.check(legacy.edges.count, maximum: ProjectGraphLimits.edges, path: "legacy.edges")
        let endpointsByID = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, $0) })
        var addresses: [UUID: Set<LegacyPort>] = [:]
        for edge in legacy.edges {
            for port in [edge.from, edge.to] { addresses[port.nodeID, default: []].insert(port) }
        }
        let nodes = legacy.nodes.map { node in
            let endpoint = node.kind.reference.flatMap { endpointsByID[$0] }
            let kind = node.kind.neutralKind(destination: endpoint?.destination)
            let role = kind.requiresRole ? node.kind.reference.flatMap {
                RoleID(rawValue: "legacy.\(node.kind.name).\($0.uuidString)")
            } : nil
            let ports = kind.isRoutable ? (addresses[node.id] ?? []).sorted { $0.id < $1.id }.map {
                GraphPort(id: $0.id, direction: $0.side == .input ? .input : .output, signal: .audio)
            } : []
            return GraphNode(
                id: NodeID(uuid: node.id), kind: kind, label: node.title, role: role, ports: ports,
                position: GraphPoint(x: Double(node.position.x), y: Double(node.position.y))
            )
        }
        let edges = legacy.edges.map {
            GraphEdge(id: EdgeID(uuid: $0.id), from: $0.from.address, to: $0.to.address)
        }
        var evidence: [String: JSONValue] = ["source": .string("StudioGraph"), "reviewRequired": .bool(true),
                                             "originalGraph": original]
        if let endpointsData {
            evidence["originalEndpoints"] = try ContractCoding.decode(JSONValue.self, from: endpointsData)
        }
        let graph = GraphDocument(
            id: id, nodes: nodes, edges: edges, extensions: ["legacyStudio": .object(evidence)], requiresReview: true
        )
        try graph.checkCollectionBounds()
        _ = try graph.encoded()
        return StudioGraphImport(graph: graph, originalGraph: graphData, originalEndpoints: endpointsData)
    }

    enum ImportError: Error { case duplicateEndpoint, unsupportedKind, versionedInput }

    private struct LegacyGraph: Decodable {
        let nodes: [LegacyNode]
        let edges: [LegacyEdge]
    }

    private struct LegacyNode: Decodable {
        let id: UUID
        let kind: LegacyKind
        let title: String
        let position: CGPoint
    }

    private struct LegacyEndpoint: Decodable {
        let id: UUID
        let destination: String
    }

    private struct LegacyEdge: Decodable {
        let id: UUID
        let from: LegacyPort
        let to: LegacyPort
    }

    private enum LegacySide: String, Decodable { case input, output }

    private struct LegacyPort: Decodable, Hashable {
        let nodeID: UUID
        let side: LegacySide
        let port: Int
        var id: PortID { PortID(rawValue: "\(side == .input ? "in" : "out").\(port)")! }
        var address: PortAddress { PortAddress(node: NodeID(uuid: nodeID), port: id) }
    }

    private struct LegacyKind: Decodable {
        let name: String
        let reference: UUID?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            guard container.allKeys.count == 1, let key = container.allKeys.first,
                  ["instrument", "effect", "endpoint", "liveChannel"].contains(key.stringValue) else {
                throw ImportError.unsupportedKind
            }
            name = key.stringValue
            let payload = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key)
            reference = name == "liveChannel" ? nil : try payload.decode(UUID.self, forKey: DynamicCodingKey("_0"))
        }

        func neutralKind(destination: String?) -> NodeKind {
            switch name {
            case "instrument": .roleInput
            case "effect": .externalInsert
            case "endpoint": destination == "space" ? .spatialBus : .roleOutput
            default: .observedShortcut
            }
        }
    }
}
