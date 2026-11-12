//
//  MIDICIMessageTests+ProfileReport.swift
//  FluxKlangTests
//
//  Profile Enabled (0x24), Disabled (0x25), Added (0x26) and Removed (0x27) Reports, and Set Profile On (0x22) and
//  Off (0x23): hand-written goldens, decode, encode, the CI 1.1 / CI 1.2 channel count and reserved bytes, exact
//  lengths, the broadcast or one-MUID destination, high bytes and the round trip (#83, slices PIQ2 and CIP1).
//
//  Provenance: as in `MIDICIMessageTests+Profile.swift`, the report layout was cross-checked against the public ktmidi
//  and JUCE sources; the 18-byte CI 1.1 Enabled and Disabled Report is JUCE's alone. The Set Profile On and Off
//  goldens were derived by hand from M2-101-UM v1.2, section 7.8 (Table 24), section 7.9 (Table 25) and section 3.3.3.
//  No byte array was copied from any source; every value below is this suite's own.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    // MARK: Report goldens (written by hand from the layout, never produced by the encoder)

    static let enabled12Zero = prefix(0x7F, 0x24, 0x02) + sourceBytes + broadcastBytes + profileA + [0x00, 0x00]
    static let enabled12Max = prefix(0x7E, 0x24, 0x02) + sourceBytes + broadcastBytes + profileC + [0x7F, 0x7F]
    static let disabled12One = prefix(0x00, 0x25, 0x02) + sourceBytes + broadcastBytes + profileB + [0x01, 0x00]
    static let disabled12High = prefix(0x10, 0x25, 0x02) + maximumBytes + broadcastBytes + profileE + [0x00, 0x01]
    static let enabled11 = prefix(0x10, 0x24, 0x01) + sourceBytes + broadcastBytes + profileD
    static let disabled11 = prefix(0x0F, 0x25, 0x01) + sourceBytes + broadcastBytes + profileA
    static let added12 = prefix(0x10, 0x26, 0x02) + sourceBytes + broadcastBytes + profileA
    static let added11 = prefix(0x7F, 0x26, 0x01) + maximumBytes + broadcastBytes + profileE
    static let removed12 = prefix(0x7E, 0x27, 0x02) + sourceBytes + broadcastBytes + profileB
    static let removed11 = prefix(0x00, 0x27, 0x01) + sourceBytes + broadcastBytes + profileC
    static let reportGoldens: [[UInt8]] = [
        enabled12Zero, enabled12Max, disabled12One, disabled12High, enabled11, disabled11,
        added12, added11, removed12, removed11
    ]

    static func reportMessages() throws -> [MIDICIProfileMessage] {
        let maximum: UInt32 = 0x0FFF_FEFF
        return [
            .enabledReport(try header(.ci12, device: 0x7F), profile: try profile(profileA), channels: 0),
            .enabledReport(try header(.ci12, device: 0x7E), profile: try profile(profileC), channels: 16_383),
            .disabledReport(try header(.ci12, device: 0x00), profile: try profile(profileB), channels: 1),
            .disabledReport(try header(.ci12, source: maximum), profile: try profile(profileE), channels: 128),
            .enabledReport(try header(.ci11), profile: try profile(profileD), channels: nil),
            .disabledReport(try header(.ci11, device: 0x0F), profile: try profile(profileA), channels: nil),
            .addedReport(try header(.ci12), profile: try profile(profileA)),
            .addedReport(try header(.ci11, device: 0x7F, source: maximum), profile: try profile(profileE)),
            .removedReport(try header(.ci12, device: 0x7E), profile: try profile(profileB)),
            .removedReport(try header(.ci11, device: 0x00), profile: try profile(profileC))
        ]
    }

    // MARK: Goldens, decode and encode

    @Test func everyReportEncodesToItsHandWrittenGoldenBytes() throws {
        let messages = try Self.reportMessages()
        try #require(messages.count == Self.reportGoldens.count)
        for (message, golden) in zip(messages, Self.reportGoldens) {
            #expect(try message.encode(limits: .standard) == golden)
        }
        #expect([Self.enabled12Zero, Self.enabled12Max, Self.disabled12One, Self.disabled12High].allSatisfy {
            $0.count == 20
        })
        #expect([Self.enabled11, Self.disabled11, Self.added12, Self.added11, Self.removed12, Self.removed11]
            .allSatisfy { $0.count == 18 })
    }

    @Test func everyReportGoldenDecodesToItsExactTypedValue() throws {
        let messages = try Self.reportMessages()
        try #require(messages.count == Self.reportGoldens.count)
        for (golden, message) in zip(Self.reportGoldens, messages) {
            #expect(try MIDICIProfileMessage.decode(payload: golden, limits: .standard) == message)
        }
        let kinds: [MIDICIProfileKind] = [
            .enabledReport, .enabledReport, .disabledReport, .disabledReport, .enabledReport, .disabledReport,
            .addedReport, .addedReport, .removedReport, .removedReport
        ]
        #expect(messages.map(\.kind) == kinds)
        let decoded = try MIDICIProfileMessage.decode(payload: Self.enabled12Max, limits: .standard)
        guard case let .enabledReport(header, profile, channels) = decoded else {
            Issue.record("expected a Profile Enabled Report")
            return
        }
        #expect(header.device.rawValue == 0x7E && header.format == .ci12 && header.destination.isBroadcast)
        #expect(header.source.rawValue == 0x0123_4567 && profile.bytes == Self.profileC && channels == 16_383)
        let legacy = try MIDICIProfileMessage.decode(payload: Self.disabled11, limits: .standard)
        guard case let .disabledReport(_, legacyProfile, legacyChannels) = legacy else {
            Issue.record("expected a Profile Disabled Report")
            return
        }
        #expect(legacyProfile.bytes == Self.profileA && legacyChannels == nil)
        let high = try MIDICIProfileMessage.decode(payload: Self.disabled12High, limits: .standard)
        guard case let .disabledReport(_, _, highChannels) = high else {
            Issue.record("expected a Profile Disabled Report")
            return
        }
        #expect(highChannels == 128)
    }

    @Test func everyReportSurvivesTheRoundTripInBothDirections() throws {
        for message in try Self.reportMessages() {
            let bytes = try message.encode(limits: .standard)
            #expect(try MIDICIProfileMessage.decode(payload: bytes, limits: .standard) == message)
        }
        for golden in Self.reportGoldens {
            let message = try MIDICIProfileMessage.decode(payload: golden, limits: .standard)
            #expect(try message.encode(limits: .standard) == golden)
        }
        for channels: UInt16 in [0, 1, 0x7F, 0x80, 0x2AAA, 0x3FFF] {
            let message = MIDICIProfileMessage.enabledReport(
                try Self.header(.ci12), profile: try Self.profile(Self.profileB), channels: channels)
            let bytes = try message.encode(limits: .standard)
            #expect(try MIDICIProfileMessage.decode(payload: bytes, limits: .standard) == message)
        }
    }

    @Test func theManagementDecoderStillRefusesTheReportSubIDs() throws {
        for (golden, sub) in [(Self.enabled12Zero, UInt8(0x24)), (Self.disabled11, 0x25), (Self.added12, 0x26),
                              (Self.removed11, 0x27)] {
            #expect(Self.decodeRefusal(golden) == .unknownSubID(sub))
        }
    }

    @Test func theProfileDecoderRefusesTheProfileSubIDsItDoesNotHandle() throws {
        for sub: UInt8 in [0x28, 0x2F] {
            let bytes = Self.replacing(Self.added12, at: 3, with: sub)
            #expect(Self.profileDecodeRefusal(bytes) == .unknownSubID(sub))
        }
    }

    // MARK: Exact length

    @Test func theChannelCountIsReadExactlyWhenTheFormatIsCI12() throws {
        let enabled11WithCount = Self.enabled11 + [0x01, 0x00]
        #expect(Self.profileDecodeRefusal(enabled11WithCount) == .trailingBytes(2))
        #expect(Self.profileDecodeRefusal(Self.disabled11 + [0x00, 0x00]) == .trailingBytes(2))
        let enabled12WithoutCount = Array(Self.enabled12Zero.prefix(18))
        #expect(Self.profileDecodeRefusal(enabled12WithoutCount) == .truncated(need: 20, have: 18))
        #expect(Self.profileDecodeRefusal(Array(Self.disabled12One.prefix(19))) == .truncated(need: 20, have: 19))
        #expect(Self.profileDecodeRefusal(Self.enabled12Max + [0x00]) == .trailingBytes(1))
        let formatSwapped = Self.replacing(Self.enabled12Zero, at: 4, with: 0x01)
        #expect(Self.profileDecodeRefusal(formatSwapped) == .trailingBytes(2))
    }

    @Test func addedAndRemovedReportsAreEighteenBytesInBothFormats() throws {
        #expect(Self.profileDecodeRefusal(Self.added12 + [0x00, 0x00]) == .trailingBytes(2))
        #expect(Self.profileDecodeRefusal(Self.removed11 + [0x00]) == .trailingBytes(1))
        #expect(Self.profileDecodeRefusal(Array(Self.added11.prefix(17))) == .truncated(need: 18, have: 17))
        #expect(Self.profileDecodeRefusal(Array(Self.removed12.prefix(13))) == .truncated(need: 18, have: 13))
    }

    @Test func everyPrefixOfAReportIsTruncatedAtItsFullLength() throws {
        for golden in Self.reportGoldens {
            for length in 13..<golden.count {
                let short = Array(golden.prefix(length))
                #expect(Self.profileDecodeRefusal(short) == .truncated(need: golden.count, have: length))
            }
        }
    }

    // MARK: Addressing and order

    @Test func aReportMustBeAddressedToBroadcast() throws {
        for golden in [Self.enabled12Zero, Self.disabled12One, Self.enabled11, Self.added12, Self.removed11] {
            let unicast = Self.replacing(golden, range: 9..<13, with: Self.maximumBytes)
            #expect(Self.profileDecodeRefusal(unicast) == .destinationNotBroadcast)
            let zero = Self.replacing(golden, range: 9..<13, with: Self.zeroBytes)
            #expect(Self.profileDecodeRefusal(zero) == .destinationNotBroadcast)
        }
        let inquiryToOne = try MIDICIProfileMessage.decode(payload: Self.inquiry11, limits: .standard)
        #expect(!inquiryToOne.header.destination.isBroadcast)
    }

    @Test func reportLengthBeatsMUIDsWhichBeatAddressingWhichBeatsTheDevice() throws {
        let unicast = Self.replacing(Self.enabled12Zero, range: 9..<13, with: Self.maximumBytes)
        #expect(Self.profileDecodeRefusal(Array(unicast.prefix(19))) == .truncated(need: 20, have: 19))
        #expect(Self.profileDecodeRefusal(unicast + [0x00]) == .trailingBytes(1))
        let reserved = Self.replacing(Self.added12, range: 9..<13, with: Self.reservedBytes)
        #expect(Self.profileDecodeRefusal(reserved) == .invalidMUID(0x0FFF_FF00))
        let broadcastSource = Self.replacing(Self.added12, range: 5..<9, with: Self.broadcastBytes)
        let bothWrong = Self.replacing(broadcastSource, range: 9..<13, with: Self.sourceBytes)
        #expect(Self.profileDecodeRefusal(bothWrong) == .sourceIsBroadcast)
        for device: UInt8 in [0x00, 0x0F, 0x7E, 0x7F] {
            #expect(Self.profileDecodeRefusal(Self.replacing(Self.disabled12One, at: 1, with: device)) == nil)
        }
    }

    @Test func aHighByteInAReportProfileIDOrChannelCountIsRefusedAtItsOffset() throws {
        for offset in 13..<20 {
            for value: UInt8 in [0x80, 0xFF] {
                let high = Self.replacing(Self.enabled12Max, at: offset, with: value)
                #expect(Self.profileDecodeRefusal(high) == .dataByteHigh(offset: offset))
            }
        }
        for offset in 13..<18 {
            #expect(Self.profileDecodeRefusal(Self.replacing(Self.removed12, at: offset, with: 0x90)) ==
                .dataByteHigh(offset: offset))
        }
        let highAndShort = Self.replacing(Array(Self.disabled12One.prefix(19)), at: 18, with: 0x81)
        #expect(Self.profileDecodeRefusal(highAndShort) == .dataByteHigh(offset: 18))
    }

    // MARK: Encode refusals

    @Test func encodeRefusesAMismatchBetweenTheFormatAndTheChannelCount() throws {
        let profile = try Self.profile(Self.profileA)
        let legacy = MIDICIProfileMessage.enabledReport(try Self.header(.ci11), profile: profile, channels: 0)
        #expect(Self.profileEncodeRefusal(legacy) == .channelCountNotAllowed)
        let missing = MIDICIProfileMessage.disabledReport(try Self.header(.ci12), profile: profile, channels: nil)
        #expect(Self.profileEncodeRefusal(missing) == .channelCountRequired)
        let over = MIDICIProfileMessage.enabledReport(try Self.header(.ci12), profile: profile, channels: 0x4000)
        #expect(Self.profileEncodeRefusal(over) == .fieldOutOfRange(.channelCount, value: 0x4000))
        let maximum = MIDICIProfileMessage.disabledReport(
            try Self.header(.ci12), profile: profile, channels: UInt16.max)
        #expect(Self.profileEncodeRefusal(maximum) == .fieldOutOfRange(.channelCount, value: 65_535))
        let atBound = MIDICIProfileMessage.enabledReport(try Self.header(.ci12), profile: profile, channels: 0x3FFF)
        #expect(try atBound.encode(limits: .standard).suffix(2) == [0x7F, 0x7F])
    }

    @Test func encodeChecksTheSourceThenTheDestinationThenTheBodyThenTheSize() throws {
        let profile = try Self.profile(Self.profileA)
        let unicast = try Self.header(.ci11, destination: 0x0123_4568)
        let broadcastSource = try Self.header(.ci11, source: 0x0FFF_FFFF, destination: 0x0123_4568)
        let both = MIDICIProfileMessage.enabledReport(broadcastSource, profile: profile, channels: 1)
        #expect(Self.profileEncodeRefusal(both) == .sourceIsBroadcast)
        let mismatchedToOne = MIDICIProfileMessage.enabledReport(unicast, profile: profile, channels: 1)
        #expect(Self.profileEncodeRefusal(mismatchedToOne) == .destinationNotBroadcast)
        #expect(Self.profileEncodeRefusal(.removedReport(unicast, profile: profile)) == .destinationNotBroadcast)
        let tiny = try Self.limits(payload: 13, text: 0)
        let mismatched = MIDICIProfileMessage.enabledReport(try Self.header(.ci11), profile: profile, channels: 1)
        #expect(Self.profileEncodeRefusal(mismatched, limits: tiny) == .channelCountNotAllowed)
        let outOfRange = MIDICIProfileMessage.enabledReport(try Self.header(.ci12), profile: profile, channels: 0x4000)
        #expect(Self.profileEncodeRefusal(outOfRange, limits: tiny) == .fieldOutOfRange(.channelCount, value: 0x4000))
        let report = MIDICIProfileMessage.enabledReport(try Self.header(.ci12), profile: profile, channels: 1)
        let limit19 = try Self.limits(payload: 19, text: 0)
        #expect(Self.profileEncodeRefusal(report, limits: limit19) == .payloadTooLarge(20))
        #expect(Self.profileEncodeRefusal(report, limits: try Self.limits(payload: 20, text: 0)) == nil)
        let added = MIDICIProfileMessage.addedReport(try Self.header(.ci12), profile: profile)
        #expect(Self.profileEncodeRefusal(added, limits: try Self.limits(payload: 17, text: 0)) == .payloadTooLarge(18))
    }
}

