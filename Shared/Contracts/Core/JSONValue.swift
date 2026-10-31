//
//  JSONValue.swift
//  FluxKlang
//
//  A Foundation-only model of an arbitrary JSON value, used to carry unknown
//  optional contract data through a decode/encode round trip.
//

import Foundation

/// Any JSON value.
///
/// Numbers decode in this order: `.int` when the value fits in `Int64`, else
/// `.uint` when it fits in `UInt64`, else `.double`. Decoding never produces
/// `.uint` for a value that fits in `Int64`. Integers beyond 64 bits become
/// `.double` and lose precision (e.g. 2^64 + 1 re-encodes as 18446744073709551616).
/// An integral literal such as `2.0` or `-0.0` decodes as `.int`.
///
/// Equality and hashing compare numbers by value: `.int`, `.uint` and `.double`
/// are equal when they represent the same exact integer (the double is finite,
/// integral and exactly representable), so `.double(1.0) == .int(1)`. `-0.0`
/// is normalised to `0`. Encoding a non-finite double throws.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .uint(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            // The last attempt rethrows its own underlying error.
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        func single(_ value: some Encodable) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            try single(value)
        case .int(let value):
            try single(value)
        case .uint(let value):
            try single(value)
        case .double(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "JSON cannot represent a non-finite number"
                    )
                )
            }
            try single(value)
        case .string(let value):
            try single(value)
        case .array(let value):
            try single(value)
        case .object(let members):
            // Sorted keys: deterministic for encoders that keep insertion order.
            // JSONEncoder does not, so contract output also needs `.sortedKeys`
            // (see `ContractCoding.makeEncoder()`).
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in members.sorted(by: { $0.key < $1.key }) {
                try container.encode(value, forKey: DynamicCodingKey(key))
            }
        }
    }

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case let (.bool(left), .bool(right)):
            return left == right
        case let (.string(left), .string(right)):
            return left == right
        case let (.array(left), .array(right)):
            return left == right
        case let (.object(left), .object(right)):
            return left == right
        default:
            guard let left = lhs.numberKey, let right = rhs.numberKey else { return false }
            return left == right
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .bool(let value):
            hasher.combine(1)
            hasher.combine(value)
        case .int, .uint, .double:
            hasher.combine(2)
            hasher.combine(numberKey)
        case .string(let value):
            hasher.combine(3)
            hasher.combine(value)
        case .array(let value):
            hasher.combine(4)
            hasher.combine(value)
        case .object(let value):
            hasher.combine(5)
            hasher.combine(value)
        }
    }

    /// The canonical form of a number: exact integers by value, anything else as
    /// the (zero-normalised) double.
    private enum NumberKey: Hashable {
        case negative(Int64)
        case nonNegative(UInt64)
        case inexact(Double)
    }

    private var numberKey: NumberKey? {
        switch self {
        case .int(let value):
            return value < 0 ? .negative(value) : .nonNegative(UInt64(value))
        case .uint(let value):
            return .nonNegative(value)
        case .double(let value):
            if let exact = Int64(exactly: value), exact < 0 { return .negative(exact) }
            if let exact = UInt64(exactly: value) { return .nonNegative(exact) }
            return .inexact(value)
        default:
            return nil
        }
    }
}
