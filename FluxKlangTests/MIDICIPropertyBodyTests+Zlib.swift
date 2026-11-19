//
//  MIDICIPropertyBodyTests+Zlib.swift
//  FluxKlangTests
//
//  #858: fixed Python stdlib zlib goldens, independently Mcoded7-packed, not produced by this decoder.
//  The binary plaintext is deliberately not JSON. No MIDI specification/interoperability claim.
//

import Testing
import zlib
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIPropertyBodyTests {
    static let zlibPlaintext: [UInt8] = [
        0, 128, 255, 70, 108, 117, 120, 75, 108, 97, 110, 103, 0, 110, 111, 116, 32, 74, 83, 79, 78, 13, 10,
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
        28, 29, 30, 31
    ]
    static let zlibGolden: [UInt8] = [
        39, 120, 28, 99, 104, 120, 111, 22, 31, 83, 90, 97, 29, 19, 24, 23, 118, 78, 16, 23, 95, 34, 96, 21,
        127, 108, 111, 71, 75, 69, 64, 72, 127, 68, 76, 66, 74, 70, 78, 65, 126, 73, 69, 77, 67, 75, 71, 47,
        0, 32, 40, 36, 44, 34, 42, 38, 0, 46, 33, 41, 37, 45, 35, 43, 5, 39, 15, 0, 121, 99, 9, 62
    ]

    // Original witness retained separately for byte-faithful execution against the pinned unsupported baseline.
    @Test func zlibGoldenDecodesThroughExistingBodyAPI() throws {
        try #require(Self.zlibGolden.count == 72 && Self.zlibPlaintext.count == 55)
        let decoded = try MIDICIPropertyBody.decode(Self.zlibGolden, encoding: .zlibMcoded7)
        #expect(decoded == Self.zlibPlaintext)
    }

    static let zlibEmpty: [UInt8] = [0x78, 0x9C, 0x03, 0, 0, 0, 0, 1]
    static let zlibEmptyWire: [UInt8] = [0x20, 0x78, 0x1C, 3, 0, 0, 0, 0, 0, 1]
    static let malformedZlibNames = [
        "absent", "truncatedEmpty", "checksum", "dictionary", "trailing", "concatenated", "raw", "gzip",
        "header", "deflate"
    ]

    /// Independent Python-zlib output, represented compactly without running a compressor in the tests.
    /// Every vector is pinned in the retained generator evidence; the zero runs are literal compressed bytes.
    static func repeatedZlib(_ count: Int) throws -> [UInt8] {
        let prefix: [UInt8] = [120, 218, 237, 193, 49, 1, 0, 0, 0, 194, 160, 108, 235, 95, 202]
        switch count {
        case 262_143:
            return prefix + [219, 14, 64, 1] + [UInt8](repeating: 0, count: 253) + [156, 1, 193, 180, 14, 252]
        case 262_144:
            return prefix + [219, 14, 64, 1] + [UInt8](repeating: 0, count: 253) + [188, 1, 208, 241, 15, 61]
        case 262_145:
            return prefix + [223, 12, 64, 1] + [UInt8](repeating: 0, count: 253) + [156, 1, 224, 111, 15, 126]
        default:
            try #require(count == 1_048_576)
            return prefix + [16, 190, 64, 1] + [UInt8](repeating: 0, count: 1_015) + [124, 6, 177, 140, 60, 241]
        }
    }

    /// Fixed compression-stage faults. Mcoded7 is applied afterward so none is accidentally a packing refusal.
    static func malformedZlib(_ name: String) throws -> [UInt8] {
        switch name {
        case "absent": return []
        case "truncatedEmpty": return Array(zlibEmpty.dropLast())
        case "checksum": return Array(zlibEmpty.dropLast()) + [0]
        // RFC1950 FDICT header plus the independently generated dictionary stream.
        case "dictionary":
            return [
                120, 187, 80, 148, 7, 227, 99, 104, 248, 239, 6, 19, 102, 200, 203, 47, 81, 240, 10, 246, 247,
                227, 229, 98, 96, 100, 98, 102, 97, 101, 99, 231, 224, 228, 226, 230, 225, 229, 227, 23, 16,
                20, 18, 22, 17, 21, 19, 151, 144, 148, 146, 150, 145, 149, 147, 7, 0, 121, 227, 9, 190
            ]
        case "trailing": return zlibEmpty + [0]
        case "concatenated": return zlibEmpty + zlibEmpty
        // A raw empty DEFLATE stream and a fixed gzip-wrapped empty stream, not RFC1950.
        case "raw": return [3, 0]
        case "gzip": return [31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case "header": return [0, 0] + Array(zlibEmpty.dropFirst(2))
        default:
            try #require(name == "deflate")
            return [0x78, 0x9C, 0x07, 0, 0, 0, 0, 1] // Reserved DEFLATE BTYPE.
        }
    }

    /// Independent bounded reference entry point for the existing seeded oracle (not the helper under test).
    /// uncompress2 reports input consumed, unlike uncompress; require it all to reject suffixes.
    static func zlibReference(_ compressed: [UInt8]) -> Result<[UInt8], Refusal> {
        var output = [UInt8](repeating: 0, count: 262_145)
        var produced = uLongf(output.count)
        var consumed = uLong(compressed.count)
        let status = compressed.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                uncompress2(destination.baseAddress, &produced, source.baseAddress, &consumed)
            }
        }
        if produced > 262_144 { return .failure(.decodedTooLong(limit: 262_144)) }
        guard status == Z_OK, consumed == compressed.count else { return .failure(.invalidCompressedData) }
        return .success(Array(output.prefix(Int(produced))))
    }

    @Test func zlibValidEmptyAndHeaderConvenienceSucceed() throws {
        #expect(try MIDICIPropertyBody.decode(Self.zlibEmptyWire, encoding: .zlibMcoded7) == [])
        let header = try MIDICIPropertyHeader.parse(Array(#"{"mutualEncoding":"zlib+Mcoded7"}"#.utf8))
        #expect(try header.decodeBody(Self.zlibGolden) == Self.zlibPlaintext)
        #expect(try header.decodeBody(Self.zlibEmptyWire) == [])
        #expect(Self.zlibReference(Self.zlibEmpty) == .success([]))
        // Six unused header bits on the short last Mcoded7 group remain ignored.
        var unusedBits = Self.zlibEmptyWire
        try #require(unusedBits.count == 10)
        unusedBits[8] = 0x3F
        #expect(try header.decodeBody(unusedBits) == [])
    }

    @Test(arguments: 0..<8)
    func zlibEveryTruncatedEmptyPrefixIsMalformed(count: Int) {
        let truncated = Array(Self.zlibEmpty.prefix(count))
        #expect(Self.outcome(MIDICIMcoded7.encode(truncated), .zlibMcoded7) == .failure(.invalidCompressedData))
    }

    @Test(arguments: [262_143, 262_144])
    func zlibDecodedCeilingIsInclusive(count: Int) throws {
        let compressed = try Self.repeatedZlib(count)
        try #require(compressed.count == 278)
        let coded = MIDICIMcoded7.encode(compressed)
        try #require(coded.count == 318)
        let decoded = try MIDICIPropertyBody.decode(coded, encoding: .zlibMcoded7)
        #expect(decoded.count == count)
        #expect(decoded.firstIndex { $0 != 0x41 } == nil)
        #expect(Self.zlibReference(compressed).map(\.count) == .success(count))
    }

    @Test(arguments: [262_145, 1_048_576])
    func zlibOverflowReturnsNoPartialBody(count: Int) throws {
        let compressed = try Self.repeatedZlib(count)
        let coded = MIDICIMcoded7.encode(compressed)
        try #require(coded.count < 2_000)
        let first = Self.outcome(coded, .zlibMcoded7)
        #expect(first == .failure(.decodedTooLong(limit: 262_144)))
        #expect(Self.outcome(coded, .zlibMcoded7) == first)
        #expect(Self.zlibReference(compressed) == first)
    }

    @Test(arguments: MIDICIPropertyBodyTests.malformedZlibNames)
    func zlibMalformedStreamsReturnOnlyTypedFailure(name: String) throws {
        let compressed = try Self.malformedZlib(name)
        let coded = MIDICIMcoded7.encode(compressed)
        #expect(Self.outcome(coded, .zlibMcoded7) == .failure(.invalidCompressedData))
        #expect(Self.outcome(coded, .zlibMcoded7) == Self.outcome(coded, .zlibMcoded7))
        #expect(Self.zlibReference(compressed) == .failure(.invalidCompressedData))
    }

    @Test func zlibChecksumAndTruncationNeverReturnAValidPrefix() throws {
        let compressed = try MIDICIMcoded7.decode(Self.zlibGolden)
        try #require(compressed.count == 63)
        // All proper prefixes, including ones that yield plaintext but no complete checksum.
        for count in 0..<compressed.count {
            let coded = MIDICIMcoded7.encode(Array(compressed.prefix(count)))
            #expect(Self.outcome(coded, .zlibMcoded7) == .failure(.invalidCompressedData))
        }
        for offset in (compressed.count - 4)..<compressed.count {
            var corrupt = compressed
            corrupt[offset] ^= 1
            #expect(Self.outcome(MIDICIMcoded7.encode(corrupt), .zlibMcoded7) == .failure(.invalidCompressedData))
        }
        for suffix in [[UInt8](arrayLiteral: 0), compressed, Self.zlibEmpty] {
            let coded = MIDICIMcoded7.encode(compressed + suffix)
            #expect(Self.outcome(coded, .zlibMcoded7) == .failure(.invalidCompressedData))
        }
    }

    @Test(arguments: [262_144, 262_145, 1_048_576])
    func zlibDetectedOverflowWinsOverLaterIntegrityFaults(count: Int) throws {
        let compressed = try Self.repeatedZlib(count)
        try #require(compressed.count > 4)
        let expected: Refusal = count > 262_144 ? .decodedTooLong(limit: 262_144) : .invalidCompressedData
        let faults = [
            Array(compressed.dropLast()) + [0],
            Array(compressed.dropLast(4)),
            compressed + [0],
            compressed + Self.zlibEmpty
        ]
        for faulty in faults {
            #expect(Self.outcome(MIDICIMcoded7.encode(faulty), .zlibMcoded7) == .failure(expected))
        }
    }

    @Test func zlibMcoded7AndEncodedSizeChecksKeepPrecedence() throws {
        let bomb = MIDICIMcoded7.encode(try Self.repeatedZlib(1_048_576))
        try #require(!bomb.isEmpty)
        var high = bomb
        high[high.count - 1] = 0x80
        #expect(Self.outcome(high, .zlibMcoded7) == .failure(.byteHigh(offset: high.count - 1)))
        // An otherwise valid compressed binary body has exactly nine full groups.
        try #require(Self.zlibGolden.count == 72)
        #expect(Self.outcome(Self.zlibGolden + [0], .zlibMcoded7) == .failure(.truncatedGroup(offset: 72)))
        #expect(Self.outcome(Self.zlibGolden + [0x80], .zlibMcoded7) == .failure(.byteHigh(offset: 72)))
        #expect(Self.outcome([0, 0x80] + [UInt8](repeating: 0, count: 7), .zlibMcoded7)
            == .failure(.byteHigh(offset: 1)))
        let over = Self.zlibGolden + [UInt8](repeating: 0x80, count: 262_145 - Self.zlibGolden.count)
        for encoding in Self.encodings {
            #expect(Self.outcome(over, encoding) == .failure(.tooLong(count: 262_145, limit: 262_144)))
        }
        #expect(Self.outcome(high, .other("zlib")) == .failure(.unsupportedEncoding(.other("zlib"))))
    }
}
