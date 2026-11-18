//
//  MIDICIPropertyChunkerTests.swift
//  FluxKlangTests
//
//  The goldens rebuilt, the greedy fill at the payload limit, the round trip through the codec, the reassembler and
//  the content decoder, the kinds without property data, the inclusive limits, the wrapped chunk refusals, the check
//  order and the envelope of every chunk for `MIDICIPropertyChunker.chunks` (#83, slice M83-PXO, issue #831). Seeded
//  input is in `MIDICIPropertyChunkerTests+Seeded.swift`. Nothing calls the chunker yet.
//
//  Provenance: the goldens and typed fixtures are `MIDICIMessageTests`' own, and every expected chunk size, payload
//  size and refusal was worked out by hand from the layout (`22 + H + D` bytes). No expected value was produced by the
//  chunker under test. The Property Exchange specifications (M2-102-UM and M2-103-UM) were not read.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI-CI Property Exchange chunker", .productionAccessAudit)
struct MIDICIPropertyChunkerTests {
    typealias Refusal = MIDICIPropertyChunkingRefusal
    typealias Message = MIDICIPropertyDataMessage

    /// Every kind, in the order of Tables 33 to 39.
    static let kinds: [MIDICIPropertyDataKind] = [
        .getInquiry, .getReply, .setInquiry, .setReply, .subscription, .subscriptionReply, .notify
    ]
    /// `{"mutualEncoding":"Mcoded7"}`, 28 bytes.
    static let mcoded7Header = Array(#"{"mutualEncoding":"Mcoded7"}"#.utf8)
    /// `{"status":200}`, 14 bytes.
    static let status = MIDICIMessageTests.exchangeStatus200Header

    static func limits(_ payload: Int) throws -> MIDICILimits {
        try MIDICIMessageTests.limits(payload: payload, text: 0)
    }

    /// `count` 7-bit bytes that repeat every 127 bytes, so that no two cuts of a body look alike.
    static func data(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8($0 % 127) }
    }

    /// The chunks or the refusal. The default header is the reassembler tests' CI 1.2 header to the Function Block.
    static func outcome(
        _ kind: MIDICIPropertyDataKind = .getReply, header: MIDICIHeader? = nil, requestID: UInt8 = 0x2A,
        headerData: [UInt8] = [], propertyData: [UInt8] = [], limit: Int = 4_096
    ) throws -> Result<[Message], Refusal> {
        let header = try header ?? MIDICIPropertyReassemblerTests.header()
        let limits = try Self.limits(limit)
        do {
            return .success(try MIDICIPropertyChunker.chunks(
                kind, header: header, requestID: requestID, headerData: headerData, propertyData: propertyData,
                limits: limits))
        } catch {
            return .failure(error)
        }
    }

    /// The chunks, or the refusal thrown.
    static func cut(
        _ kind: MIDICIPropertyDataKind = .getReply, header: MIDICIHeader? = nil, requestID: UInt8 = 0x2A,
        headerData: [UInt8] = [], propertyData: [UInt8] = [], limit: Int = 4_096
    ) throws -> [Message] {
        try outcome(
            kind, header: header, requestID: requestID, headerData: headerData, propertyData: propertyData,
            limit: limit
        ).get()
    }

    /// The refusal, or nil for chunks: small to print, whatever the number of chunks.
    static func refusal(
        _ kind: MIDICIPropertyDataKind = .getReply, requestID: UInt8 = 0x2A, headerData: [UInt8] = [],
        propertyData: [UInt8] = [], limit: Int = 4_096
    ) throws -> Refusal? {
        let result = try outcome(
            kind, requestID: requestID, headerData: headerData, propertyData: propertyData, limit: limit)
        guard case .failure(let refusal) = result else { return nil }
        return refusal
    }

    /// `MIDICIPropertyChunk.make` on its own: the refusal the chunker must wrap.
    static func factoryRefusal(
        requestID: UInt8 = 0x2A, headerData: [UInt8] = [], count: UInt16 = 1, number: UInt16 = 1,
        propertyData: [UInt8] = []
    ) -> MIDICIRefusal? {
        do {
            _ = try MIDICIPropertyChunk.make(
                requestID: requestID, headerData: headerData, chunkCount: count, chunkNumber: number,
                propertyData: propertyData)
            return nil
        } catch {
            return error
        }
    }

    static func propertySizes(_ messages: [Message]) -> [Int] {
        messages.map(\.chunk.propertyData.count)
    }