extension MIDICIMessageTests {
    // MARK: Set Profile On and Off goldens (written by hand from the layout, never produced by the encoder)

    static let setOn12One = prefix(0x10, 0x22, 0x02) + sourceBytes + maximumBytes + profileA + [0x01, 0x00]
    /// A count of 291 is `0x23, 0x02`: the low seven bits first.
    static let setOn12Many = prefix(0x00, 0x22, 0x02) + maximumBytes + sourceBytes + profileC + [0x23, 0x02]
    static let setOn12Max = prefix(0x0F, 0x22, 0x02) + sourceBytes + maximumBytes + profileB + [0x7F, 0x7F]
    static let setOn12Group = prefix(0x7E, 0x22, 0x02) + sourceBytes + maximumBytes + profileD + [0x00, 0x00]
    static let setOn12Block = prefix(0x7F, 0x22, 0x02) + sourceBytes + maximumBytes + profileE + [0x00, 0x00]
    static let setOn11 = prefix(0x10, 0x22, 0x01) + sourceBytes + maximumBytes + profileA
    static let setOff12 = prefix(0x10, 0x23, 0x02) + sourceBytes + maximumBytes + profileB + [0x00, 0x00]
    static let setOff11 = prefix(0x00, 0x23, 0x01) + maximumBytes + sourceBytes + profileD
    /// Reserved bytes that are not zero: decoded, never kept, written back as zeros.
    static let setOff12Reserved = prefix(0x7F, 0x23, 0x02) + sourceBytes + maximumBytes + profileC + [0x05, 0x7F]
    static let setProfileGoldens: [[UInt8]] = [
        setOn12One, setOn12Many, setOn12Max, setOn12Group, setOn12Block, setOn11, setOff12, setOff11
    ]

