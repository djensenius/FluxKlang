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
/// `extensions: [String: JSONValue]` property:
///
///     extensions = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
///     ...encode known keys...
///     try ExtensionFields.encode(extensions, to: encoder, knownKeys: CodingKeys.self)
///
/// Known keys always win: decoding never puts a known key into the extensions,
/// and encoding skips any extension whose key is known, so a stray entry cannot
/// overwrite or duplicate a modelled field.
enum ExtensionFields {
    /// Every key in `decoder`'s keyed container that is not in `knownKeys`.
    static func decode(
        from decoder: any Decoder,
        knownKeys: Set<String>
    ) throws -> [String: JSONValue] {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var extensions: [String: JSONValue] = [:]
        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            extensions[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return extensions
    }

    /// Every unknown key, with the known set taken from a `CaseIterable` key type.
    static func decode<Keys: CodingKey & CaseIterable>(
        from decoder: any Decoder,
        knownKeys: Keys.Type
    ) throws -> [String: JSONValue] {
        try decode(from: decoder, knownKeys: names(of: knownKeys))
    }

    /// Writes `extensions` into `encoder`'s keyed container, skipping known keys.
    static func encode(
        _ extensions: [String: JSONValue],
        to encoder: any Encoder,
        knownKeys: Set<String>
    ) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extensions where !knownKeys.contains(key) {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }

    /// Writes `extensions`, with the known set taken from a `CaseIterable` key type.
    static func encode<Keys: CodingKey & CaseIterable>(
        _ extensions: [String: JSONValue],
        to encoder: any Encoder,
        knownKeys: Keys.Type
    ) throws {
        try encode(extensions, to: encoder, knownKeys: names(of: knownKeys))
    }

    private static func names<Keys: CodingKey & CaseIterable>(of keys: Keys.Type) -> Set<String> {
        Set(keys.allCases.map(\.stringValue))
    }
}
