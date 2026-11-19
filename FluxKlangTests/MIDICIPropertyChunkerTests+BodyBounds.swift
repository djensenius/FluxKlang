//
//  MIDICIPropertyChunkerTests+BodyBounds.swift
//  FluxKlangTests
//
//  #865: independent inclusive raw/encoded bounds, expansion before allocation, and bounded zlib overflow.
//  Large successful round trips use a 4,096-byte payload so they stay below the reassembler's 256-count cap.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIPropertyChunkerTests {
    /// Fixed xorshift64* byte fixture: incompressible in these cases, without external randomness or a provider.
    /// No expected compressed byte string is pinned to a particular SDK.
    static func rawNoise(_ count: Int) -> [UInt8] {
        var state: UInt64 = 0x8650_0083_0048_1234
        return (0..<count).map { _ in
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return UInt8(truncatingIfNeeded: (state &* 0x2545_F491_4F6C_DD1D) >> 56)
        }
    }

    @Test(arguments: [262_143, 262_144])
    func rawASCIICeilingIsInclusiveAndAlsoReachesEncodedCeiling(count: Int) throws {
        let raw = Self.data(count)
        let messages = try Self.rawCut(rawBody: raw)
        #expect(messages.flatMap(\.chunk.propertyData) == raw)
        // H=2, first capacity=4072, then 4074. These are 65 chunks, not a lowered chunker cap.
        #expect(messages.count == 65)
        _ = try Self.rawContent(messages, headerData: Self.rawEmptyHeader, rawBody: raw, limit: 4_096)
    }

    @Test(arguments: [262_143, 262_144])
    func rawZlibAcceptsRawCeilingWhenCompressedBodyFits(count: Int) throws {
        let raw = [UInt8](repeating: 0xFF, count: count)
        let messages = try Self.rawCut(headerData: Self.rawZlibHeader, rawBody: raw)
        #expect(messages.flatMap(\.chunk.propertyData).count < count)
        _ = try Self.rawContent(messages, headerData: Self.rawZlibHeader, rawBody: raw, limit: 4_096)
        try Self.checkRawCompressedOutput(messages, plaintext: raw)
    }

    @Test func rawCeilingCannotBeEvadedByCompressionOrUnknownEncoding() throws {
        let raw = [UInt8](repeating: 0, count: 262_145)
        for encoding in Self.rawEncodingNames + ["future"] {
            for kind in Self.kinds where !kind.hasNoPropertyData {
                #expect(try Self.rawRefusal(kind, headerData: Self.rawHeader(encoding), rawBody: raw)
                    == .rawBodyTooLong(count: 262_145, limit: 262_144))
            }
        }
    }

    @Test func rawMcoded7PrepackingCeilingAndPartialGroupsAreInclusive() throws {
        let cases = [(229_369, 262_136), (229_375, 262_143), (229_376, 262_144)]
        for (rawCount, encodedCount) in cases {
            let raw = [UInt8](repeating: 0xFF, count: rawCount)
            let messages = try Self.rawCut(headerData: Self.mcoded7Header, rawBody: raw)
            #expect(messages.flatMap(\.chunk.propertyData).count == encodedCount)
            #expect(messages.count == 65)
            _ = try Self.rawContent(messages, headerData: Self.mcoded7Header, rawBody: raw, limit: 4_096)
        }
        for (rawCount, encodedCount) in [(229_377, 262_146), (262_144, 299_594)] {
            #expect(try Self.rawRefusal(
                headerData: Self.mcoded7Header, rawBody: [UInt8](repeating: 0xFF, count: rawCount))
                == .encodedBodyTooLong(count: encodedCount, limit: 262_144))
        }
    }

    @Test func rawMcoded7ShortLengthsIncludeEveryFinalGroupWidth() throws {
        // Hand-counted output lengths, not an expectation computed by the production encoder.
        let encodedCounts = [0, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16, 18]
        for (rawCount, encodedCount) in encodedCounts.enumerated() {
            let raw = (0..<rawCount).map { UInt8(0x80 + $0) }
            let messages = try Self.rawCut(headerData: Self.mcoded7Header, rawBody: raw)
            #expect(messages.flatMap(\.chunk.propertyData).count == encodedCount)
            _ = try Self.rawContent(messages, headerData: Self.mcoded7Header, rawBody: raw, limit: 4_096)
        }
    }

    @Test func rawIncompressibleBodyFitsBelowPackingLimit() throws {
        let raw = Self.rawNoise(200_000)
        let messages = try Self.rawCut(headerData: Self.rawZlibHeader, rawBody: raw)
        // This fixture exercises many wire chunks and essentially all byte values, not a repeated-byte special case.
        #expect(messages.count > 40 && messages.count < 256)
        _ = try Self.rawContent(messages, headerData: Self.rawZlibHeader, rawBody: raw, limit: 4_096)
        try Self.checkRawCompressedOutput(messages, plaintext: raw)
    }

    @Test(arguments: [229_376, 262_144])
    func rawIncompressibleZlibOverflowRefusesInsteadOfFallingBackOrReturningChunks(count: Int) throws {
        let raw = Self.rawNoise(count)
        let result = try Self.rawOutcome(headerData: Self.rawZlibHeader, rawBody: raw)
        guard case .failure(.encodedBodyTooLong(let encodedCount, let limit)) = result else {
            Issue.record("Expected whole-body zlib packing overflow, not compression failure, fallback or chunks")
            return
        }
        #expect(limit == 262_144 && encodedCount > limit)
        // Compression finished in fixed storage; the exact size is deliberately not pinned across SDKs.
        #expect(encodedCount <= 300_764) // 263168 + ceil(263168 / 7).
        // A later valid call is independent of the failed compression, with no saved partial stream state.
        let next = try Self.rawCut(headerData: Self.rawZlibHeader, rawBody: [0, 0x80, 0xFF])
        _ = try Self.rawContent(
            next, headerData: Self.rawZlibHeader, rawBody: [0, 0x80, 0xFF], limit: 4_096)
        try Self.checkRawCompressedOutput(next, plaintext: [0, 0x80, 0xFF])
    }

    @Test func rawOriginalHeaderAtParserCeilingSurvivesWholeChain() throws {
        let headerData = Self.rawEmptyHeader + [UInt8](repeating: 0x20, count: 2_046)
        let raw = Self.data(4_100)
        let messages = try Self.rawCut(headerData: headerData, rawBody: raw)
        #expect(Self.propertySizes(messages) == [2_026, 2_074])
        _ = try Self.rawContent(messages, headerData: headerData, rawBody: raw, limit: 4_096)
        #expect(try Self.rawRefusal(headerData: headerData + [0x20], rawBody: raw)
            == .header(.tooLong(count: 2_049, limit: 2_048)))
    }

    @Test func rawHeaderOnlyFirstChunkRemainsGreedyForEveryEncoding() throws {
        for encoding in Self.rawEncodingNames {
            let headerData = Self.rawHeader(encoding)
            let limit = 22 + headerData.count
            let raw: [UInt8] = [0, 0x41, 0x7F]
            let messages = try Self.rawCut(headerData: headerData, rawBody: raw, limit: limit)
            try #require(messages.count == 2)
            #expect(messages[0].chunk.propertyData.isEmpty)
            #expect(messages[1].chunk.headerData.isEmpty)
            _ = try Self.rawContent(messages, headerData: headerData, rawBody: raw, limit: limit)
        }
    }
}
