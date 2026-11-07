//
//  PeerEndpointPolicyTests+Classify.swift
//  FluxKlangTests
//
//  Classification of address bytes: every prefix edge at N and N+1, and IPv4-mapped IPv6 (#93, slice P4).
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Rows = [([UInt8], PeerAddressClass)]
private typealias Subject = PeerEndpointPolicyTests

private func b4(_ first: UInt8, _ second: UInt8, _ third: UInt8, _ fourth: UInt8) -> [UInt8] {
    Subject.v4Bytes(first, second, third, fourth)
}

private func b6(_ head: [UInt8], tail: [UInt8] = []) -> [UInt8] { Subject.v6Bytes(head, tail: tail) }

private func bm(_ first: UInt8, _ second: UInt8, _ third: UInt8, _ fourth: UInt8) -> [UInt8] {
    Subject.mappedBytes(first, second, third, fourth)
}

private func fill(_ head: UInt8, count: Int) -> [UInt8] { [head] + Array(repeating: UInt8(0xFF), count: count) }

extension PeerEndpointPolicyTests {
    private static func mismatches(_ rows: Rows) throws -> [String] {
        try rows.compactMap { bytes, expected in
            let actual = try address(bytes).classification
            return actual == expected ? nil : "\(bytes) expected \(expected) got \(actual)"
        }
    }

    @Test func ipv4RangeEdgesClassifyAtNAndNPlusOne() throws {
        let rows: Rows = [
            (b4(0, 0, 0, 0), .unspecified), (b4(0, 0, 0, 1), .publicRange),
            (b4(1, 1, 1, 1), .publicRange), (b4(8, 8, 8, 8), .publicRange),
            (b4(9, 255, 255, 255), .publicRange), (b4(10, 0, 0, 0), .privateRange),
            (b4(10, 255, 255, 255), .privateRange), (b4(11, 0, 0, 0), .publicRange),
            (b4(126, 255, 255, 255), .publicRange), (b4(127, 0, 0, 0), .loopback),
            (b4(127, 0, 0, 1), .loopback), (b4(127, 255, 255, 255), .loopback),
            (b4(128, 0, 0, 0), .publicRange), (b4(223, 255, 255, 255), .publicRange),
            (b4(224, 0, 0, 0), .multicast), (b4(239, 255, 255, 255), .multicast),
            (b4(240, 0, 0, 0), .publicRange), (b4(255, 255, 255, 254), .publicRange),
            (b4(255, 255, 255, 255), .broadcast)
        ]
        #expect(try Self.mismatches(rows) == [])
    }

    @Test func theSeventeenTwoZeroBlockEdgesClassifyAtNAndNPlusOne() throws {
        let rows: Rows = [
            (b4(172, 15, 255, 255), .publicRange), (b4(172, 16, 0, 0), .privateRange),
            (b4(172, 20, 1, 1), .privateRange), (b4(172, 31, 255, 255), .privateRange),
            (b4(172, 32, 0, 0), .publicRange), (b4(171, 16, 0, 0), .publicRange),
            (b4(173, 16, 0, 0), .publicRange)
        ]
        #expect(try Self.mismatches(rows) == [])
    }

    @Test func theOneNineTwoOneSixEightBlockEdgesClassifyAtNAndNPlusOne() throws {
        let rows: Rows = [
            (b4(192, 167, 255, 255), .publicRange), (b4(192, 168, 0, 0), .privateRange),
            (b4(192, 168, 255, 255), .privateRange), (b4(192, 169, 0, 0), .publicRange),
            (b4(191, 168, 0, 1), .publicRange), (b4(193, 168, 0, 1), .publicRange)
        ]
        #expect(try Self.mismatches(rows) == [])
    }

    @Test func theLinkLocalIPv4BlockEdgesClassifyAtNAndNPlusOne() throws {
        let rows: Rows = [
            (b4(169, 253, 255, 255), .publicRange), (b4(169, 254, 0, 0), .linkLocal),
            (b4(169, 254, 169, 254), .linkLocal), (b4(169, 254, 255, 255), .linkLocal),
            (b4(169, 255, 0, 0), .publicRange), (b4(168, 254, 0, 0), .publicRange),
            (b4(170, 254, 0, 0), .publicRange)
        ]
        #expect(try Self.mismatches(rows) == [])
    }

