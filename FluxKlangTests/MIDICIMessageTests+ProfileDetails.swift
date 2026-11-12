//
//  MIDICIMessageTests+ProfileDetails.swift
//  FluxKlangTests
//
//  Profile Details Inquiry (0x28), Reply to Profile Details Inquiry (0x29) and Profile Specific Data (0x2F): hand
//  written goldens, round trips and the length fields, including the least-significant-byte-first split of each byte
//  of the 14-bit and 28-bit lengths (#83, slice CIP4). Refusals, the format and addressing rules, the encode rules,
//  the neighbouring sub-ids and hostile input are in `MIDICIMessageTests+ProfileDetailsRules.swift`.
//
//  Provenance: every vector is written by hand from M2-101-UM v1.2, Tables 22, 23 and 28; none comes from another
//  project or from the encoder.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    /// Five distinct 7-bit bytes.
    static let detailsProfileBytes: [UInt8] = [0x21, 0x32, 0x43, 0x54, 0x65]

    /// Table 22: device 0x7F, CI 1.2, profile id, registered target 0x01. 19 bytes.
    static let detailsInquiryGolden: [UInt8] = prefix(0x7F, 0x28, 0x02) + sourceBytes + maximumBytes
        + detailsProfileBytes + [0x01]
    /// Table 23: profile specific target 0x41, dl = 3, then three data bytes. 24 bytes.
    static let detailsReplyGolden: [UInt8] = prefix(0x10, 0x29, 0x02) + sourceBytes + maximumBytes
        + detailsProfileBytes + [0x41, 0x03, 0x00, 0x05, 0x06, 0x07]
    /// Table 23 with dl = 0 and the two MUIDs swapped. 21 bytes.
    static let detailsEmptyReplyGolden: [UInt8] = prefix(0x00, 0x29, 0x02) + maximumBytes + sourceBytes
        + detailsProfileBytes + [0x01, 0x00, 0x00]
    /// Table 28 in CI 1.2: n = 4, then four data bytes. 26 bytes.
    static let specificDataGolden12: [UInt8] = prefix(0x10, 0x2F, 0x02) + sourceBytes + maximumBytes
        + detailsProfileBytes + [0x04, 0x00, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44]
    /// Table 28 in CI 1.1, to the Broadcast MUID: n = 2, then two data bytes. 24 bytes.
    static let specificDataGolden11: [UInt8] = prefix(0x00, 0x2F, 0x01) + sourceBytes + broadcastBytes
        + detailsProfileBytes + [0x02, 0x00, 0x00, 0x00, 0x10, 0x20]
    static let detailsGoldens: [[UInt8]] = [
        detailsInquiryGolden, detailsReplyGolden, detailsEmptyReplyGolden, specificDataGolden12, specificDataGolden11
    ]

    static func detailsMessages() throws -> [MIDICIProfileDetailsMessage] {
        let maximum: UInt32 = 0x0FFF_FEFF
        let id = try profile(detailsProfileBytes)
        return [
            .detailsInquiry(try header(.ci12, device: 0x7F, destination: maximum), profile: id, target: 0x01),
            .detailsReply(
                try header(.ci12, device: 0x10, destination: maximum), profile: id, target: 0x41,
                data: [0x05, 0x06, 0x07]),
            .detailsReply(
                try header(.ci12, device: 0x00, source: maximum, destination: 0x0123_4567), profile: id, target: 0x01,
                data: []),
            .specificData(
                try header(.ci12, device: 0x10, destination: maximum), profile: id, data: [0x11, 0x22, 0x33, 0x44]),
            .specificData(try header(.ci11, device: 0x00), profile: id, data: [0x10, 0x20])
        ]
    }

    static func detailsDecodeRefusal(_ payload: [UInt8], limits: MIDICILimits = .standard) -> MIDICIRefusal? {
        do {
            _ = try MIDICIProfileDetailsMessage.decode(payload: payload, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func detailsEncodeRefusal(
        _ message: MIDICIProfileDetailsMessage, limits: MIDICILimits = .standard
    ) -> MIDICIRefusal? {
        do {
            _ = try message.encode(limits: limits)
            return nil
        } catch {
            return error
        }
    }

    /// A Reply payload (CI 1.2, device 0x10) built from raw length bytes, so a test can declare any length.
    static func detailsReplyPayload(lengthBytes: [UInt8], data: [UInt8], target: UInt8 = 0x41) -> [UInt8] {
        prefix(0x10, 0x29, 0x02) + sourceBytes + maximumBytes + detailsProfileBytes + [target] + lengthBytes + data
    }

    /// A Profile Specific Data payload (device 0x10) built from raw length bytes.
    static func detailsSpecificPayload(lengthBytes: [UInt8], data: [UInt8], format: UInt8 = 0x02) -> [UInt8] {
        prefix(0x10, 0x2F, format) + sourceBytes + maximumBytes + detailsProfileBytes + lengthBytes + data
    }

    static func detailsReplyMessage(data: [UInt8]) throws -> MIDICIProfileDetailsMessage {
        .detailsReply(
            try header(.ci12, device: 0x10, destination: 0x0FFF_FEFF), profile: try profile(detailsProfileBytes),
            target: 0x41, data: data)
    }

    static func detailsSpecificMessage(data: [UInt8]) throws -> MIDICIProfileDetailsMessage {
        .specificData(
            try header(.ci12, device: 0x10, destination: 0x0FFF_FEFF), profile: try profile(detailsProfileBytes),
            data: data)
    }

    // MARK: Goldens

    @Test func everyProfileDetailsMessageEncodesToItsHandWrittenGoldenBytes() throws {
        let messages = try Self.detailsMessages()
        try #require(messages.count == Self.detailsGoldens.count)
        for (message, golden) in zip(messages, Self.detailsGoldens) {
            #expect(try message.encode(limits: .standard) == golden)
        }
    }

    @Test func everyProfileDetailsGoldenDecodesToItsExactTypedValue() throws {
        let messages = try Self.detailsMessages()
        try #require(messages.count == Self.detailsGoldens.count)
        for (message, golden) in zip(messages, Self.detailsGoldens) {
            #expect(try MIDICIProfileDetailsMessage.decode(payload: golden, limits: .standard) == message)
        }
    }

    @Test func theGoldensHaveTheLengthsOfTheTables() {
        #expect(Self.detailsInquiryGolden.count == 19)
        #expect(Self.detailsReplyGolden.count == 21 + 3)
        #expect(Self.detailsEmptyReplyGolden.count == 21)
        #expect(Self.specificDataGolden12.count == 22 + 4)
        #expect(Self.specificDataGolden11.count == 22 + 2)
        #expect(MIDICIProfileDetailsMessage.inquiryBytes == 19)
        #expect(MIDICIProfileDetailsMessage.replyFixedBytes == 21)
        #expect(MIDICIProfileDetailsMessage.specificDataFixedBytes == 22)
    }

    @Test func theKindAndHeaderOfEachMessageAreTheOnesInItsBytes() throws {
        let messages = try Self.detailsMessages()
        let kinds: [MIDICIProfileDetailsKind] = [
            .detailsInquiry, .detailsReply, .detailsReply, .specificData, .specificData
        ]
        try #require(messages.count == kinds.count)
        for (message, kind) in zip(messages, kinds) { #expect(message.kind == kind) }
        #expect(MIDICIProfileDetailsKind.detailsInquiry.rawValue == 0x28)
        #expect(MIDICIProfileDetailsKind.detailsReply.rawValue == 0x29)
        #expect(MIDICIProfileDetailsKind.specificData.rawValue == 0x2F)
        #expect(messages[4].header.format == .ci11 && messages[4].header.destination.isBroadcast)
    }

    @Test func everyGoldenRoundTripsThroughEncodeAndDecode() throws {
        for message in try Self.detailsMessages() {
            let bytes = try message.encode(limits: .standard)
            #expect(try MIDICIProfileDetailsMessage.decode(payload: bytes, limits: .standard) == message)
        }
    }

    // MARK: Lengths

    @Test func replyAndSpecificDataRoundTripWithZeroOneAndSeveralHundredBytesOfData() throws {
        let wide = (0..<300).map { UInt8($0 % 0x80) }
        for data in [[], [0x2A], wide] as [[UInt8]] {
            let reply = try Self.detailsReplyMessage(data: data)
            let replyBytes = try reply.encode(limits: .standard)
            #expect(replyBytes.count == 21 + data.count)
            #expect(try MIDICIProfileDetailsMessage.decode(payload: replyBytes, limits: .standard) == reply)
            let specific = try Self.detailsSpecificMessage(data: data)
            let specificBytes = try specific.encode(limits: .standard)
            #expect(specificBytes.count == 22 + data.count)
            #expect(try MIDICIProfileDetailsMessage.decode(payload: specificBytes, limits: .standard) == specific)
        }
    }

    @Test func theLengthFieldsAreWrittenLeastSignificantByteFirst() throws {
        let data129 = [UInt8](repeating: 0x33, count: 129)
        let reply = Self.detailsReplyPayload(lengthBytes: [0x01, 0x01], data: data129)
        #expect(try Self.detailsReplyMessage(data: data129).encode(limits: .standard) == reply)
        #expect(try Self.detailsReplyMessage(data: data129) ==
            MIDICIProfileDetailsMessage.decode(payload: reply, limits: .standard))
        let specific = Self.detailsSpecificPayload(lengthBytes: [0x01, 0x01, 0x00, 0x00], data: data129)
        #expect(try Self.detailsSpecificMessage(data: data129).encode(limits: .standard) == specific)
        #expect(try Self.detailsSpecificMessage(data: data129) ==
            MIDICIProfileDetailsMessage.decode(payload: specific, limits: .standard))
        let data300 = [UInt8](repeating: 0x44, count: 300)
        let reply300 = Self.detailsReplyPayload(lengthBytes: [0x2C, 0x02], data: data300)
        #expect(try Self.detailsReplyMessage(data: data300).encode(limits: .standard) == reply300)
        let specific300 = Self.detailsSpecificPayload(lengthBytes: [0x2C, 0x02, 0x00, 0x00], data: data300)
        #expect(try Self.detailsSpecificMessage(data: data300).encode(limits: .standard) == specific300)
    }

    @Test func eachByteOfTheReplyLengthCarriesItsOwnWeightOnDecode() {
        #expect(Self.detailsDecodeRefusal(Self.detailsReplyPayload(lengthBytes: [0x01, 0x00], data: [])) ==
            .truncated(need: 21 + 1, have: 21))
        #expect(Self.detailsDecodeRefusal(Self.detailsReplyPayload(lengthBytes: [0x00, 0x01], data: [])) ==
            .truncated(need: 21 + 128, have: 21))
        #expect(Self.detailsDecodeRefusal(Self.detailsReplyPayload(lengthBytes: [0x01, 0x01], data: [])) ==
            .truncated(need: 21 + 129, have: 21))
        #expect(Self.detailsDecodeRefusal(Self.detailsReplyPayload(lengthBytes: [0x7F, 0x7F], data: [])) ==
            .truncated(need: 21 + 0x3FFF, have: 21))
    }

    @Test func eachOfTheFourBytesOfTheSpecificDataLengthCarriesItsOwnWeightOnDecode() {
        let weights: [([UInt8], Int)] = [
            ([0x01, 0x00, 0x00, 0x00], 1),
            ([0x00, 0x01, 0x00, 0x00], 128),
            ([0x00, 0x00, 0x01, 0x00], 16_384),
            ([0x00, 0x00, 0x00, 0x01], 2_097_152),
            ([0x01, 0x01, 0x01, 0x00], 16_513),
            ([0x7F, 0x7F, 0x7F, 0x7F], 0x0FFF_FFFF)
        ]
        for (bytes, length) in weights {
            let payload = Self.detailsSpecificPayload(lengthBytes: bytes, data: [])
            #expect(Self.detailsDecodeRefusal(payload) == .truncated(need: 22 + length, have: 22))
        }
    }

    @Test func aDeclaredLengthAboveOrBelowTheBytesPresentIsTruncatedOrTrailing() {
        let data = [UInt8](repeating: 0x01, count: 5)
        #expect(Self.detailsDecodeRefusal(Self.detailsReplyPayload(lengthBytes: [0x06, 0x00], data: data)) ==
            .truncated(need: 21 + 6, have: 21 + 5))
        #expect(Self.detailsDecodeRefusal(Self.detailsReplyPayload(lengthBytes: [0x04, 0x00], data: data)) ==
            .trailingBytes(1))
        #expect(Self.detailsDecodeRefusal(Self.detailsSpecificPayload(lengthBytes: [0x06, 0, 0, 0], data: data)) ==
            .truncated(need: 22 + 6, have: 22 + 5))
        #expect(Self.detailsDecodeRefusal(Self.detailsSpecificPayload(lengthBytes: [0x04, 0, 0, 0], data: data)) ==
            .trailingBytes(1))
    }

    @Test func forEveryProfileDetailsKindOneByteTooFewIsTruncatedAtTheExactLengthAndOneTooManyIsTrailing() {
        for golden in Self.detailsGoldens {
            #expect(Self.detailsDecodeRefusal(golden) == nil)
            #expect(Self.detailsDecodeRefusal(Array(golden.dropLast())) ==
                .truncated(need: golden.count, have: golden.count - 1))
            #expect(Self.detailsDecodeRefusal(golden + [0x00]) == .trailingBytes(1))
            #expect(Self.detailsDecodeRefusal(golden + [0x7F, 0x7F, 0x7F]) == .trailingBytes(3))
        }
    }

    @Test func theInquiryIsExactlyNineteenBytes() {
        let golden = Self.detailsInquiryGolden
        #expect(Self.detailsDecodeRefusal(Array(golden.dropLast())) == .truncated(need: 19, have: 18))
        #expect(Self.detailsDecodeRefusal(Array(golden.prefix(13))) == .truncated(need: 19, have: 13))
        #expect(Self.detailsDecodeRefusal(Array(golden.prefix(12))) == .truncated(need: 13, have: 12))
        #expect(Self.detailsDecodeRefusal(golden + [0x00]) == .trailingBytes(1))
    }

    @Test func everyPrefixOfAProfileDetailsGoldenIsTruncatedAtTheNeededLength() {
        for golden in Self.detailsGoldens {
            let subID = golden.dropFirst(3).first
            let fixed = subID == 0x28 ? 19 : (subID == 0x29 ? 21 : 22)
            for length in 1..<5 {
                #expect(Self.detailsDecodeRefusal(Array(golden.prefix(length))) ==
                    .truncated(need: 5, have: length))
            }
            for length in 5..<golden.count {
                let expected: Int
                switch length {
                case 5..<13: expected = 13
                case 13..<fixed: expected = fixed
                default: expected = golden.count
                }
                #expect(Self.detailsDecodeRefusal(Array(golden.prefix(length))) ==
                    .truncated(need: expected, have: length))
            }
        }
        #expect(Self.detailsDecodeRefusal([]) == .truncated(need: 1, have: 0))
    }
}