    static func setProfileMessages() throws -> [MIDICIProfileMessage] {
        let maximum: UInt32 = 0x0FFF_FEFF
        let peer: UInt32 = 0x0123_4567
        return [
            .setProfileOn(try header(.ci12, destination: maximum), profile: try profile(profileA), channels: 1),
            .setProfileOn(try header(.ci12, device: 0x00, source: maximum, destination: peer),
                          profile: try profile(profileC), channels: 291),
            .setProfileOn(try header(.ci12, device: 0x0F, destination: maximum),
                          profile: try profile(profileB), channels: 16_383),
            .setProfileOn(try header(.ci12, device: 0x7E, destination: maximum),
                          profile: try profile(profileD), channels: 0),
            .setProfileOn(try header(.ci12, device: 0x7F, destination: maximum),
                          profile: try profile(profileE), channels: 0),
            .setProfileOn(try header(.ci11, destination: maximum), profile: try profile(profileA), channels: nil),
            .setProfileOff(try header(.ci12, destination: maximum), profile: try profile(profileB)),
            .setProfileOff(try header(.ci11, device: 0x00, source: maximum, destination: peer),
                           profile: try profile(profileD))
        ]
    }

    // MARK: Set Profile goldens, decode and encode

    @Test func everySetProfileMessageEncodesToItsHandWrittenGoldenBytes() throws {
        let messages = try Self.setProfileMessages()
        try #require(messages.count == Self.setProfileGoldens.count)
        for (message, golden) in zip(messages, Self.setProfileGoldens) {
            #expect(try message.encode(limits: .standard) == golden)
        }
        #expect(Self.setProfileGoldens.map(\.count) == [20, 20, 20, 20, 20, 18, 20, 18])
    }

