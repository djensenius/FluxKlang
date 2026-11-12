//
//  MIDICIMessageTests+ProfileReport.swift
//  FluxKlangTests
//
//  Profile Enabled (0x24), Disabled (0x25), Added (0x26) and Removed (0x27) Reports: hand-written goldens, decode,
//  encode, the CI 1.1 / CI 1.2 channel count, exact lengths, the broadcast destination, high bytes and the round
//  trip (#83, slice PIQ2).
//
//  Provenance: as in `MIDICIMessageTests+Profile.swift`, the layout was cross-checked against the public ktmidi and
//  JUCE sources (the MIDI Association specification was not reachable); the 18-byte CI 1.1 Enabled and Disabled
//  Report is JUCE's alone. No byte array was copied from either source; every value below is this slice's own.
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
        for sub: UInt8 in [0x22, 0x23, 0x28, 0x2F] {
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
