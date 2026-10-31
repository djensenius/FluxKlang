//
//  ContractID.swift
//  FluxKlang
//
//  A phantom-typed, string-backed identifier shared by the versioned contracts.
//  It carries human-readable catalog IDs (`par.mains.gain`) and legacy UUIDs
//  alike, and encodes as a bare JSON string.
//

import Foundation

/// Marker for the phantom tag of a `ContractID`. Contract owners declare their
/// own tags, e.g. `enum NodeTag: ContractIDTag {}` and
/// `typealias NodeID = ContractID<NodeTag>`.
protocol ContractIDTag {}

/// Why a raw string is not a valid `ContractID`.
enum ContractIDError: Error, Equatable, Sendable {
    /// The string is empty or longer than `ContractID.maximumLength` UTF-8 bytes.
    case invalidLength(Int)
    /// The string contains a character outside `[A-Za-z0-9._:-]`.
    case invalidCharacter(Character)
}

/// A validated identifier: 1…128 characters from `[A-Za-z0-9._:-]`.
/// Equality, hashing and ordering use the raw string only; the tag merely keeps
/// IDs of different kinds from mixing at compile time.
struct ContractID<Tag: ContractIDTag>: Hashable, Comparable, Sendable, CustomStringConvertible {
    static var maximumLength: Int { 128 }

    let rawValue: String

    /// Creates an ID, throwing if `rawValue` is not valid.
    init(_ rawValue: String) throws(ContractIDError) {
        try Self.validate(rawValue)
        self.rawValue = rawValue
    }

    /// Creates an ID, or returns `nil` if `rawValue` is not valid.
    init?(rawValue: String) {
        guard (try? Self.validate(rawValue)) != nil else { return nil }
        self.rawValue = rawValue
    }

    /// Creates an ID from a static catalog literal such as `"par.mains.gain"`.
    /// Invalid literals are programmer errors and stop at a `precondition`.
    init(validated literal: StaticString) {
        let raw = literal.description
        precondition((try? Self.validate(raw)) != nil, "Invalid static contract ID \"\(raw)\"")
        rawValue = raw
    }

    /// Wraps a legacy UUID as `uuid.uuidString` exactly (uppercase), matching how
    /// Foundation's JSON coding writes `UUID`, so legacy adapters are deterministic.
    init(uuid: UUID) {
        rawValue = uuid.uuidString
    }

    var description: String { rawValue }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Checks the length and character rules without constructing an ID. The
    /// length is checked in UTF-8 bytes first, which bounds the character scan;
    /// valid IDs are ASCII, so bytes and characters agree for them.
    static func validate(_ rawValue: String) throws(ContractIDError) {
        let count = rawValue.utf8.count
        guard (1...maximumLength).contains(count) else {
            throw .invalidLength(count)
        }
        if let bad = rawValue.first(where: { !isAllowed($0) }) {
            throw .invalidCharacter(bad)
        }
    }

    private static func isAllowed(_ character: Character) -> Bool {
        guard character.isASCII, let ascii = character.asciiValue else { return false }
        switch ascii {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        default:
            return ascii == UInt8(ascii: ".") || ascii == UInt8(ascii: "_")
                || ascii == UInt8(ascii: ":") || ascii == UInt8(ascii: "-")
        }
    }
}

extension ContractID: Codable {
    /// Decodes a bare string; an invalid string throws `DecodingError.dataCorrupted`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        do {
            try self.init(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid contract ID \"\(raw)\": \(error)"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
