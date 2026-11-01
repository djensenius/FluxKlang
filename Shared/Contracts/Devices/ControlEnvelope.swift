import Foundation

struct DuplicateIDError: Error, Equatable, Sendable {
    let rawValue: String
}

enum ContractUniqueness {
    static func require<Tag>(_ ids: some Sequence<ContractID<Tag>>) throws(DuplicateIDError) {
        var seen = Set<ContractID<Tag>>()
        for id in ids where !seen.insert(id).inserted {
            throw DuplicateIDError(rawValue: id.rawValue)
        }
    }
}

enum ControlValidationError: Error, Equatable, Sendable {
    case invalid(String)
    case unsupportedRequiredData([String])
    case duplicateID(String)
}

/// Wire payloads are independently versioned. Runtime anchors and live authority are not payloads.
protocol ControlPayload: Codable, Hashable, Sendable {
    static var contract: String { get }
    func validate() throws
}

struct ControlEnvelope<Payload: ControlPayload>: Codable, Hashable, Sendable {
    let revision: ContractRevision
    let payload: Payload
    var extensions: [String: JSONValue] = [:]
    var unknownFields: [String: JSONValue] = [:]

    init(revision: ContractRevision, payload: Payload) throws {
        try payload.validate()
        self.revision = revision
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case contract, version, revision, payload, requiredFeatures, extensions
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let compatibility = try ContractVersion.check(
            contract: fields.decode(String.self, forKey: .contract),
            version: fields.decode(Int.self, forKey: .version),
            supported: ContractVersion(contract: Payload.contract, version: 1)
        )
        guard compatibility == .current else { throw ControlValidationError.invalid("Envelope migration required") }
        let required = try fields.decodeIfPresent([String].self, forKey: .requiredFeatures) ?? []
        guard required.isEmpty else { throw ControlValidationError.unsupportedRequiredData(required) }
        try self.init(revision: fields.decode(ContractRevision.self, forKey: .revision),
                      payload: fields.decode(Payload.self, forKey: .payload))
        extensions = try fields.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? [:]
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        try payload.validate()
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(Payload.contract, forKey: .contract)
        try fields.encode(1, forKey: .version)
        try fields.encode(revision, forKey: .revision)
        try fields.encode(payload, forKey: .payload)
        try fields.encode(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

/// Nested wire objects retain additive fields while validating their known semantics.
protocol ControlFields: Codable, Hashable, Sendable {
    static var knownKeys: Set<String> { get }
    func validate() throws
}

protocol ControlPayloadFields: ControlFields {
    static var contract: String { get }
}

extension ControlRecord: ControlPayload where Fields: ControlPayloadFields {
    static var contract: String { Fields.contract }
    func validate() throws { try fields.validate() }
}

@dynamicMemberLookup
struct ControlRecord<Fields: ControlFields>: Codable, Hashable, Sendable {
    let fields: Fields
    var unknownFields: [String: JSONValue]
    private var nestedUnknownFields: [String: JSONValue] = [:]

    init(_ fields: Fields, unknownFields: [String: JSONValue] = [:]) throws {
        try fields.validate()
        self.fields = fields
        self.unknownFields = unknownFields
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<Fields, Value>) -> Value { fields[keyPath: keyPath] }

    init(from decoder: any Decoder) throws {
        try self.init(Fields(from: decoder),
                      unknownFields: ExtensionFields.decode(from: decoder, knownKeys: Fields.knownKeys))
        let raw = try JSONValue(from: decoder)
        nestedUnknownFields = try ControlJSON.unknown(in: raw, comparedTo: ControlJSON.value(fields))
            .filter { Fields.knownKeys.contains($0.key) }
    }

    func encode(to encoder: any Encoder) throws {
        try fields.validate()
        try ControlJSON.merging(ControlJSON.value(fields), unknown: nestedUnknownFields).encode(to: encoder)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: Fields.knownKeys)
    }
}

/// Retains additive members nested inside synthesized Codable values without changing known semantics.
enum ControlJSON {
    static func value(_ value: some Encodable) throws -> JSONValue {
        try ContractCoding.decode(JSONValue.self, from: ContractCoding.makeEncoder().encode(value))
    }

    static func unknown(in original: JSONValue, comparedTo known: JSONValue) -> [String: JSONValue] {
        guard case .object(let original) = original, case .object(let known) = known else { return [:] }
        var result: [String: JSONValue] = [:]
        for (key, value) in original {
            guard let recognized = known[key] else { result[key] = value; continue }
            let nested = unknown(in: value, comparedTo: recognized)
            if !nested.isEmpty { result[key] = .object(nested) }
        }
        return result
    }

    static func merging(_ value: JSONValue, unknown: [String: JSONValue]) -> JSONValue {
        guard case .object(var fields) = value else { return value }
        for (key, addition) in unknown {
            if let existing = fields[key], case .object(let nested) = addition {
                fields[key] = merging(existing, unknown: nested)
            } else if fields[key] == nil {
                fields[key] = addition
            }
        }
        return .object(fields)
    }
}
