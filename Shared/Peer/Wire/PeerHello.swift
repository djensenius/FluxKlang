//
//  PeerHello.swift
//  FluxKlang
//
//  Capability-hello payloads (#93). Capabilities name protocol features a peer
//  declares it can speak; they are not permissions or grants (#94). Every
//  payload has one canonical encoding: tokens strictly ascending, no trailing
//  bytes. Anything else is refused as malformed.
//

import Foundation

/// A declared protocol feature token: 1–32 bytes of `a-z`, `0-9`, `.` or `-`,
/// starting with a letter, ending with a letter or digit, and with no two
/// separators in a row. Ordered by UTF-8 bytes. Well-formed tokens outside the
/// initial vocabulary are carried and simply never shared unless both sides
/// declare them.
struct PeerCapability: Hashable, Comparable, Sendable, CustomStringConvertible {
    static let utf8Bounds = 1...32

    /// Initial frozen vocabulary (#92: control/status/telemetry only initially).
    static let control = PeerCapability(uncheckedRawValue: "control")
    static let status = PeerCapability(uncheckedRawValue: "status")
    static let telemetry = PeerCapability(uncheckedRawValue: "telemetry")
    static let initialVocabulary: [PeerCapability] = [control, status, telemetry]

    let rawValue: String

    init?(_ rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard Self.utf8Bounds.contains(bytes.count), let first = bytes.first, let last = bytes.last,
              Self.isLetter(first), Self.isAlphanumeric(last),
              bytes.allSatisfy({ Self.isAlphanumeric($0) || Self.isSeparator($0) }),
              !zip(bytes, bytes.dropFirst()).contains(where: { Self.isSeparator($0) && Self.isSeparator($1) })
        else { return nil }
        self.rawValue = rawValue
    }

    private init(uncheckedRawValue: String) {
        rawValue = uncheckedRawValue
    }

    var description: String { rawValue }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8) }

    private static func isLetter(_ byte: UInt8) -> Bool { (0x61...0x7A).contains(byte) }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool { isLetter(byte) || (0x30...0x39).contains(byte) }

    private static func isSeparator(_ byte: UInt8) -> Bool { byte == 0x2E || byte == 0x2D }
}

/// A sorted, duplicate-free set of at most `maximumCount` capabilities.
struct PeerCapabilitySet: Hashable, Sendable {
    static let maximumCount = 16
    static let empty = PeerCapabilitySet(sortedUnique: [])

    let members: [PeerCapability]

    init?(_ capabilities: some Sequence<PeerCapability>) {
        let sorted = Set(capabilities).sorted()
        guard sorted.count <= Self.maximumCount else { return nil }
        members = sorted
    }

    private init(sortedUnique: [PeerCapability]) {
        members = sortedUnique
    }

    func contains(_ capability: PeerCapability) -> Bool { members.contains(capability) }

    func isSubset(of other: Self) -> Bool { members.allSatisfy(other.contains) }

    func intersection(_ other: Self) -> Self { Self(sortedUnique: members.filter(other.contains)) }

    func encode(into writer: inout PeerWireWriter) {
        writer.append(UInt8(members.count))
        for member in members {
            writer.append(UInt8(member.rawValue.utf8.count))
            writer.append(member.rawValue.utf8)
        }
    }

    static func decode(from reader: inout PeerWireReader) throws(PeerWireError) -> Self {
        let count = Int(try reader.readUInt8())
        guard count <= maximumCount else { throw .malformedPayload(reader.kind) }
        var members: [PeerCapability] = []
        for _ in 0..<count {
            let length = Int(try reader.readUInt8())
            let bytes = try reader.readBytes(count: length)
            guard let token = String(validating: bytes, as: UTF8.self), let capability = PeerCapability(token),
                  members.last.map({ $0 < capability }) ?? true else { throw .malformedPayload(reader.kind) }
            members.append(capability)
        }
        return Self(sortedUnique: members)
    }
}

