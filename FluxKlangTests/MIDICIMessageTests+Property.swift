//
//  MIDICIMessageTests+Property.swift
//  FluxKlangTests
//
//  Inquiry: Property Exchange Capabilities (0x30) and its Reply (0x31): reference goldens, decode, encode, the
//  CI 1.1 / CI 1.2 body, exact lengths, every refusal in decoder order, high bytes, seeded mutations and the round
//  trip (#83, slice PEX1).
//
//  Provenance: the four `amInquiry11`, `amReply11`, `amInquiry12` and `amReply12` vectors are the bytes printed by
//  AM_MIDI2.0Lib's `CIMessage::sendPECapabilityRequest` / `sendPECapabilityReply` (src/midiCIMessageCreate.cpp,
//  commit 7fa1b0c) for the arguments named next to each vector; the field values are this slice's own. The other
//  vectors are written by hand from the layout. The full refusal order is the doc comment of
//  `MIDICIPropertyCapabilityMessage.decode(payload:limits:)`.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    // MARK: Property capability goldens (never produced by the encoder)

    /// AM: `sendPECapabilityRequest(sysex, 1, 0x01234567, 0x0FFFFEFF, 4, 0, 0)`.
    static let amInquiry11: [UInt8] = [
        0x7E, 0x7F, 0x0D, 0x30, 0x01, 0x67, 0x0A, 0x0D, 0x09, 0x7F, 0x7D, 0x7F, 0x7F, 0x04
    ]
    /// AM: `sendPECapabilityReply(sysex, 1, 0x0FFFFEFF, 0x01234567, 1, 0, 0)`.
    static let amReply11: [UInt8] = [
        0x7E, 0x7F, 0x0D, 0x31, 0x01, 0x7F, 0x7D, 0x7F, 0x7F, 0x67, 0x0A, 0x0D, 0x09, 0x01
    ]
    /// AM: `sendPECapabilityRequest(sysex, 2, 0x01234567, 0x0FFFFFFF, 0x7F, 0, 0)`.
    static let amInquiry12: [UInt8] = [
        0x7E, 0x7F, 0x0D, 0x30, 0x02, 0x67, 0x0A, 0x0D, 0x09, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x00, 0x00
    ]
    /// AM: `sendPECapabilityReply(sysex, 2, 0x01234567, 0x0FFFFEFF, 2, 1, 0x7F)`.
    static let amReply12: [UInt8] = [
        0x7E, 0x7F, 0x0D, 0x31, 0x02, 0x67, 0x0A, 0x0D, 0x09, 0x7F, 0x7D, 0x7F, 0x7F, 0x02, 0x01, 0x7F
    ]
    static let propertyInquiry11Zero = prefix(0x10, 0x30, 0x01) + sourceBytes + zeroBytes + [0x00]
    static let propertyReply12Device = prefix(0x00, 0x31, 0x02) + maximumBytes + broadcastBytes + [0x10, 0x7F, 0x00]
    static let propertyGoldens: [[UInt8]] = [
        amInquiry11, amReply11, amInquiry12, amReply12, propertyInquiry11Zero, propertyReply12Device
    ]

    // MARK: Property fixtures

    static func capabilities(_ requests: UInt8, _ version: (UInt8, UInt8)? = nil) throws -> MIDICIPropertyCapabilities {
        var typed: MIDICIPropertyExchangeVersion?
        if let version { typed = try MIDICIPropertyExchangeVersion.make(major: version.0, minor: version.1) }
        return try MIDICIPropertyCapabilities.make(simultaneousRequests: requests, version: typed)
    }

    static func propertyMessages() throws -> [MIDICIPropertyCapabilityMessage] {
        let maximum: UInt32 = 0x0FFF_FEFF
        return [
            .inquiry(try header(.ci11, device: 0x7F, destination: maximum), try capabilities(4)),
            .reply(try header(.ci11, device: 0x7F, source: maximum, destination: 0x0123_4567), try capabilities(1)),
            .inquiry(try header(.ci12, device: 0x7F), try capabilities(0x7F, (0, 0))),
            .reply(try header(.ci12, device: 0x7F, destination: maximum), try capabilities(2, (1, 0x7F))),
            .inquiry(try header(.ci11, destination: 0), try capabilities(0)),
            .reply(try header(.ci12, device: 0x00, source: maximum), try capabilities(0x10, (0x7F, 0)))
        ]
    }

    static func propertyDecodeRefusal(_ payload: [UInt8], limits: MIDICILimits = .standard) -> MIDICIRefusal? {
        do {
            _ = try MIDICIPropertyCapabilityMessage.decode(payload: payload, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func propertyEncodeRefusal(
        _ message: MIDICIPropertyCapabilityMessage, limits: MIDICILimits = .standard
    ) -> MIDICIRefusal? {
        do {
            _ = try message.encode(limits: limits)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Goldens, decode and encode

    @Test func everyPropertyCapabilityMessageEncodesToItsGoldenBytes() throws {
        let messages = try Self.propertyMessages()
        try #require(messages.count == Self.propertyGoldens.count)
        for (message, golden) in zip(messages, Self.propertyGoldens) {
            #expect(try message.encode(limits: .standard) == golden)
        }
        #expect([Self.amInquiry11, Self.amReply11, Self.propertyInquiry11Zero].allSatisfy { $0.count == 14 })
        #expect([Self.amInquiry12, Self.amReply12, Self.propertyReply12Device].allSatisfy { $0.count == 16 })
    }

    @Test func everyPropertyCapabilityGoldenDecodesToItsExactTypedValue() throws {
        let messages = try Self.propertyMessages()
        try #require(messages.count == Self.propertyGoldens.count)
        for (golden, message) in zip(Self.propertyGoldens, messages) {
            #expect(try MIDICIPropertyCapabilityMessage.decode(payload: golden, limits: .standard) == message)
        }
        #expect(messages.map(\.kind) == [.inquiry, .reply, .inquiry, .reply, .inquiry, .reply])
        let reply = try MIDICIPropertyCapabilityMessage.decode(payload: Self.amReply12, limits: .standard)
        guard case let .reply(header, capabilities) = reply else {
            Issue.record("expected a Reply to Property Exchange Capabilities")
            return
        }
        #expect(header.device.rawValue == 0x7F && header.format == .ci12)
        #expect(header.source.rawValue == 0x0123_4567 && header.destination.rawValue == 0x0FFF_FEFF)
        #expect(capabilities.simultaneousRequests == 2)
        #expect(capabilities.version?.major == 1 && capabilities.version?.minor == 0x7F)
        let legacy = try MIDICIPropertyCapabilityMessage.decode(payload: Self.amInquiry11, limits: .standard)
        guard case let .inquiry(legacyHeader, legacyCapabilities) = legacy else {
            Issue.record("expected an Inquiry: Property Exchange Capabilities")
            return
        }
        #expect(legacyHeader.format == .ci11 && legacyCapabilities.simultaneousRequests == 4)
        #expect(legacyCapabilities.version == nil && legacy.capabilities == legacyCapabilities)
    }

    @Test func everyPropertyCapabilityMessageSurvivesTheRoundTripInBothFormats() throws {
        for message in try Self.propertyMessages() {
            let bytes = try message.encode(limits: .standard)
            #expect(try MIDICIPropertyCapabilityMessage.decode(payload: bytes, limits: .standard) == message)
        }
        for golden in Self.propertyGoldens {
            let message = try MIDICIPropertyCapabilityMessage.decode(payload: golden, limits: .standard)
            #expect(try message.encode(limits: .standard) == golden)
        }
        for requests: UInt8 in [0, 1, 0x40, 0x7F] {
            let legacy = MIDICIPropertyCapabilityMessage.reply(try Self.header(.ci11), try Self.capabilities(requests))
            let legacyBytes = try legacy.encode(limits: .standard)
            #expect(legacyBytes.count == 14 && legacyBytes.last == requests)
            #expect(try MIDICIPropertyCapabilityMessage.decode(payload: legacyBytes, limits: .standard) == legacy)
            for version: (UInt8, UInt8) in [(0, 0), (0, 0x7F), (0x7F, 0), (0x2A, 0x55)] {
                let current = MIDICIPropertyCapabilityMessage.inquiry(
                    try Self.header(.ci12), try Self.capabilities(requests, version))
                let bytes = try current.encode(limits: .standard)
                #expect(bytes.suffix(3) == [requests, version.0, version.1])
                #expect(try MIDICIPropertyCapabilityMessage.decode(payload: bytes, limits: .standard) == current)
            }
        }
    }

    // MARK: Sub-ids

    @Test func theOtherDecodersStillRefuseThePropertyCapabilitySubIDs() throws {
        for golden in Self.propertyGoldens {
            let sub = try #require(golden.dropFirst(3).first)
            #expect(Self.decodeRefusal(golden) == .unknownSubID(sub))
            #expect(Self.profileDecodeRefusal(golden) == .unknownSubID(sub))
        }
    }

    @Test func thePropertyDecoderRefusesPropertyDataAndEveryOtherSubIDAsUnknown() throws {
        let getPropertyData = Self.replacing(Self.amInquiry12, at: 3, with: 0x34)
        #expect(Self.propertyDecodeRefusal(getPropertyData) == .unknownSubID(0x34))
        let others: [UInt8] = Array(0x32...0x3F) + [0x00, 0x20, 0x21, 0x2F, 0x40, 0x70, 0x71, 0x7F]
        for sub in others {
            #expect(Self.propertyDecodeRefusal(Self.replacing(Self.amReply11, at: 3, with: sub)) == .unknownSubID(sub))
        }
        for golden in Self.goldens + Self.profileGoldens {
            let sub = try #require(golden.dropFirst(3).first)
            #expect(Self.propertyDecodeRefusal(golden) == .unknownSubID(sub))
        }
    }

    // MARK: Format and exact length

    @Test func aFormatOtherThanOneOrTwoIsUnsupported() throws {
        for format: UInt8 in [0x00, 0x03, 0x10, 0x7F] {
            #expect(Self.propertyDecodeRefusal(Self.replacing(Self.amInquiry12, at: 4, with: format)) ==
                .unsupportedFormat(format))
            #expect(Self.propertyDecodeRefusal(Self.replacing(Self.amReply11, at: 4, with: format)) ==
                .unsupportedFormat(format))
        }
        let shortNewFormat = Self.replacing(Array(Self.amInquiry12.prefix(6)), at: 4, with: 0x03)
        #expect(Self.propertyDecodeRefusal(shortNewFormat) == .unsupportedFormat(3))
    }

    @Test func theVersionBytesAreReadExactlyWhenTheFormatIsCI12() throws {
        #expect(Self.propertyDecodeRefusal(Self.replacing(Self.amInquiry12, at: 4, with: 0x01)) == .trailingBytes(2))
        #expect(Self.propertyDecodeRefusal(Self.replacing(Self.amReply11, at: 4, with: 0x02)) ==
            .truncated(need: 16, have: 14))
        #expect(Self.propertyDecodeRefusal(Self.amInquiry11 + [0x01, 0x00]) == .trailingBytes(2))
        #expect(Self.propertyDecodeRefusal(Self.amReply11 + [0x00]) == .trailingBytes(1))
        #expect(Self.propertyDecodeRefusal(Self.amReply12 + [0x00]) == .trailingBytes(1))
        let long = Self.amInquiry12 + [UInt8](repeating: 0x00, count: 100)
        #expect(Self.propertyDecodeRefusal(long) == .trailingBytes(100))
    }

    @Test func everyPrefixOfAPropertyCapabilityMessageIsTruncated() throws {
        #expect(Self.propertyDecodeRefusal([]) == .truncated(need: 1, have: 0))
        for golden in Self.propertyGoldens {
            for length in 1..<golden.count {
                let need: Int
                switch length {
                case 1..<5: need = 5
                case 5..<13: need = 13
                default: need = golden.count
                }
                #expect(Self.propertyDecodeRefusal(Array(golden.prefix(length))) ==
                    .truncated(need: need, have: length))
            }
        }
    }

    // MARK: Bytes, MUIDs, addressing and the device id

    @Test func aHighByteAnywhereIsRefusedAtItsOffsetAndAWrongLeadIsNotCI() throws {
        for golden in Self.propertyGoldens {
            for offset in 1..<golden.count {
                for value: UInt8 in [0x80, 0xFF] {
                    let high = Self.replacing(golden, at: offset, with: value)
                    #expect(Self.propertyDecodeRefusal(high) == (offset == 2 ? .notCI : .dataByteHigh(offset: offset)))
                }
            }
            #expect(Self.propertyDecodeRefusal(Self.replacing(golden, at: 0, with: 0x7F)) == .notCI)
            #expect(Self.propertyDecodeRefusal(Self.replacing(golden, at: 2, with: 0x0C)) == .notCI)
        }
        let highAndShort = Self.replacing(Array(Self.amReply12.prefix(15)), at: 14, with: 0x81)
        #expect(Self.propertyDecodeRefusal(highAndShort) == .dataByteHigh(offset: 14))
    }

    @Test func propertyLengthBeatsMUIDsWhichBeatAddressing() throws {
        let reservedSource = Self.replacing(Self.amReply12, range: 5..<9, with: Self.reservedBytes)
        #expect(Self.propertyDecodeRefusal(reservedSource) == .invalidMUID(0x0FFF_FF00))
        #expect(Self.propertyDecodeRefusal(Array(reservedSource.prefix(15))) == .truncated(need: 16, have: 15))
        #expect(Self.propertyDecodeRefusal(reservedSource + [0x00]) == .trailingBytes(1))
        let reservedDestination = Self.replacing(Self.amInquiry11, range: 9..<13, with: Self.reservedBytes)
        #expect(Self.propertyDecodeRefusal(reservedDestination) == .invalidMUID(0x0FFF_FF00))
        let bothReserved = Self.replacing(reservedSource, range: 9..<13, with: [0x01, 0x7E, 0x7F, 0x7F])
        #expect(Self.propertyDecodeRefusal(bothReserved) == .invalidMUID(0x0FFF_FF00))
        let broadcastSource = Self.replacing(Self.amInquiry11, range: 5..<9, with: Self.broadcastBytes)
        #expect(Self.propertyDecodeRefusal(broadcastSource) == .sourceIsBroadcast)
        let broadcastToReserved = Self.replacing(broadcastSource, range: 9..<13, with: Self.reservedBytes)
        #expect(Self.propertyDecodeRefusal(broadcastToReserved) == .invalidMUID(0x0FFF_FF00))
        for destination in [Self.broadcastBytes, Self.zeroBytes, Self.maximumBytes, Self.sourceBytes] {
            for golden in [Self.amInquiry11, Self.amReply12] {
                #expect(Self.propertyDecodeRefusal(Self.replacing(golden, range: 9..<13, with: destination)) == nil)
            }
        }
        for device: UInt8 in [0x00, 0x0F, 0x10, 0x7E, 0x7F] {
            let decoded = try MIDICIPropertyCapabilityMessage.decode(
                payload: Self.replacing(Self.amReply11, at: 1, with: device), limits: .standard)
            #expect(decoded.header.device.rawValue == device)
        }
    }

    @Test func thePayloadLimitIsCheckedBeforeEverythingElse() throws {
        let limit13 = try Self.limits(payload: 13, text: 0)
        #expect(Self.propertyDecodeRefusal(Self.amInquiry11, limits: limit13) == .payloadTooLarge(14))
        let limit15 = try Self.limits(payload: 15, text: 0)
        #expect(Self.propertyDecodeRefusal(Self.amReply12, limits: limit15) == .payloadTooLarge(16))
        let hostile = [UInt8](repeating: 0xFF, count: 4_097)
        #expect(Self.propertyDecodeRefusal(hostile) == .payloadTooLarge(4_097))
        #expect(Self.propertyDecodeRefusal(Self.amReply12, limits: try Self.limits(payload: 16, text: 0)) == nil)
    }

    @Test func seededMutationsOfThePropertyGoldensDecodeOnlyToCanonicalBytes() throws {
        var random = Xorshift(seed: 0x5045_5831)
        for golden in Self.propertyGoldens {
            for _ in 0..<400 {
                var bytes = golden
                let offset = Int(random.next() % UInt64(bytes.count))
                bytes[offset] = UInt8(truncatingIfNeeded: random.next())
                if random.next() % 4 == 0 { bytes.removeLast() }
                guard let message = try? MIDICIPropertyCapabilityMessage.decode(payload: bytes, limits: .standard)
                else { continue }
                #expect(try message.encode(limits: .standard) == bytes)
            }
        }
    }

    // MARK: Factories and encode refusals

    @Test func theFactoriesRefuseAByteOfEightBits() throws {
        #expect(throws: MIDICIRefusal.fieldOutOfRange(.simultaneousRequests, value: 0x80)) {
            try MIDICIPropertyCapabilities.make(simultaneousRequests: 0x80, version: nil)
        }
        #expect(throws: MIDICIRefusal.fieldOutOfRange(.propertyExchangeMajorVersion, value: 0xFF)) {
            try MIDICIPropertyExchangeVersion.make(major: 0xFF, minor: 0x80)
        }
        #expect(throws: MIDICIRefusal.fieldOutOfRange(.propertyExchangeMinorVersion, value: 0x80)) {
            try MIDICIPropertyExchangeVersion.make(major: 0x7F, minor: 0x80)
        }
        let edge = try Self.capabilities(0x7F, (0x7F, 0x7F))
        #expect(edge.simultaneousRequests == 0x7F && edge.version?.major == 0x7F && edge.version?.minor == 0x7F)
    }

    @Test func propertyEncodeChecksTheSourceThenTheVersionPairingThenTheSize() throws {
        let legacyWithVersion = MIDICIPropertyCapabilityMessage.inquiry(
            try Self.header(.ci11), try Self.capabilities(1, (1, 0)))
        #expect(Self.propertyEncodeRefusal(legacyWithVersion) == .propertyVersionNotAllowed)
        let currentWithout = MIDICIPropertyCapabilityMessage.reply(try Self.header(.ci12), try Self.capabilities(1))
        #expect(Self.propertyEncodeRefusal(currentWithout) == .propertyVersionRequired)
        let broadcastSource = try Self.header(.ci12, source: 0x0FFF_FFFF)
        let both = MIDICIPropertyCapabilityMessage.reply(broadcastSource, try Self.capabilities(1))
        #expect(Self.propertyEncodeRefusal(both) == .sourceIsBroadcast)
        let tiny = try Self.limits(payload: 1, text: 0)
        #expect(Self.propertyEncodeRefusal(currentWithout, limits: tiny) == .propertyVersionRequired)
        let legacy = MIDICIPropertyCapabilityMessage.inquiry(try Self.header(.ci11), try Self.capabilities(1))
        #expect(Self.propertyEncodeRefusal(legacy, limits: try Self.limits(payload: 13, text: 0)) ==
            .payloadTooLarge(14))
        #expect(Self.propertyEncodeRefusal(legacy, limits: try Self.limits(payload: 14, text: 0)) == nil)
        let current = MIDICIPropertyCapabilityMessage.reply(try Self.header(.ci12), try Self.capabilities(1, (0, 0)))
        #expect(Self.propertyEncodeRefusal(current, limits: try Self.limits(payload: 15, text: 0)) ==
            .payloadTooLarge(16))
        #expect(Self.propertyEncodeRefusal(current, limits: try Self.limits(payload: 16, text: 0)) == nil)
        let toBroadcast = MIDICIPropertyCapabilityMessage.inquiry(try Self.header(.ci11), try Self.capabilities(3))
        #expect(try toBroadcast.encode(limits: .standard).suffix(5) == Self.broadcastBytes + [0x03])
    }
}
