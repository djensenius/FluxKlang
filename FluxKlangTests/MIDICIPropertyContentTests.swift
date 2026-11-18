//
//  MIDICIPropertyContentTests.swift
//  FluxKlangTests
//
//  The goldens through the reassembler, the encoding each header names, a Mcoded7 body across chunks, the kinds
//  without property data, the wrapped refusals, the check order and the envelope fields for
//  `MIDICIPropertyContent.decode(_:)` (#83, slice M83-PXD, issue #828). Hostile input is in
//  `MIDICIPropertyContentTests+Seeded.swift`. Nothing calls the decoder yet.
//
//  Provenance: the goldens and typed fixtures are `MIDICIMessageTests`' own, and the Mcoded7 vectors are
//  `MIDICIPropertyBodyTests`' copies of `MIDICIMcoded7Tests`' vectors. Most header refusals are cases of
//  `MIDICIPropertyHeaderTests`; every expected offset was counted by hand. No expected value was produced by the
//  decoder under test. The Property Exchange specifications (M2-102-UM and M2-103-UM) were not read.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI-CI Property Exchange content", .productionAccessAudit)
struct MIDICIPropertyContentTests {
    typealias Refusal = MIDICIPropertyContentRefusal

    /// Every kind, in the order of Tables 33 to 39.
    static let kinds: [MIDICIPropertyDataKind] = [
        .getInquiry, .getReply, .setInquiry, .setReply, .subscription, .subscriptionReply, .notify
    ]
    static let mcoded7Header = bytes(#"{"mutualEncoding":"Mcoded7"}"#)
    static let zlibHeader = bytes(#"{"mutualEncoding":"zlib+Mcoded7"}"#)
    static let asciiHeader = bytes(#"{"mutualEncoding":"ASCII"}"#)
    static let gzipHeader = bytes(#"{"mutualEncoding":"gzip"}"#)

    static func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    /// The content or the refusal.
    static func outcome(_ reassembly: MIDICIPropertyReassembly) -> Result<MIDICIPropertyContent, Refusal> {
        do {
            return .success(try MIDICIPropertyContent.decode(reassembly))
        } catch {
            return .failure(error)
        }
    }

    /// The refusal, or nil for content: small to print, whatever the size of the body.
    static func refusal(_ reassembly: MIDICIPropertyReassembly) -> Refusal? {
        do {
            _ = try MIDICIPropertyContent.decode(reassembly)
            return nil
        } catch {
            return error
        }
    }

    /// The first stage on its own: `MIDICIPropertyHeader.parse(_:)`.
    static func headerStage(_ bytes: [UInt8]) -> Result<MIDICIPropertyHeader, MIDICIPropertyHeaderRefusal> {
        do {
            return .success(try MIDICIPropertyHeader.parse(bytes))
        } catch {
            return .failure(error)
        }
    }

    /// The second stage on its own: `MIDICIPropertyBody.decode(_:encoding:)`.
    static func bodyStage(
        _ bytes: [UInt8], _ encoding: MIDICIPropertyEncoding
    ) -> Result<[UInt8], MIDICIPropertyBodyRefusal> {
        do {
            return .success(try MIDICIPropertyBody.decode(bytes, encoding: encoding))
        } catch {
            return .failure(error)
        }
    }

    /// A reassembly built field by field, so it may hold what no chunk can: header data above 2,048 bytes, bytes of
    /// 0x80 or more, or more than 16,383 bytes of property data.
    static func reassembly(
        _ kind: MIDICIPropertyDataKind = .getReply, headerData: [UInt8], propertyData: [UInt8] = []
    ) throws -> MIDICIPropertyReassembly {
        MIDICIPropertyReassembly(
            kind: kind, header: try MIDICIPropertyReassemblerTests.header(), requestID: 0x2A, headerData: headerData,
            propertyData: propertyData)
    }

    /// Feeds `messages` to a new reassembler; only the last one completes the message.
    static func reassemble(_ messages: [MIDICIPropertyDataMessage]) throws -> MIDICIPropertyReassembly {
        var reassembler = try MIDICIPropertyReassembler.make()
        var complete: MIDICIPropertyReassembly?
        for message in messages {
            try #require(complete == nil)
            complete = try reassembler.accept(message)
        }
        return try #require(complete)
    }

    /// Chunk 1 of 1 of `kind`, request 0x2A, through the reassembler.
    static func single(
        _ kind: MIDICIPropertyDataKind, headerData: [UInt8], data: [UInt8] = []
    ) throws -> MIDICIPropertyReassembly {
        let input = try MIDICIPropertyReassemblerTests.chunk(1, of: 1, data: data, headerData: headerData, kind: kind)
        return try reassemble([input])
    }

    /// Expects every kind with property data to wrap `expected` unchanged, and the body stage on its own to give it.
    static func expectBody(
        _ headerData: [UInt8], _ propertyData: [UInt8], _ expected: MIDICIPropertyBodyRefusal,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let encoding = try MIDICIPropertyHeader.parse(headerData).encoding
        let stage = bodyStage(propertyData, encoding)
        #expect(stage.map(\.count) == .failure(expected), sourceLocation: sourceLocation)
        for kind in kinds where !kind.hasNoPropertyData {
            let input = try reassembly(kind, headerData: headerData, propertyData: propertyData)
            #expect(refusal(input) == .body(expected), "\(kind)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Decoding

    @Test func everyGoldenDecodesThroughTheReassemblerToItsContent() throws {
        let goldens = MIDICIMessageTests.exchangeGoldens
        let messages = try MIDICIMessageTests.exchangeMessages()
        let resource = MIDICIPropertyHeader(resource: "DeviceInfo")
        let status200 = MIDICIPropertyHeader(status: 200)
        // In the order of the goldens. No header names an encoding, so every body is ASCII. The Set Inquiry golden is
        // chunk 1 of 3 (`7F 00 41`); `later` holds chunks 2 and 3.
        let expected: [(propertyHeader: MIDICIPropertyHeader, body: [UInt8])] = [
            (resource, []), (resource, MIDICIMessageTests.exchangeArrayData),
            (resource, [0x7F, 0x00, 0x41, 0x42, 0x43, 0x44]), (status200, []),
            (MIDICIPropertyHeader(command: "start"), []), (status200, []),
            (MIDICIPropertyHeader(status: 500), [0x4F, 0x4B])
        ]
        let later: [(number: UInt16, data: [UInt8])] = [(2, [0x42]), (3, [0x43, 0x44])]
        try #require(goldens.count == 7 && messages.count == 7 && expected.count == 7)
        for ((golden, typed), (propertyHeader, body)) in zip(zip(goldens, messages), expected) {
            let message = try MIDICIPropertyDataMessage.decode(payload: golden, limits: .standard)
            try #require(message == typed)
            var chunks = [message]
            if message.kind == .setInquiry {
                for (number, data) in later {
                    let chunk = try MIDICIMessageTests.exchangeChunk(
                        request: 0x7F, count: 3, number: number, data: data)
                    chunks.append(.setInquiry(message.header, chunk))
                }
            }
            #expect(try MIDICIPropertyContent.decode(Self.reassemble(chunks)) == MIDICIPropertyContent(
                kind: typed.kind, header: typed.header, requestID: typed.chunk.requestID,
                propertyHeader: propertyHeader, body: body))
        }
    }

    @Test func theBodyIsDecodedWithItsOwnHeadersEncoding() throws {
        let text = MIDICIPropertyBodyTests.jsonText
        let coded = MIDICIPropertyBodyTests.jsonMcoded7
        try #require(text.count == 41 && coded.count == 47)
        let mcoded7 = try MIDICIPropertyContent.decode(
            Self.single(.getReply, headerData: Self.mcoded7Header, data: coded))
        #expect(mcoded7.propertyHeader == MIDICIPropertyHeader(encoding: .mcoded7))
        #expect(mcoded7.body == text)
        // ASCII, named or by default, returns the same property data as received: every byte is below 0x80.
        for headerData in [Self.asciiHeader, Self.bytes("{}"), MIDICIMessageTests.exchangeStatus200Header] {
            let ascii = try MIDICIPropertyContent.decode(Self.single(.notify, headerData: headerData, data: coded))
            #expect(ascii.propertyHeader.encoding == .ascii)
            #expect(ascii.body == coded)
        }
        // `40 25` is 0xA5 in Mcoded7 and two bytes in ASCII.
        let short: [UInt8] = [0x40, 0x25]
        #expect(try MIDICIPropertyContent.decode(Self.reassembly(headerData: Self.mcoded7Header, propertyData: short))
            .body == [0xA5])
        #expect(try MIDICIPropertyContent.decode(Self.reassembly(headerData: Self.asciiHeader, propertyData: short))
            .body == short)
    }

    @Test func aMultiChunkMcoded7BodyIsDecodedOnceAfterReassembly() throws {
        let coded = MIDICIPropertyBodyTests.jsonMcoded7
        try #require(coded.count == 47)
        // Cut at 5 and 25, inside the first and the fourth group of 8 bytes.
        let parts = [Array(coded[0..<5]), Array(coded[5..<25]), Array(coded[25..<47])]
        let chunks = [
            try MIDICIPropertyReassemblerTests.chunk(1, of: 3, data: parts[0], headerData: Self.mcoded7Header),
            try MIDICIPropertyReassemblerTests.chunk(2, of: 3, data: parts[1]),
            try MIDICIPropertyReassemblerTests.chunk(3, of: 3, data: parts[2])
        ]
        let reassembly = try Self.reassemble(chunks)
        try #require(reassembly.propertyData == coded)
        #expect(try MIDICIPropertyContent.decode(reassembly).body == MIDICIPropertyBodyTests.jsonText)
        // Each chunk decoded on its own is valid Mcoded7 too, but gives 4 + 17 + 19 = 40 other bytes.
        var perChunk: [UInt8] = []
        for part in parts {
            perChunk += try MIDICIPropertyBody.decode(part, encoding: .mcoded7)
        }
        #expect(perChunk.count == 40)
    }

    // MARK: Kinds without property data

    @Test func kindsWithoutPropertyDataSkipTheBodyAndKeepTheirEncoding() throws {
        try #require(Self.kinds.filter(\.hasNoPropertyData) == [.getInquiry, .setReply])
        let header = try MIDICIPropertyReassemblerTests.header()
        // `zlib+Mcoded7` and an unknown name refuse any body, an empty one included; Mcoded7 decodes an empty one.
        let headers: [(data: [UInt8], encoding: MIDICIPropertyEncoding)] = [
            (Self.zlibHeader, .zlibMcoded7), (Self.gzipHeader, .other("gzip")), (Self.mcoded7Header, .mcoded7)
        ]
        for (headerData, encoding) in headers {
            for kind in Self.kinds {
                let outcome = Self.outcome(try Self.single(kind, headerData: headerData))
                if kind.hasNoPropertyData || encoding == .mcoded7 {
                    #expect(outcome == .success(MIDICIPropertyContent(
                        kind: kind, header: header, requestID: 0x2A,
                        propertyHeader: MIDICIPropertyHeader(encoding: encoding), body: [])), "\(kind)")
                } else {
                    #expect(outcome == .failure(.body(.unsupportedEncoding(encoding))), "\(kind)")
                }
            }
        }
    }

    @Test func propertyDataInAKindWithoutItIsRefused() throws {
        let status = MIDICIMessageTests.exchangeStatus200Header
        // The codec and the reassembler keep the property data (lenient receive); the other five kinds decode it.
        for kind in Self.kinds {
            for data: [UInt8] in [[0x41], [0x4F, 0x4B]] {
                let outcome = Self.outcome(try Self.single(kind, headerData: status, data: data))
                if kind.hasNoPropertyData {
                    #expect(outcome == .failure(.propertyDataNotAllowed(kind: kind, count: data.count)))
                } else {
                    #expect(try outcome.get().body == data)
                }
            }
        }
        for kind in Self.kinds where kind.hasNoPropertyData {
            // Property data in a later chunk only.
            let chunks = [
                try MIDICIPropertyReassemblerTests.chunk(1, of: 2, headerData: status, kind: kind),
                try MIDICIPropertyReassemblerTests.chunk(2, of: 2, data: [0x41], kind: kind)
            ]
            #expect(Self.refusal(try Self.reassemble(chunks)) == .propertyDataNotAllowed(kind: kind, count: 1))
            // Not checked: the single chunk of Tables 33 and 36, since the reassembly keeps no chunk count.
            let empty = [
                try MIDICIPropertyReassemblerTests.chunk(1, of: 2, headerData: status, kind: kind),
                try MIDICIPropertyReassemblerTests.chunk(2, of: 2, kind: kind)
            ]
            #expect(try Self.outcome(Self.reassemble(empty)).get().body == [])
            // More than one chunk can carry, at the body limit and one past it.
            for count in [0x4000, 262_144, 262_145] {
                let data = [UInt8](repeating: 0x41, count: count)
                let input = try Self.reassembly(kind, headerData: status, propertyData: data)
                #expect(Self.refusal(input) == .propertyDataNotAllowed(kind: kind, count: count))
            }
        }
    }

    // MARK: Refusals

    @Test func aHeaderRefusalIsWrappedUnchanged() throws {
        // The last two fit in no chunk.
        let cases: [(headerData: [UInt8], refusal: MIDICIPropertyHeaderRefusal)] = [
            ([], .unexpectedEnd(offset: 0)),
            (Self.bytes("{"), .unexpectedEnd(offset: 1)),
            (Self.bytes("[]"), .unexpectedByte(offset: 0)),
            (Self.bytes("{}x"), .trailingBytes(offset: 2)),
            (Self.bytes(#"{"a":1,"a":2}"#), .duplicateKey(name: "a", offset: 7)),
            (Self.bytes(#"{"status":"200"}"#), .wrongType(key: "status", offset: 10)),
            (Self.bytes(#"{"status":-1}"#), .outOfRange(key: "status", offset: 10)),
            (Self.bytes(#"{"mutualEncoding":7}"#), .wrongType(key: "mutualEncoding", offset: 18)),
            ([0x7B, 0x80, 0x7D], .byteHigh(offset: 1)),
            ([UInt8](repeating: 0x20, count: 2_049), .tooLong(count: 2_049, limit: 2_048))
        ]
        for (headerData, refusal) in cases {
            try #require(Self.headerStage(headerData) == .failure(refusal))
            for kind in Self.kinds {
                let input = try Self.reassembly(kind, headerData: headerData)
                #expect(Self.outcome(input) == .failure(.header(refusal)), "\(kind)")
            }
        }
        // Through the reassembler, with property data the header refusal comes first.
        #expect(Self.refusal(try Self.single(.notify, headerData: [])) == .header(.unexpectedEnd(offset: 0)))
        let array = try Self.single(.getReply, headerData: Self.bytes("[]"), data: [0x41])
        #expect(Self.refusal(array) == .header(.unexpectedByte(offset: 0)))
    }

    @Test func aBodyRefusalIsWrappedUnchanged() throws {
        let ascii = Self.bytes("{}")
        try Self.expectBody(ascii, [0x41, 0x80], .byteHigh(offset: 1))
        try Self.expectBody(Self.asciiHeader, [0x80], .byteHigh(offset: 0))
        try Self.expectBody(Self.mcoded7Header, [0x00, 0x7F, 0xFF], .byteHigh(offset: 2))
        try Self.expectBody(Self.mcoded7Header, [0x00], .truncatedGroup(offset: 0))
        try Self.expectBody(Self.mcoded7Header, [UInt8](repeating: 0x00, count: 9), .truncatedGroup(offset: 8))
        try Self.expectBody(Self.zlibHeader, [], .unsupportedEncoding(.zlibMcoded7))
        try Self.expectBody(Self.zlibHeader, MIDICIPropertyBodyTests.jsonMcoded7, .unsupportedEncoding(.zlibMcoded7))
        try Self.expectBody(Self.gzipHeader, [0x41], .unsupportedEncoding(.other("gzip")))
        // 262,145 bytes fit in no reassembly, and every encoding refuses them before reading a byte; 262,144 decode.
        let over = [UInt8](repeating: 0x41, count: 262_145)
        for headerData in [ascii, Self.mcoded7Header, Self.zlibHeader, Self.gzipHeader] {
            try Self.expectBody(headerData, over, .tooLong(count: 262_145, limit: 262_144))
        }
        let atLimit = try Self.reassembly(headerData: ascii, propertyData: Array(over.dropLast()))
        #expect(try MIDICIPropertyContent.decode(atLimit).body.count == 262_144)
        // Through the reassembler: one full group across two chunks, then a lone header byte in the third.
        let chunks = [
            try MIDICIPropertyReassemblerTests.chunk(1, of: 3, data: [0x00, 0x41], headerData: Self.mcoded7Header),
            try MIDICIPropertyReassemblerTests.chunk(2, of: 3, data: [UInt8](repeating: 0x41, count: 6)),
            try MIDICIPropertyReassemblerTests.chunk(3, of: 3, data: [0x7F])
        ]
        #expect(Self.refusal(try Self.reassemble(chunks)) == .body(.truncatedGroup(offset: 8)))
    }

    @Test func theCheckOrderIsKindRuleThenHeaderThenBody() throws {
        let longHeader = [UInt8](repeating: 0x80, count: 2_049)
        let highOver = [UInt8](repeating: 0x80, count: 262_145)
        let headerTooLong = Refusal.header(.tooLong(count: 2_049, limit: 2_048))
        for kind in Self.kinds where kind.hasNoPropertyData {
            // The kind rule first: the header data and the property data would each be `tooLong`.
            let both = try Self.reassembly(kind, headerData: longHeader, propertyData: highOver)
            #expect(Self.refusal(both) == .propertyDataNotAllowed(kind: kind, count: 262_145))
            let oneByte = try Self.reassembly(kind, headerData: [], propertyData: [0x80])
            #expect(Self.refusal(oneByte) == .propertyDataNotAllowed(kind: kind, count: 1))
            // Without property data the header data is still parsed.
            #expect(Self.refusal(try Self.reassembly(kind, headerData: longHeader)) == headerTooLong)
        }
        for kind in Self.kinds where !kind.hasNoPropertyData {
            // The header before the body, which would be `tooLong`, `byteHigh` or `unsupportedEncoding`.
            let both = try Self.reassembly(kind, headerData: longHeader, propertyData: highOver)
            #expect(Self.refusal(both) == headerTooLong)
            let empty = try Self.reassembly(kind, headerData: [], propertyData: [0x80])
            #expect(Self.refusal(empty) == .header(.unexpectedEnd(offset: 0)))
            // The body last.
            let zlib = try Self.reassembly(kind, headerData: Self.zlibHeader, propertyData: [0x80])
            #expect(Self.refusal(zlib) == .body(.unsupportedEncoding(.zlibMcoded7)))
        }
    }

    // MARK: The envelope and the text

    @Test func theEnvelopeFieldsAreCopiedFromTheReassembly() throws {
        let headers = [
            try MIDICIMessageTests.header(.ci11, device: 0x7F, source: 0x80, destination: 0x0123_4567),
            try MIDICIMessageTests.header(.ci12, device: 0x00, source: 0x0FFF_FEFF, destination: 0)
        ]
        let requestIDs: [UInt8] = [0x00, 0x2A, 0x7F]
        for kind in Self.kinds {
            for header in headers {
                for requestID in requestIDs {
                    let input = MIDICIPropertyReassembly(
                        kind: kind, header: header, requestID: requestID,
                        headerData: MIDICIMessageTests.exchangeStatus200Header, propertyData: [])
                    #expect(try MIDICIPropertyContent.decode(input) == MIDICIPropertyContent(
                        kind: kind, header: header, requestID: requestID,
                        propertyHeader: MIDICIPropertyHeader(status: 200), body: []))
                }
            }
        }
    }

    @Test func unknownKeysAndTheBodyTextAreKeptUninterpreted() throws {
        // Unknown members are named, sorted by their UTF-8 bytes, and their values dropped; a key's case matters.
        let headerData = Self.bytes(
            #"{"zeta":{"status":"x"},"resource":"ResourceList","alpha":null,"MutualEncoding":"Mcoded7"}"#)
        // Text that is not JSON and names a status and an encoding, with NUL and DEL, comes back as received.
        let text = Self.bytes(#"{"status":500,"mutualEncoding":"Mcoded7""#) + [0x00, 0x7F]
        let content = try MIDICIPropertyContent.decode(
            Self.reassembly(.notify, headerData: headerData, propertyData: text))
        #expect(content.propertyHeader == MIDICIPropertyHeader(
            resource: "ResourceList", unknownKeys: ["MutualEncoding", "alpha", "zeta"]))
        #expect(content.body == text)
        // A Mcoded7 body decodes to bytes that are not text at all (the 0x55 vector).
        let coded: [UInt8] = [0x55, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]
        let binary = try MIDICIPropertyContent.decode(
            Self.reassembly(headerData: Self.mcoded7Header, propertyData: coded))
        #expect(binary.propertyHeader == MIDICIPropertyHeader(encoding: .mcoded7))
        #expect(binary.body == [0x81, 0x02, 0x83, 0x04, 0x85, 0x06, 0x87])
    }
}
