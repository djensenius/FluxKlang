//
//  MIDICIMessageTests+PropertyDataRules.swift
//  FluxKlangTests
//
//  Property Exchange data messages (0x34 to 0x39 and 0x3F): exact lengths, the lenient decode and strict encode
//  rules, the addressing, the format, the decode and encode orders, bytes of 0x80 or more, the value factory, the
//  neighbouring sub-ids and decoders, and seeded hostile input (#83, slice CIP3). The goldens and the typed fixtures
//  are in `MIDICIMessageTests+PropertyData.swift`.
//
//  Provenance: every vector is written by hand from M2-101-UM v1.2, section 8 and Tables 33 to 39; none comes from
//  another project or from the encoder.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    static let exchangeSubIDs: [UInt8] = [0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3F]

    static func exchangeMessage(
        _ subID: UInt8, device: UInt8 = 0x7F, source: UInt32 = 0x0123_4567, destination: UInt32 = 0x0FFF_FEFF,
        chunk: MIDICIPropertyChunk
    ) throws -> MIDICIPropertyDataMessage {
        let kind = try #require(MIDICIPropertyDataKind(rawValue: subID))
        return MIDICIPropertyDataMessage.make(
            kind, header: try header(.ci12, device: device, source: source, destination: destination), chunk: chunk)
    }

    // MARK: Lengths

    @Test func forEveryKindOneByteTooFewIsTruncatedAtTheExactLengthAndOneTooManyIsTrailing() throws {
        for golden in Self.exchangeGoldens {
            #expect(Self.exchangeDecodeRefusal(golden) == nil)
            let short = Array(golden.dropLast())
            #expect(Self.exchangeDecodeRefusal(short) == .truncated(need: golden.count, have: golden.count - 1))
            #expect(Self.exchangeDecodeRefusal(golden + [0x00]) == .trailingBytes(1))
            #expect(Self.exchangeDecodeRefusal(golden + [0x7F, 0x7F, 0x7F]) == .trailingBytes(3))
        }
    }

    @Test func everyPrefixOfAGoldenIsTruncatedAtTheNeededLength() throws {
        for golden in Self.exchangeGoldens {
            let lengthBytes = Array(golden.dropFirst(14).prefix(2))
            try #require(lengthBytes.count == 2)
            let headerLength = Int(lengthBytes[0]) + 128 * Int(lengthBytes[1])
            for length in 5..<golden.count {
                let expected: Int
                switch length {
                case 5..<13: expected = 13
                case 13..<16: expected = 16
                case 16..<(22 + headerLength): expected = 22 + headerLength
                default: expected = golden.count
                }
                #expect(Self.exchangeDecodeRefusal(Array(golden.prefix(length))) ==
                    .truncated(need: expected, have: length))
            }
            for length in 1..<5 {
                #expect(Self.exchangeDecodeRefusal(Array(golden.prefix(length))) ==
                    .truncated(need: 5, have: length))
            }
        }
        #expect(Self.exchangeDecodeRefusal([]) == .truncated(need: 1, have: 0))
    }

    @Test func aDeclaredPropertyDataLengthAboveOrBelowTheBytesPresentIsRefused() throws {
        let golden = Self.exchangeGetReply
        let offset = 22 + Self.exchangeResourceHeader.count - 2
        try #require(golden.count > offset + 1)
        #expect(Array(golden[offset...(offset + 1)]) == [0x05, 0x00])
        let more = Self.replacing(golden, range: offset..<(offset + 2), with: [0x06, 0x00])
        #expect(Self.exchangeDecodeRefusal(more) == .truncated(need: golden.count + 1, have: golden.count))
        let huge = Self.replacing(golden, range: offset..<(offset + 2), with: [0x7F, 0x7F])
        #expect(Self.exchangeDecodeRefusal(huge) == .truncated(need: 22 + 25 + 0x3FFF, have: golden.count))
        let fewer = Self.replacing(golden, range: offset..<(offset + 2), with: [0x00, 0x00])
        #expect(Self.exchangeDecodeRefusal(fewer) == .trailingBytes(5))
    }

    @Test func aPayloadAboveTheLimitIsRefusedWhateverItsBytes() throws {
        let limit = try Self.limits(payload: 46, text: 0)
        #expect(Self.exchangeDecodeRefusal(Self.exchangeGetInquiry, limits: limit) == .payloadTooLarge(47))
        let exact = try Self.limits(payload: 47, text: 0)
        #expect(Self.exchangeDecodeRefusal(Self.exchangeGetInquiry, limits: exact) == nil)
        #expect(Self.exchangeDecodeRefusal([UInt8](repeating: 0xFF, count: 65_536)) == .payloadTooLarge(65_536))
        let big = Self.exchangePayload(header: [UInt8](repeating: 0x20, count: 2_048),
                                       data: [UInt8](repeating: 0x21, count: 2_000))
        #expect(big.count == 4_070)
        #expect(Self.exchangeDecodeRefusal(big) == nil)
        #expect(Self.exchangeDecodeRefusal(big + [UInt8](repeating: 0, count: 27)) == .payloadTooLarge(4_097))
    }

    // MARK: Lenient decode, strict encode

    @Test func decodeKeepsPropertyDataChunkFieldsAndAnyDeviceIDThatEncodeWouldRefuse() throws {
        for subID: UInt8 in [0x34, 0x37] {
            let payload = Self.exchangePayload(
                subID: subID, header: [0x41], count: 0, number: 4, data: [0x01, 0x02])
            let decoded = try MIDICIPropertyDataMessage.decode(payload: payload, limits: .standard)
            #expect(decoded.chunk.propertyData == [0x01, 0x02])
            #expect(decoded.chunk.chunkCount == 0 && decoded.chunk.chunkNumber == 4)
            #expect(Self.exchangeEncodeRefusal(decoded) == .propertyDataNotAllowed(2))
        }
        for device in UInt8(0)...0x7F {
            let payload = Self.replacing(Self.exchangeGetReply, at: 1, with: device)
            let decoded = try MIDICIPropertyDataMessage.decode(payload: payload, limits: .standard)
            #expect(decoded.header.device.rawValue == device)
            if device == 0x7F {
                #expect(try decoded.encode(limits: .standard) == payload)
            } else {
                #expect(Self.exchangeEncodeRefusal(decoded) == .deviceNotFunctionBlock(device))
            }
        }
    }

    @Test func encodeRefusesPropertyDataAndOtherChunkFieldsOnlyOnGetInquiryAndSetReply() throws {
        for subID in Self.exchangeSubIDs {
            let strict = subID == 0x34 || subID == 0x37
            let withData = try Self.exchangeMessage(subID, chunk: try Self.exchangeChunk(request: 1, data: [0x10]))
            #expect(Self.exchangeEncodeRefusal(withData) == (strict ? .propertyDataNotAllowed(1) : nil))
            let fields: [(UInt16, UInt16)] = [(0, 1), (1, 0), (2, 1), (1, 2), (0, 0), (0x3FFF, 0x3FFF)]
            for (count, number) in fields {
                let chunk = try Self.exchangeChunk(request: 1, count: count, number: number)
                let message = try Self.exchangeMessage(subID, chunk: chunk)
                let expected: MIDICIRefusal? = strict ? .singleChunkRequired(count: count, number: number) : nil
                #expect(Self.exchangeEncodeRefusal(message) == expected)
            }
            let single = try Self.exchangeMessage(subID, chunk: try Self.exchangeChunk(request: 1))
            #expect(Self.exchangeEncodeRefusal(single) == nil)
        }
    }

    @Test func encodeRefusesHeaderDataFromChunkTwoOnButNotOnChunkZeroOrOne() throws {
        for subID in [0x35, 0x36, 0x38, 0x39, 0x3F] as [UInt8] {
            for number: UInt16 in [0, 1] {
                let chunk = try Self.exchangeChunk(request: 1, header: [0x41], count: 3, number: number)
                #expect(Self.exchangeEncodeRefusal(try Self.exchangeMessage(subID, chunk: chunk)) == nil)
            }
            for number: UInt16 in [2, 3, 0x3FFF] {
                let chunk = try Self.exchangeChunk(request: 1, header: [0x41], count: 3, number: number)
                #expect(Self.exchangeEncodeRefusal(try Self.exchangeMessage(subID, chunk: chunk)) ==
                    .headerOnlyInFirstChunk(number))
                let empty = try Self.exchangeChunk(request: 1, count: 3, number: number, data: [0x01])
                #expect(Self.exchangeEncodeRefusal(try Self.exchangeMessage(subID, chunk: empty)) == nil)
            }
        }
        // On 0x34 and 0x37 the chunk number rule is `singleChunkRequired`, which comes first.
        let strict = try Self.exchangeChunk(request: 1, header: [0x41], count: 1, number: 2)
        #expect(Self.exchangeEncodeRefusal(try Self.exchangeMessage(0x34, chunk: strict)) ==
            .singleChunkRequired(count: 1, number: 2))
    }

    @Test func aMessageThatBreaksSeveralEncodeRulesReportsTheFirstInTheDocumentedOrder() throws {
        let bad = try Self.exchangeChunk(request: 1, header: [0x41], count: 2, number: 2, data: [0x01])
        let broadcast: UInt32 = 0x0FFF_FFFF
        let everything = try Self.exchangeMessage(
            0x34, device: 0x10, source: broadcast, destination: broadcast, chunk: bad)
        #expect(Self.exchangeEncodeRefusal(everything) == .sourceIsBroadcast)
        let noSource = try Self.exchangeMessage(0x34, device: 0x10, destination: broadcast, chunk: bad)
        #expect(Self.exchangeEncodeRefusal(noSource) == .destinationIsBroadcast)
        let device = try Self.exchangeMessage(0x34, device: 0x10, chunk: bad)
        #expect(Self.exchangeEncodeRefusal(device) == .deviceNotFunctionBlock(0x10))
        let data = try Self.exchangeMessage(0x34, chunk: bad)
        #expect(Self.exchangeEncodeRefusal(data) == .propertyDataNotAllowed(1))
        let fields = try Self.exchangeMessage(0x37, chunk: try Self.exchangeChunk(request: 1, count: 2, number: 2))
        #expect(Self.exchangeEncodeRefusal(fields) == .singleChunkRequired(count: 2, number: 2))
        let header = try Self.exchangeMessage(0x36, chunk: bad)
        #expect(Self.exchangeEncodeRefusal(header, limits: try Self.limits(payload: 1, text: 0)) ==
            .headerOnlyInFirstChunk(2))
    }

    @Test func encodeRefusesAPayloadAboveTheLimitAtTheExactSize() throws {
        let message = try #require(try Self.exchangeMessages().dropFirst().first)
        #expect(Self.exchangeEncodeRefusal(message, limits: try Self.limits(payload: 51, text: 0)) ==
            .payloadTooLarge(52))
        #expect(Self.exchangeEncodeRefusal(message, limits: try Self.limits(payload: 52, text: 0)) == nil)
        let one = try Self.limits(payload: 1, text: 0)
        #expect(Self.exchangeEncodeRefusal(message, limits: one) == .payloadTooLarge(52))
        let widest = try Self.exchangeMessage(
            0x35, chunk: try Self.exchangeChunk(
                request: 0, header: [UInt8](repeating: 0x20, count: 2_048),
                data: [UInt8](repeating: 0x21, count: 2_026)))
        #expect(try widest.encode(limits: .standard).count == 4_096)
        let over = try Self.exchangeMessage(
            0x35, chunk: try Self.exchangeChunk(
                request: 0, header: [UInt8](repeating: 0x20, count: 2_048),
                data: [UInt8](repeating: 0x21, count: 2_027)))
        #expect(Self.exchangeEncodeRefusal(over) == .payloadTooLarge(4_097))
    }

    // MARK: Addressing, MUIDs and format

    @Test func everyKindRefusesABroadcastSourceThenABroadcastDestinationOnEncode() throws {
        let broadcast: UInt32 = 0x0FFF_FFFF
        for subID in Self.exchangeSubIDs {
            let chunk = try Self.exchangeChunk(request: 1)
            let destination = try Self.exchangeMessage(subID, destination: broadcast, chunk: chunk)
            #expect(Self.exchangeEncodeRefusal(destination) == .destinationIsBroadcast)
            let source = try Self.exchangeMessage(subID, source: broadcast, chunk: chunk)
            #expect(Self.exchangeEncodeRefusal(source) == .sourceIsBroadcast)
            let both = try Self.exchangeMessage(subID, source: broadcast, destination: broadcast, chunk: chunk)
            #expect(Self.exchangeEncodeRefusal(both) == .sourceIsBroadcast)
        }
    }

    @Test func everyKindRefusesABroadcastSourceThenABroadcastDestinationOnDecode() throws {
        for golden in Self.exchangeGoldens {
            let source = Self.replacing(golden, range: 5..<9, with: Self.broadcastBytes)
            #expect(Self.exchangeDecodeRefusal(source) == .sourceIsBroadcast)
            let destination = Self.replacing(golden, range: 9..<13, with: Self.broadcastBytes)
            #expect(Self.exchangeDecodeRefusal(destination) == .destinationIsBroadcast)
            let both = Self.replacing(destination, range: 5..<9, with: Self.broadcastBytes)
            #expect(Self.exchangeDecodeRefusal(both) == .sourceIsBroadcast)
        }
    }

    @Test func everyKindRefusesAnUnassignableMUIDSourceFirstAndBeforeTheAddressingRules() throws {
        for golden in Self.exchangeGoldens {
            let source = Self.replacing(golden, range: 5..<9, with: Self.reservedBytes)
            #expect(Self.exchangeDecodeRefusal(source) == .invalidMUID(0x0FFF_FF00))
            let destination = Self.replacing(golden, range: 9..<13, with: Self.reservedBytes)
            #expect(Self.exchangeDecodeRefusal(destination) == .invalidMUID(0x0FFF_FF00))
            let both = Self.replacing(source, range: 9..<13, with: [0x7E, 0x7F, 0x7F, 0x7F])
            #expect(Self.exchangeDecodeRefusal(both) == .invalidMUID(0x0FFF_FF00))
            // An invalid destination beats a broadcast source, because the MUIDs are checked first.
            let mixed = Self.replacing(destination, range: 5..<9, with: Self.broadcastBytes)
            #expect(Self.exchangeDecodeRefusal(mixed) == .invalidMUID(0x0FFF_FF00))
            // A bad length beats a bad MUID.
            #expect(Self.exchangeDecodeRefusal(source + [0x00]) == .trailingBytes(1))
        }
    }

    @Test func aFormatOtherThanOneOrTwoIsUnsupportedAndTheSubIDIsCheckedFirst() throws {
        for format: UInt8 in [0x00, 0x03, 0x04, 0x7F] {
            let payload = Self.replacing(Self.exchangeGetReply, at: 4, with: format)
            #expect(Self.exchangeDecodeRefusal(payload) == .unsupportedFormat(format))
            #expect(Self.exchangeDecodeRefusal(Self.replacing(payload, at: 3, with: 0x3A)) == .unknownSubID(0x3A))
            #expect(Self.exchangeDecodeRefusal(Array(payload.prefix(5))) == .unsupportedFormat(format))
        }
        let short = Self.replacing(Array(Self.exchangeGetReply.prefix(8)), at: 4, with: 0x00)
        #expect(Self.exchangeDecodeRefusal(short) == .unsupportedFormat(0))
    }

    // MARK: Bytes of 0x80 or more

    @Test func aByteOfEightBitsAtAnyOffsetIsDataByteHighExceptAtOffsetTwoWhichIsNotCI() throws {
        for golden in Self.exchangeGoldens {
            for offset in 1..<golden.count {
                for value: UInt8 in [0x80, 0xFF] {
                    let expected: MIDICIRefusal = offset == 2 ? .notCI : .dataByteHigh(offset: offset)
                    #expect(Self.exchangeDecodeRefusal(Self.replacing(golden, at: offset, with: value)) == expected)
                }
            }
            #expect(Self.exchangeDecodeRefusal(Self.replacing(golden, at: 0, with: 0x7F)) == .notCI)
        }
        // The scan runs before the sub-id and the lengths: a high byte beyond a truncated end is still found.
        let cut = Array(Self.exchangeGetReply.prefix(30)) + [0x80]
        #expect(Self.exchangeDecodeRefusal(cut) == .dataByteHigh(offset: 30))
    }

    @Test func theChunkFactoryRefusesWhatTheWireCannotCarry() throws {
        func make(
            request: UInt8 = 1, header: [UInt8] = [], count: UInt16 = 1, number: UInt16 = 1, data: [UInt8] = []
        ) throws -> MIDICIPropertyChunk {
            try MIDICIPropertyChunk.make(
                requestID: request, headerData: header, chunkCount: count, chunkNumber: number, propertyData: data)
        }
        #expect(throws: MIDICIRefusal.fieldOutOfRange(.requestID, value: 0x80)) { try make(request: 0x80) }
        #expect(throws: MIDICIRefusal.fieldOutOfRange(.headerData, value: 0xFF)) { try make(header: [0x00, 0xFF]) }
        #expect(throws: MIDICIRefusal.propertyHeaderTooLong(2_049)) {
            try make(header: [UInt8](repeating: 0x20, count: 2_049))
        }
        #expect(throws: MIDICIRefusal.fieldOutOfRange(.chunkCount, value: 0x4000)) { try make(count: 0x4000) }
        #expect(throws: MIDICIRefusal.fieldOutOfRange(.chunkNumber, value: 0xFFFF)) { try make(number: 0xFFFF) }
        #expect(throws: MIDICIRefusal.fieldOutOfRange(.propertyData, value: 0x80)) { try make(data: [0x7F, 0x80]) }
        #expect(throws: MIDICIRefusal.fieldOutOfRange(.propertyDataLength, value: 16_384)) {
            try make(data: [UInt8](repeating: 0x20, count: 16_384))
        }
        let widest = try make(
            request: 0x7F, header: [UInt8](repeating: 0x7F, count: 2_048), count: 0x3FFF, number: 0x3FFF,
            data: [UInt8](repeating: 0x7F, count: 16_383))
        #expect(widest.headerData.count == 2_048 && widest.propertyData.count == 16_383)
        #expect(widest.requestID == 0x7F && widest.chunkCount == 0x3FFF && widest.chunkNumber == 0x3FFF)
        let empty = try make(count: 0, number: 0)
        #expect(empty.headerData.isEmpty && empty.propertyData.isEmpty && empty.chunkCount == 0)
    }

    // MARK: Neighbours

    @Test func theSubIDsOutsideTheSevenAreUnknownHereAndTheOtherDecodersStillRefuseTheSeven() throws {
        let unknown: [UInt8] = [0x00, 0x30, 0x31, 0x32, 0x33, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x40, 0x44, 0x70, 0x7F]
        for subID in unknown {
            let payload = Self.replacing(Self.exchangeGetReply, at: 3, with: subID)
            #expect(Self.exchangeDecodeRefusal(payload) == .unknownSubID(subID))
        }
        for (subID, golden) in zip(Self.exchangeSubIDs, Self.exchangeGoldens) {
            #expect(golden.dropFirst(3).first == subID)
            let refusal = MIDICIRefusal.unknownSubID(subID)
            #expect(Self.decodeRefusal(golden) == refusal)
            #expect(throws: refusal) { try MIDICIProfileMessage.decode(payload: golden, limits: .standard) }
            #expect(throws: refusal) { try MIDICIPropertyCapabilityMessage.decode(payload: golden, limits: .standard) }
            #expect(throws: refusal) { try MIDICIEndpointMessage.decode(payload: golden, limits: .standard) }
            #expect(throws: refusal) { try MIDICIProcessInquiryMessage.decode(payload: golden, limits: .standard) }
        }
    }

    // MARK: Hostile input

    @Test func seededMutationsAndRandomPayloadsNeverTrapAndEverySuccessReencodesIdentically() throws {
        var random = Xorshift(seed: 0x5045_4433)
        var decoded = 0
        var refused = 0
        for golden in Self.exchangeGoldens {
            for _ in 0..<600 {
                var bytes = golden
                bytes[Int(random.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: random.next())
                if random.next() % 4 == 0 { bytes.removeLast() }
                Self.checkExchangeRoundTrip(bytes, decoded: &decoded, refused: &refused)
            }
        }
        for round in 0..<3_000 {
            var bytes: [UInt8]
            if round % 3 == 0 {
                bytes = (0..<Int(random.next() % 70)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            } else {
                let header = (0..<Int(random.next() % 6)).map { _ in UInt8(random.next() & 0x7F) }
                let data = (0..<Int(random.next() % 6)).map { _ in UInt8(random.next() & 0x7F) }
                bytes = Self.exchangePayload(
                    subID: Self.exchangeSubIDs[Int(random.next() % 7)], format: UInt8(1 + random.next() % 2),
                    request: UInt8(random.next() & 0x7F), header: header, count: Int(random.next() & 0x3FFF),
                    number: Int(random.next() & 0x3FFF), data: data)
                if round % 3 == 1, bytes.count > 1 { bytes[1] = UInt8(random.next() & 0x7F) }
            }
            Self.checkExchangeRoundTrip(bytes, decoded: &decoded, refused: &refused)
        }
        #expect(decoded > 1_000 && refused > 1_000)
    }

    /// A payload that decodes either re-encodes to the same bytes or is refused by one of the encode-only rules.
    static func checkExchangeRoundTrip(_ bytes: [UInt8], decoded: inout Int, refused: inout Int) {
        guard let message = try? MIDICIPropertyDataMessage.decode(payload: bytes, limits: .standard) else {
            refused += 1
            return
        }
        decoded += 1
        do {
            let encoded = try message.encode(limits: .standard)
            #expect(encoded == bytes)
            #expect(try MIDICIPropertyDataMessage.decode(payload: encoded, limits: .standard) == message)
        } catch {
            switch error {
            case .deviceNotFunctionBlock, .propertyDataNotAllowed, .singleChunkRequired, .headerOnlyInFirstChunk:
                break
            default:
                Issue.record("unexpected encode refusal \(error)")
            }
        }
    }
}