    /// The length of each encoded payload (without F0 and F7).
    static func payloadSizes(_ messages: [Message], limit: Int) throws -> [Int] {
        let limits = try Self.limits(limit)
        var sizes: [Int] = []
        for message in messages {
            sizes.append(try message.encode(limits: limits).count)
        }
        return sizes
    }

    /// Encodes and decodes each message under `limit`, then feeds it to a reassembler at its ceilings; only the last
    /// message completes the reassembly.
    static func roundTrip(_ messages: [Message], limit: Int) throws -> MIDICIPropertyReassembly {
        let limits = try Self.limits(limit)
        var reassembler = try MIDICIPropertyReassembler.make(maximumChunks: 256, maximumPropertyBytes: 262_144)
        var complete: MIDICIPropertyReassembly?
        for message in messages {
            try #require(complete == nil)
            let decoded = try Message.decode(payload: message.encode(limits: limits), limits: limits)
            try #require(decoded == message)
            complete = try reassembler.accept(decoded)
        }
        return try #require(complete)
    }

    // MARK: Goldens

    @Test func everySingleChunkGoldenIsRebuiltByteForByte() throws {
        let goldens = MIDICIMessageTests.exchangeGoldens
        let messages = try MIDICIMessageTests.exchangeMessages()
        try #require(goldens.count == 7 && messages.count == 7)
        var rebuilt = 0
        for (golden, message) in zip(goldens, messages) where message.kind != .setInquiry {
            let chunk = message.chunk
            try #require(chunk.chunkCount == 1 && chunk.chunkNumber == 1)
            let chunks = try Self.cut(
                message.kind, header: message.header, requestID: chunk.requestID, headerData: chunk.headerData,
                propertyData: chunk.propertyData, limit: 4_096)
            #expect(chunks == [message], "\(message.kind)")
            let only = try #require(chunks.first)
            #expect(try only.encode(limits: .standard) == golden, "\(message.kind)")
            rebuilt += 1
        }
        #expect(rebuilt == 6)
    }

    @Test func theSetInquiryGoldenIsChunkOneOfThreeAtFiftyBytes() throws {
        let messages = try MIDICIMessageTests.exchangeMessages()
        try #require(messages.count == 7)
        let golden = messages[2]
        try #require(golden.kind == .setInquiry && golden.chunk.propertyData == [0x7F, 0x00, 0x41])
        // H = 25, so chunk 1 has room for 50 - 22 - 25 = 3 bytes and every later chunk for 28.
        let tail = Self.data(30)
        let chunks = try Self.cut(
            .setInquiry, header: golden.header, requestID: 0x7F, headerData: MIDICIMessageTests.exchangeResourceHeader,
            propertyData: golden.chunk.propertyData + tail, limit: 50)
        try #require(chunks.count == 3)
        #expect(chunks[0] == golden)
        #expect(try chunks[0].encode(limits: Self.limits(50)) == MIDICIMessageTests.exchangeSetInquiry)
        let second = try MIDICIMessageTests.exchangeChunk(request: 0x7F, count: 3, number: 2, data: Array(tail[0..<28]))
        let third = try MIDICIMessageTests.exchangeChunk(request: 0x7F, count: 3, number: 3, data: Array(tail[28...]))
        #expect(chunks[1] == .setInquiry(golden.header, second))
        #expect(chunks[2] == .setInquiry(golden.header, third))
        #expect(Self.propertySizes(chunks) == [3, 28, 2])
        #expect(try Self.payloadSizes(chunks, limit: 50) == [50, 50, 24])
    }

    // MARK: Sizes