    @Test func everySetProfileGoldenDecodesToItsExactTypedValue() throws {
        let messages = try Self.setProfileMessages()
        try #require(messages.count == Self.setProfileGoldens.count)
        for (golden, message) in zip(Self.setProfileGoldens, messages) {
            #expect(try MIDICIProfileMessage.decode(payload: golden, limits: .standard) == message)
        }
        let kinds = Array(repeating: MIDICIProfileKind.setProfileOn, count: 6) + [.setProfileOff, .setProfileOff]
        #expect(messages.map(\.kind) == kinds)
        let many = try MIDICIProfileMessage.decode(payload: Self.setOn12Many, limits: .standard)
        guard case let .setProfileOn(header, profile, channels) = many else {
            Issue.record("expected a Set Profile On")
            return
        }
        #expect(header.device.rawValue == 0x00 && header.format == .ci12 && !header.destination.isBroadcast)
        #expect(header.source.rawValue == 0x0FFF_FEFF && header.destination.rawValue == 0x0123_4567)
        #expect(profile.bytes == Self.profileC && channels == 291)
    }

    @Test func setProfileOffIgnoresItsReservedBytesOnDecodeAndWritesZerosOnEncode() throws {
        let expected = MIDICIProfileMessage.setProfileOff(
            try Self.header(.ci12, device: 0x7F, destination: 0x0FFF_FEFF), profile: try Self.profile(Self.profileC))
        for reserved: [UInt8] in [[0x00, 0x00], [0x05, 0x7F], [0x01, 0x00], [0x00, 0x01], [0x7F, 0x7F]] {
            let payload = Self.replacing(Self.setOff12Reserved, range: 18..<20, with: reserved)
            #expect(try MIDICIProfileMessage.decode(payload: payload, limits: .standard) == expected)
        }
        let zeros = Self.replacing(Self.setOff12Reserved, range: 18..<20, with: [0x00, 0x00])
        #expect(try expected.encode(limits: .standard) == zeros)
        #expect(try expected.encode(limits: .standard) != Self.setOff12Reserved)
    }

