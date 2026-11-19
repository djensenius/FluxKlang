//
//  MIDICIPropertyContentTests+Zlib.swift
//  FluxKlangTests
//
//  #858: actual chunk -> wire codec -> reassembler -> content, with a cut inside Mcoded7.
//  Whole-body compression before Mcoded7 before chunking is a disclosed local assumption.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIPropertyContentTests {
    // Original witness retained separately for byte-faithful execution against the pinned unsupported baseline.
    @Test func zlibGoldenDecodesThroughExistingChunkContentAPI() throws {
        let coded = MIDICIPropertyBodyTests.zlibGolden
        let headerData = Self.bytes(
            #"{"resource":"opaque","status":200,"mutualEncoding":"zlib+Mcoded7","zeta":null}"#)
        let header = try MIDICIMessageTests.header(.ci12, device: 0x7F, source: 0x80, destination: 0x0123_4567)
        let limits = try MIDICILimits.make(maximumPayloadBytes: 22 + headerData.count + 5, maximumTextBytes: 256)
        let chunks = try MIDICIPropertyChunker.chunks(
            .getReply, header: header, requestID: 0x7F, headerData: headerData, propertyData: coded, limits: limits)
        try #require(chunks.count == 2)
        #expect(chunks[0].chunk.propertyData == Array(coded.prefix(5)))
        #expect(chunks[1].chunk.propertyData == Array(coded.dropFirst(5)))
        var received: [MIDICIPropertyDataMessage] = []
        for chunk in chunks {
            received.append(try MIDICIPropertyDataMessage.decode(payload: chunk.encode(limits: limits), limits: limits))
        }
        let done = try Self.reassemble(received)
        #expect(done.chunkCount == 2)
        #expect(done.header == header && done.requestID == 0x7F)
        #expect(done.headerData == headerData && done.propertyData == coded)
        let content = try MIDICIPropertyContent.decode(done)
        #expect(content == MIDICIPropertyContent(
            kind: .getReply, header: header, requestID: 0x7F,
            propertyHeader: MIDICIPropertyHeader(
                resource: "opaque", status: 200, encoding: .zlibMcoded7, unknownKeys: ["zeta"]),
            body: MIDICIPropertyBodyTests.zlibPlaintext))
    }

    @Test(arguments: [MIDICIFormat.ci11, .ci12])
    func zlibPipelinePreservesEveryParsedFieldAndEnvelope(format: MIDICIFormat) throws {
        let headerData = Self.bytes(
            #"{"resource":"opaque","resId":"r","status":200,"message":"ok","command":"start","subscribeId":"s","# +
            #""mediaType":"application/octet-stream","offset":1,"limit":2,"totalCount":3,"setPartial":true,"# +
            #""cacheTime":4,"mutualEncoding":"zlib+Mcoded7","zeta":null,"alpha":[]}"#)
        let expected = MIDICIPropertyHeader(
            resource: "opaque", resID: "r", status: 200, message: "ok", command: "start", subscribeID: "s",
            mediaType: "application/octet-stream", offset: 1, limit: 2, totalCount: 3, setPartial: true,
            cacheTime: 4, encoding: .zlibMcoded7, unknownKeys: ["alpha", "zeta"])
        let envelope = try MIDICIMessageTests.header(
            format, device: 0x7F, source: 0x0FFF_FEFF, destination: 0x80)
        let limits = try MIDICILimits.make(maximumPayloadBytes: 22 + headerData.count + 5, maximumTextBytes: 256)
        for kind in Self.kinds where !kind.hasNoPropertyData {
            let chunks = try MIDICIPropertyChunker.chunks(
                kind, header: envelope, requestID: 0x2A, headerData: headerData,
                propertyData: MIDICIPropertyBodyTests.zlibGolden, limits: limits)
            try #require(chunks.count == 2)
            #expect(chunks[0].chunk.propertyData.count == 5)
            var received: [MIDICIPropertyDataMessage] = []
            for chunk in chunks {
                received.append(try MIDICIPropertyDataMessage.decode(
                    payload: chunk.encode(limits: limits), limits: limits))
            }
            let done = try Self.reassemble(received)
            try MIDICIPropertyReassemblerTests.requireConsistentCompletion(done, fragments: received)
            #expect(done.chunkCount == 2)
            #expect(Self.outcome(done) == .success(MIDICIPropertyContent(
                kind: kind, header: envelope, requestID: 0x2A,
                propertyHeader: expected, body: MIDICIPropertyBodyTests.zlibPlaintext)))
        }
    }

    @Test(arguments: MIDICIPropertyBodyTests.malformedZlibNames)
    func zlibContentWrapsEveryCompressionFailureWithoutPartialContent(name: String) throws {
        let coded = MIDICIMcoded7.encode(try MIDICIPropertyBodyTests.malformedZlib(name))
        try Self.expectBody(Self.zlibHeader, coded, .invalidCompressedData)
        let done = try Self.single(.getReply, headerData: Self.zlibHeader, data: coded)
        #expect(Self.outcome(done) == .failure(.body(.invalidCompressedData)))
        #expect(Self.outcome(done) == Self.outcome(done))
    }

    @Test(arguments: [262_143, 262_144, 262_145, 1_048_576])
    func zlibContentAppliesDecodedLimitAfterReassembly(count: Int) throws {
        let coded = MIDICIMcoded7.encode(try MIDICIPropertyBodyTests.repeatedZlib(count))
        let header = try MIDICIPropertyReassemblerTests.header()
        let limits = try MIDICILimits.make(maximumPayloadBytes: 22 + Self.zlibHeader.count + 5, maximumTextBytes: 0)
        let chunks = try MIDICIPropertyChunker.chunks(
            .getReply, header: header, requestID: 0, headerData: Self.zlibHeader,
            propertyData: coded, limits: limits)
        try #require(chunks.count > 1)
        #expect(chunks[0].chunk.propertyData.count == 5)
        let done = try Self.reassemble(chunks)
        #expect(done.propertyData == coded)
        #expect(done.chunkCount == UInt16(chunks.count))
        if count > 262_144 {
            #expect(Self.outcome(done) == .failure(.body(.decodedTooLong(limit: 262_144))))
        } else {
            let content = try MIDICIPropertyContent.decode(done)
            #expect(content.body.count == count)
            #expect(content.body.firstIndex { $0 != 0x41 } == nil)
            #expect(content.header == header && content.requestID == 0 && content.kind == .getReply)
            #expect(content.propertyHeader == MIDICIPropertyHeader(encoding: .zlibMcoded7))
        }
    }

    @Test func zlibContentKeepsMcoded7RefusalsAndHeaderPrecedence() throws {
        try Self.expectBody(Self.zlibHeader, [0x80], .byteHigh(offset: 0))
        try Self.expectBody(Self.zlibHeader, [0], .truncatedGroup(offset: 0))
        try Self.expectBody(Self.zlibHeader, MIDICIPropertyBodyTests.zlibGolden + [0], .truncatedGroup(offset: 72))
        let highOver = [UInt8](repeating: 0x80, count: 262_145)
        try Self.expectBody(Self.zlibHeader, highOver, .tooLong(count: 262_145, limit: 262_144))
        for data in [MIDICIPropertyBodyTests.zlibGolden, [0x80], highOver] {
            let input = try Self.reassembly(chunkCount: 17, headerData: [], propertyData: data)
            #expect(Self.outcome(input) == .failure(.header(.unexpectedEnd(offset: 0))))
        }
    }

    @Test(arguments: [MIDICIPropertyDataKind.getInquiry, .setReply])
    func zlibRestrictedKindsStillSkipAbsentBodiesButRefuseCompressedEmpty(kind: MIDICIPropertyDataKind) throws {
        let absent = try Self.single(kind, headerData: Self.zlibHeader)
        #expect(try MIDICIPropertyContent.decode(absent).body == [])
        #expect(try MIDICIPropertyContent.decode(absent).propertyHeader.encoding == .zlibMcoded7)
        // A compressed empty stream is nonempty property data. It cannot evade the kind rule.
        let coded = MIDICIPropertyBodyTests.zlibEmptyWire
        let emptyStream = try Self.single(kind, headerData: Self.zlibHeader, data: coded)
        #expect(Self.outcome(emptyStream) == .failure(.propertyDataNotAllowed(kind: kind, count: coded.count)))
        for count: UInt16 in [0, 2] {
            let withData = try Self.reassembly(kind, chunkCount: count, headerData: [], propertyData: coded)
            #expect(Self.outcome(withData) == .failure(.propertyDataNotAllowed(kind: kind, count: coded.count)))
            let noData = try Self.reassembly(kind, chunkCount: count, headerData: [])
            #expect(Self.outcome(noData) == .failure(.singleChunkRequired(kind: kind, chunkCount: count)))
        }
        // Other kinds do decode that same valid empty stream rather than treating its bytes as absent.
        for kind in Self.kinds where !kind.hasNoPropertyData {
            let done = try Self.single(kind, headerData: Self.zlibHeader, data: coded)
            #expect(try MIDICIPropertyContent.decode(done).body == [])
        }
    }
}
