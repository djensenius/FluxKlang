//
//  ExtensionFields.swift
//  FluxKlang
//
//  Unknown-key preservation for versioned contracts. A type decodes its known
//  keys as usual, collects every other key into `[String: JSONValue]`, and writes
//  them back on encode, so newer optional data survives an older reader.
//

import Foundation

/// A coding key for arbitrary string (or integer) keys.
struct DynamicCodingKey: CodingKey, Hashable, Sendable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Collects and re-emits the keys a contract type does not model.
///
/// Usage, in a type with `CodingKeys: CaseIterable` and an
/// `unknownFields: [String: JSONValue]` property:
///
///     unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
///     ...encode known keys...
///     try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
///
/// Known keys always win: decoding never puts a known key into `unknownFields`,
/// and encoding skips any entry whose key is known, so a stray entry cannot
/// overwrite or duplicate a modelled field. Encoding writes entries in sorted
/// key order.
///
/// Two bags, two purposes. A wire member named `extensions` (the explicit
/// extension bag of the G-MEDIA contract §12) is a real `CodingKey` modelled as
/// `extensions: [String: JSONValue]`. `unknownFields` instead holds stray
/// top-level keys for lenient forward compatibility; a strict validator rejects
/// any document whose stray-key decode is non-empty.
///
/// Both functions need a keyed (object) container: on a top-level array or
/// scalar, `decode` throws `DecodingError.typeMismatch`.
enum ExtensionFields {
    /// Every key in `decoder`'s keyed container that is not in `knownKeys`.
    static func decode(
        from decoder: any Decoder,
        knownKeys: Set<String>
    ) throws -> [String: JSONValue] {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var unknownFields: [String: JSONValue] = [:]
        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            unknownFields[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return unknownFields
    }

    /// Every unknown key, with the known set taken from a `CaseIterable` key type.
    static func decode<Keys: CodingKey & CaseIterable>(
        from decoder: any Decoder,
        knownKeys: Keys.Type
    ) throws -> [String: JSONValue] {
        try decode(from: decoder, knownKeys: names(of: knownKeys))
    }

    /// Writes `unknownFields` into `encoder`'s keyed container, skipping known keys.
    static func encode(
        _ unknownFields: [String: JSONValue],
        to encoder: any Encoder,
        knownKeys: Set<String>
    ) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for key in unknownFields.keys.sorted() where !knownKeys.contains(key) {
            try container.encode(unknownFields[key] ?? .null, forKey: DynamicCodingKey(key))
        }
    }

    /// Writes `unknownFields`, with the known set taken from a `CaseIterable` key type.
    static func encode<Keys: CodingKey & CaseIterable>(
        _ unknownFields: [String: JSONValue],
        to encoder: any Encoder,
        knownKeys: Keys.Type
    ) throws {
        try encode(unknownFields, to: encoder, knownKeys: names(of: knownKeys))
    }

    private static func names<Keys: CodingKey & CaseIterable>(of keys: Keys.Type) -> Set<String> {
        Set(keys.allCases.map(\.stringValue))
    }
}

/// The JSON coders every contract document uses. Output is canonical: sorted
/// keys and unescaped slashes. Contract coders must keep the default key, date
/// and data strategies; a key strategy such as `.convertFromSnakeCase` would
/// rename the stray keys that `ExtensionFields` preserves.
enum ContractCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