    @Test func everySetProfileMessageSurvivesTheRoundTripInBothDirections() throws {
        for message in try Self.setProfileMessages() {
            let bytes = try message.encode(limits: .standard)
            #expect(try MIDICIProfileMessage.decode(payload: bytes, limits: .standard) == message)
        }
        for golden in Self.setProfileGoldens {
            let message = try MIDICIProfileMessage.decode(payload: golden, limits: .standard)
            #expect(try message.encode(limits: .standard) == golden)
        }
        // The count is carried, never interpreted: no pairing with the device id is refused.
        for device: UInt8 in [0x00, 0x10, 0x7E, 0x7F] {
            for channels: UInt16 in [0, 1, 0x7F, 0x80, 0x2AAA, 0x3FFF] {
                let message = MIDICIProfileMessage.setProfileOn(
                    try Self.header(.ci12, device: device, destination: 0x0FFF_FEFF),
                    profile: try Self.profile(Self.profileB), channels: channels)
                let bytes = try message.encode(limits: .standard)
                #expect(try MIDICIProfileMessage.decode(payload: bytes, limits: .standard) == message)
            }
        }
    }

    @Test func theManagementDecoderStillRefusesTheSetProfileSubIDs() throws {
        for (golden, sub) in [(Self.setOn12One, UInt8(0x22)), (Self.setOn11, 0x22), (Self.setOff12, 0x23),
                              (Self.setOff11, 0x23)] {
            #expect(Self.decodeRefusal(golden) == .unknownSubID(sub))
        }
    }

