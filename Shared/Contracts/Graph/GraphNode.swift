//
//  GraphNode.swift
//  FluxKlang
//
//  Nodes and their typed ports. A port declares its signal and, for audio, its
//  channel count; legacy imports leave the count unset, which keeps the port
//  inert (validation fails) until a review confirms it.
//

import Foundation

/// A typed port, unique by `id` within its node.
struct GraphPort: Codable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case direction
        case signal
        case channels
        case label
        case extensions
    }

    var id: PortID
    var direction: PortDirection
    var signal: PortSignal
    /// Audio channel count (1...64). Must be nil for non-audio signals.
    var channels: Int?
    var label: String?
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(id: PortID, direction: PortDirection, signal: PortSignal, channels: Int? = nil, label: String? = nil) {
        self.id = id
        self.direction = direction
        self.signal = signal
        self.channels = channels
        self.label = label
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PortID.self, forKey: .id)
        direction = try container.decode(PortDirection.self, forKey: .direction)
        signal = try container.decode(PortSignal.self, forKey: .signal)
        channels = try container.decodeIfPresent(Int.self, forKey: .channels)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(direction, forKey: .direction)
        try container.encode(signal, forKey: .signal)
        try container.encodeIfPresent(channels, forKey: .channels)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

/// What a node represents. Roles, patches and shared graphs are referenced by
/// ID; the referenced objects live in the project.
enum NodeKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Signal entering from a portable project role (needs `role`).
    case roleInput
    /// Signal leaving to a portable project role (needs `role`).
    case roleOutput
    /// A spatial output bus for a portable role (needs `role`); layout is #114's.
    case spatialBus
    /// A hosted processor or instrument.
    case plugin
    /// Outboard gear through a send and return; compensation is #68's seam.
    case externalInsert
    /// Plays a project asset (needs `asset`).
    case mediaPlayer
    /// An instance of a shared graph (needs `graph`).
    case sharedGraph
    /// A console shortcut seen on the device. Never routable, so it has no ports.
    case observedShortcut

    var isRoutable: Bool { self != .observedShortcut }
    var requiresRole: Bool { [.roleInput, .roleOutput, .spatialBus].contains(self) }
}

/// A node of the neutral graph.
struct GraphNode: Codable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case kind
        case label
        case role
        case asset
        case graph
        case ports
        case requiredCapabilities
        case advisoryCapabilities
        case position
        case extensions
    }

    var id: NodeID
    var kind: NodeKind
    var label: String
    var role: RoleID?
    var asset: AssetID?
    var graph: GraphID?
    var ports: [GraphPort]
    /// Capabilities whose absence blocks activation.
    var requiredCapabilities: [CapabilityID]
    /// Capabilities whose absence degrades the node to a silent placeholder.
    var advisoryCapabilities: [CapabilityID]
    var position: GraphPoint?
    /// The explicit extension bag (G-MEDIA §12); legacy-only data lives here.
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(
        id: NodeID,
        kind: NodeKind,
        label: String,
        role: RoleID? = nil,
        asset: AssetID? = nil,
        graph: GraphID? = nil,
        ports: [GraphPort] = [],
        requiredCapabilities: [CapabilityID] = [],
        advisoryCapabilities: [CapabilityID] = [],
        position: GraphPoint? = nil,
        extensions: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.role = role
        self.asset = asset
        self.graph = graph
        self.ports = ports
        self.requiredCapabilities = requiredCapabilities
        self.advisoryCapabilities = advisoryCapabilities
        self.position = position
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(NodeID.self, forKey: .id)
        kind = try container.decode(NodeKind.self, forKey: .kind)
        label = try container.decode(String.self, forKey: .label)
        role = try container.decodeIfPresent(RoleID.self, forKey: .role)
        asset = try container.decodeIfPresent(AssetID.self, forKey: .asset)
        graph = try container.decodeIfPresent(GraphID.self, forKey: .graph)
        ports = try container.decodeIfPresent([GraphPort].self, forKey: .ports) ?? []
        requiredCapabilities = try container.decodeIfPresent(
            [CapabilityID].self, forKey: .requiredCapabilities
        ) ?? []
        advisoryCapabilities = try container.decodeIfPresent(
            [CapabilityID].self, forKey: .advisoryCapabilities
        ) ?? []
        position = try container.decodeIfPresent(GraphPoint.self, forKey: .position)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(asset, forKey: .asset)
        try container.encodeIfPresent(graph, forKey: .graph)
        try container.encode(ports, forKey: .ports)
        if !requiredCapabilities.isEmpty {
            try container.encode(requiredCapabilities, forKey: .requiredCapabilities)
        }
        if !advisoryCapabilities.isEmpty {
            try container.encode(advisoryCapabilities, forKey: .advisoryCapabilities)
        }
        try container.encodeIfPresent(position, forKey: .position)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }

    func port(_ id: PortID) -> GraphPort? {
        ports.first { $0.id == id }
    }
}
