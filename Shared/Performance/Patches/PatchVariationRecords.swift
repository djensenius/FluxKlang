//
//  PatchVariationRecords.swift
//  FluxKlang
//
//  Explicit patch variations (#104): named sets of absolute values for live
//  catalog parameters. They hold no plugin state, so nothing diffs opaque state.
//  A set is stored in its patch's `extensions` (see `PatchVariationExtension`).
//

import Foundation

enum PatchVariationTag: ContractIDTag {}
typealias PatchVariationID = ContractID<PatchVariationTag>

/// One absolute parameter value a variation applies over its patch's baseline.
/// The wire form is flat (`parameter`, `value`, `unit`) so unknown keys round-trip.
struct PatchParameterDelta: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case parameter, value, unit, extensions
    }

    var parameter: ParameterID
    var value: ParameterValue
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(parameter: ParameterID, value: ParameterValue, extensions: [String: JSONValue]? = nil) {
        self.parameter = parameter
        self.value = value
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parameter = try container.decode(ParameterID.self, forKey: .parameter)
        value = try ParameterValue(
            value: container.decode(Double.self, forKey: .value),
            unit: container.decode(ParameterUnit.self, forKey: .unit)
        )
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(parameter, forKey: .parameter)
        try container.encode(value.value, forKey: .value)
        try container.encode(value.unit, forKey: .unit)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

/// A named variation of its containing patch. The patch is its only base: there
/// are no references to other variations or other patches.
struct PatchVariation: Codable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, deltas, extensions
    }

    var id: PatchVariationID
    var label: String
    var deltas: [PatchParameterDelta]
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(
        id: PatchVariationID,
        label: String,
        deltas: [PatchParameterDelta] = [],
        extensions: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.label = label
        self.deltas = deltas
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PatchVariationID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        deltas = try container.decode([PatchParameterDelta].self, forKey: .deltas)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(deltas, forKey: .deltas)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

/// Every variation of one patch, at the current extension version. Its wire form
/// always carries `version`; other versions never decode into this type.
struct PatchVariationSet: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, variations, extensions
    }

    var variations: [PatchVariation]
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(variations: [PatchVariation] = [], extensions: [String: JSONValue]? = nil) {
        self.variations = variations
        self.extensions = extensions
    }

    /// No variations and nothing else to preserve; writing it removes the key.
    var isEmpty: Bool { variations.isEmpty && extensions == nil && unknownFields.isEmpty }

    subscript(id: PatchVariationID) -> PatchVariation? { variations.first { $0.id == id } }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == PatchVariationLimits.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "Unsupported version \(version)"
            )
        }
        variations = try container.decode([PatchVariation].self, forKey: .variations)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(PatchVariationLimits.currentVersion, forKey: .version)
        try container.encode(variations, forKey: .variations)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}