    @Test func chunksAreFilledGreedilyAndEachFullChunkIsExactlyAtTheLimit() throws {
        // Worked out by hand: chunk 1 holds `limit - 22 - H` bytes and every later chunk `limit - 22`.
        let cases: [(input: [Int], sizes: [Int])] = [
            ([23, 0, 0], [0]), ([23, 0, 1], [1]), ([23, 0, 2], [1, 1]), ([23, 0, 3], [1, 1, 1]),
            ([23, 1, 0], [0]), ([23, 1, 1], [0, 1]), ([23, 1, 2], [0, 1, 1]),
            ([24, 0, 1], [1]), ([24, 0, 2], [2]), ([24, 0, 3], [2, 1]), ([24, 0, 4], [2, 2]), ([24, 0, 5], [2, 2, 1]),
            ([24, 1, 1], [1]), ([24, 1, 2], [1, 1]), ([24, 1, 3], [1, 2]), ([24, 1, 4], [1, 2, 1]),
            ([50, 0, 57], [28, 28, 1]), ([50, 25, 2], [2]), ([50, 25, 3], [3]), ([50, 25, 4], [3, 1]),
            ([50, 25, 30], [3, 27]), ([50, 25, 31], [3, 28]), ([50, 25, 32], [3, 28, 1]),
            ([50, 25, 59], [3, 28, 28]), ([50, 25, 60], [3, 28, 28, 1]),
            ([4_096, 0, 4_073], [4_073]), ([4_096, 0, 4_074], [4_074]), ([4_096, 0, 4_075], [4_074, 1]),
            ([4_096, 0, 8_148], [4_074, 4_074]), ([4_096, 0, 8_149], [4_074, 4_074, 1]),
            ([4_096, 25, 4_050], [4_049, 1]), ([4_096, 25, 8_123], [4_049, 4_074]),
            ([4_096, 25, 8_124], [4_049, 4_074, 1])
        ]
        for (input, sizes) in cases {
            try #require(input.count == 3)
            let chunks = try Self.cut(
                headerData: Self.data(input[1]), propertyData: Self.data(input[2]), limit: input[0])
            #expect(Self.propertySizes(chunks) == sizes, "\(input)")
        }
        for limit in [23, 24, 50, 4_096] {
            for headerCount in [0, 1, 25] {
                try Self.expectGreedyAround(limit: limit, headerCount: headerCount)
            }
        }
    }

