//
//  MIDICIPropertyChunkerTests+BodyOrder.swift
//  FluxKlangTests
//
//  #865: competing defects pin raw-kind -> raw-size -> original header -> body -> existing chunker.
//  No resource/status semantics are inferred from these fixtures.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIPropertyChunkerTests {
    @Test func rawForbiddenBodyWinsOverEveryLaterDefect() throws {
        let tooLong = [UInt8](repeating: 0xFF, count: 262_145)
        let malformed = [UInt8](repeating: 0x80, count: 2_049)
        for kind in [MIDICIPropertyDataKind.getInquiry, .setReply] {
            for raw in [[0x80], tooLong] {
                for headerData in [malformed, Self.rawHeader("future"), Self.rawZlibHeader] {
                    #expect(try Self.rawRefusal(
                        kind, requestID: 0xFF, headerData: headerData, rawBody: raw, limit: 1)
                        == .rawBodyNotAllowed(kind: kind, count: raw.count))
                }
            }
        }
    }

    @Test func rawSizeWinsBeforeHeaderAndAllEncodingWork() throws {
        let tooLong = [UInt8](repeating: 0xFF, count: 262_145)
        let headers = [
            [], [0x80], Self.rawEmptyHeader, Self.mcoded7Header, Self.rawZlibHeader, Self.rawHeader("future")
        ]
        for kind in Self.kinds where !kind.hasNoPropertyData {
            for headerData in headers {
                #expect(try Self.rawRefusal(
                    kind, requestID: 0x80, headerData: headerData, rawBody: tooLong, limit: 1)
                    == .rawBodyTooLong(count: 262_145, limit: 262_144))
            }
        }
    }

    @Test func rawHeaderParserRefusalsWinOverEncodingAndChunkerDefects() throws {
        let malformed: [([UInt8], MIDICIPropertyHeaderRefusal)] = [
            ([], .unexpectedEnd(offset: 0)),
            ([0x80], .byteHigh(offset: 0)),
            (Array("[]".utf8), .unexpectedByte(offset: 0)),
            (Array(#"{"status":true}"#.utf8), .wrongType(key: "status", offset: 10)),
            ([UInt8](repeating: 0x80, count: 2_049), .tooLong(count: 2_049, limit: 2_048))
        ]
        for (headerData, expected) in malformed {
            for raw in [[], [0x80], [UInt8](repeating: 0xFF, count: 262_144)] {
                #expect(try Self.rawRefusal(
                    requestID: 0x80, headerData: headerData, rawBody: raw, limit: 1) == .header(expected))
            }
        }
        // Unknown encoding does not short-circuit the rest of the header parser.
        let unknown = Self.rawHeader("future") + [UInt8(ascii: "!")]
        #expect(try Self.rawRefusal(headerData: unknown, rawBody: [0x80], limit: 1)
            == .header(.trailingBytes(offset: unknown.count - 1)))
        let encodedWrongType = Array(#"{"mutualEncoding":true}"#.utf8)
        #expect(try Self.rawRefusal(headerData: encodedWrongType, rawBody: [0x80], limit: 1)
            == .header(.wrongType(key: "mutualEncoding", offset: 18)))
    }

    @Test func rawEncodingRefusalsWinOverPayloadAndRequestID() throws {
        for raw in [[], [0x80], [UInt8](repeating: 0xFF, count: 262_144)] {
            #expect(try Self.rawRefusal(
                requestID: 0x80, headerData: Self.rawHeader("future"), rawBody: raw, limit: 1)
                == .body(.unsupportedEncoding(.other("future"))))
        }
        for headerData in [Self.rawEmptyHeader, Self.rawHeader("ASCII")] {
            #expect(try Self.rawRefusal(
                requestID: 0xFF, headerData: headerData, rawBody: [0, 0xFF, 0x80], limit: 1)
                == .body(.byteHigh(offset: 1)))
            var atCeiling = [UInt8](repeating: 0, count: 262_144)
            atCeiling[262_143] = 0x80
            #expect(try Self.rawRefusal(
                requestID: 0x80, headerData: headerData, rawBody: atCeiling, limit: 24)
                == .body(.byteHigh(offset: 262_143)))
        }
        #expect(try Self.rawRefusal(
            requestID: 0x80, headerData: Self.mcoded7Header,
            rawBody: [UInt8](repeating: 0xFF, count: 229_377), limit: 1)
            == .encodedBodyTooLong(count: 262_146, limit: 262_144))
    }

    @Test func rawCompressionOverflowWinsOverDownstreamDefects() throws {
        let result = try Self.rawOutcome(
            requestID: 0x80, headerData: Self.rawZlibHeader, rawBody: Self.rawNoise(262_144), limit: 1)
        guard case .failure(.encodedBodyTooLong(let count, let limit)) = result else {
            Issue.record("Compression/packing overflow must precede payload fit and request ID")
            return
        }
        #expect(count > 262_144 && limit == 262_144)
    }

    @Test func rawRestrictedEmptyBodiesStillValidateHeaderAndChunker() throws {
        for kind in [MIDICIPropertyDataKind.getInquiry, .setReply] {
            #expect(try Self.rawRefusal(kind, requestID: 0x80, headerData: [], limit: 1)
                == .header(.unexpectedEnd(offset: 0)))
            for encoding in Self.rawEncodingNames + ["future"] {
                let headerData = Self.rawHeader(encoding)
                #expect(try Self.rawRefusal(kind, requestID: 0x80, headerData: headerData, limit: 1)
                    == .chunking(.payloadLimitTooSmall(needed: 22 + headerData.count, limit: 1)))
                #expect(try Self.rawRefusal(kind, requestID: 0x80, headerData: headerData)
                    == .chunking(.chunk(.fieldOutOfRange(.requestID, value: 0x80))))
                let limit = 22 + headerData.count
                let messages = try Self.rawCut(kind, headerData: headerData, limit: limit)
                #expect(Self.propertySizes(messages) == [0])
                _ = try Self.rawContent(messages, headerData: headerData, rawBody: [], limit: limit)
            }
        }
    }

    @Test func rawDownstreamRefusalsKeepFitThenCountThenChunkOrder() throws {
        let body = Self.data(32_765)
        #expect(try Self.rawRefusal(requestID: 0x80, rawBody: body, limit: 23)
            == .chunking(.payloadLimitTooSmall(needed: 24, limit: 23)))
        // H=2 leaves no data in chunk 1 at limit 24; the remaining 32765 bytes need 16383 more chunks.
        #expect(try Self.rawRefusal(requestID: 0x80, rawBody: body, limit: 24)
            == .chunking(.tooManyChunks(count: 16_384, limit: 16_383)))
        #expect(try Self.rawRefusal(requestID: 0x80, rawBody: [0x41], limit: 24)
            == .chunking(.chunk(.fieldOutOfRange(.requestID, value: 0x80))))
        #expect(try Self.rawRefusal(requestID: 0x80)
            == .chunking(.chunk(.fieldOutOfRange(.requestID, value: 0x80))))
        // Successful encoding is not deferred until after the chunk factory: binary Mcoded7 is allowed
        // but the bad request still fails; this is not a byteHigh refusal.
        #expect(try Self.rawRefusal(requestID: 0x80, headerData: Self.mcoded7Header, rawBody: [0xFF])
            == .chunking(.chunk(.fieldOutOfRange(.requestID, value: 0x80))))
    }
}
