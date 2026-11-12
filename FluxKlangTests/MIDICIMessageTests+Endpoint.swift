//
//  MIDICIMessageTests+Endpoint.swift
//  FluxKlangTests
//
//  Inquiry: Endpoint Information (0x72) and its Reply (0x73): reference goldens, decode, encode, CI 1.2 only, the
//  14-bit information length, the information bound, every refusal in decoder order, high bytes, the Product
//  Instance ID view, seeded mutations and the round trip (#83, slice CEI1).
//
//  Provenance: the `amEndpoint*` vectors are the bytes printed by AM_MIDI2.0Lib's
//  `CIMessage::sendEndpointInfoRequest` / `sendEndpointInfoReply` (src/midiCIMessageCreate.cpp, commit 7fa1b0c) for
//  the arguments named next to each vector (for CI version 1 both functions return 0 bytes); the field values are
//  this slice's own. The other vectors are written by hand from the layout. The full refusal order is the doc
//  comment of `MIDICIEndpointMessage.decode(payload:limits:)`.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    // MARK: Endpoint goldens (never produced by the encoder)

    /// "FK-CEI1-00000042", 16 ASCII bytes.
    static let productIDBytes: [UInt8] = [
        0x46, 0x4B, 0x2D, 0x43, 0x45, 0x49, 0x31, 0x2D, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x34, 0x32
    ]
    /// AM: `sendEndpointInfoRequest(sysex, 2, 0x01234567, 0x0FFFFEFF, 0)`.
    static let amEndpointInquiry: [UInt8] = [
        0x7E, 0x7F, 0x0D, 0x72, 0x02, 0x67, 0x0A, 0x0D, 0x09, 0x7F, 0x7D, 0x7F, 0x7F, 0x00
    ]
    /// AM: `sendEndpointInfoReply(sysex, 2, 0x0FFFFEFF, 0x01234567, 0, 16, "FK-CEI1-00000042")`.
    static let amEndpointReplyID: [UInt8] = [
        0x7E, 0x7F, 0x0D, 0x73, 0x02, 0x7F, 0x7D, 0x7F, 0x7F, 0x67, 0x0A, 0x0D, 0x09, 0x00, 0x10, 0x00
    ] + productIDBytes
    /// AM: `sendEndpointInfoReply(sysex, 2, 0x01234567, 0x00000000, 0, 0, nullptr)`.
    static let amEndpointReplyEmpty: [UInt8] = [
        0x7E, 0x7F, 0x0D, 0x73, 0x02, 0x67, 0x0A, 0x0D, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ]
    /// AM: `sendEndpointInfoReply(sysex, 2, 0x01234567, 0x0FFFFEFF, 5, 130, data)` with `data[i] = i & 0x7F`: the
    /// length 130 is coded `02 01`, least significant first (byte-identical to AM's 146-byte output).
    static let amEndpointReply130 = prefix(0x7F, 0x73, 0x02) + sourceBytes + maximumBytes + [0x05, 0x02, 0x01]
        + endpointData(130)
    /// AM: `sendEndpointInfoRequest(sysex, 3, 0x01234567, 0x0FFFFEFF, 0)` (AM writes any version from 2 on).
    static let amEndpointInquiryV3: [UInt8] = [
        0x7E, 0x7F, 0x0D, 0x72, 0x03, 0x67, 0x0A, 0x0D, 0x09, 0x7F, 0x7D, 0x7F, 0x7F, 0x00
    ]
    static let endpointInquiry11 = replacing(amEndpointInquiry, at: 4, with: 0x01)
    static let endpointInquiryOther = prefix(0x10, 0x72, 0x02) + maximumBytes + zeroBytes + [0x7F]
    static let endpointReplyOther = prefix(0x00, 0x73, 0x02) + sourceBytes + maximumBytes
        + [0x01, 0x03, 0x00, 0x00, 0x7F, 0x41]
    static let endpointReplyMaximum = prefix(0x7E, 0x73, 0x02) + maximumBytes + sourceBytes + [0x00, 0x00, 0x02]
        + endpointData(256)
    static let endpointGoldens: [[UInt8]] = [
        amEndpointInquiry, amEndpointReplyID, amEndpointReplyEmpty, amEndpointReply130, endpointInquiryOther,
        endpointReplyOther, endpointReplyMaximum
    ]

    // MARK: Endpoint fixtures

    static func endpointData(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8($0 & 0x7F) }
    }

    static func endpointStatus(_ raw: UInt8) throws -> MIDICIEndpointStatus {
        try MIDICIEndpointStatus.make(raw)
    }

    static func information(_ status: UInt8, _ data: [UInt8]) throws -> MIDICIEndpointInformation {
        try MIDICIEndpointInformation.make(status: try endpointStatus(status), data: data)
    }

    static func endpointMessages() throws -> [MIDICIEndpointMessage] {
        let maximum: UInt32 = 0x0FFF_FEFF
        let source: UInt32 = 0x0123_4567
        return [
            .inquiry(try header(.ci12, device: 0x7F, destination: maximum), status: .productInstanceID),
            .reply(try header(.ci12, device: 0x7F, source: maximum, destination: source),
                   try information(0, productIDBytes)),
            .reply(try header(.ci12, device: 0x7F, destination: 0), try information(0, [])),
            .reply(try header(.ci12, device: 0x7F, destination: maximum), try information(5, endpointData(130))),
            .inquiry(try header(.ci12, source: maximum, destination: 0), status: try endpointStatus(0x7F)),
            .reply(try header(.ci12, device: 0x00, destination: maximum), try information(1, [0x00, 0x7F, 0x41])),
            .reply(try header(.ci12, device: 0x7E, source: maximum, destination: source),
                   try information(0, endpointData(256)))
        ]
    }

    static func endpointDecodeRefusal(_ payload: [UInt8], limits: MIDICILimits = .standard) -> MIDICIRefusal? {
        do {
            _ = try MIDICIEndpointMessage.decode(payload: payload, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func endpointEncodeRefusal(
        _ message: MIDICIEndpointMessage, limits: MIDICILimits = .standard
    ) -> MIDICIRefusal? {
        do {
            _ = try message.encode(limits: limits)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Goldens, decode and encode

    @Test func everyEndpointMessageEncodesToItsGoldenBytes() throws {
        let messages = try Self.endpointMessages()
        try #require(messages.count == Self.endpointGoldens.count)
        for (message, golden) in zip(messages, Self.endpointGoldens) {
            #expect(try message.encode(limits: .standard) == golden)
        }
        #expect(Self.endpointGoldens.map(\.count) == [14, 32, 16, 146, 14, 19, 272])
    }

    @Test func everyEndpointGoldenDecodesToItsExactTypedValue() throws {
        let messages = try Self.endpointMessages()
        try #require(messages.count == Self.endpointGoldens.count)
        for (golden, message) in zip(Self.endpointGoldens, messages) {
            #expect(try MIDICIEndpointMessage.decode(payload: golden, limits: .standard) == message)
        }
        #expect(messages.map(\.kind) == [.inquiry, .reply, .reply, .reply, .inquiry, .reply, .reply])
        #expect(messages.map(\.status.rawValue) == [0, 0, 0, 5, 0x7F, 1, 0])
        let reply = try MIDICIEndpointMessage.decode(payload: Self.amEndpointReplyID, limits: .standard)
        guard case let .reply(header, information) = reply else {
            Issue.record("expected a Reply to Endpoint Information")
            return
        }
        #expect(header.device.rawValue == 0x7F && header.format == .ci12)
        #expect(header.source.rawValue == 0x0FFF_FEFF && header.destination.rawValue == 0x0123_4567)
        #expect(information.status == .productInstanceID && information.data == Self.productIDBytes)
        #expect(information.productInstanceID == "FK-CEI1-00000042")
        let inquiry = try MIDICIEndpointMessage.decode(payload: Self.amEndpointInquiry, limits: .standard)
        #expect(inquiry == .inquiry(try Self.header(.ci12, device: 0x7F, destination: 0x0FFF_FEFF),
                                    status: .productInstanceID))
    }

    @Test func everyEndpointMessageSurvivesTheRoundTripAtEveryLengthEdge() throws {
        for golden in Self.endpointGoldens {
            let message = try MIDICIEndpointMessage.decode(payload: golden, limits: .standard)
            #expect(try message.encode(limits: .standard) == golden)
        }
        for count in [0, 1, 16, 17, 127, 128, 129, 255, 256] {
            let message = MIDICIEndpointMessage.reply(
                try Self.header(.ci12, destination: 0), try Self.information(0x22, Self.endpointData(count)))
            let bytes = try message.encode(limits: .standard)
            #expect(bytes.count == 16 + count)
            #expect(Array(bytes.dropFirst(13).prefix(3)) == [0x22, UInt8(count & 0x7F), UInt8(count >> 7)])
            #expect(try MIDICIEndpointMessage.decode(payload: bytes, limits: .standard) == message)
        }
        for status: UInt8 in [0x00, 0x01, 0x40, 0x7F] {
            let inquiry = MIDICIEndpointMessage.inquiry(
                try Self.header(.ci12, destination: 0), status: try Self.endpointStatus(status))
            let bytes = try inquiry.encode(limits: .standard)
            #expect(bytes.count == 14 && bytes.last == status)
            #expect(try MIDICIEndpointMessage.decode(payload: bytes, limits: .standard) == inquiry)
        }
    }

    // MARK: Sub-ids and format

    @Test func theOtherDecodersStillRefuseTheEndpointSubIDs() throws {
        for golden in Self.endpointGoldens {
            let sub = try #require(golden.dropFirst(3).first)
            #expect(Self.decodeRefusal(golden) == .unknownSubID(sub))
            #expect(Self.profileDecodeRefusal(golden) == .unknownSubID(sub))
            #expect(Self.propertyDecodeRefusal(golden) == .unknownSubID(sub))
        }
        let others: [UInt8] = [0x00, 0x20, 0x30, 0x31, 0x34, 0x70, 0x71, 0x74, 0x7D, 0x7E, 0x7F]
        for sub in others {
            let changed = Self.replacing(Self.amEndpointInquiry, at: 3, with: sub)
            #expect(Self.endpointDecodeRefusal(changed) == .unknownSubID(sub))
        }
        for golden in Self.goldens + Self.profileGoldens + Self.propertyGoldens {
            let sub = try #require(golden.dropFirst(3).first)
            #expect(Self.endpointDecodeRefusal(golden) == .unknownSubID(sub))
        }
    }

    @Test func endpointMessagesExistOnlyFromCI12On() throws {
        #expect(Self.endpointDecodeRefusal(Self.endpointInquiry11) == .unsupportedFormat(1))
        #expect(Self.endpointDecodeRefusal(Self.amEndpointInquiryV3) == .unsupportedFormat(3))
        for format: UInt8 in [0x00, 0x01, 0x03, 0x10, 0x7F] {
            for golden in [Self.amEndpointInquiry, Self.amEndpointReplyID, Self.amEndpointReplyEmpty] {
                #expect(Self.endpointDecodeRefusal(Self.replacing(golden, at: 4, with: format)) ==
                    .unsupportedFormat(format))
            }
        }
        #expect(Self.endpointDecodeRefusal(Array(Self.endpointInquiry11.prefix(5))) == .unsupportedFormat(1))
        let legacyInquiry = MIDICIEndpointMessage.inquiry(
            try Self.header(.ci11, destination: 0), status: .productInstanceID)
        #expect(Self.endpointEncodeRefusal(legacyInquiry) == .unsupportedFormat(1))
        let legacyReply = MIDICIEndpointMessage.reply(
            try Self.header(.ci11, source: 0x0FFF_FFFF), try Self.information(0, Self.productIDBytes))
        #expect(Self.endpointEncodeRefusal(legacyReply, limits: try Self.limits(payload: 1, text: 0)) ==
            .unsupportedFormat(1))
    }

    // MARK: Length

    @Test func everyPrefixOfAnEndpointMessageIsTruncated() throws {
        #expect(Self.endpointDecodeRefusal([]) == .truncated(need: 1, have: 0))
        for golden in Self.endpointGoldens {
            let isReply = golden.dropFirst(3).first == 0x73
            for length in 1..<golden.count {
                let need: Int
                switch length {
                case 1..<5: need = 5
                case 5..<13: need = 13
                case 13..<16 where isReply: need = 16
                default: need = golden.count
                }
                #expect(Self.endpointDecodeRefusal(Array(golden.prefix(length))) ==
                    .truncated(need: need, have: length))
            }
        }
    }

    @Test func theDeclaredInformationLengthMustMatchThePayloadAndTheBound() throws {
        #expect(Self.endpointDecodeRefusal(Self.replacing(Self.amEndpointReplyID, at: 14, with: 0x0F)) ==
            .trailingBytes(1))
        #expect(Self.endpointDecodeRefusal(Self.replacing(Self.amEndpointReplyID, at: 14, with: 0x11)) ==
            .truncated(need: 33, have: 32))
        #expect(Self.endpointDecodeRefusal(Self.replacing(Self.amEndpointReply130, at: 15, with: 0x00)) ==
            .trailingBytes(128))
        #expect(Self.endpointDecodeRefusal(Self.amEndpointReplyEmpty + [0x00]) == .trailingBytes(1))
        #expect(Self.endpointDecodeRefusal(Self.amEndpointInquiry + [0x00, 0x00]) == .trailingBytes(2))
        let limit = MIDICIEndpointMessage.maximumInformationBytes
        let over = Self.replacing(Self.amEndpointReplyEmpty, range: 14..<16, with: [0x01, 0x02])
        #expect(Self.endpointDecodeRefusal(over) == .informationTooLong(count: 257, limit: limit))
        let hostile = Self.replacing(Self.amEndpointReplyEmpty, range: 14..<16, with: [0x7F, 0x7F])
        #expect(Self.endpointDecodeRefusal(hostile) == .informationTooLong(count: 0x3FFF, limit: limit))
        let filled = hostile + [UInt8](repeating: 0x41, count: 4_080)
        #expect(Self.endpointDecodeRefusal(filled) == .informationTooLong(count: 0x3FFF, limit: limit))
        let overAndFull = Self.replacing(Self.endpointReplyMaximum, range: 14..<16, with: [0x01, 0x02]) + [0x00]
        #expect(Self.endpointDecodeRefusal(overAndFull) == .informationTooLong(count: 257, limit: limit))
        #expect(Self.endpointDecodeRefusal(Self.endpointReplyMaximum) == nil)
    }

    // MARK: Bytes, MUIDs, addressing and the device id

    @Test func aHighEndpointByteAnywhereIsRefusedAtItsOffset() throws {
        for golden in Self.endpointGoldens {
            for offset in 1..<golden.count {
                for value: UInt8 in [0x80, 0xFF] {
                    let high = Self.replacing(golden, at: offset, with: value)
                    #expect(Self.endpointDecodeRefusal(high) == (offset == 2 ? .notCI : .dataByteHigh(offset: offset)))
                }
            }
            #expect(Self.endpointDecodeRefusal(Self.replacing(golden, at: 0, with: 0x7F)) == .notCI)
        }
        let highAndShort = Self.replacing(Array(Self.amEndpointReplyID.prefix(20)), at: 19, with: 0xC1)
        #expect(Self.endpointDecodeRefusal(highAndShort) == .dataByteHigh(offset: 19))
    }

    @Test func endpointLengthBeatsMUIDsWhichBeatAddressing() throws {
        let reservedSource = Self.replacing(Self.amEndpointReplyID, range: 5..<9, with: Self.reservedBytes)
        #expect(Self.endpointDecodeRefusal(reservedSource) == .invalidMUID(0x0FFF_FF00))
        #expect(Self.endpointDecodeRefusal(Array(reservedSource.dropLast())) == .truncated(need: 32, have: 31))
        #expect(Self.endpointDecodeRefusal(reservedSource + [0x00]) == .trailingBytes(1))
        let reservedAndLong = Self.replacing(reservedSource, range: 14..<16, with: [0x7F, 0x7F])
        #expect(Self.endpointDecodeRefusal(reservedAndLong) == .informationTooLong(count: 0x3FFF, limit: 256))
        let legacyReserved = Self.replacing(Array(reservedSource.prefix(10)), at: 4, with: 0x01)
        #expect(Self.endpointDecodeRefusal(legacyReserved) == .unsupportedFormat(1))
        let reservedDestination = Self.replacing(Self.amEndpointInquiry, range: 9..<13, with: Self.reservedBytes)
        #expect(Self.endpointDecodeRefusal(reservedDestination) == .invalidMUID(0x0FFF_FF00))
        let bothReserved = Self.replacing(reservedSource, range: 9..<13, with: [0x01, 0x7E, 0x7F, 0x7F])
        #expect(Self.endpointDecodeRefusal(bothReserved) == .invalidMUID(0x0FFF_FF00))
        let broadcastSource = Self.replacing(Self.amEndpointInquiry, range: 5..<9, with: Self.broadcastBytes)
        #expect(Self.endpointDecodeRefusal(broadcastSource) == .sourceIsBroadcast)
        let broadcastToReserved = Self.replacing(broadcastSource, range: 9..<13, with: Self.reservedBytes)
        #expect(Self.endpointDecodeRefusal(broadcastToReserved) == .invalidMUID(0x0FFF_FF00))
        let broadcastBoth = Self.replacing(broadcastSource, range: 9..<13, with: Self.broadcastBytes)
        #expect(Self.endpointDecodeRefusal(broadcastBoth) == .sourceIsBroadcast)
        for golden in [Self.amEndpointInquiry, Self.amEndpointReplyID, Self.amEndpointReplyEmpty] {
            let toBroadcast = Self.replacing(golden, range: 9..<13, with: Self.broadcastBytes)
            #expect(Self.endpointDecodeRefusal(toBroadcast) == .destinationIsBroadcast)
            #expect(Self.endpointDecodeRefusal(Array(toBroadcast.dropLast())) != .destinationIsBroadcast)
            for destination in [Self.zeroBytes, Self.maximumBytes, Self.sourceBytes] {
                #expect(Self.endpointDecodeRefusal(Self.replacing(golden, range: 9..<13, with: destination)) == nil)
            }
        }
        for device: UInt8 in [0x00, 0x0F, 0x10, 0x7E, 0x7F] {
            let decoded = try MIDICIEndpointMessage.decode(
                payload: Self.replacing(Self.amEndpointReplyEmpty, at: 1, with: device), limits: .standard)
            #expect(decoded.header.device.rawValue == device)
        }
    }

    @Test func thePayloadLimitIsCheckedBeforeEveryEndpointRule() throws {
        let limit13 = try Self.limits(payload: 13, text: 0)
        #expect(Self.endpointDecodeRefusal(Self.amEndpointInquiry, limits: limit13) == .payloadTooLarge(14))
        let limit31 = try Self.limits(payload: 31, text: 0)
        #expect(Self.endpointDecodeRefusal(Self.amEndpointReplyID, limits: limit31) == .payloadTooLarge(32))
        let limit32 = try Self.limits(payload: 32, text: 0)
        #expect(Self.endpointDecodeRefusal(Self.amEndpointReplyID, limits: limit32) == nil)
        let hostile = [UInt8](repeating: 0xFF, count: 4_097)
        #expect(Self.endpointDecodeRefusal(hostile) == .payloadTooLarge(4_097))
    }

    @Test func seededMutationsOfTheEndpointGoldensDecodeOnlyToCanonicalBytes() throws {
        var random = Xorshift(seed: 0x4345_4931)
        for golden in Self.endpointGoldens {
            for _ in 0..<400 {
                var bytes = golden
                let offset = Int(random.next() % UInt64(bytes.count))
                bytes[offset] = UInt8(truncatingIfNeeded: random.next())
                if random.next() % 4 == 0 { bytes.removeLast() }
                guard let message = try? MIDICIEndpointMessage.decode(payload: bytes, limits: .standard)
                else { continue }
                #expect(try message.encode(limits: .standard) == bytes)
            }
        }
    }

    // MARK: Factories, the Product Instance ID view and encode refusals

    @Test func theEndpointFactoriesRefuseEightBitsAndOverlongData() throws {
        #expect(throws: MIDICIRefusal.fieldOutOfRange(.endpointStatus, value: 0x80)) {
            try MIDICIEndpointStatus.make(0x80)
        }
        let status = MIDICIEndpointStatus.productInstanceID
        #expect(throws: MIDICIRefusal.fieldOutOfRange(.endpointInformation, value: 0x80)) {
            try MIDICIEndpointInformation.make(status: status, data: [0x41, 0x80, 0xFF])
        }
        #expect(throws: MIDICIRefusal.informationTooLong(count: 257, limit: 256)) {
            try MIDICIEndpointInformation.make(status: status, data: [UInt8](repeating: 0xFF, count: 257))
        }
        let edge = try Self.information(0x7F, [UInt8](repeating: 0x7F, count: 256))
        #expect(edge.status.rawValue == 0x7F && edge.data.count == 256)
    }

    @Test func theProductInstanceIDIsReadOnlyForStatusZeroAndPrintableASCII() throws {
        #expect(try Self.information(0, Self.productIDBytes).productInstanceID == "FK-CEI1-00000042")
        #expect(try Self.information(0, [0x20, 0x7E]).productInstanceID == " ~")
        #expect(try Self.information(0, []).productInstanceID == nil)
        #expect(try Self.information(1, Self.productIDBytes).productInstanceID == nil)
        #expect(try Self.information(0, Self.productIDBytes + [0x41]).productInstanceID == nil)
        for byte: UInt8 in [0x00, 0x1F, 0x7F] {
            #expect(try Self.information(0, [0x41, byte]).productInstanceID == nil)
        }
        let decoded = try MIDICIEndpointMessage.decode(payload: Self.endpointReplyMaximum, limits: .standard)
        guard case let .reply(_, information) = decoded else {
            Issue.record("expected a Reply to Endpoint Information")
            return
        }
        #expect(information.data.count == 256 && information.productInstanceID == nil)
    }

    @Test func endpointEncodeChecksTheFormatThenTheAddressingThenTheSize() throws {
        let information = try Self.information(0, Self.productIDBytes)
        let broadcastSource = MIDICIEndpointMessage.reply(
            try Self.header(.ci12, source: 0x0FFF_FFFF, destination: 0x0FFF_FFFF), information)
        #expect(Self.endpointEncodeRefusal(broadcastSource) == .sourceIsBroadcast)
        let toBroadcast = MIDICIEndpointMessage.reply(try Self.header(.ci12), information)
        #expect(Self.endpointEncodeRefusal(toBroadcast, limits: try Self.limits(payload: 1, text: 0)) ==
            .destinationIsBroadcast)
        let inquiryToBroadcast = MIDICIEndpointMessage.inquiry(try Self.header(.ci12), status: .productInstanceID)
        #expect(Self.endpointEncodeRefusal(inquiryToBroadcast) == .destinationIsBroadcast)
        let reply = MIDICIEndpointMessage.reply(try Self.header(.ci12, destination: 0), information)
        #expect(Self.endpointEncodeRefusal(reply, limits: try Self.limits(payload: 31, text: 0)) ==
            .payloadTooLarge(32))
        #expect(Self.endpointEncodeRefusal(reply, limits: try Self.limits(payload: 32, text: 0)) == nil)
        let inquiry = MIDICIEndpointMessage.inquiry(try Self.header(.ci12, destination: 0), status: .productInstanceID)
        #expect(Self.endpointEncodeRefusal(inquiry, limits: try Self.limits(payload: 13, text: 0)) ==
            .payloadTooLarge(14))
        #expect(Self.endpointEncodeRefusal(inquiry, limits: try Self.limits(payload: 14, text: 0)) == nil)
    }
}
