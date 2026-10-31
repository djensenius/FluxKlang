//
//  GraphDocument.swift
//  FluxKlang
//
//  The versioned `fluxklang.graph` document: nodes, edges and the capability
//  definitions the nodes require. Decode with `ContractCoding.decode`.
//

import Foundation

/// Reads the `{contract, version}` envelope of a #54 document and accepts only
/// the current version. Unversioned data goes through the read-only legacy
/// adapters instead; a future major version is rejected.
enum ProjectGraphEnvelope {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case contract
        case version
        case requiredFeatures
    }

    static func requireCurrent(from decoder: any Decoder, supported: ContractVersion) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let contract = try container.decodeIfPresent(String.self, forKey: .contract)
        let version = try container.decodeIfPresent(Int.self, forKey: .version)
        let compatibility = try ContractVersion.check(contract: contract, version: version, supported: supported)
        guard compatibility == .current else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "\(supported.contract) document is \(compatibility); "
                    + "import it through the legacy adapter or a migration"
            ))
        }
        let required = try container.decodeIfPresent([String].self, forKey: .requiredFeatures) ?? []
        guard required.isEmpty else { throw ProjectGraphVersionError.unsupportedRequiredFeatures(required) }
    }

    static func encode(_ supported: ContractVersion, to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(supported.contract, forKey: .contract)
        try container.encode(supported.version, forKey: .version)
    }
}

enum ProjectGraphVersionError: Error, Equatable {
    case unsupportedRequiredFeatures([String])
}

/// A neutral, typed signal graph with no console or engine handles.
struct GraphDocument: Codable, Hashable, Sendable, Identifiable {
    static let currentVersion = ContractVersion(contract: "fluxklang.graph", version: 1)

    enum CodingKeys: String, CodingKey, CaseIterable {
        case contract
        case version
        case id
        case revision
        case label
        case capabilities
        case nodes
        case edges
        case extensions
        case requiresReview
        case requiredFeatures
    }

    var id: GraphID
    var revision: ContractRevision
    var label: String?
    var capabilities: [CapabilityDefinition]
    var nodes: [GraphNode]
    var edges: [GraphEdge]
    var extensions: [String: JSONValue]?
    var requiresReview: Bool
    var unknownFields: [String: JSONValue] = [:]

    init(
        id: GraphID,
        revision: ContractRevision = .initial,
        label: String? = nil,
        capabilities: [CapabilityDefinition] = [],
        nodes: [GraphNode] = [],
        edges: [GraphEdge] = [],
        extensions: [String: JSONValue]? = nil,
        requiresReview: Bool = false
    ) {
        self.id = id
        self.revision = revision
        self.label = label
        self.capabilities = capabilities
        self.nodes = nodes
        self.edges = edges
        self.extensions = extensions
        self.requiresReview = requiresReview
    }

    init(from decoder: any Decoder) throws {
        try ProjectGraphEnvelope.requireCurrent(from: decoder, supported: Self.currentVersion)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(GraphID.self, forKey: .id)
        revision = try container.decode(ContractRevision.self, forKey: .revision)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        capabilities = try container.decodeIfPresent([CapabilityDefinition].self, forKey: .capabilities) ?? []
        nodes = try container.decode([GraphNode].self, forKey: .nodes)
        edges = try container.decode([GraphEdge].self, forKey: .edges)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        requiresReview = try container.decodeIfPresent(Bool.self, forKey: .requiresReview) ?? false
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
        try checkCollectionBounds()
    }

    func encode(to encoder: any Encoder) throws {
        try checkCollectionBounds()
        try ProjectGraphEnvelope.encode(Self.currentVersion, to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(label, forKey: .label)
        if !capabilities.isEmpty {
            try container.encode(capabilities, forKey: .capabilities)
        }
        try container.encode(nodes, forKey: .nodes)
        try container.encode(edges, forKey: .edges)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        if requiresReview { try container.encode(true, forKey: .requiresReview) }
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }

    /// Decodes a graph document, rejecting duplicate member names.
    static func decode(from data: Data) throws -> GraphDocument {
        try ProjectGraphLimits.checkBytes(data)
        return try ContractCoding.decode(GraphDocument.self, from: data)
    }

    func encoded() throws -> Data {
        let data = try ContractCoding.makeEncoder().encode(self)
        try ProjectGraphLimits.checkBytes(data)
        return data
    }

    func node(_ id: NodeID) -> GraphNode? {
        nodes.first { $0.id == id }
    }

    func port(at address: PortAddress) -> GraphPort? {
        node(address.node)?.port(address.port)
    }
}