    // MARK: Set Profile exact length

    @Test func theSetProfileCountAndReservedBytesAreReadExactlyWhenTheFormatIsCI12() throws {
        #expect(Self.profileDecodeRefusal(Self.setOn11 + [0x01, 0x00]) == .trailingBytes(2))
        #expect(Self.profileDecodeRefusal(Self.setOff11 + [0x00, 0x00]) == .trailingBytes(2))
        #expect(Self.profileDecodeRefusal(Array(Self.setOn12One.prefix(18))) == .truncated(need: 20, have: 18))
        #expect(Self.profileDecodeRefusal(Array(Self.setOff12.prefix(19))) == .truncated(need: 20, have: 19))
        #expect(Self.profileDecodeRefusal(Self.setOn12Max + [0x00]) == .trailingBytes(1))
        #expect(Self.profileDecodeRefusal(Self.setOff12 + [0x00]) == .trailingBytes(1))
        let on11AsCI12 = Self.replacing(Self.setOn11, at: 4, with: 0x02)
        #expect(Self.profileDecodeRefusal(on11AsCI12) == .truncated(need: 20, have: 18))
        let off12AsCI11 = Self.replacing(Self.setOff12, at: 4, with: 0x01)
        #expect(Self.profileDecodeRefusal(off12AsCI11) == .trailingBytes(2))
    }

    @Test func everyPrefixOfASetProfileMessageIsTruncatedAtItsFullLength() throws {
        for golden in Self.setProfileGoldens + [Self.setOff12Reserved] {
            for length in 5..<golden.count {
                let need = length < 13 ? 13 : golden.count
                #expect(Self.profileDecodeRefusal(Array(golden.prefix(length))) == .truncated(need: need, have: length))
            }
        }
    }

    // MARK: Set Profile addressing and order

