//
//  PeerEndpointPolicyTests.swift
//  FluxKlangTests
//
//  Address construction limits and shared fixtures for the peer endpoint policy (#93, slice P4).
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct PeerEndpointPolicyTests {
    static func v4Bytes(_ first: UInt8, _ second: UInt8, _ third: UInt8, _ fourth: UInt8) -> [UInt8] {
        [first, second, third, fourth]
    }

    /// `head` bytes, then zeros, then `tail` bytes, 16 in total.
    static func v6Bytes(_ head: [UInt8], tail: [UInt8] = []) -> [UInt8] {
        head + Array(repeating: 0, count: 16 - head.count - tail.count) + tail
    }

    static func mappedBytes(_ first: UInt8, _ second: UInt8, _ third: UInt8, _ fourth: UInt8) -> [UInt8] {
        v6Bytes([], tail: [0xFF, 0xFF, first, second, third, fourth])
    }

    static func address(
        _ octets: [UInt8],
        port: UInt16 = 4_242,
        zone: UInt32? = nil
    ) throws -> PeerEndpointAddress {
        try PeerEndpointAddress.make(octets: octets, port: port, zoneIndex: zone)
    }

    static func mask(_ octets: [UInt8], _ bits: Int) throws -> PeerAddressMask {
        try PeerAddressMask.make(octets: octets, prefixBits: bits)
    }

    static func policy(
        allowed: Set<PeerAddressClass> = Set(PeerAddressClass.allCases),
        denied: [PeerAddressMask] = [],
        localLink: Bool = false,
        manual: Bool = true
    ) throws -> PeerEndpointPolicy {
        try PeerEndpointPolicy.make(
            allowedClasses: allowed,
            denied: denied,
            requireLocalLink: localLink,
            manualEntryAllowed: manual
        )
    }

    @Test func anAddressIsFourOrSixteenOctetsAndEveryOtherLengthRefusesWithItsCount() {
        for count in [0, 1, 3, 5, 15, 17, 32] {
            #expect(throws: PeerEndpointRefusal.badLength(count: count)) {
                try Self.address(Array(repeating: 1, count: count))
            }
        }
        #expect((try? Self.address(Self.v4Bytes(1, 2, 3, 4))) != nil)
        #expect((try? Self.address(Self.v6Bytes([0x20, 0x01]))) != nil)
    }

    @Test func thePortIsOneToSixtyFiveThousandFiveHundredThirtyFiveAndZeroRefuses() throws {
        #expect(throws: PeerEndpointRefusal.badPort) { try Self.address(Self.v4Bytes(1, 2, 3, 4), port: 0) }
        let low = try Self.address(Self.v4Bytes(1, 2, 3, 4), port: 1)
        let high = try Self.address(Self.v4Bytes(1, 2, 3, 4), port: 65_535)
        #expect(low.port == 1)
        #expect(high.port == 65_535)
    }

    @Test func aBuiltAddressKeepsItsOctetsPortAndZoneVerbatim() throws {
        let bytes = Self.v6Bytes([0xFE, 0x80], tail: [0, 0, 0, 0, 0, 0, 0xAB, 0xCD])
        let built = try Self.address(bytes, port: 9_001, zone: 7)
        #expect(built.octets == bytes)
        #expect(built.port == 9_001)
        #expect(built.zoneIndex == 7)
        let plain = try Self.address(Self.v4Bytes(9, 8, 7, 6), port: 12)
        #expect(plain.zoneIndex == nil)
        #expect(plain.octets == [9, 8, 7, 6])
    }

    @Test func aZoneIsAcceptedOnlyOnNativeIPv6LinkLocalAddresses() throws {
        let linkLocal = Self.v6Bytes([0xFE, 0x80])
        let edgeLow = Self.v6Bytes([0xFE, 0x80], tail: [1])
        let edgeHigh = Array([0xFE, 0xBF] + Array(repeating: UInt8(0xFF), count: 14))
        for bytes in [linkLocal, edgeLow, edgeHigh] {
            #expect(try Self.address(bytes, zone: 1).zoneIndex == 1)
        }
        #expect(try Self.address(linkLocal, zone: UInt32.max).zoneIndex == UInt32.max)
        let refused: [[UInt8]] = [
            Self.v6Bytes([0xFE, 0xC0]), Self.v6Bytes([0xFE, 0x7F]), Self.v6Bytes([0x20, 0x01]),
            Self.v6Bytes([], tail: [1]), Self.v6Bytes([0xFD]), Self.v4Bytes(169, 254, 1, 1),
            Self.v4Bytes(10, 0, 0, 1), Self.mappedBytes(169, 254, 1, 1)
        ]
        for bytes in refused {
            #expect(throws: PeerEndpointRefusal.zoneNotAllowed) { try Self.address(bytes, zone: 1) }
        }
    }

    @Test func aZoneOfZeroRefusesOnALinkLocalAddress() {
        #expect(throws: PeerEndpointRefusal.badZone) { try Self.address(Self.v6Bytes([0xFE, 0x80]), zone: 0) }
    }

    @Test func addressRefusalOrderIsLengthThenPortThenZoneAllowedThenZoneZero() {
        #expect(throws: PeerEndpointRefusal.badLength(count: 5)) {
            try Self.address([1, 2, 3, 4, 5], port: 0, zone: 1)
        }
        #expect(throws: PeerEndpointRefusal.badPort) {
            try Self.address(Self.v4Bytes(1, 2, 3, 4), port: 0, zone: 1)
        }
        #expect(throws: PeerEndpointRefusal.zoneNotAllowed) {
            try Self.address(Self.v4Bytes(1, 2, 3, 4), zone: 0)
        }
        #expect(throws: PeerEndpointRefusal.badZone) {
            try Self.address(Self.v6Bytes([0xFE, 0x80]), port: 5, zone: 0)
        }
    }

    @Test func equalOctetsPortAndZoneGiveEqualAddressesAndAnyDifferenceDoesNot() throws {
        let base = try Self.address(Self.v4Bytes(10, 0, 0, 1), port: 80)
        #expect(base == (try Self.address(Self.v4Bytes(10, 0, 0, 1), port: 80)))
        #expect(base != (try Self.address(Self.v4Bytes(10, 0, 0, 2), port: 80)))
        #expect(base != (try Self.address(Self.v4Bytes(10, 0, 0, 1), port: 81)))
        let zoned = try Self.address(Self.v6Bytes([0xFE, 0x80]), zone: 3)
        #expect(zoned != (try Self.address(Self.v6Bytes([0xFE, 0x80]), zone: 4)))
        #expect(zoned != (try Self.address(Self.v6Bytes([0xFE, 0x80]))))
    }
}