/// The initiator's declaration: versions it speaks, capabilities it offers and
/// the subset it requires.
struct PeerHello: Hashable, Sendable {
    let versions: ClosedRange<UInt16>
    let offered: PeerCapabilitySet
    let required: PeerCapabilitySet

    init?(versions: ClosedRange<UInt16>, offered: PeerCapabilitySet, required: PeerCapabilitySet) {
        guard versions.lowerBound >= 1, required.isSubset(of: offered) else { return nil }
        self.versions = versions
        self.offered = offered
        self.required = required
    }

    func encoded() -> [UInt8] {
        var writer = PeerWireWriter()
        writer.append(versions.lowerBound)
        writer.append(versions.upperBound)
        offered.encode(into: &writer)
        var mask: UInt16 = 0
        for (index, member) in offered.members.enumerated() where required.contains(member) {
            mask |= 1 << UInt16(index)
        }
        writer.append(mask)
        return writer.bytes
    }

    static func decode(_ payload: [UInt8]) throws(PeerWireError) -> Self {
        var reader = PeerWireReader(payload, kind: .hello)
        let lower = try reader.readUInt16()
        let upper = try reader.readUInt16()
        guard lower >= 1, lower <= upper else { throw .malformedPayload(.hello) }
        let offered = try PeerCapabilitySet.decode(from: &reader)
        let mask = try reader.readUInt16()
        try reader.finish()
        guard mask >> UInt16(offered.members.count) == 0 else { throw .malformedPayload(.hello) }
        let required = offered.members.enumerated().filter { mask & (1 << UInt16($0.offset)) != 0 }.map(\.element)
        guard let requiredSet = PeerCapabilitySet(required),
              let hello = Self(versions: lower...upper, offered: offered, required: requiredSet) else {
            throw .malformedPayload(.hello)
        }
        return hello
    }
}

/// The acceptor's answer. Its frame header must carry `connectionEpoch`.
struct PeerHelloAccept: Hashable, Sendable {
    let version: UInt16
    let hostEpoch: Generation
    let connectionEpoch: Generation
    let capabilities: PeerCapabilitySet

    func encoded() -> [UInt8] {
        var writer = PeerWireWriter()
        writer.append(version)
        writer.append(PeerWireEpoch.encode(hostEpoch))
        writer.append(PeerWireEpoch.encode(connectionEpoch))
        capabilities.encode(into: &writer)
        return writer.bytes
    }

    static func decode(_ payload: [UInt8]) throws(PeerWireError) -> Self {
        var reader = PeerWireReader(payload, kind: .helloAccept)
        let version = try reader.readUInt16()
        let rawHost = try reader.readUInt64()
        let rawConnection = try reader.readUInt64()
        let capabilities = try PeerCapabilitySet.decode(from: &reader)
        try reader.finish()
        guard version >= 1, let host = try? PeerWireEpoch.decode(rawHost),
              let connection = try? PeerWireEpoch.decode(rawConnection) else {
            throw .malformedPayload(.helloAccept)
        }
        return Self(version: version, hostEpoch: host, connectionEpoch: connection, capabilities: capabilities)
    }
}

/// Why an acceptor refused a hello. Unknown codes are malformed.
enum PeerRejectReason: UInt8, Hashable, Sendable, CaseIterable {
    case incompatibleVersion = 1
    case missingRequiredCapability = 2
    case malformedHello = 3
    /// The host cannot offer peer control here (for example Local Network denied).
    case ineligible = 4
    /// The host declined this connection; the deciding policy belongs to #94.
    case denied = 5

    var encoded: [UInt8] { [rawValue] }

    static func decode(_ payload: [UInt8]) throws(PeerWireError) -> Self {
        guard payload.count == 1, let reason = Self(rawValue: payload[0]) else {
            throw .malformedPayload(.helloReject)
        }
        return reason
    }
}
