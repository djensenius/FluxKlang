//
//  MIDICIMessageTests+Profile.swift
//  FluxKlangTests
//
//  Profile Inquiry (0x20) and Reply to Profile Inquiry (0x21): hand-written goldens, decode, encode, the refusal
//  order, truncation, trailing bytes, the per-list bound, hostile counts and the round trip (#83, slice PIQ1).
//
//  Provenance: as in `MIDICIMessageTests.swift`, the layout was cross-checked against the public ktmidi and JUCE
//  sources (the MIDI Association specification was not reachable). No byte array was copied from either source;
//  every value below is this slice's own. The full refusal order is the doc comment of
//  `MIDICIProfileMessage.decode(payload:limits:)`.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    // MARK: Profile goldens (written by hand from the layout, never produced by the encoder)

    static let profileA: [UInt8] = [0x7E, 0x00, 0x01, 0x01, 0x00]
    static let profileB: [UInt8] = [0x00, 0x20, 0x29, 0x05, 0x06]
    static let profileC: [UInt8] = [0x7E, 0x12, 0x34, 0x56, 0x7F]
    static let profileD: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
    static let profileE: [UInt8] = [0x7F, 0x7F, 0x7F, 0x7F, 0x7F]

    static let inquiry11 = prefix(0x10, 0x20, 0x01) + sourceBytes + maximumBytes
    static let inquiry12 = prefix(0x7F, 0x20, 0x02) + sourceBytes + broadcastBytes
    static let profileReply00 = prefix(0x10, 0x21, 0x02) + sourceBytes + maximumBytes + [0x00, 0x00, 0x00, 0x00]
    static let profileReply10 = prefix(0x10, 0x21, 0x01) + maximumBytes + sourceBytes
        + [0x01, 0x00] + profileA + [0x00, 0x00]
    static let profileReply01 = prefix(0x7E, 0x21, 0x02) + sourceBytes + maximumBytes
        + [0x00, 0x00] + [0x01, 0x00] + profileB
    static let profileReply23 = prefix(0x00, 0x21, 0x02) + sourceBytes + broadcastBytes
        + [0x02, 0x00] + profileA + profileB + [0x03, 0x00] + profileC + profileD + profileE
    static let profileGoldens: [[UInt8]] = [
        inquiry11, inquiry12, profileReply00, profileReply10, profileReply01, profileReply23
    ]

    // MARK: Profile fixtures

    static func profile(_ bytes: [UInt8]) throws -> MIDICapabilityProfileID {
        try MIDICapabilityProfileID.make(bytes: bytes)
    }

    static func profileMessages() throws -> [MIDICIProfileMessage] {
        let maximum: UInt32 = 0x0FFF_FEFF
        return [
            .inquiry(try header(.ci11, destination: maximum)),
            .inquiry(try header(.ci12, device: 0x7F)),
            .inquiryReply(try header(.ci12, destination: maximum), enabled: [], disabled: []),
            .inquiryReply(
                try header(.ci11, source: maximum, destination: 0x0123_4567),
                enabled: [try profile(profileA)], disabled: []),
            .inquiryReply(
                try header(.ci12, device: 0x7E, destination: maximum), enabled: [], disabled: [try profile(profileB)]),
            .inquiryReply(
                try header(.ci12, device: 0x00),
                enabled: [try profile(profileA), try profile(profileB)],
                disabled: [try profile(profileC), try profile(profileD), try profile(profileE)])
        ]
    }

    static func profileDecodeRefusal(_ payload: [UInt8], limits: MIDICILimits = .standard) -> MIDICIRefusal? {
        do {
            _ = try MIDICIProfileMessage.decode(payload: payload, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func profileEncodeRefusal(
        _ message: MIDICIProfileMessage, limits: MIDICILimits = .standard
    ) -> MIDICIRefusal? {
        do {
            _ = try message.encode(limits: limits)
            return nil
        } catch {
            return error
        }
    }

    /// `count` distinct ids `7E 00 00 hi lo`, for the bound tests (the bytes are a pattern, not a golden).
    static func profileList(_ count: Int) throws -> [MIDICapabilityProfileID] {
        try (0..<count).map { index in try profile(profileListBytes(index)) }
    }

    static func profileListBytes(_ index: Int) -> [UInt8] {
        [0x7E, 0x00, 0x00, UInt8(index >> 7), UInt8(index & 0x7F)]
    }

    /// A reply payload built from a count field and raw id bytes, so a test can declare any count.
    static func replyPayload(enabled: [UInt8], enabledIDs: Int, disabled: [UInt8], disabledIDs: Int) -> [UInt8] {
        prefix(0x10, 0x21, 0x02) + sourceBytes + maximumBytes
            + enabled + (0..<enabledIDs).flatMap { profileListBytes($0) }
            + disabled + (0..<disabledIDs).flatMap { profileListBytes($0) }
    }

    // MARK: Goldens, decode and encode

    @Test func everyProfileMessageEncodesToItsHandWrittenGoldenBytes() throws {
        let messages = try Self.profileMessages()
        try #require(messages.count == Self.profileGoldens.count)
        for (message, golden) in zip(messages, Self.profileGoldens) {
            #expect(try message.encode(limits: .standard) == golden)
        }
        #expect(Self.inquiry11.count == 13 && Self.inquiry12.count == 13 && Self.profileReply00.count == 17)
        #expect(Self.profileReply10.count == 22 && Self.profileReply01.count == 22 && Self.profileReply23.count == 42)
    }

    @Test func everyProfileGoldenDecodesToItsExactTypedValue() throws {
        let messages = try Self.profileMessages()
        try #require(messages.count == Self.profileGoldens.count)
        for (golden, message) in zip(Self.profileGoldens, messages) {
            #expect(try MIDICIProfileMessage.decode(payload: golden, limits: .standard) == message)
        }
        let decoded = try MIDICIProfileMessage.decode(payload: Self.profileReply23, limits: .standard)
        guard case let .inquiryReply(header, enabled, disabled) = decoded else {
            Issue.record("expected a Reply to Profile Inquiry")
            return
        }
        #expect(header.device.rawValue == 0x00 && header.format == .ci12 && header.destination.isBroadcast)
        #expect(header.source.rawValue == 0x0123_4567 && decoded.kind == .inquiryReply)
        try #require(enabled.count == 2 && disabled.count == 3)
        #expect(enabled[0].bytes == Self.profileA && enabled[1].bytes == Self.profileB)
        #expect(disabled[0].bytes == Self.profileC && disabled[1].bytes == Self.profileD)
        #expect(disabled[2].bytes == Self.profileE)
    }

    @Test func theInquiryIsTheThirteenByteHeaderInBothFormats() throws {
        let inquiry = try MIDICIProfileMessage.decode(payload: Self.inquiry11, limits: .standard)
        #expect(inquiry.kind == .inquiry && inquiry.header.format == .ci11)
        #expect(inquiry.header.destination.rawValue == 0x0FFF_FEFF)
        let broadcast = try MIDICIProfileMessage.decode(payload: Self.inquiry12, limits: .standard)
        #expect(broadcast.header.device == .allCall && broadcast.header.destination.isBroadcast)
    }

    @Test func theManagementDecoderStillRefusesTheProfileSubIDs() throws {
        #expect(Self.decodeRefusal(Self.inquiry11) == .unknownSubID(0x20))
        #expect(Self.decodeRefusal(Self.profileReply23) == .unknownSubID(0x21))
        #expect(Self.profileDecodeRefusal(Self.discovery11) == .unknownSubID(0x70))
        #expect(Self.profileDecodeRefusal(Self.replacing(Self.inquiry11, at: 3, with: 0x22)) == .unknownSubID(0x22))
    }

    @Test func everyProfileMessageSurvivesTheRoundTripInBothDirections() throws {
        for message in try Self.profileMessages() {
            let bytes = try message.encode(limits: .standard)
            #expect(try MIDICIProfileMessage.decode(payload: bytes, limits: .standard) == message)
        }
        for golden in Self.profileGoldens {
            let message = try MIDICIProfileMessage.decode(payload: golden, limits: .standard)
            #expect(try message.encode(limits: .standard) == golden)
        }
        let full = MIDICIProfileMessage.inquiryReply(
            try Self.header(.ci11), enabled: try Self.profileList(64), disabled: try Self.profileList(64))
        let bytes = try full.encode(limits: .standard)
        #expect(bytes.count == 17 + 2 * 64 * 5)
        #expect(try MIDICIProfileMessage.decode(payload: bytes, limits: .standard) == full)
    }

    // MARK: Refusal order of the common header

    @Test func theProfileEnvelopeChecksRunInTheManagementOrder() throws {
        #expect(Self.profileDecodeRefusal([]) == .truncated(need: 1, have: 0))
        let tight = try Self.limits(payload: 16, text: 0)
        #expect(Self.profileDecodeRefusal(Self.profileReply00, limits: tight) == .payloadTooLarge(17))
        #expect(Self.profileDecodeRefusal(Self.replacing(Self.inquiry11, at: 0, with: 0x7F)) == .notCI)
        #expect(Self.profileDecodeRefusal(Self.replacing(Self.inquiry11, at: 2, with: 0x80)) == .notCI)
        #expect(Self.profileDecodeRefusal([0x7E, 0x90, 0x0D, 0x20, 0x01]) == .dataByteHigh(offset: 1))
        #expect(Self.profileDecodeRefusal([0x7E, 0x10, 0x0D, 0x20]) == .truncated(need: 5, have: 4))
        #expect(Self.profileDecodeRefusal([0x7E, 0x10, 0x0D, 0x22, 0x09, 0x00]) == .unknownSubID(0x22))
        #expect(Self.profileDecodeRefusal([0x7E, 0x10, 0x0D, 0x21, 0x03, 0x00]) == .unsupportedFormat(0x03))
        #expect(Self.profileDecodeRefusal([0x7E, 0x10, 0x0D, 0x21, 0x01, 0x00]) == .truncated(need: 13, have: 6))
        let highAndShort = Self.replacing(Array(Self.profileReply10.dropLast()), at: 17, with: 0x80)
        #expect(Self.profileDecodeRefusal(highAndShort) == .dataByteHigh(offset: 17))
    }

    @Test func lengthBeatsMUIDsWhichBeatAddressingWhichBeatsTheDevice() throws {
        let reservedSource = Self.replacing(Self.inquiry11, range: 5..<9, with: Self.reservedBytes)
        #expect(Self.profileDecodeRefusal(reservedSource + [0x00]) == .trailingBytes(1))
        let reservedReply = Self.replacing(Self.profileReply00, range: 5..<9, with: Self.reservedBytes)
        #expect(Self.profileDecodeRefusal(Array(reservedReply.dropLast())) == .truncated(need: 17, have: 16))
        #expect(Self.profileDecodeRefusal(reservedSource) == .invalidMUID(0x0FFF_FF00))
        let bothReserved = Self.replacing(reservedSource, range: 9..<13, with: [0x01, 0x7E, 0x7F, 0x7F])
        #expect(Self.profileDecodeRefusal(bothReserved) == .invalidMUID(0x0FFF_FF00))
        let broadcastSource = Self.replacing(Self.inquiry11, range: 5..<9, with: Self.broadcastBytes)
        #expect(Self.profileDecodeRefusal(broadcastSource) == .sourceIsBroadcast)
        let broadcastThenReserved = Self.replacing(broadcastSource, range: 9..<13, with: Self.reservedBytes)
        #expect(Self.profileDecodeRefusal(broadcastThenReserved) == .invalidMUID(0x0FFF_FF00))
        let zeroDestination = Self.replacing(Self.profileReply00, range: 9..<13, with: Self.zeroBytes)
        #expect(Self.profileDecodeRefusal(zeroDestination) == nil)
        for device: UInt8 in [0x00, 0x0F, 0x7E, 0x7F] {
            #expect(Self.profileDecodeRefusal(Self.replacing(Self.inquiry11, at: 1, with: device)) == nil)
        }
    }

    // MARK: Truncation and trailing bytes

    @Test func aReplyCutInsideACountOrAnIDIsTruncatedAtTheExactNeed() throws {
        #expect(Self.profileDecodeRefusal(Array(Self.profileReply00.prefix(13))) == .truncated(need: 15, have: 13))
        #expect(Self.profileDecodeRefusal(Array(Self.profileReply00.prefix(14))) == .truncated(need: 15, have: 14))
        #expect(Self.profileDecodeRefusal(Array(Self.profileReply00.prefix(16))) == .truncated(need: 17, have: 16))
        #expect(Self.profileDecodeRefusal(Array(Self.profileReply10.prefix(17))) == .truncated(need: 20, have: 17))
        #expect(Self.profileDecodeRefusal(Array(Self.profileReply10.prefix(21))) == .truncated(need: 22, have: 21))
        #expect(Self.profileDecodeRefusal(Array(Self.profileReply23.prefix(40))) == .truncated(need: 42, have: 40))
        #expect(Self.profileDecodeRefusal(Array(Self.profileReply01.prefix(19))) == .truncated(need: 22, have: 19))
        for length in 13..<Self.profileReply23.count {
            #expect(Self.profileDecodeRefusal(Array(Self.profileReply23.prefix(length))) != nil)
        }
    }

    @Test func bytesAfterACompleteProfileMessageAreTrailing() throws {
        #expect(Self.profileDecodeRefusal(Self.inquiry12 + [0x00]) == .trailingBytes(1))
        #expect(Self.profileDecodeRefusal(Self.inquiry11 + [0x00, 0x00, 0x00, 0x00]) == .trailingBytes(4))
        #expect(Self.profileDecodeRefusal(Self.profileReply00 + [0x00, 0x00, 0x00]) == .trailingBytes(3))
        #expect(Self.profileDecodeRefusal(Self.profileReply23 + [0x7F]) == .trailingBytes(1))
    }

    // MARK: Bounds and hostile counts

    @Test func eachListAcceptsTheBoundAndRefusesOneMore() throws {
        #expect(MIDICIProfileMessage.maximumProfilesPerList == 64)
        let atCap = Self.replyPayload(enabled: [0x40, 0x00], enabledIDs: 64, disabled: [0x40, 0x00], disabledIDs: 64)
        let decoded = try MIDICIProfileMessage.decode(payload: atCap, limits: .standard)
        guard case let .inquiryReply(_, enabled, disabled) = decoded else {
            Issue.record("expected a Reply to Profile Inquiry")
            return
        }
        #expect(enabled.count == 64 && disabled.count == 64)
        let lastEnabled = try #require(enabled.last)
        #expect(lastEnabled.bytes == [0x7E, 0x00, 0x00, 0x00, 0x3F])
        let enabledOver = Self.replyPayload(
            enabled: [0x41, 0x00], enabledIDs: 65, disabled: [0x00, 0x00], disabledIDs: 0)
        #expect(Self.profileDecodeRefusal(enabledOver) == .tooManyProfiles(count: 65, limit: 64))
        let disabledOver = Self.replyPayload(
            enabled: [0x00, 0x00], enabledIDs: 0, disabled: [0x41, 0x00], disabledIDs: 65)
        #expect(Self.profileDecodeRefusal(disabledOver) == .tooManyProfiles(count: 65, limit: 64))
    }

    @Test func aHostileCountIsRefusedBeforeAnyIDIsReadOrAnyLaterCheckRuns() throws {
        let header = Array(Self.profileReply00.prefix(13))
        #expect(Self.profileDecodeRefusal(header + [0x7F, 0x7F]) == .tooManyProfiles(count: 16_383, limit: 64))
        #expect(Self.profileDecodeRefusal(header + [0x41, 0x00]) == .tooManyProfiles(count: 65, limit: 64))
        let hostileDisabled = header + [0x00, 0x00, 0x7F, 0x7F]
        #expect(Self.profileDecodeRefusal(hostileDisabled) == .tooManyProfiles(count: 16_383, limit: 64))
        let reserved = Self.replacing(header, range: 5..<9, with: Self.reservedBytes)
        #expect(Self.profileDecodeRefusal(reserved + [0x7F, 0x7F]) == .tooManyProfiles(count: 16_383, limit: 64))
        #expect(Self.profileDecodeRefusal(header + [0x40, 0x00]) == .truncated(need: 335, have: 15))
    }

    @Test func aHighByteInACountOrAProfileIDIsRefusedAtItsOffset() throws {
        for (offset, value) in [(13, UInt8(0x81)), (14, 0x80), (20, 0x90), (21, 0xFF)] {
            let high = Self.replacing(Self.profileReply10, at: offset, with: value)
            #expect(Self.profileDecodeRefusal(high) == .dataByteHigh(offset: offset))
        }
        for offset in 15..<20 {
            let high = Self.replacing(Self.profileReply10, at: offset, with: 0x80)
            #expect(Self.profileDecodeRefusal(high) == .dataByteHigh(offset: offset))
        }
        #expect(throws: MIDICapabilityRefusal.invalidProfileID(count: 5, offset: 2)) {
            try MIDICapabilityProfileID.make(bytes: [0x7E, 0x00, 0x80, 0x00, 0x00])
        }
    }

    // MARK: Encode refusals

    @Test func encodeRefusesABroadcastSourceThenEachOversizedListThenTheSize() throws {
        let broadcastSource = MIDICIProfileMessage.inquiry(try Self.header(.ci12, source: 0x0FFF_FFFF))
        #expect(Self.profileEncodeRefusal(broadcastSource) == .sourceIsBroadcast)
        let both = MIDICIProfileMessage.inquiryReply(
            try Self.header(.ci12), enabled: try Self.profileList(65), disabled: try Self.profileList(66))
        #expect(Self.profileEncodeRefusal(both) == .tooManyProfiles(count: 65, limit: 64))
        let disabled = MIDICIProfileMessage.inquiryReply(
            try Self.header(.ci12), enabled: [], disabled: try Self.profileList(65))
        #expect(Self.profileEncodeRefusal(disabled) == .tooManyProfiles(count: 65, limit: 64))
        let reply = MIDICIProfileMessage.inquiryReply(
            try Self.header(.ci12), enabled: [try Self.profile(Self.profileA)], disabled: [])
        #expect(Self.profileEncodeRefusal(reply, limits: try Self.limits(payload: 21, text: 0)) == .payloadTooLarge(22))
        #expect(Self.profileEncodeRefusal(reply, limits: try Self.limits(payload: 22, text: 0)) == nil)
        let destinationBroadcast = MIDICIProfileMessage.inquiry(try Self.header(.ci11))
        #expect(Self.profileEncodeRefusal(destinationBroadcast) == nil)
    }
}
