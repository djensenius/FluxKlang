//
//  MIDICIMessageTests+ProfileDetailsRules.swift
//  FluxKlangTests
//
//  Profile Details Inquiry (0x28), Reply (0x29) and Profile Specific Data (0x2F): the format and addressing rules,
//  values kept as received, the strict encode rules and their order, bytes of 0x80 or more, the neighbouring sub-ids
//  and decoders, and seeded hostile input (#83, slice CIP4). The goldens and the typed fixtures are in
//  `MIDICIMessageTests+ProfileDetails.swift`.
//
//  Provenance: every vector is written by hand from M2-101-UM v1.2, Tables 22, 23 and 28 and section 3.3.3; none
//  comes from another project or from the encoder.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    static let detailsSubIDs: [UInt8] = [0x28, 0x29, 0x2F]

    // MARK: Format

    @Test func theInquiryAndTheReplyAreCI12OnlyAndSpecificDataAcceptsBothFormats() throws {
        for golden in [Self.detailsInquiryGolden, Self.detailsReplyGolden] {
            #expect(Self.detailsDecodeRefusal(Self.replacing(golden, at: 4, with: 0x01)) == .unsupportedFormat(1))
        }
        for format: UInt8 in [0x01, 0x02] {
            let payload = Self.replacing(Self.specificDataGolden12, at: 4, with: format)
            let message = try MIDICIProfileDetailsMessage.decode(payload: payload, limits: .standard)
            #expect(message.header.format == (format == 1 ? .ci11 : .ci12))
            #expect(try message.encode(limits: .standard) == payload)
        }
        let id = try Self.profile(Self.detailsProfileBytes)
        let ci11 = try Self.header(.ci11, device: 0x10, destination: 0x0FFF_FEFF)
        #expect(Self.detailsEncodeRefusal(.detailsInquiry(ci11, profile: id, target: 0x01)) == .unsupportedFormat(1))
        #expect(Self.detailsEncodeRefusal(.detailsReply(ci11, profile: id, target: 0x01, data: [])) ==
            .unsupportedFormat(1))
        #expect(Self.detailsEncodeRefusal(.specificData(ci11, profile: id, data: [])) == nil)
    }

    @Test func formatsZeroAndThreeAndAboveAreUnsupportedForAllThreeKinds() {
        for golden in [Self.detailsInquiryGolden, Self.detailsReplyGolden, Self.specificDataGolden12] {
            for format: UInt8 in [0x00, 0x03, 0x04, 0x7F] {
                #expect(Self.detailsDecodeRefusal(Self.replacing(golden, at: 4, with: format)) ==
                    .unsupportedFormat(format))
            }
        }
    }

    @Test func theFormatIsCheckedBeforeTheLengthAndAfterTheSubID() {
        #expect(Self.detailsDecodeRefusal(Self.prefix(0x7F, 0x28, 0x01)) == .unsupportedFormat(1))
        #expect(Self.detailsDecodeRefusal(Self.prefix(0x7F, 0x29, 0x01) + [0x00]) == .unsupportedFormat(1))
        #expect(Self.detailsDecodeRefusal(Self.prefix(0x7F, 0x2F, 0x03)) == .unsupportedFormat(3))
        #expect(Self.detailsDecodeRefusal(Self.prefix(0x7F, 0x2A, 0x03)) == .unknownSubID(0x2A))
        #expect(Self.detailsDecodeRefusal(Self.prefix(0x7F, 0x28, 0x02)) == .truncated(need: 13, have: 5))
        #expect(Self.detailsDecodeRefusal(Self.prefix(0x7F, 0x2F, 0x01)) == .truncated(need: 13, have: 5))
    }

    // MARK: Addressing

    @Test func aBroadcastSourceIsRefusedForEveryKindOnDecodeAndEncode() throws {
        for golden in Self.detailsGoldens {
            let payload = Self.replacing(golden, range: 5..<9, with: Self.broadcastBytes)
            #expect(Self.detailsDecodeRefusal(payload) == .sourceIsBroadcast)
        }
        let id = try Self.profile(Self.detailsProfileBytes)
        let header = try Self.header(.ci12, source: 0x0FFF_FFFF, destination: 0x0FFF_FEFF)
        #expect(Self.detailsEncodeRefusal(.detailsInquiry(header, profile: id, target: 0x01)) == .sourceIsBroadcast)
        #expect(Self.detailsEncodeRefusal(.detailsReply(header, profile: id, target: 0x01, data: [])) ==
            .sourceIsBroadcast)
        #expect(Self.detailsEncodeRefusal(.specificData(header, profile: id, data: [])) == .sourceIsBroadcast)
    }

    @Test func aBroadcastDestinationIsRefusedForTheInquiryAndTheReplyAndAcceptedForSpecificData() throws {
        for golden in [Self.detailsInquiryGolden, Self.detailsReplyGolden, Self.detailsEmptyReplyGolden] {
            let payload = Self.replacing(golden, range: 9..<13, with: Self.broadcastBytes)
            #expect(Self.detailsDecodeRefusal(payload) == .destinationIsBroadcast)
        }
        let id = try Self.profile(Self.detailsProfileBytes)
        let toAll = try Self.header(.ci12, destination: 0x0FFF_FFFF)
        #expect(Self.detailsEncodeRefusal(.detailsInquiry(toAll, profile: id, target: 0x01)) ==
            .destinationIsBroadcast)
        #expect(Self.detailsEncodeRefusal(.detailsReply(toAll, profile: id, target: 0x01, data: [])) ==
            .destinationIsBroadcast)
        let specific = MIDICIProfileDetailsMessage.specificData(toAll, profile: id, data: [0x01, 0x02])
        let bytes = try specific.encode(limits: .standard)
        #expect(Array(bytes.dropFirst(9).prefix(4)) == Self.broadcastBytes)
        #expect(try MIDICIProfileDetailsMessage.decode(payload: bytes, limits: .standard) == specific)
        #expect(MIDICIProfileDetailsKind.detailsInquiry.destinationRule == .oneMUID)
        #expect(MIDICIProfileDetailsKind.detailsReply.destinationRule == .oneMUID)
        #expect(MIDICIProfileDetailsKind.specificData.destinationRule == .either)
    }

    @Test func anUnassignableMUIDIsRefusedForEveryKindSourceFirst() {
        for golden in Self.detailsGoldens {
            let source = Self.replacing(golden, range: 5..<9, with: Self.reservedBytes)
            #expect(Self.detailsDecodeRefusal(source) == .invalidMUID(0x0FFF_FF00))
            let destination = Self.replacing(golden, range: 9..<13, with: [0x01, 0x7F, 0x7F, 0x7F])
            #expect(Self.detailsDecodeRefusal(destination) == .invalidMUID(0x0FFF_FF81))
            let both = Self.replacing(source, range: 9..<13, with: [0x01, 0x7F, 0x7F, 0x7F])
            #expect(Self.detailsDecodeRefusal(both) == .invalidMUID(0x0FFF_FF00))
        }
    }

    @Test func theDecodeOrderRunsLengthThenMUIDsThenAddressing() {
        let golden = Self.detailsInquiryGolden
        let broadcasts = Self.replacing(golden, range: 5..<13, with: Self.broadcastBytes + Self.broadcastBytes)
        #expect(Self.detailsDecodeRefusal(broadcasts) == .sourceIsBroadcast)
        let invalidAndBroadcast = Self.replacing(golden, range: 5..<13, with: Self.broadcastBytes + Self.reservedBytes)
        #expect(Self.detailsDecodeRefusal(invalidAndBroadcast) == .invalidMUID(0x0FFF_FF00))
        #expect(Self.detailsDecodeRefusal(invalidAndBroadcast + [0x00]) == .trailingBytes(1))
        #expect(Self.detailsDecodeRefusal(Self.replacing(broadcasts, at: 4, with: 0x01)) == .unsupportedFormat(1))
    }

    // MARK: Kept as received

    @Test func everyInquiryTargetAndEveryDeviceIDIsKeptAsReceived() throws {
        for target in UInt8(0)...0x7F {
            for golden in [Self.detailsInquiryGolden, Self.detailsReplyGolden] {
                let payload = Self.replacing(golden, at: 18, with: target)
                let message = try MIDICIProfileDetailsMessage.decode(payload: payload, limits: .standard)
                switch message {
                case let .detailsInquiry(_, _, kept), let .detailsReply(_, _, kept, _): #expect(kept == target)
                case .specificData: Issue.record("unexpected kind")
                }
                #expect(try message.encode(limits: .standard) == payload)
            }
        }
        for device in UInt8(0)...0x7F {
            for golden in Self.detailsGoldens {
                let payload = Self.replacing(golden, at: 1, with: device)
                let message = try MIDICIProfileDetailsMessage.decode(payload: payload, limits: .standard)
                #expect(message.header.device.rawValue == device)
                #expect(try message.encode(limits: .standard) == payload)
            }
        }
    }

    @Test func theProfileIdTheTargetAndTheDataAreReadAtTheirOwnOffsets() throws {
        let message = try MIDICIProfileDetailsMessage.decode(payload: Self.detailsReplyGolden, limits: .standard)
        guard case let .detailsReply(_, id, target, data) = message else {
            Issue.record("expected a reply")
            return
        }
        #expect(id.bytes == Self.detailsProfileBytes && target == 0x41 && data == [0x05, 0x06, 0x07])
        let specific = try MIDICIProfileDetailsMessage.decode(payload: Self.specificDataGolden12, limits: .standard)
        guard case let .specificData(_, specificID, specificData) = specific else {
            Issue.record("expected profile specific data")
            return
        }
        #expect(specificID.bytes == Self.detailsProfileBytes && specificData == [0x11, 0x22, 0x33, 0x44])
    }

    // MARK: Encode rules

    @Test func aTargetOrADataByteOfEightyHexOrMoreIsRefusedOnEncode() throws {
        let id = try Self.profile(Self.detailsProfileBytes)
        let header = try Self.header(.ci12, destination: 0x0FFF_FEFF)
        #expect(Self.detailsEncodeRefusal(.detailsInquiry(header, profile: id, target: 0x80)) ==
            .fieldOutOfRange(.inquiryTarget, value: 0x80))
        #expect(Self.detailsEncodeRefusal(.detailsReply(header, profile: id, target: 0xFF, data: [])) ==
            .fieldOutOfRange(.inquiryTarget, value: 0xFF))
        #expect(Self.detailsEncodeRefusal(.detailsReply(header, profile: id, target: 0x7F, data: [0x00, 0x80])) ==
            .fieldOutOfRange(.inquiryTargetData, value: 0x80))
        #expect(Self.detailsEncodeRefusal(.specificData(header, profile: id, data: [0x7F, 0xC3, 0x90])) ==
            .fieldOutOfRange(.profileSpecificData, value: 0xC3))
        #expect(Self.detailsEncodeRefusal(.detailsInquiry(header, profile: id, target: 0x7F)) == nil)
        #expect(Self.detailsEncodeRefusal(.detailsReply(header, profile: id, target: 0x7F, data: [0x7F])) == nil)
    }

    @Test func aReplyWithMoreThan0x3FFFDataBytesIsRefusedBeforeThePayloadSize() throws {
        let tooMany = try Self.detailsReplyMessage(data: [UInt8](repeating: 0x01, count: 0x4000))
        #expect(Self.detailsEncodeRefusal(tooMany) == .fieldOutOfRange(.inquiryTargetDataLength, value: 0x4000))
        let widest = try Self.detailsReplyMessage(data: [UInt8](repeating: 0x01, count: 0x3FFF))
        #expect(Self.detailsEncodeRefusal(widest) == .payloadTooLarge(21 + 0x3FFF))
    }

    @Test func thePayloadLimitIsExactOnEncodeAndDecode() throws {
        let reply = try Self.detailsReplyMessage(data: [UInt8](repeating: 0x01, count: 4_075))
        #expect(try reply.encode(limits: .standard).count == 4_096)
        let over = try Self.detailsReplyMessage(data: [UInt8](repeating: 0x01, count: 4_076))
        #expect(Self.detailsEncodeRefusal(over) == .payloadTooLarge(4_097))
        let specific = try Self.detailsSpecificMessage(data: [UInt8](repeating: 0x01, count: 4_074))
        #expect(try specific.encode(limits: .standard).count == 4_096)
        let specificOver = try Self.detailsSpecificMessage(data: [UInt8](repeating: 0x01, count: 4_075))
        #expect(Self.detailsEncodeRefusal(specificOver) == .payloadTooLarge(4_097))
        let small = try Self.limits(payload: 24, text: 0)
        let messages = try Self.detailsMessages()
        try #require(messages.count == 5)
        #expect(Self.detailsEncodeRefusal(messages[0], limits: small) == nil)
        #expect(Self.detailsEncodeRefusal(messages[1], limits: small) == nil)
        #expect(Self.detailsEncodeRefusal(messages[3], limits: small) == .payloadTooLarge(26))
        #expect(Self.detailsDecodeRefusal(Self.specificDataGolden12, limits: small) == .payloadTooLarge(26))
        #expect(Self.detailsDecodeRefusal(Self.detailsReplyGolden, limits: small) == nil)
        let tiny = try Self.limits(payload: 18, text: 0)
        #expect(Self.detailsDecodeRefusal(Self.detailsInquiryGolden, limits: tiny) == .payloadTooLarge(19))
        #expect(Self.detailsEncodeRefusal(messages[0], limits: tiny) == .payloadTooLarge(19))
    }

    @Test func theEncodeRefusalOrderIsFormatSourceDestinationTargetDataLengthThenSize() throws {
        let id = try Self.profile(Self.detailsProfileBytes)
        let long = [UInt8](repeating: 0x01, count: 0x4000)
        let broadcast: UInt32 = 0x0FFF_FFFF
        let small = try Self.limits(payload: 20, text: 0)
        let ci11 = try Self.header(.ci11, source: broadcast, destination: broadcast)
        #expect(Self.detailsEncodeRefusal(.detailsReply(ci11, profile: id, target: 0x80, data: long)) ==
            .unsupportedFormat(1))
        let bothBroadcast = try Self.header(.ci12, source: broadcast, destination: broadcast)
        #expect(Self.detailsEncodeRefusal(.detailsReply(bothBroadcast, profile: id, target: 0x80, data: long)) ==
            .sourceIsBroadcast)
        let toBroadcast = try Self.header(.ci12, destination: broadcast)
        #expect(Self.detailsEncodeRefusal(.detailsReply(toBroadcast, profile: id, target: 0x80, data: long)) ==
            .destinationIsBroadcast)
        let header = try Self.header(.ci12, destination: 0x0FFF_FEFF)
        let highData = [0x80] + long
        #expect(Self.detailsEncodeRefusal(.detailsReply(header, profile: id, target: 0x80, data: highData)) ==
            .fieldOutOfRange(.inquiryTarget, value: 0x80))
        #expect(Self.detailsEncodeRefusal(.detailsReply(header, profile: id, target: 0x01, data: highData)) ==
            .fieldOutOfRange(.inquiryTargetData, value: 0x80))
        #expect(Self.detailsEncodeRefusal(.detailsReply(header, profile: id, target: 0x01, data: long)) ==
            .fieldOutOfRange(.inquiryTargetDataLength, value: 0x4000))
        #expect(Self.detailsEncodeRefusal(
            .detailsReply(header, profile: id, target: 0x01, data: [0x01, 0x02]), limits: small) ==
            .payloadTooLarge(23))
        #expect(Self.detailsEncodeRefusal(.specificData(toBroadcast, profile: id, data: [0x80]), limits: small) ==
            .fieldOutOfRange(.profileSpecificData, value: 0x80))
        #expect(Self.detailsEncodeRefusal(.specificData(toBroadcast, profile: id, data: [0x01]), limits: small) ==
            .payloadTooLarge(23))
    }

    // MARK: Bytes of 0x80 or more

    @Test func aByteOfEightyHexOrMoreAtEveryOffsetOfEveryGoldenIsRefusedAsDataOrNotCI() {
        for golden in Self.detailsGoldens {
            #expect(Self.detailsDecodeRefusal(Self.replacing(golden, at: 0, with: 0x80)) == .notCI)
            for offset in 1..<golden.count {
                let payload = Self.replacing(golden, at: offset, with: 0x80)
                let expected: MIDICIRefusal = offset == 2 ? .notCI : .dataByteHigh(offset: offset)
                #expect(Self.detailsDecodeRefusal(payload) == expected)
                #expect(Self.detailsDecodeRefusal(Self.replacing(golden, at: offset, with: 0xFF)) == expected)
            }
        }
    }

    @Test func theEnvelopeBytesAreCheckedFirst() {
        #expect(Self.detailsDecodeRefusal(Self.replacing(Self.detailsInquiryGolden, at: 0, with: 0x7F)) == .notCI)
        #expect(Self.detailsDecodeRefusal(Self.replacing(Self.detailsReplyGolden, at: 2, with: 0x0E)) == .notCI)
        #expect(Self.detailsDecodeRefusal([0x7E, 0x7F, 0x0D]) == .truncated(need: 5, have: 3))
        #expect(Self.detailsDecodeRefusal([0x7E, 0x7F, 0x0C]) == .notCI)
    }

    // MARK: Neighbours

    @Test func theSubIDsNextToTheThreeAreUnknownHere() {
        let unknown: [UInt8] = [0x00, 0x20, 0x27, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x30, 0x34, 0x40, 0x70, 0x7F]
        for subID in unknown {
            #expect(Self.detailsDecodeRefusal(Self.replacing(Self.detailsReplyGolden, at: 3, with: subID)) ==
                .unknownSubID(subID))
        }
        for golden in Self.exchangeGoldens {
            #expect(Self.detailsDecodeRefusal(golden) == .unknownSubID(golden.dropFirst(3).first ?? 0))
        }
    }

    @Test func theOtherDecodersStillRefuseTheThreeSubIDs() {
        for (subID, golden) in zip([0x28, 0x29, 0x29, 0x2F, 0x2F] as [UInt8], Self.detailsGoldens) {
            #expect(golden.dropFirst(3).first == subID)
            let refusal = MIDICIRefusal.unknownSubID(subID)
            #expect(Self.decodeRefusal(golden) == refusal)
            #expect(throws: refusal) { try MIDICIProfileMessage.decode(payload: golden, limits: .standard) }
            #expect(throws: refusal) { try MIDICIPropertyCapabilityMessage.decode(payload: golden, limits: .standard) }
            #expect(throws: refusal) { try MIDICIEndpointMessage.decode(payload: golden, limits: .standard) }
            #expect(throws: refusal) { try MIDICIProcessInquiryMessage.decode(payload: golden, limits: .standard) }
            #expect(throws: refusal) { try MIDICIPropertyDataMessage.decode(payload: golden, limits: .standard) }
        }
    }

    // MARK: Hostile input

    @Test func seededProfileDetailsMutationsAndRandomPayloadsNeverTrapAndEverySuccessReencodesIdentically() {
        var random = Xorshift(seed: 0x5044_4934)
        var decoded = 0
        var refused = 0
        for golden in Self.detailsGoldens {
            for _ in 0..<600 {
                var bytes = golden
                bytes[Int(random.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: random.next())
                if random.next() % 4 == 0 { bytes.removeLast() }
                Self.checkDetailsRoundTrip(bytes, decoded: &decoded, refused: &refused)
            }
        }
        for round in 0..<3_000 {
            var bytes: [UInt8]
            if round % 3 == 0 {
                bytes = (0..<Int(random.next() % 70)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            } else {
                bytes = Self.randomDetailsPayload(&random)
                if round % 3 == 1, bytes.count > 1 { bytes[1] = UInt8(random.next() & 0x7F) }
            }
            Self.checkDetailsRoundTrip(bytes, decoded: &decoded, refused: &refused)
        }
        #expect(decoded > 1_000 && refused > 1_000)
    }

    /// A structurally plausible payload: a kind, a format, 7-bit fields and a declared length that is right two
    /// times in three.
    static func randomDetailsPayload(_ random: inout Xorshift) -> [UInt8] {
        let subID = detailsSubIDs[Int(random.next() % 3)]
        let data = (0..<Int(random.next() % 6)).map { _ in UInt8(random.next() & 0x7F) }
        let profileBytes = (0..<5).map { _ in UInt8(random.next() & 0x7F) }
        let declared = random.next() % 3 == 0 ? Int(random.next() & 0x3F) : data.count
        let tail: [UInt8]
        switch subID {
        case 0x28: tail = [UInt8(random.next() & 0x7F)]
        case 0x29: tail = [UInt8(random.next() & 0x7F)] + MIDICIWire.encode(UInt32(declared), byteCount: 2) + data
        default: tail = MIDICIWire.encode(UInt32(declared), byteCount: 4) + data
        }
        let muids = MIDICIWire.encode(UInt32(random.next() & 0x0FFF_FEFF), byteCount: 4)
            + MIDICIWire.encode(UInt32(random.next() & 0x0FFF_FEFF), byteCount: 4)
        return prefix(UInt8(random.next() & 0x7F), subID, UInt8(random.next() % 4)) + muids + profileBytes + tail
    }

    /// A payload that decodes re-encodes to the same bytes: decode and encode apply the same format and addressing
    /// rules and every kept value is 7-bit.
    static func checkDetailsRoundTrip(_ bytes: [UInt8], decoded: inout Int, refused: inout Int) {
        guard let message = try? MIDICIProfileDetailsMessage.decode(payload: bytes, limits: .standard) else {
            refused += 1
            return
        }
        decoded += 1
        do {
            let encoded = try message.encode(limits: .standard)
            #expect(encoded == bytes)
            #expect(try MIDICIProfileDetailsMessage.decode(payload: encoded, limits: .standard) == message)
        } catch {
            Issue.record("unexpected encode refusal \(error)")
        }
    }
}
