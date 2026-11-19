//
//  MIDICIPropertyChunkerTests+Body.swift
//  FluxKlangTests
//
//  #865: original raw bodies through preparation -> existing chunker -> wire codec -> reassembler -> content.
//  Extends the audited chunker root and reuses its roundTrip helper (independent reassembler cap: 256).
//  Compression-before-packing is local policy, not a specification or peer interoperability assertion.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIPropertyChunkerTests {
    typealias PreparationRefusal = MIDICIPropertyPreparationRefusal

    static let rawEncodingNames = ["ASCII", "Mcoded7", "zlib+Mcoded7"]
    static let rawZlibHeader = Array(#"{"mutualEncoding":"zlib+Mcoded7"}"#.utf8)
    static let rawEmptyHeader = Array("{}".utf8)

    /// Deliberately noncanonical JSON with unknown VALUES that the typed parser drops.
    /// This is a fixed fixture, not a production header serializer.
    static func rawHeader(_ encoding: String) -> [UInt8] {
        Array((
            " \n{ \"zeta\" : [null,{\"nested\":true}], \"resource\":\"opaque\", " +
            "\"mutualEncoding\":\"\(encoding)\", \"alpha\":{\"n\":1e2} }\t"
        ).utf8)
    }

    static func rawOutcome(
        _ kind: MIDICIPropertyDataKind = .getReply, header: MIDICIHeader? = nil, requestID: UInt8 = 0x2A,
        headerData: [UInt8] = rawEmptyHeader, rawBody: [UInt8] = [], limit: Int = 4_096
    ) throws -> Result<[Message], PreparationRefusal> {
        let header = try header ?? MIDICIPropertyReassemblerTests.header()
        let limits = try Self.limits(limit)
        do {
            return .success(try MIDICIPropertyChunker.chunks(
                kind, header: header, requestID: requestID, headerData: headerData, rawBody: rawBody, limits: limits))
        } catch {
            return .failure(error)
        }
    }

    static func rawCut(
        _ kind: MIDICIPropertyDataKind = .getReply, header: MIDICIHeader? = nil, requestID: UInt8 = 0x2A,
        headerData: [UInt8] = rawEmptyHeader, rawBody: [UInt8] = [], limit: Int = 4_096
    ) throws -> [Message] {
        try rawOutcome(
            kind, header: header, requestID: requestID, headerData: headerData, rawBody: rawBody, limit: limit).get()
    }

    static func rawRefusal(
        _ kind: MIDICIPropertyDataKind = .getReply, requestID: UInt8 = 0x2A,
        headerData: [UInt8] = rawEmptyHeader, rawBody: [UInt8] = [], limit: Int = 4_096
    ) throws -> PreparationRefusal? {
        let result = try rawOutcome(
            kind, requestID: requestID, headerData: headerData, rawBody: rawBody, limit: limit)
        guard case .failure(let refusal) = result else { return nil }
        return refusal
    }

    /// Require the actual wire/reassembly/content chain, not a direct content construction.
    /// Tests that deliberately exceed the reassembler count cap do not call this helper.
    static func rawContent(
        _ messages: [Message], headerData: [UInt8], rawBody: [UInt8], limit: Int
    ) throws -> MIDICIPropertyContent {
        try #require(!messages.isEmpty && messages.count <= 256)
        let first = try #require(messages.first)
        Self.expectEnvelope(
            messages, kind: first.kind, header: first.header, requestID: first.chunk.requestID,
            headerData: headerData)
        let payloads = try Self.payloadSizes(messages, limit: limit)
        #expect(payloads.dropLast().allSatisfy { $0 == limit })
        #expect(payloads.allSatisfy { $0 <= limit })
        let reassembly = try Self.roundTrip(messages, limit: limit)
        #expect(reassembly.headerData == headerData)
        #expect(reassembly.propertyData == messages.flatMap(\.chunk.propertyData))
        let content = try MIDICIPropertyContent.decode(reassembly)
        #expect(content.kind == first.kind)
        #expect(content.header == first.header && content.requestID == first.chunk.requestID)
        #expect(content.body == rawBody)
        return content
    }

    /// Separate arithmetic unpacking of generated output, not either production Mcoded7 direction.
    /// Then use the existing bounded uncompress2 reference: a separate zlib entry point, NOT an
    /// independent DEFLATE implementation. It checks full input consumption and fixed plaintext.
    static func checkRawCompressedOutput(_ messages: [Message], plaintext: [UInt8]) throws {
        let packed = messages.flatMap(\.chunk.propertyData)
        try #require(!packed.isEmpty && packed.count <= 262_144)
        try #require(packed.allSatisfy { $0 < 128 } && packed.count % 8 != 1)
        var compressed: [UInt8] = []
        for index in packed.indices where index % 8 != 0 {
            let groupStart = index - index % 8
            let high = (Int(packed[groupStart]) / (1 << (7 - index % 8))) % 2
            compressed.append(packed[index] + UInt8(high * 128))
        }
        #expect(compressed.count <= 229_376)
        #expect(MIDICIPropertyBodyTests.zlibReference(compressed) == .success(plaintext))
        // RFC1950 CM=8, legal window, header checksum and no preset dictionary.
        try #require(compressed.count >= 6)
        #expect(compressed[0] & 0x0F == 8 && compressed[0] >> 4 <= 7)
        #expect((Int(compressed[0]) * 256 + Int(compressed[1])) % 31 == 0)
        #expect(compressed[1] & 0x20 == 0)
    }

    @Test(arguments: [MIDICIFormat.ci11, .ci12])
    func rawBodiesCoverEveryEncodingKindAndEnvelope(format: MIDICIFormat) throws {
        let envelope = try MIDICIMessageTests.header(
            format, device: 0x7F, source: 0x80, destination: 0x0123_4567)
        for encoding in Self.rawEncodingNames {
            let headerData = Self.rawHeader(encoding)
            let raw = encoding == "ASCII" ? (0...127).map { UInt8($0) } : (0...255).map { UInt8($0) }
            let limit = 22 + headerData.count + 5
            for kind in Self.kinds where !kind.hasNoPropertyData {
                for requestID: UInt8 in [0, 0x2A, 0x7F] {
                    let messages = try Self.rawCut(
                        kind, header: envelope, requestID: requestID, headerData: headerData,
                        rawBody: raw, limit: limit)
                    try #require(messages.count > 1)
                    #expect(messages[0].chunk.propertyData.count == 5)
                    Self.expectEnvelope(
                        messages, kind: kind, header: envelope, requestID: requestID, headerData: headerData)
                    let content = try Self.rawContent(messages, headerData: headerData, rawBody: raw, limit: limit)
                    #expect(content.propertyHeader == MIDICIPropertyHeader(
                        resource: "opaque", encoding: MIDICIPropertyEncoding(name: encoding),
                        unknownKeys: ["alpha", "zeta"]))
                    if encoding == "zlib+Mcoded7" {
                        try Self.checkRawCompressedOutput(messages, plaintext: raw)
                    }
                }
            }
        }
    }

    @Test(arguments: [MIDICIFormat.ci11, .ci12])
    func rawEmptyBodiesEncodeNormallyExceptForRestrictedKinds(format: MIDICIFormat) throws {
        let envelope = try MIDICIMessageTests.header(format, device: 0x7F, destination: 0x80)
        for encoding in Self.rawEncodingNames + ["future", "ascii", ""] {
            let headerData = Self.rawHeader(encoding)
            for kind in Self.kinds {
                let outcome = try Self.rawOutcome(kind, header: envelope, headerData: headerData)
                if !kind.hasNoPropertyData && !Self.rawEncodingNames.contains(encoding) {
                    #expect(outcome == .failure(.body(.unsupportedEncoding(.other(encoding)))))
                    continue
                }
                let messages = try outcome.get()
                let content = try Self.rawContent(messages, headerData: headerData, rawBody: [], limit: 4_096)
                #expect(content.propertyHeader.encoding == MIDICIPropertyEncoding(name: encoding))
                let encoded = messages.flatMap(\.chunk.propertyData)
                if kind.hasNoPropertyData || encoding != "zlib+Mcoded7" {
                    #expect(encoded.isEmpty && messages.count == 1)
                } else {
                    #expect(!encoded.isEmpty)
                    try Self.checkRawCompressedOutput(messages, plaintext: [])
                }
            }
        }
    }

    @Test func rawDefaultASCIIKeepsEveryControlByteAndDEL() throws {
        let raw = (0...127).map { UInt8($0) }
        for headerData in [Self.rawEmptyHeader, Self.rawHeader("ASCII")] {
            let messages = try Self.rawCut(headerData: headerData, rawBody: raw)
            #expect(messages.flatMap(\.chunk.propertyData) == raw)
            let content = try Self.rawContent(messages, headerData: headerData, rawBody: raw, limit: 4_096)
            #expect(content.propertyHeader.encoding == .ascii)
        }
    }

    @Test func rawMcoded7HasHandCheckedBitsAndCutsInsideGroups() throws {
        let raw: [UInt8] = [0x80, 1, 0xFF, 0x7F, 0xAA, 0, 0xFE, 0x81, 0x82]
        // First group's high bits: 1010101. Final two high bits: 1100000.
        let expected: [UInt8] = [0x55, 0, 1, 0x7F, 0x7F, 0x2A, 0, 0x7E, 0x60, 1, 2]
        for firstCapacity in [1, 2, 5, 7, 8, 9] {
            let limit = 22 + Self.mcoded7Header.count + firstCapacity
            let messages = try Self.rawCut(
                headerData: Self.mcoded7Header, rawBody: raw, limit: limit)
            #expect(Self.propertySizes(messages) == [firstCapacity, 11 - firstCapacity])
            #expect(messages.flatMap(\.chunk.propertyData) == expected)
            _ = try Self.rawContent(messages, headerData: Self.mcoded7Header, rawBody: raw, limit: limit)
        }
    }

    @Test func rawZlibCutsInsideWholeBodyPackingNotPerChunkStreams() throws {
        let raw = MIDICIPropertyBodyTests.zlibPlaintext
        for firstCapacity in [1, 2, 5, 7, 8, 9] {
            let limit = 22 + Self.rawZlibHeader.count + firstCapacity
            let messages = try Self.rawCut(
                headerData: Self.rawZlibHeader, rawBody: raw, limit: limit)
            try #require(messages.count > 1)
            #expect(messages[0].chunk.propertyData.count == firstCapacity)
            _ = try Self.rawContent(messages, headerData: Self.rawZlibHeader, rawBody: raw, limit: limit)
            try Self.checkRawCompressedOutput(messages, plaintext: raw)
        }
    }
}
