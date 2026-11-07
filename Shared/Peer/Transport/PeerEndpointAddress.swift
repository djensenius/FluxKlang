//
//  PeerEndpointAddress.swift
//  FluxKlang
//
//  A validated peer endpoint (address bytes, port, optional IPv6 zone) and its
//  classification (#93, slice P4). Classification works on bytes only: there is
//  no text parsing of addresses. An IPv4-mapped IPv6 address (::ffff:a.b.c.d)
//  classifies as the embedded IPv4 address, so it cannot launder past a policy.
//
//  IPv4 outside the named ranges is `publicRange`, including 0.0.0.0/8 other
//  than 0.0.0.0 and the reserved 240.0.0.0/4 other than 255.255.255.255: they
//  are never local, which is the conservative reading. IPv6 site-local
//  (fec0::/10, deprecated) is also `publicRange`.
//

enum PeerAddressClass: Hashable, Sendable, CaseIterable {
    case loopback, linkLocal, privateRange, publicRange, unspecified, multicast, broadcast
}

/// Constructible only through `make`; the stored fields are never mutable from outside this file.
struct PeerEndpointAddress: Hashable, Sendable {
    static let ipv4Length = 4
    static let ipv6Length = 16

    private(set) var octets: [UInt8]
    private(set) var port: UInt16
    private(set) var zoneIndex: UInt32?

    private init(octets: [UInt8], port: UInt16, zoneIndex: UInt32?) {
        self.octets = octets
        self.port = port
        self.zoneIndex = zoneIndex
    }

    /// Refusal order: length, port, zone-not-allowed, zone 0.
    static func make(
        octets: [UInt8],
        port: UInt16,
        zoneIndex: UInt32?
    ) throws(PeerEndpointRefusal) -> PeerEndpointAddress {
        guard octets.count == ipv4Length || octets.count == ipv6Length else {
            throw .badLength(count: octets.count)
        }
        guard port != 0 else { throw .badPort }
        if let zone = zoneIndex {
            guard isNativeLinkLocalIPv6(octets) else { throw .zoneNotAllowed }
            guard zone != 0 else { throw .badZone }
        }
        return PeerEndpointAddress(octets: octets, port: port, zoneIndex: zoneIndex)
    }

    var isIPv4Mapped: Bool {
        octets.count == Self.ipv6Length && Self.isMapped(octets)
    }

    /// The IPv4 bytes of a native IPv4 address or of an IPv4-mapped IPv6 address; `nil` otherwise.
    var embeddedIPv4: [UInt8]? {
        if octets.count == Self.ipv4Length { return octets }
        return isIPv4Mapped ? Array(octets[12...]) : nil
    }

    var classification: PeerAddressClass {
        if let ipv4 = embeddedIPv4 { return Self.classifyIPv4(ipv4) }
        return Self.classifyIPv6(octets)
    }

    private static func isMapped(_ bytes: [UInt8]) -> Bool {
        bytes[..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
    }

    private static func isNativeLinkLocalIPv6(_ bytes: [UInt8]) -> Bool {
        bytes.count == ipv6Length && classifyIPv6(bytes) == .linkLocal
    }

    private static func classifyIPv4(_ bytes: [UInt8]) -> PeerAddressClass {
        let first = bytes[0]
        let second = bytes[1]
        if bytes == [255, 255, 255, 255] { return .broadcast }
        if bytes == [0, 0, 0, 0] { return .unspecified }
        switch first {
        case 127: return .loopback
        case 10: return .privateRange
        case 224...239: return .multicast
        case 169 where second == 254: return .linkLocal
        case 172 where (16...31).contains(second): return .privateRange
        case 192 where second == 168: return .privateRange
        default: return .publicRange
        }
    }

    private static func classifyIPv6(_ bytes: [UInt8]) -> PeerAddressClass {
        if bytes.allSatisfy({ $0 == 0 }) { return .unspecified }
        if bytes[..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .loopback }
        if bytes[0] == 0xFF { return .multicast }
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return .linkLocal }
        if (bytes[0] & 0xFE) == 0xFC { return .privateRange }
        return .publicRange
    }
}
