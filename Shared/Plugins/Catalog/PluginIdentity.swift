//
//  PluginIdentity.swift
//  FluxKlang
//
//  Stable plugin identities for the catalog (#70). An identity is the
//  component's format plus its type, subtype and manufacturer codes. Names,
//  versions and scan order never take part, so a renamed or updated plugin keeps
//  its identity and a different plugin with the same name never replaces it.
//  Pure values only: nothing here enumerates, opens or instantiates a component.
//

import Foundation

enum PluginIdentityError: Error, Equatable, Sendable {
    /// A four-character code must be exactly four printable ASCII bytes.
    case invalidFourCharacterCode(String)
    /// The component type is not an instrument, effect, generator or MIDI kind the catalog covers.
    case unsupportedComponentType(PluginFourCharacterCode)
}

/// A four-character component code, stored big-endian as Audio Components store it.
struct PluginFourCharacterCode: Hashable, Comparable, Sendable, CustomStringConvertible {
    let rawValue: UInt32

    /// Accepts only codes whose four bytes are printable ASCII (0x20…0x7E).
    init?(rawValue: UInt32) {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: rawValue >> (24 - 8 * $0)) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        self.rawValue = rawValue
    }

    init(_ text: String) throws(PluginIdentityError) {
        let bytes = Array(text.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            throw .invalidFourCharacterCode(text)
        }
        rawValue = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    var description: String {
        String((0..<4).map { Character(Unicode.Scalar(UInt8(truncatingIfNeeded: rawValue >> (24 - 8 * $0)))) })
    }

    /// Eight lowercase hex digits; always valid inside a `ContractID`.
    var hexDigits: String {
        let digits = String(rawValue, radix: 16)
        return String(repeating: "0", count: 8 - digits.count) + digits
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The plugin API generation. Both are core on Mac; AUv2 runs in process, so
/// the same codes under another format are a different plugin, never a substitute.
enum PluginFormat: String, Hashable, Sendable, CaseIterable {
    case audioUnitV2 = "au2"
    case audioUnitV3 = "au3"
}

/// What a component does, derived only from its component type code.
enum PluginComponentKind: String, Hashable, Sendable, CaseIterable {
    case effect = "aufx"
    case musicEffect = "aumf"
    case instrument = "aumu"
    case generator = "augn"
    case midiProcessor = "aumi"
}

enum PluginTag: ContractIDTag {}
typealias PluginID = ContractID<PluginTag>

/// The stable identity of one installed or referenced component.
struct PluginIdentity: Hashable, Sendable {
    let format: PluginFormat
    let type: PluginFourCharacterCode
    let subtype: PluginFourCharacterCode
    let manufacturer: PluginFourCharacterCode
    let kind: PluginComponentKind

    init(
        format: PluginFormat,
        type: PluginFourCharacterCode,
        subtype: PluginFourCharacterCode,
        manufacturer: PluginFourCharacterCode
    ) throws(PluginIdentityError) {
        guard let kind = PluginComponentKind(rawValue: type.description) else {
            throw .unsupportedComponentType(type)
        }
        self.format = format
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
        self.kind = kind
    }

    /// `plg.<format>.<type>.<subtype>.<manufacturer>` with hex codes, so any
    /// printable code (including spaces) yields the same valid ID on every host.
    var id: PluginID {
        let raw = ["plg", format.rawValue, type.hexDigits, subtype.hexDigits, manufacturer.hexDigits]
            .joined(separator: ".")
        guard let id = PluginID(rawValue: raw) else {
            preconditionFailure("Hex plugin IDs are always valid contract IDs")
        }
        return id
    }
}

/// An Audio Unit version word, `0xMMMMmmbb`. Ordering is informational; it is
/// never used to choose between identities.
struct PluginVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    var major: Int { Int(rawValue >> 16) }
    var minor: Int { Int((rawValue >> 8) & 0xFF) }
    var bugFix: Int { Int(rawValue & 0xFF) }
    var description: String { "\(major).\(minor).\(bugFix)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