    /// At chunk 1's capacity, then one and two later chunks' capacity past it, and one byte either side: every
    /// payload but the last is at the limit and the last is not empty. Without room for the header, it is refused.
    static func expectGreedyAround(limit: Int, headerCount: Int) throws {
        let first = limit - 22 - headerCount
        let next = limit - 22
        guard first >= 0 else {
            let refusal = try Self.refusal(headerData: Self.data(headerCount), propertyData: [0x41], limit: limit)
            #expect(refusal == .payloadLimitTooSmall(needed: 22 + headerCount, limit: limit))
            return
        }
        let edges = [first, first + next, first + 2 * next].flatMap { [$0 - 1, $0, $0 + 1] }.filter { $0 >= 0 }
        for dataCount in edges {
            let data = Self.data(dataCount)
            let chunks = try Self.cut(headerData: Self.data(headerCount), propertyData: data, limit: limit)
            let payloads = try Self.payloadSizes(chunks, limit: limit)
            let last = try #require(chunks.last)
            let label = "\(limit) \(headerCount) \(dataCount)"
            #expect(payloads.dropLast().allSatisfy { $0 == limit }, "\(label)")
            #expect(
                payloads.last == 22 + (chunks.count == 1 ? headerCount : 0) + last.chunk.propertyData.count,
                "\(label)"
            )
            #expect(payloads.allSatisfy { $0 <= limit }, "\(label)")
            #expect(chunks.count == 1 || !last.chunk.propertyData.isEmpty, "\(label)")
            #expect(chunks.flatMap(\.chunk.propertyData) == data, "\(label)")
        }
    }

    // MARK: Round trips

    @Test func chunksRoundTripThroughTheCodecAndTheReassembler() throws {
        let headers = [
            try MIDICIMessageTests.header(.ci11, device: 0x7F, source: 0x80, destination: 0x0123_4567),
            try MIDICIMessageTests.header(.ci12, device: 0x7F, source: 0x0FFF_FEFF, destination: 0)
        ]
        // H = 14 at a limit of 64: 28 bytes in chunk 1, 42 in each later chunk.
        let sizes: [(dataCount: Int, chunkCount: Int)] = [(0, 1), (1, 1), (28, 1), (29, 2), (70, 2), (71, 3), (500, 13)]
        for kind in Self.kinds {
            for header in headers {
                for (dataCount, chunkCount) in sizes where dataCount == 0 || !kind.hasNoPropertyData {
                    let data = Self.data(dataCount)
                    let chunks = try Self.cut(
                        kind, header: header, requestID: 0x11, headerData: Self.status, propertyData: data, limit: 64)
                    #expect(chunks.count == chunkCount, "\(kind) \(dataCount)")
                    #expect(try Self.roundTrip(chunks, limit: 64) == MIDICIPropertyReassembly(
                        kind: kind, header: header, requestID: 0x11, headerData: Self.status, propertyData: data))
                }
            }
        }
    }

    @Test func aMcoded7BodyCutInsideGroupsDecodesThroughTheContentDecoder() throws {
        let raw = (0...255).map { UInt8($0) }
        let coded = MIDICIMcoded7.encode(raw)
        // 36 groups of 8 bytes, then a header byte and the last 4 bytes.
        try #require(coded.count == 293 && Self.mcoded7Header.count == 28)
        // Chunk 1 holds 60 - 22 - 28 = 10 bytes, so most cuts fall inside a group of 8.
        let chunks = try Self.cut(headerData: Self.mcoded7Header, propertyData: coded, limit: 60)
        #expect(Self.propertySizes(chunks) == [10, 38, 38, 38, 38, 38, 38, 38, 17])
        let reassembly = try Self.roundTrip(chunks, limit: 60)
        #expect(reassembly.propertyData == coded)
        let content = try MIDICIPropertyContent.decode(reassembly)
        #expect(content.propertyHeader == MIDICIPropertyHeader(encoding: .mcoded7))
        #expect(content.body == raw)
    }

    // MARK: Limits

    @Test func kindsWithoutPropertyDataGiveOneChunkAndRefuseData() throws {
        try #require(Self.kinds.filter(\.hasNoPropertyData) == [.getInquiry, .setReply])
        for kind in Self.kinds {
            let chunks = try Self.cut(kind, headerData: Self.status)
            let only = try #require(chunks.first)
            #expect(chunks.count == 1)
            #expect(only.chunk.chunkCount == 1 && only.chunk.chunkNumber == 1 && only.chunk.propertyData.isEmpty)
            #expect(try only.encode(limits: .standard).count == 36, "\(kind)")
            let oneByte = try Self.refusal(kind, headerData: Self.status, propertyData: [0x41])
            let tooLong = try Self.refusal(kind, propertyData: Self.data(262_145))
            if kind.hasNoPropertyData {
                #expect(oneByte == .propertyDataNotAllowed(kind: kind, count: 1))
                #expect(tooLong == .propertyDataNotAllowed(kind: kind, count: 262_145))
            } else {
                #expect(oneByte == nil)
                #expect(tooLong == .propertyDataTooLong(count: 262_145, limit: 262_144))
            }
        }
    }

    @Test func thePropertyDataLimitIsInclusive() throws {
        let data = Self.data(262_144)
        let chunks = try Self.cut(propertyData: data, limit: 4_096)
        #expect(Self.propertySizes(chunks) == [Int](repeating: 4_074, count: 64) + [1_408])
        #expect(try Self.roundTrip(chunks, limit: 4_096).propertyData == data)
        let over = try Self.refusal(propertyData: Self.data(262_145), limit: 4_096)
        #expect(over == .propertyDataTooLong(count: 262_145, limit: 262_144))
    }

    @Test func thePayloadLimitMustHoldTheHeaderAndOneByte() throws {
        let header = MIDICIMessageTests.exchangeResourceHeader
        try #require(header.count == 25)
        // The header data alone.
        #expect(try Self.payloadSizes(Self.cut(headerData: header, limit: 47), limit: 47) == [47])
        #expect(try Self.refusal(headerData: header, limit: 46) == .payloadLimitTooSmall(needed: 47, limit: 46))
        // One byte of property data alone.
        #expect(try Self.payloadSizes(Self.cut(propertyData: [0x41], limit: 23), limit: 23) == [23])
        #expect(try Self.refusal(propertyData: [0x41], limit: 22) == .payloadLimitTooSmall(needed: 23, limit: 22))
        // Neither: the 22 fixed bytes.
        #expect(try Self.payloadSizes(Self.cut(limit: 22), limit: 22) == [22])
        #expect(try Self.refusal(limit: 1) == .payloadLimitTooSmall(needed: 22, limit: 1))
        // Both, with no room for property data in chunk 1: an empty chunk 1, then the byte in chunk 2.
        let both = try Self.cut(headerData: header, propertyData: [0x41], limit: 47)
        #expect(Self.propertySizes(both) == [0, 1])
        #expect(try Self.payloadSizes(both, limit: 47) == [47, 23])
        #expect(try Self.roundTrip(both, limit: 47) == MIDICIPropertyReassembly(
            kind: .getReply, header: MIDICIPropertyReassemblerTests.header(), requestID: 0x2A,
            headerData: header, propertyData: [0x41]))
        #expect(try Self.refusal(headerData: header, propertyData: [0x41], limit: 46)
            == .payloadLimitTooSmall(needed: 47, limit: 46))
    }

    @Test func theChunkCountLimitIsInclusive() throws {
        // One byte per chunk at a limit of 23 with no header data.
        let ones = try Self.cut(propertyData: Self.data(16_383), limit: 23)
        try #require(ones.count == 16_383)
        #expect(Self.propertySizes(ones) == [Int](repeating: 1, count: 16_383))
        let last = try #require(ones.last)
        #expect(last.chunk.chunkCount == 16_383 && last.chunk.chunkNumber == 16_383)
        #expect(try last.encode(limits: Self.limits(23)).count == 23)
        let over = try Self.refusal(propertyData: Self.data(16_384), limit: 23)
        #expect(over == .tooManyChunks(count: 16_384, limit: 16_383))
        // One header byte leaves chunk 1 empty, so one byte less fits.
        let empty = try Self.cut(headerData: [0x7B], propertyData: Self.data(16_382), limit: 23)
        try #require(empty.count == 16_383)
        let first = try #require(empty.first)
        #expect(first.chunk.headerData == [0x7B] && first.chunk.propertyData.isEmpty)
        let emptyOver = try Self.refusal(headerData: [0x7B], propertyData: Self.data(16_383), limit: 23)
        #expect(emptyOver == .tooManyChunks(count: 16_384, limit: 16_383))
    }

    // MARK: Refusals

    @Test func aChunkFactoryRefusalIsWrappedUnchanged() throws {
        let request = try #require(Self.factoryRefusal(requestID: 0x80))
        #expect(request == .fieldOutOfRange(.requestID, value: 0x80))
        #expect(try Self.refusal(requestID: 0x80) == .chunk(request))
        let long = [UInt8](repeating: 0x20, count: 2_049)
        let tooLong = try #require(Self.factoryRefusal(headerData: long))
        #expect(tooLong == .propertyHeaderTooLong(2_049))
        #expect(try Self.refusal(headerData: long, limit: 4_096) == .chunk(tooLong))
        let highHeader = try #require(Self.factoryRefusal(headerData: [0x7B, 0x80, 0x7D]))
        #expect(highHeader == .fieldOutOfRange(.headerData, value: 0x80))
        #expect(try Self.refusal(headerData: [0x7B, 0x80, 0x7D], propertyData: [0x41]) == .chunk(highHeader))
        // Two bytes per chunk at a limit of 24: byte 4 is the first of chunk 3.
        var data = Self.data(6)
        data[4] = 0xFF
        let third = try #require(Self.factoryRefusal(count: 3, number: 3, propertyData: Array(data[4...])))
        #expect(third == .fieldOutOfRange(.propertyData, value: 0xFF))
        #expect(try Self.refusal(propertyData: data, limit: 24) == .chunk(third))
        // The first failing chunk wins.
        data[1] = 0x81
        let first = try #require(Self.factoryRefusal(count: 3, propertyData: Array(data[0..<2])))
        #expect(first == .fieldOutOfRange(.propertyData, value: 0x81))
        #expect(try Self.refusal(propertyData: data, limit: 24) == .chunk(first))
    }

    @Test func theCheckOrderIsKindLengthFitCountThenChunk() throws {
        let over = [UInt8](repeating: 0x80, count: 262_145)
        let high = [UInt8](repeating: 0x80, count: 16_384)
        let long = [UInt8](repeating: 0x80, count: 2_049)
        // The kind rule beats every other refusal.
        for kind in Self.kinds where kind.hasNoPropertyData {
            #expect(try Self.refusal(kind, requestID: 0x80, headerData: long, propertyData: over, limit: 1)
                == .propertyDataNotAllowed(kind: kind, count: 262_145))
            #expect(try Self.refusal(kind, propertyData: [0x80], limit: 1)
                == .propertyDataNotAllowed(kind: kind, count: 1))
        }
        // The length of the property data beats the fit, the count and the chunk.
        let tooLong = Refusal.propertyDataTooLong(count: 262_145, limit: 262_144)
        #expect(try Self.refusal(requestID: 0x80, headerData: long, propertyData: over, limit: 1) == tooLong)
        #expect(try Self.refusal(propertyData: over, limit: 23) == tooLong)
        // The fit beats the count and the chunk, which would be `propertyHeaderTooLong`.
        #expect(try Self.refusal(propertyData: high, limit: 22) == .payloadLimitTooSmall(needed: 23, limit: 22))
        #expect(try Self.refusal(headerData: [0x7B, 0x7B], propertyData: high, limit: 23)
            == .payloadLimitTooSmall(needed: 24, limit: 23))
        #expect(try Self.refusal(headerData: long, limit: 2_000) == .payloadLimitTooSmall(needed: 2_071, limit: 2_000))
        #expect(try Self.refusal(requestID: 0x80, limit: 1) == .payloadLimitTooSmall(needed: 22, limit: 1))
        // The count beats the chunk.
        #expect(try Self.refusal(requestID: 0x80, headerData: [0x80], propertyData: high, limit: 23)
            == .tooManyChunks(count: 16_385, limit: 16_383))
        #expect(try Self.refusal(requestID: 0x80, propertyData: high, limit: 23)
            == .tooManyChunks(count: 16_384, limit: 16_383))
        // The chunk last: the request id first, then the header data, then the property data.
        #expect(try Self.refusal(requestID: 0x80, headerData: long, propertyData: high, limit: 4_096)
            == .chunk(.fieldOutOfRange(.requestID, value: 0x80)))
        #expect(try Self.refusal(headerData: long, propertyData: high, limit: 4_096)
            == .chunk(.propertyHeaderTooLong(2_049)))
        #expect(try Self.refusal(headerData: [0x7B, 0x80], propertyData: high, limit: 4_096)
            == .chunk(.fieldOutOfRange(.headerData, value: 0x80)))
    }

    // MARK: The envelope

    @Test func everyChunkCarriesTheEnvelopeAndOnlyTheFirstTheHeader() throws {
        let headers = [
            try MIDICIMessageTests.header(.ci11, device: 0x7F, source: 0x80, destination: 0x0123_4567),
            try MIDICIMessageTests.header(.ci12, device: 0x7F, source: 0x0FFF_FEFF, destination: 0)
        ]
        // H = 14 at a limit of 40: 4 bytes in chunk 1 and 18 in each later chunk, so 50 bytes take 4 chunks.
        for kind in Self.kinds where !kind.hasNoPropertyData {
            for header in headers {
                for requestID: UInt8 in [0x00, 0x2A, 0x7F] {
                    let chunks = try Self.cut(
                        kind, header: header, requestID: requestID, headerData: Self.status,
                        propertyData: Self.data(50), limit: 40)
                    #expect(Self.propertySizes(chunks) == [4, 18, 18, 10])
                    Self.expectEnvelope(
                        chunks, kind: kind, header: header, requestID: requestID, headerData: Self.status)
                }
            }
        }
        // Addressing is left to `encode(limits:)`: the chunks are made, and each is refused there.
        let addressed: [(header: MIDICIHeader, refusal: MIDICIRefusal)] = [
            (try MIDICIMessageTests.header(.ci12, device: 0x7F, source: 0x0FFF_FFFF), .sourceIsBroadcast),
            (try MIDICIMessageTests.header(.ci12, device: 0x7F), .destinationIsBroadcast),
            (
                try MIDICIMessageTests.header(.ci12, device: 0x10, destination: 0x0FFF_FEFF),
                .deviceNotFunctionBlock(0x10)
            )
        ]
        for (header, refusal) in addressed {
            let chunks = try Self.cut(
                .notify, header: header, headerData: Self.status, propertyData: Self.data(50), limit: 40)
            #expect(chunks.count == 4)
            Self.expectEnvelope(chunks, kind: .notify, header: header, requestID: 0x2A, headerData: Self.status)
            for message in chunks {
                #expect(try MIDICIMessageTests.exchangeEncodeRefusal(message, limits: Self.limits(40)) == refusal)
            }
        }
    }

    /// Every chunk has `kind`, `header`, `requestID` and the chunk count; the numbers run 1...n; only chunk 1 has the
    /// header data, `headerData`.
    static func expectEnvelope(
        _ chunks: [Message], kind: MIDICIPropertyDataKind, header: MIDICIHeader, requestID: UInt8,
        headerData: [UInt8], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for (index, message) in chunks.enumerated() {
            let chunk = message.chunk
            #expect(message.kind == kind && message.header == header, sourceLocation: sourceLocation)
            #expect(chunk.requestID == requestID, sourceLocation: sourceLocation)
            #expect(Int(chunk.chunkCount) == chunks.count, sourceLocation: sourceLocation)
            #expect(Int(chunk.chunkNumber) == index + 1, sourceLocation: sourceLocation)
            #expect(chunk.headerData == (index == 0 ? headerData : []), sourceLocation: sourceLocation)
        }
    }
}
