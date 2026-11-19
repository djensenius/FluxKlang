//
//  MIDICIPropertyChunkerTests+BodyCompatibility.swift
//  FluxKlangTests
//
//  #865: the encoded-byte overload is not redirected through raw preparation.
//  Message addressing stays downstream; no receive or chunk-count policy changes.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIPropertyChunkerTests {
    @Test func rawPreparationEqualsOldChunkerForHandEncodedBodies() throws {
        let vectors: [(header: [UInt8], body: (raw: [UInt8], encoded: [UInt8]))] = [
            (Self.rawEmptyHeader, ([0, 0x41, 0x7F], [0, 0x41, 0x7F])),
            (Self.mcoded7Header, ([0x80, 0xFF], [0x60, 0, 0x7F])),
            (Self.mcoded7Header, ([], []))
        ]
        for (headerData, body) in vectors {
            for kind in Self.kinds where !kind.hasNoPropertyData {
                for limit in [22 + headerData.count, 64, 4_096] {
                    let prepared = try Self.rawCut(kind, headerData: headerData, rawBody: body.raw, limit: limit)
                    let old = try Self.cut(kind, headerData: headerData, propertyData: body.encoded, limit: limit)
                    #expect(prepared == old)
                    _ = try Self.rawContent(prepared, headerData: headerData, rawBody: body.raw, limit: limit)
                }
            }
        }
    }

    @Test func rawZlibDelegatesCutsWithoutReencodingChunks() throws {
        let raw = Self.rawNoise(1_024)
        let headerData = Self.rawHeader("zlib+Mcoded7")
        for limit in [22 + headerData.count, 22 + headerData.count + 5, 4_096] {
            let prepared = try Self.rawCut(headerData: headerData, rawBody: raw, limit: limit)
            // This equality checks delegation, NOT compressed correctness. The separate reference and
            // full plaintext chain below check correctness without promising compressed-byte determinism.
            let encoded = prepared.flatMap(\.chunk.propertyData)
            let old = try Self.cut(headerData: headerData, propertyData: encoded, limit: limit)
            #expect(prepared == old)
            _ = try Self.rawContent(prepared, headerData: headerData, rawBody: raw, limit: limit)
            try Self.checkRawCompressedOutput(prepared, plaintext: raw)
        }
    }

    @Test func oldEncodedAPIStillKeepsOpaqueHeadersAndUninterpretedBodies() throws {
        let headers = [[], Array("not JSON".utf8), Self.rawHeader("future"), Self.rawZlibHeader]
        for headerData in headers {
            let bytes: [UInt8] = [0, 0x7F, 1]
            let old = try Self.cut(headerData: headerData, propertyData: bytes)
            let reassembly = try Self.roundTrip(old, limit: 4_096)
            #expect(reassembly.headerData == headerData && reassembly.propertyData == bytes)
            // Old chunking is not preparation, even when the header names compression.
            #expect(old.flatMap(\.chunk.propertyData) == bytes)
        }
        #expect(try Self.rawRefusal(headerData: []) == .header(.unexpectedEnd(offset: 0)))
        #expect(try Self.rawRefusal(headerData: Self.rawHeader("future"), rawBody: [0])
            == .body(.unsupportedEncoding(.other("future"))))
    }

    @Test func oldEncodedRefusalsAndPrecedenceRemainUnchanged() throws {
        let tooLong = [UInt8](repeating: 0x80, count: 262_145)
        let malformed = [UInt8](repeating: 0x80, count: 2_049)
        #expect(try Self.refusal(
            .getInquiry, requestID: 0x80, headerData: malformed, propertyData: tooLong, limit: 1)
            == .propertyDataNotAllowed(kind: .getInquiry, count: 262_145))
        #expect(try Self.refusal(
            requestID: 0x80, headerData: malformed, propertyData: tooLong, limit: 1)
            == .propertyDataTooLong(count: 262_145, limit: 262_144))
        // Unlike raw preparation, payload fit wins before header checks in the old overload.
        #expect(try Self.refusal(headerData: malformed, limit: 1)
            == .payloadLimitTooSmall(needed: 2_071, limit: 1))
        #expect(try Self.refusal(requestID: 0x80, headerData: malformed)
            == .chunk(.fieldOutOfRange(.requestID, value: 0x80)))
        #expect(try Self.refusal(headerData: malformed) == .chunk(.propertyHeaderTooLong(2_049)))
        #expect(try Self.refusal(headerData: Self.mcoded7Header, propertyData: [0xFF])
            == .chunk(.fieldOutOfRange(.propertyData, value: 0xFF)))
        #expect(try Self.refusal(headerData: Self.rawZlibHeader, propertyData: []) == nil)
    }

    @Test func rawChunkCountPolicyRemainsIndependentOfReassemblerCap() throws {
        // At H=2 and payload 24, chunk 1 is header-only and later chunks hold two bytes.
        // Deliberately do NOT send these >256-chunk preparations to the roundTrip helper.
        for (rawCount, chunkCount) in [(512, 257), (32_764, 16_383)] {
            let raw = Self.data(rawCount)
            let prepared = try Self.rawCut(rawBody: raw, limit: 24)
            let old = try Self.cut(headerData: Self.rawEmptyHeader, propertyData: raw, limit: 24)
            #expect(prepared == old && prepared.count == chunkCount)
            let first = try #require(prepared.first)
            let last = try #require(prepared.last)
            #expect(first.chunk.propertyData.isEmpty && first.chunk.headerData == Self.rawEmptyHeader)
            #expect(last.chunk.chunkNumber == UInt16(chunkCount))
            #expect(try last.encode(limits: Self.limits(24)).count == 24)
        }
    }

    @Test func rawPreparationLeavesAddressingRefusalsAtMessageEncode() throws {
        let addressed: [(MIDICIHeader, MIDICIRefusal)] = [
            (try MIDICIMessageTests.header(.ci12, device: 0x7F, source: 0x0FFF_FFFF), .sourceIsBroadcast),
            (try MIDICIMessageTests.header(.ci12, device: 0x7F), .destinationIsBroadcast),
            (try MIDICIMessageTests.header(.ci12, device: 0x10, destination: 0x80), .deviceNotFunctionBlock(0x10))
        ]
        for (envelope, refusal) in addressed {
            for encoding in Self.rawEncodingNames {
                let headerData = Self.rawHeader(encoding)
                let limit = 22 + headerData.count + 5
                let prepared = try Self.rawCut(
                    .notify, header: envelope, headerData: headerData, rawBody: Self.data(256), limit: limit)
                try #require(prepared.count > 1)
                Self.expectEnvelope(
                    prepared, kind: .notify, header: envelope, requestID: 0x2A, headerData: headerData)
                for message in prepared {
                    #expect(try MIDICIMessageTests.exchangeEncodeRefusal(
                        message, limits: Self.limits(limit)) == refusal)
                }
            }
        }
    }

    @Test func rawBodyEncodingDoesNotInterpretResourceStatusOrJSON() throws {
        // These are type-correct headers, not assertions that any resource/status/command is permitted
        // by a peer or has application meaning. Body bytes need not be JSON in any supported encoding.
        let headerData = Array(#"{"resource":"unknown","status":0,"command":"opaque","mutualEncoding":"Mcoded7"}"#.utf8)
        let raw: [UInt8] = [0xFF, 0, 0x80]
        let messages = try Self.rawCut(.subscriptionReply, headerData: headerData, rawBody: raw)
        let content = try Self.rawContent(messages, headerData: headerData, rawBody: raw, limit: 4_096)
        #expect(content.propertyHeader.resource == "unknown")
        #expect(content.propertyHeader.status == 0 && content.propertyHeader.command == "opaque")
        #expect(content.propertyHeader.encoding == .mcoded7)
    }
}