    @Test func ipv6RangeEdgesClassifyAtNAndNPlusOne() throws {
        let rows: Rows = [
            (b6([]), .unspecified), (b6([], tail: [1]), .loopback),
            (b6([], tail: [2]), .publicRange), (b6([], tail: [1, 0]), .publicRange),
            (b6([0, 1], tail: [1]), .publicRange), (b6([0x20, 0x01, 0x0D, 0xB8]), .publicRange),
            (b6([0xFE, 0x7F]), .publicRange), (b6([0xFE, 0x80]), .linkLocal),
            (b6([0x01, 0x80]), .publicRange), (b6([0xFD, 0x80]), .privateRange),
            (b6([0xFE, 0x80, 0x12]), .linkLocal), (b6([0xFE, 0xBF]), .linkLocal),
            ([0xFE, 0xBF] + Array(repeating: UInt8(0xFF), count: 14), .linkLocal),
            (b6([0xFE, 0xC0]), .publicRange), (b6([0xFE, 0x00]), .publicRange),
            (b6([0xFE, 0xFF]), .publicRange), (b6([0xFB]), .publicRange),
            (fill(0xFB, count: 15), .publicRange), (b6([0xFC]), .privateRange),
            (b6([0xFD, 0x12]), .privateRange), (fill(0xFD, count: 15), .privateRange),
            (b6([0xFE]), .publicRange), (b6([0xFF]), .multicast), (fill(0xFF, count: 15), .multicast)
        ]
        #expect(try Self.mismatches(rows) == [])
    }

    @Test func anIPv4MappedIPv6AddressClassifiesAsItsEmbeddedIPv4Address() throws {
        let rows: Rows = [
            (bm(8, 8, 8, 8), .publicRange), (bm(127, 0, 0, 1), .loopback),
            (bm(10, 0, 0, 1), .privateRange), (bm(172, 16, 0, 1), .privateRange),
            (bm(172, 32, 0, 1), .publicRange), (bm(192, 168, 1, 1), .privateRange),
            (bm(169, 254, 1, 1), .linkLocal), (bm(169, 255, 0, 0), .publicRange),
            (bm(224, 0, 0, 1), .multicast), (bm(0, 0, 0, 0), .unspecified),
            (bm(255, 255, 255, 255), .broadcast)
        ]
        #expect(try Self.mismatches(rows) == [])
        let mapped = try Self.address(bm(8, 8, 8, 8))
        #expect(mapped.isIPv4Mapped)
        #expect(mapped.embeddedIPv4 == [8, 8, 8, 8])
    }

    @Test func lookalikesOfTheMappedPrefixAreNativeIPv6AndStayPublic() throws {
        let tail: [UInt8] = [0x7F, 0, 0, 1]
        let rows: Rows = [
            (b6([], tail: [0xFF, 0xFE] + tail), .publicRange), (b6([], tail: [0xFE, 0xFF] + tail), .publicRange),
            (b6([], tail: [0x01, 0xFF, 0xFF] + tail), .publicRange),
            (b6([1], tail: [0xFF, 0xFF] + tail), .publicRange), (b6([], tail: tail), .publicRange)
        ]
        #expect(try Self.mismatches(rows) == [])
        let native = try Self.address(b6([], tail: [0xFF, 0xFE] + tail))
        #expect(!native.isIPv4Mapped)
        #expect(native.embeddedIPv4 == nil)
        let mapped = try Self.address(Self.mappedBytes(127, 0, 0, 1))
        #expect(mapped.isIPv4Mapped)
        #expect(mapped.embeddedIPv4 == [127, 0, 0, 1])
        #expect(try Self.address(b4(1, 2, 3, 4)).embeddedIPv4 == [1, 2, 3, 4])
        #expect(try Self.address(b4(1, 2, 3, 4)).isIPv4Mapped == false)
    }
}
