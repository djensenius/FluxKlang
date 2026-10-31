//
//  GraphEdge.swift
//  FluxKlang
//
//  Wires between ports. Channel conversion and feedback are explicit edge
//  attributes: nothing is ever converted or treated as feedback implicitly.
//

import Foundation

/// An explicit channel conversion: one row per destination channel listing the
/// source channel indices summed into it. An empty row is a silent channel.
struct EdgeConversion: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case map
        case label
        case extensions
    }

    static let channelMapKind = "channelMap"

    var map: [[Int]]
    var label: String?
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(map: [[Int]], label: String? = nil) {
        self.map = map
        self.label = label
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard kind == Self.channelMapKind else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unsupported conversion kind \"\(kind)\""
            )
        }
        map = try container.decode([[Int]].self, forKey: .map)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.channelMapKind, forKey: .kind)
        try container.encode(map, forKey: .map)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

/// Marks an edge as intentional, causal feedback: it is delayed by at least one
/// render block and its loop gain is capped. Only such edges may close a cycle.
struct EdgeFeedback: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case delayBlocks
        case gainCeilingDb
        case extensions
    }

    /// Render blocks of delay; at least 1.
    var delayBlocks: Int
    /// Loop gain ceiling in dB; at most 0.
    var gainCeilingDb: Double
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(delayBlocks: Int = 1, gainCeilingDb: Double) {
        self.delayBlocks = delayBlocks
        self.gainCeilingDb = gainCeilingDb
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delayBlocks = try container.decode(Int.self, forKey: .delayBlocks)
        gainCeilingDb = try container.decode(Double.self, forKey: .gainCeilingDb)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(delayBlocks, forKey: .delayBlocks)
        try container.encode(gainCeilingDb, forKey: .gainCeilingDb)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }

    var isValid: Bool { delayBlocks >= 1 && gainCeilingDb.isFinite && gainCeilingDb <= 0 }
}

/// A wire from an output port to an input port.
struct GraphEdge: Codable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case from
        case to
        case conversion
        case feedback
        case extensions
    }

    var id: EdgeID
    var from: PortAddress
    var to: PortAddress
    var conversion: EdgeConversion?
    var feedback: EdgeFeedback?
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(
        id: EdgeID,
        from: PortAddress,
        to: PortAddress,
        conversion: EdgeConversion? = nil,
        feedback: EdgeFeedback? = nil,
        extensions: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.conversion = conversion
        self.feedback = feedback
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(EdgeID.self, forKey: .id)
        from = try container.decode(PortAddress.self, forKey: .from)
        to = try container.decode(PortAddress.self, forKey: .to)
        conversion = try container.decodeIfPresent(EdgeConversion.self, forKey: .conversion)
        feedback = try container.decodeIfPresent(EdgeFeedback.self, forKey: .feedback)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encodeIfPresent(conversion, forKey: .conversion)
        try container.encodeIfPresent(feedback, forKey: .feedback)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}