    @Test func aSetProfileMessageMustBeAddressedToOneMUIDNeverToBroadcast() throws {
        for golden in Self.setProfileGoldens + [Self.setOff12Reserved] {
            let broadcast = Self.replacing(golden, range: 9..<13, with: Self.broadcastBytes)
            #expect(Self.profileDecodeRefusal(broadcast) == .destinationIsBroadcast)
            for one in [Self.zeroBytes, Self.maximumBytes] {
                #expect(Self.profileDecodeRefusal(Self.replacing(golden, range: 9..<13, with: one)) == nil)
            }
        }
        let reportToOne = Self.replacing(Self.added12, range: 9..<13, with: Self.maximumBytes)
        #expect(Self.profileDecodeRefusal(reportToOne) == .destinationNotBroadcast)
    }

    @Test func setProfileLengthBeatsMUIDsWhichBeatAddressingWhichBeatsTheDevice() throws {
        let broadcast = Self.replacing(Self.setOn12One, range: 9..<13, with: Self.broadcastBytes)
        #expect(Self.profileDecodeRefusal(Array(broadcast.prefix(19))) == .truncated(need: 20, have: 19))
        #expect(Self.profileDecodeRefusal(broadcast + [0x00]) == .trailingBytes(1))
        let reservedSource = Self.replacing(broadcast, range: 5..<9, with: Self.reservedBytes)
        #expect(Self.profileDecodeRefusal(reservedSource) == .invalidMUID(0x0FFF_FF00))
        let reservedDestination = Self.replacing(Self.setOff11, range: 9..<13, with: Self.reservedBytes)
        #expect(Self.profileDecodeRefusal(reservedDestination) == .invalidMUID(0x0FFF_FF00))
        let broadcastSource = Self.replacing(broadcast, range: 5..<9, with: Self.broadcastBytes)
        #expect(Self.profileDecodeRefusal(broadcastSource) == .sourceIsBroadcast)
        for device: UInt8 in [0x00, 0x0F, 0x7E, 0x7F] {
            #expect(Self.profileDecodeRefusal(Self.replacing(Self.setOn12One, at: 1, with: device)) == nil)
        }
        for format: UInt8 in [0x00, 0x03, 0x7F] {
            for golden in [Self.setOn12One, Self.setOff12] {
                let unsupported = Self.replacing(golden, at: 4, with: format)
                #expect(Self.profileDecodeRefusal(unsupported) == .unsupportedFormat(format))
            }
            #expect(Self.profileDecodeRefusal([0x7E, 0x10, 0x0D, 0x22, format]) == .unsupportedFormat(format))
        }
    }

    @Test func aHighByteInASetProfileFieldIsRefusedAtItsOffset() throws {
        for golden in Self.setProfileGoldens + [Self.setOff12Reserved] {
            for offset in 13..<golden.count {
                for value: UInt8 in [0x80, 0xFF] {
                    let high = Self.replacing(golden, at: offset, with: value)
                    #expect(Self.profileDecodeRefusal(high) == .dataByteHigh(offset: offset))
                }
            }
        }
        let highAndShort = Self.replacing(Array(Self.setOn12One.prefix(19)), at: 18, with: 0x81)
        #expect(Self.profileDecodeRefusal(highAndShort) == .dataByteHigh(offset: 18))
    }

