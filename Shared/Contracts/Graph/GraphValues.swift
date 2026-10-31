import Foundation

/// What a port carries. Ports of different signals never connect.
enum PortSignal: String, Codable, Hashable, Sendable, CaseIterable {
    case audio
    case midi
    case control
    case clock
}

/// Which way signal flows through a port.
enum PortDirection: String, Codable, Hashable, Sendable, CaseIterable {
    case input
    case output
}

/// A port addressed through its owning node.
struct PortAddress: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case node
        case port
        case extensions
    }

    var node: NodeID
    var port: PortID
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(node: NodeID, port: PortID) {
        self.node = node
        self.port = port
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        node = try container.decode(NodeID.self, forKey: .node)
        port = try container.decode(PortID.self, forKey: .port)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(node, forKey: .node)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

// swiftlint:disable identifier_name
/// A canvas position. Geometry is presentation only and never affects routing.
struct GraphPoint: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case x
        case y
        case extensions
    }

    var x: Double
    var y: Double
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}
// swiftlint:enable identifier_name
