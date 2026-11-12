//
//  MIDICIMessageTests+PropertyData.swift
//  FluxKlangTests
//
//  Property Exchange data messages (0x34 to 0x39 and 0x3F): one hand-written golden per kind in both CI formats,
//  the typed fixtures, the round trips, the chunk fields and the header and property data lengths (#83, slice CIP3).
//  The refusals, the orders, the hostile input and the neighbouring decoders are in
//  `MIDICIMessageTests+PropertyDataRules.swift`.
//
//  Provenance: every vector is written by hand from M2-101-UM v1.2, section 8 and Tables 33 to 39 (the layout after
//  the 13-byte header: request id, header length and header, chunk count, chunk number, data length and data, every
//  length and chunk field two 7-bit bytes, least significant first); none comes from another project or from the
//  encoder. The full refusal order is the doc comment of `MIDICIPropertyDataMessage.decode(payload:limits:)`.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    // MARK: Parts of the goldens (ASCII written out by hand)

    /// `{"resource":"DeviceInfo"}`, 25 bytes (0x19).
    static let exchangeResourceHeader: [UInt8] = [
        0x7B, 0x22, 0x72, 0x65, 0x73, 0x6F, 0x75, 0x72, 0x63, 0x65, 0x22, 0x3A, 0x22,
        0x44, 0x65, 0x76, 0x69, 0x63, 0x65, 0x49, 0x6E, 0x66, 0x6F, 0x22, 0x7D
    ]
    /// `{"status":200}`, 14 bytes (0x0E).
    static let exchangeStatus200Header: [UInt8] = [
        0x7B, 0x22, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x22, 0x3A, 0x32, 0x30, 0x30, 0x7D
    ]
    /// `{"status":500}`, 14 bytes (0x0E).
    static let exchangeStatus500Header: [UInt8] = [
        0x7B, 0x22, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x22, 0x3A, 0x35, 0x30, 0x30, 0x7D
    ]
    /// `{"command":"start"}`, 19 bytes (0x13).
    static let exchangeSubscribeHeader: [UInt8] = [
        0x7B, 0x22, 0x63, 0x6F, 0x6D, 0x6D, 0x61, 0x6E, 0x64, 0x22, 0x3A, 0x22,
        0x73, 0x74, 0x61, 0x72, 0x74, 0x22, 0x7D
    ]
    /// `[1,2]`, 5 bytes.
    static let exchangeArrayData: [UInt8] = [0x5B, 0x31, 0x2C, 0x32, 0x5D]
    /// MUID 0x00000080.
    static let exchangeLowBytes: [UInt8] = [0x00, 0x01, 0x00, 0x00]
    /// Number of chunks 1, number of this chunk 1, no property data: the tail Tables 33 and 36 fix.
    static let exchangeNoDataTail: [UInt8] = [0x01, 0x00, 0x01, 0x00, 0x00, 0x00]

    // MARK: Goldens (never produced by the encoder), in the order of the kinds in Tables 33 to 39

    /// Table 33, CI 1.2: request 0x05, the fixed tail.
    static let exchangeGetInquiry = prefix(0x7F, 0x34, 0x02) + sourceBytes + maximumBytes + [0x05, 0x19, 0x00]
        + exchangeResourceHeader + exchangeNoDataTail
    /// Table 34, CI 1.2: request 0x2A, chunk 1 of 1, five bytes of property data.
    static let exchangeGetReply = prefix(0x7F, 0x35, 0x02) + maximumBytes + sourceBytes + [0x2A, 0x19, 0x00]
        + exchangeResourceHeader + [0x01, 0x00, 0x01, 0x00, 0x05, 0x00] + exchangeArrayData
    /// Table 35, CI 1.1: request 0x7F, chunk 1 of 3, three bytes of property data.
    static let exchangeSetInquiry = prefix(0x7F, 0x36, 0x01) + exchangeLowBytes + sourceBytes + [0x7F, 0x19, 0x00]
        + exchangeResourceHeader + [0x03, 0x00, 0x01, 0x00, 0x03, 0x00, 0x7F, 0x00, 0x41]
    /// Table 36, CI 1.1: request 0x01, the fixed tail.
    static let exchangeSetReply = prefix(0x7F, 0x37, 0x01) + sourceBytes + exchangeLowBytes + [0x01, 0x0E, 0x00]
        + exchangeStatus200Header + exchangeNoDataTail
    /// Table 37, CI 1.2: request 0x10, destination MUID 0, no property data.
    static let exchangeSubscription = prefix(0x7F, 0x38, 0x02) + maximumBytes + zeroBytes + [0x10, 0x13, 0x00]
        + exchangeSubscribeHeader + exchangeNoDataTail
    /// Table 38, CI 1.1: request 0x10.
    static let exchangeSubscriptionReply = prefix(0x7F, 0x39, 0x01) + sourceBytes + maximumBytes + [0x10, 0x0E, 0x00]
        + exchangeStatus200Header + exchangeNoDataTail
    /// Table 39, CI 1.2: request 0x00, two bytes of property data (`OK`).
    static let exchangeNotify = prefix(0x7F, 0x3F, 0x02) + exchangeLowBytes + maximumBytes + [0x00, 0x0E, 0x00]
        + exchangeStatus500Header + [0x01, 0x00, 0x01, 0x00, 0x02, 0x00, 0x4F, 0x4B]
    static let exchangeGoldens: [[UInt8]] = [
        exchangeGetInquiry, exchangeGetReply, exchangeSetInquiry, exchangeSetReply, exchangeSubscription,
        exchangeSubscriptionReply, exchangeNotify
    ]

    // MARK: Typed fixtures

    static func exchangeChunk(
        request: UInt8, header: [UInt8] = [], count: UInt16 = 1, number: UInt16 = 1, data: [UInt8] = []
    ) throws -> MIDICIPropertyChunk {
        try MIDICIPropertyChunk.make(
            requestID: request, headerData: header, chunkCount: count, chunkNumber: number, propertyData: data)
    }

    static func exchangeMessages() throws -> [MIDICIPropertyDataMessage] {
        let source: UInt32 = 0x0123_4567
        let maximum: UInt32 = 0x0FFF_FEFF
        return [
            .getInquiry(
                try header(.ci12, device: 0x7F, destination: maximum),
                try exchangeChunk(request: 0x05, header: exchangeResourceHeader)),
            .getReply(
                try header(.ci12, device: 0x7F, source: maximum, destination: source),
                try exchangeChunk(request: 0x2A, header: exchangeResourceHeader, data: exchangeArrayData)),
            .setInquiry(
                try header(.ci11, device: 0x7F, source: 0x80, destination: source),
                try exchangeChunk(
                    request: 0x7F, header: exchangeResourceHeader, count: 3, data: [0x7F, 0x00, 0x41])),
            .setReply(
                try header(.ci11, device: 0x7F, destination: 0x80),
                try exchangeChunk(request: 0x01, header: exchangeStatus200Header)),
            .subscription(
                try header(.ci12, device: 0x7F, source: maximum, destination: 0),
                try exchangeChunk(request: 0x10, header: exchangeSubscribeHeader)),
            .subscriptionReply(
                try header(.ci11, device: 0x7F, destination: maximum),
                try exchangeChunk(request: 0x10, header: exchangeStatus200Header)),
            .notify(
                try header(.ci12, device: 0x7F, source: 0x80, destination: maximum),
                try exchangeChunk(request: 0x00, header: exchangeStatus500Header, data: [0x4F, 0x4B]))
        ]
    }

    static func exchangeDecodeRefusal(_ payload: [UInt8], limits: MIDICILimits = .standard) -> MIDICIRefusal? {
        do {
            _ = try MIDICIPropertyDataMessage.decode(payload: payload, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func exchangeEncodeRefusal(
        _ message: MIDICIPropertyDataMessage, limits: MIDICILimits = .standard
    ) -> MIDICIRefusal? {
        do {
            _ = try message.encode(limits: limits)
            return nil
        } catch {
            return error
        }
    }

    /// The 13-byte header of a CI 1.2 message to the Function Block, from MUID 0x01234567 to 0x0FFFFEFF.
    static func exchangeHead(_ subID: UInt8) -> [UInt8] {
        prefix(0x7F, subID, 0x02) + sourceBytes + maximumBytes
    }

    /// A payload built field by field for the length tests: the two-byte fields are split here, least significant
    /// seven bits first, independently of the codec.
    static func exchangePayload(
        subID: UInt8 = 0x35, format: UInt8 = 0x02, request: UInt8 = 0x01, header: [UInt8] = [], count: Int = 1,
        number: Int = 1, data: [UInt8] = []
    ) -> [UInt8] {
        func split(_ value: Int) -> [UInt8] { [UInt8(value & 0x7F), UInt8(value >> 7)] }
        return prefix(0x7F, subID, format) + sourceBytes + maximumBytes + [request] + split(header.count) + header
            + split(count) + split(number) + split(data.count) + data
    }

    // MARK: Goldens, decode and encode

    @Test func everyPropertyDataMessageEncodesToItsHandWrittenGoldenBytes() throws {
        let messages = try Self.exchangeMessages()
        try #require(messages.count == Self.exchangeGoldens.count)
        for (message, golden) in zip(messages, Self.exchangeGoldens) {
            #expect(try message.encode(limits: .standard) == golden)
        }
        #expect(Self.exchangeGoldens.map(\.count) == [47, 52, 50, 36, 41, 36, 38])
        let formats = try Self.exchangeGoldens.map { try #require($0.dropFirst(4).first) }
        #expect(formats == [2, 2, 1, 1, 2, 1, 2])
        #expect(messages.map(\.kind.rawValue) == [0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3F])
    }

    @Test func everyPropertyDataGoldenDecodesToItsExactTypedValueAndSurvivesTheRoundTrip() throws {
        let messages = try Self.exchangeMessages()
        try #require(messages.count == Self.exchangeGoldens.count)
        for (golden, message) in zip(Self.exchangeGoldens, messages) {
            let decoded = try MIDICIPropertyDataMessage.decode(payload: golden, limits: .standard)
            #expect(decoded == message)
            #expect(try decoded.encode(limits: .standard) == golden)
            #expect(try MIDICIPropertyDataMessage.decode(
                payload: try message.encode(limits: .standard), limits: .standard) == message)
        }
        let reply = try MIDICIPropertyDataMessage.decode(payload: Self.exchangeGetReply, limits: .standard)
        guard case let .getReply(header, chunk) = reply else {
            Issue.record("expected a Reply to Get Property Data")
            return
        }
        #expect(header.device.rawValue == 0x7F && header.format == .ci12)
        #expect(header.source.rawValue == 0x0FFF_FEFF && header.destination.rawValue == 0x0123_4567)
        #expect(chunk.requestID == 0x2A && chunk.headerData == Self.exchangeResourceHeader)
        #expect(chunk.chunkCount == 1 && chunk.chunkNumber == 1 && chunk.propertyData == Self.exchangeArrayData)
        #expect(reply.header == header && reply.chunk == chunk)
    }

    @Test func theHeaderGoldensAreTheASCIIOfTheJSONTheyAreNamedAfter() {
        #expect(Self.exchangeResourceHeader == Array(#"{"resource":"DeviceInfo"}"#.utf8))
        #expect(Self.exchangeStatus200Header == Array(#"{"status":200}"#.utf8))
        #expect(Self.exchangeStatus500Header == Array(#"{"status":500}"#.utf8))
        #expect(Self.exchangeSubscribeHeader == Array(#"{"command":"start"}"#.utf8))
        #expect(Self.exchangeArrayData == Array("[1,2]".utf8))
    }

    @Test func eachKindHasItsSubIDItsFormatFreeLayoutAndTheFixedTailOfTables33And36() throws {
        let rawValues: [UInt8] = [0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3F]
        let kinds = rawValues.compactMap(MIDICIPropertyDataKind.init(rawValue:))
        #expect(kinds.count == 7)
        #expect(kinds.filter(\.hasNoPropertyData) == [.getInquiry, .setReply])
        #expect(MIDICIPropertyDataMessage.destinationRule == .oneMUID)
        #expect(Self.exchangeGetInquiry.suffix(6) == [0x01, 0x00, 0x01, 0x00, 0x00, 0x00])
        #expect(Self.exchangeSetReply.suffix(6) == [0x01, 0x00, 0x01, 0x00, 0x00, 0x00])
        // The same body decodes in both formats, and the format is kept.
        for format: UInt8 in [1, 2] {
            let payload = Self.replacing(Self.exchangeGetReply, at: 4, with: format)
            let decoded = try MIDICIPropertyDataMessage.decode(payload: payload, limits: .standard)
            #expect(decoded.header.format.rawValue == format)
            #expect(try decoded.encode(limits: .standard) == payload)
        }
    }

    // MARK: Chunks

    @Test func aLaterChunkCarriesNoHeaderAndKeepsItsNumber() throws {
        // Chunk 2 of 3 of a Set Property Data: empty header (length 0), count 3, number 2, four bytes of data.
        let golden = Self.exchangeHead(0x36) + [0x09, 0x00, 0x00]
            + [0x03, 0x00, 0x02, 0x00, 0x04, 0x00, 0x11, 0x22, 0x33, 0x44]
        #expect(golden.count == 26)
        let message = MIDICIPropertyDataMessage.setInquiry(
            try Self.header(.ci12, device: 0x7F, destination: 0x0FFF_FEFF),
            try Self.exchangeChunk(request: 0x09, count: 3, number: 2, data: [0x11, 0x22, 0x33, 0x44]))
        #expect(try MIDICIPropertyDataMessage.decode(payload: golden, limits: .standard) == message)
        #expect(try message.encode(limits: .standard) == golden)
    }

    @Test func anUnknownChunkCountAndAZeroChunkNumberAreKeptAsReceived() throws {
        // Count 0: the sender does not know the number of chunks (section 8.3). Number 0 on a final chunk: bad data.
        let unknown = Self.exchangeHead(0x35) + [0x03, 0x00, 0x00]
            + [0x00, 0x00, 0x04, 0x00, 0x02, 0x00, 0x31, 0x32]
        let bad = Self.exchangeHead(0x39) + [0x03, 0x00, 0x00]
            + [0x06, 0x00, 0x00, 0x00, 0x01, 0x00, 0x7F]
        let decodedUnknown = try MIDICIPropertyDataMessage.decode(payload: unknown, limits: .standard)
        let decodedBad = try MIDICIPropertyDataMessage.decode(payload: bad, limits: .standard)
        #expect(decodedUnknown.chunk.chunkCount == 0 && decodedUnknown.chunk.chunkNumber == 4)
        #expect(decodedBad.chunk.chunkCount == 6 && decodedBad.chunk.chunkNumber == 0)
        #expect(try decodedUnknown.encode(limits: .standard) == unknown)
        #expect(try decodedBad.encode(limits: .standard) == bad)
    }

    @Test func chunkNumberZeroWithHeaderDataIsAcceptedOnDecodeAndEncode() throws {
        // Section 8.3.1 is silent on header data in a chunk numbered 0 (the final chunk of possibly bad data); the
        // codec keeps it, because only chunk numbers of 2 or more are refused (`headerOnlyInFirstChunk`).
        let bytes = Self.exchangeHead(0x35) + [0x03, 0x01, 0x00, 0x41]
            + [0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x7F]
        let decoded = try MIDICIPropertyDataMessage.decode(payload: bytes, limits: .standard)
        #expect(decoded.chunk.chunkNumber == 0 && decoded.chunk.headerData == [0x41])
        #expect(try decoded.encode(limits: .standard) == bytes)
    }

    @Test func theFourteenBitChunkFieldsReachTheirMaximumAndSplitLeastSignificantSevenBitsFirst() throws {
        let maximum = Self.exchangeHead(0x38) + [0x02, 0x00, 0x00]
            + [0x7F, 0x7F, 0x7F, 0x7F, 0x00, 0x00]
        let decoded = try MIDICIPropertyDataMessage.decode(payload: maximum, limits: .standard)
        #expect(decoded.chunk.chunkCount == 0x3FFF && decoded.chunk.chunkNumber == 0x3FFF)
        #expect(try decoded.encode(limits: .standard) == maximum)
        // 0x0081 is 1 * 128 + 1: the bytes are 01 01. 0x0100 is 02 00 and 0x0080 is 00 01.
        let split = Self.exchangeHead(0x38) + [0x02, 0x00, 0x00]
            + [0x01, 0x01, 0x00, 0x01, 0x00, 0x00]
        let decodedSplit = try MIDICIPropertyDataMessage.decode(payload: split, limits: .standard)
        #expect(decodedSplit.chunk.chunkCount == 0x0081 && decodedSplit.chunk.chunkNumber == 0x0080)
        #expect(try decodedSplit.encode(limits: .standard) == split)
        let chunk = try Self.exchangeChunk(request: 0x02, count: 0x0100, number: 0x0081)
        let encoded = try MIDICIPropertyDataMessage.notify(
            try Self.header(.ci12, device: 0x7F, destination: 0x0FFF_FEFF), chunk).encode(limits: .standard)
        #expect(encoded.suffix(6) == [0x00, 0x02, 0x01, 0x01, 0x00, 0x00])
    }

    // MARK: Lengths

    @Test func theHeaderLengthIsAcceptedAtZeroOneAndTheCapAndRoundTrips() throws {
        for count in [0, 1, 2, 127, 128, 129, 2_047, 2_048] {
            let header = [UInt8](repeating: 0x2D, count: count)
            let payload = Self.exchangePayload(header: header, data: [0x01])
            #expect(payload.count == 23 + count)
            let decoded = try MIDICIPropertyDataMessage.decode(payload: payload, limits: .standard)
            #expect(decoded.chunk.headerData == header)
            #expect(try decoded.encode(limits: .standard) == payload)
        }
        #expect(MIDICIPropertyChunk.maximumHeaderBytes == 2_048)
        let hostile = Self.exchangePayload(header: [UInt8](repeating: 0x2D, count: 2_049))
        #expect(Self.exchangeDecodeRefusal(hostile) == .propertyHeaderTooLong(2_049))
    }

    @Test func aHeaderLengthAboveTheCapIsReportedBeforeAnyTruncation() throws {
        // Declares 0x3FFF header bytes, has none: the hostile length is named before `truncated` is.
        let shortPayload = Self.exchangeHead(0x35) + [0x01, 0x7F, 0x7F]
        #expect(Self.exchangeDecodeRefusal(shortPayload) == .propertyHeaderTooLong(0x3FFF))
        let justOver = Self.exchangeHead(0x35) + [0x01, 0x01, 0x10]
        #expect(Self.exchangeDecodeRefusal(justOver) == .propertyHeaderTooLong(2_049))
        let atCap = Self.exchangeHead(0x35) + [0x01, 0x00, 0x10]
        #expect(Self.exchangeDecodeRefusal(atCap) == .truncated(need: 2_070, have: 16))
    }

    @Test func thePropertyDataLengthIsAcceptedAtZeroOneAndSeveralThousandBytes() throws {
        for count in [0, 1, 127, 128, 129, 3_000] {
            let data = [UInt8](repeating: 0x55, count: count)
            let payload = Self.exchangePayload(header: Self.exchangeStatus200Header, data: data)
            #expect(payload.count == 36 + count)
            let decoded = try MIDICIPropertyDataMessage.decode(payload: payload, limits: .standard)
            #expect(decoded.chunk.propertyData == data)
            #expect(try decoded.encode(limits: .standard) == payload)
        }
    }

    @Test func theFourteenBitFieldsAreWrittenAndReadLeastSignificantSevenBitsFirst() throws {
        // Header length 130 = bytes 02 01, chunk count 256 = bytes 00 02, data length 130 = bytes 02 01. Each pair
        // differs when swapped (written out here, not by `exchangePayload`).
        let header = [UInt8](repeating: 0x2D, count: 130)
        let data = [UInt8](repeating: 0x55, count: 130)
        let golden = Self.exchangeHead(0x35) + [0x01, 0x02, 0x01] + header
            + [0x00, 0x02, 0x01, 0x00, 0x02, 0x01] + data
        let decoded = try MIDICIPropertyDataMessage.decode(payload: golden, limits: .standard)
        #expect(decoded.chunk.headerData == header)
        #expect(decoded.chunk.chunkCount == 256 && decoded.chunk.chunkNumber == 1)
        #expect(decoded.chunk.propertyData == data)
        let message = try Self.exchangeMessage(
            0x35, chunk: try Self.exchangeChunk(request: 1, header: header, count: 256, number: 1, data: data))
        #expect(try message.encode(limits: .standard) == golden)
    }
}