    @Test func aHostileSetProfileLengthIsRefusedBeforeAnyFieldIsRead() throws {
        for sub: UInt8 in [0x22, 0x23] {
            let full = Self.prefix(0x10, sub, 0x02) + [UInt8](repeating: 0x7F, count: 4_091)
            #expect(full.count == 4_096)
            #expect(Self.profileDecodeRefusal(full) == .trailingBytes(4_076))
            #expect(Self.profileDecodeRefusal(full + [0x7F]) == .payloadTooLarge(4_097))
            #expect(Self.profileDecodeRefusal(full + [0xFF]) == .payloadTooLarge(4_097))
            #expect(Self.profileDecodeRefusal(Self.replacing(full, at: 4, with: 0x01)) == .trailingBytes(4_078))
        }
        #expect(Self.profileDecodeRefusal(Self.setOn12Max, limits: try Self.limits(payload: 19, text: 0)) ==
            .payloadTooLarge(20))
        #expect(Self.profileDecodeRefusal(Self.setOff12, limits: try Self.limits(payload: 20, text: 0)) == nil)
    }

    // MARK: Set Profile encode refusals

    @Test func encodeRefusesAMismatchBetweenTheFormatAndTheSetProfileOnChannelCount() throws {
        let profile = try Self.profile(Self.profileA)
        let toOne: UInt32 = 0x0FFF_FEFF
        let legacy = MIDICIProfileMessage.setProfileOn(
            try Self.header(.ci11, destination: toOne), profile: profile, channels: 0)
        #expect(Self.profileEncodeRefusal(legacy) == .channelCountNotAllowed)
        let missing = MIDICIProfileMessage.setProfileOn(
            try Self.header(.ci12, destination: toOne), profile: profile, channels: nil)
        #expect(Self.profileEncodeRefusal(missing) == .channelCountRequired)
        for channels: UInt16 in [0x4000, 0x8000, UInt16.max] {
            let over = MIDICIProfileMessage.setProfileOn(
                try Self.header(.ci12, destination: toOne), profile: profile, channels: channels)
            #expect(Self.profileEncodeRefusal(over) == .fieldOutOfRange(.channelCount, value: Int(channels)))
        }
        let atBound = MIDICIProfileMessage.setProfileOn(
            try Self.header(.ci12, destination: toOne), profile: profile, channels: 0x3FFF)
        #expect(try atBound.encode(limits: .standard).suffix(2) == [0x7F, 0x7F])
    }

    @Test func encodeChecksTheSetProfileSourceThenTheDestinationThenTheBodyThenTheSize() throws {
        let profile = try Self.profile(Self.profileA)
        let toOne: UInt32 = 0x0FFF_FEFF
        for header in [try Self.header(.ci12, source: 0x0FFF_FFFF, destination: toOne),
                       try Self.header(.ci12, source: 0x0FFF_FFFF)] {
            let enable = MIDICIProfileMessage.setProfileOn(header, profile: profile, channels: 1)
            #expect(Self.profileEncodeRefusal(enable) == .sourceIsBroadcast)
            #expect(Self.profileEncodeRefusal(.setProfileOff(header, profile: profile)) == .sourceIsBroadcast)
        }
        let toBroadcast = try Self.header(.ci12)
        let onToBroadcast = MIDICIProfileMessage.setProfileOn(toBroadcast, profile: profile, channels: 1)
        #expect(Self.profileEncodeRefusal(onToBroadcast) == .destinationIsBroadcast)
        #expect(Self.profileEncodeRefusal(.setProfileOff(toBroadcast, profile: profile)) == .destinationIsBroadcast)
        let wrongToBroadcast = MIDICIProfileMessage.setProfileOn(try Self.header(.ci11), profile: profile, channels: 1)
        #expect(Self.profileEncodeRefusal(wrongToBroadcast) == .destinationIsBroadcast)
        let tiny = try Self.limits(payload: 13, text: 0)
        let mismatched = MIDICIProfileMessage.setProfileOn(
            try Self.header(.ci11, destination: toOne), profile: profile, channels: 1)
        #expect(Self.profileEncodeRefusal(mismatched, limits: tiny) == .channelCountNotAllowed)
        let outOfRange = MIDICIProfileMessage.setProfileOn(
            try Self.header(.ci12, destination: toOne), profile: profile, channels: 0x4000)
        #expect(Self.profileEncodeRefusal(outOfRange, limits: tiny) == .fieldOutOfRange(.channelCount, value: 0x4000))
        let ci12 = try Self.header(.ci12, destination: toOne)
        let ci11 = try Self.header(.ci11, destination: toOne)
        let sized: [(MIDICIProfileMessage, Int)] = [
            (.setProfileOn(ci12, profile: profile, channels: 1), 20), (.setProfileOff(ci12, profile: profile), 20),
            (.setProfileOn(ci11, profile: profile, channels: nil), 18), (.setProfileOff(ci11, profile: profile), 18)
        ]
        for (message, size) in sized {
            let below = try Self.limits(payload: size - 1, text: 0)
            #expect(Self.profileEncodeRefusal(message, limits: below) == .payloadTooLarge(size))
            #expect(Self.profileEncodeRefusal(message, limits: try Self.limits(payload: size, text: 0)) == nil)
        }
    }
}
