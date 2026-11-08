//
//  MIDICIMessageTests+Decode.swift
//  FluxKlangTests
//
//  Decoding: exact typed values for every golden, every truncated prefix, the 7-bit check at every offset, exact
//  lengths, sub-id and format handling, MUID and addressing refusals, and the parser-to-decode path (#83, CI1).
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    static func replacing(_ bytes: [UInt8], at offset: Int, with value: UInt8) -> [UInt8] {
        var copy = bytes
        copy[offset] = value
        return copy
    }

    static func replacing(_ bytes: [UInt8], range: Range<Int>, with values: [UInt8]) -> [UInt8] {
        var copy = bytes
        copy.replaceSubrange(range, with: values)
        return copy
    }

    @Test func decodeReadsEveryGoldenToItsExactTypedValue() throws {
        let messages = try Self.messages()
        try #require(messages.count == Self.goldens.count)
        for (golden, message) in zip(Self.goldens, messages) {
            #expect(try MIDICIMessage.decode(payload: golden, limits: .standard) == message)
        }
        let decoded = try MIDICIMessage.decode(payload: Self.discovery12, limits: .standard)
        guard case let .discovery(header, info) = decoded else {
            Issue.record("expected a Discovery message")
            return
        }
        #expect(header.device.rawValue == 0x10 && header.format == .ci12)
        #expect(header.source.rawValue == 0x0123_4567 && header.destination.isBroadcast)
        #expect(info.identity.manufacturer == [0x00, 0x20, 0x29] && info.identity.softwareRevision == [5, 6, 7, 8])
        #expect(info.identity.family == 0x0101 && info.identity.model == 0x0203)
        #expect(info.capabilityCategory == 0x0E && info.maximumSysExSize == 4_096 && info.outputPathID == 0x03)
    }

    @Test func aDecodedAckCarriesItsStatusFieldsDetailsAndTextVerbatim() throws {
        let decoded = try MIDICIMessage.decode(payload: Self.ack, limits: .standard)
        guard case let .ack(header, report) = decoded else {
            Issue.record("expected an ACK message")
            return
        }
        #expect(header.destination.rawValue == 0 && header.format == .ci12)
        #expect(report.originalSubID == 0x70 && report.statusCode == 0x01 && report.statusData == 0x02)
        #expect(report.details == [1, 2, 3, 4, 5] && report.text == "OK")
        guard case let .nak(_, optionalReport) = try MIDICIMessage.decode(payload: Self.nak, limits: .standard),
              let nakReport = optionalReport else {
            Issue.record("expected a CI 1.2 NAK message with a report")
            return
        }
        #expect(nakReport.originalSubID == 0x34 && nakReport.details == [10, 11, 12, 13, 14] && nakReport.text.isEmpty)
    }

    @Test func aDecodedReplyCarriesItsFunctionBlockAndANAKInCIOneOneCarriesNoReport() throws {
        guard case let .discoveryReply(_, info, block) = try MIDICIMessage.decode(
            payload: Self.reply12, limits: .standard) else {
            Issue.record("expected a Discovery Reply")
            return
        }
        #expect(block == 0x05 && info.outputPathID == 0x7F)
        guard case let .discoveryReply(_, info11, block11) = try MIDICIMessage.decode(
            payload: Self.reply11, limits: .standard) else {
            Issue.record("expected a Discovery Reply")
            return
        }
        #expect(block11 == nil && info11.outputPathID == nil)
        guard case let .nak(header, report) = try MIDICIMessage.decode(payload: Self.nak11, limits: .standard) else {
            Issue.record("expected a NAK message")
            return
        }
        #expect(report == nil && header.format == .ci11 && header.destination.rawValue == 0x0123_4567)
    }

    @Test func everyTruncatedPrefixOfEveryGoldenReportsWhatItNeededAndHad() throws {
        for golden in Self.goldens {
            for have in 0..<golden.count {
                let prefix = Array(golden[0..<have])
                let need: Int
                switch have {
                case 0: need = 1
                case 1..<5: need = 5
                case 5..<13: need = 13
                default: need = ((golden[3] == 0x7D || golden[3] == 0x7F) && have < 23) ? 23 : golden.count
                }
                #expect(Self.decodeRefusal(prefix) == .truncated(need: need, have: have))
            }
        }
    }

    @Test func aHighBitAtEachOffsetAfterTheFirstReportsThatOffsetAndOffsetTwoIsNotCI() throws {
        for golden in Self.goldens {
            for offset in 1..<golden.count where offset != 2 {
                let bytes = Self.replacing(golden, at: offset, with: 0x80)
                #expect(Self.decodeRefusal(bytes) == .dataByteHigh(offset: offset))
            }
            #expect(Self.decodeRefusal(Self.replacing(golden, at: 2, with: 0x8D)) == .notCI)
        }
        let last = Self.replacing(Self.ack, at: Self.ack.count - 1, with: 0xFF)
        #expect(Self.decodeRefusal(last) == .dataByteHigh(offset: Self.ack.count - 1))
        #expect(Self.decodeRefusal([0x7E, 0x80]) == .dataByteHigh(offset: 1))
        #expect(Self.decodeRefusal([0x7E, 0x00, 0x0D, 0x70, 0x80]) == .dataByteHigh(offset: 4))
    }

    @Test func theFirstOfSeveralHighBytesIsTheOneReported() throws {
        let both = Self.replacing(Self.replacing(Self.discovery11, at: 20, with: 0x90), at: 7, with: 0xA0)
        #expect(Self.decodeRefusal(both) == .dataByteHigh(offset: 7))
        let late = Self.replacing(Self.replacing(Self.discovery11, at: 28, with: 0x80), at: 21, with: 0x81)
        #expect(Self.decodeRefusal(late) == .dataByteHigh(offset: 21))
    }

    @Test func oneOrManyExtraBytesAreTrailingAndEveryExactLengthDecodes() throws {
        for golden in Self.goldens {
            #expect(throws: Never.self) { try MIDICIMessage.decode(payload: golden, limits: .standard) }
            #expect(Self.decodeRefusal(golden + [0x00]) == .trailingBytes(1))
            #expect(Self.decodeRefusal(golden + [0x01, 0x02, 0x03]) == .trailingBytes(3))
        }
    }

    @Test func anAckDeclaringMoreTextThanItCarriesIsTruncatedAndOneDeclaringLessHasTrailingBytes() throws {
        let more = Self.replacing(Self.ack, at: 21, with: 0x03)
        let fewer = Self.replacing(Self.ack, at: 21, with: 0x01)
        let zero = Self.replacing(Self.ack, at: 21, with: 0x00)
        #expect(Self.decodeRefusal(more) == .truncated(need: 26, have: 25))
        #expect(Self.decodeRefusal(fewer) == .trailingBytes(1))
        #expect(Self.decodeRefusal(zero) == .trailingBytes(2))
        let limits = try Self.limits(payload: 4_096, text: 2)
        #expect(throws: Never.self) { try MIDICIMessage.decode(payload: Self.ack, limits: limits) }
        let tooLong = Self.replacing(Self.ack, range: 21..<25, with: [0x03, 0x00, 0x41, 0x42, 0x43])
        #expect(Self.decodeRefusal(tooLong, limits: limits) == .textTooLong(3))
        let tooLongAndTrailing = Self.replacing(Self.ack, range: 21..<25, with: [0x03, 0x00, 0x41, 0x42, 0x43, 0x44])
        #expect(Self.decodeRefusal(tooLongAndTrailing, limits: limits) == .textTooLong(3))
        let tooLongAndTruncated = Self.replacing(Self.ack, range: 21..<25, with: [0x03, 0x00, 0x41])
        #expect(Self.decodeRefusal(tooLongAndTruncated, limits: limits) == .textTooLong(3))
    }

    @Test func aTextLengthOfTwoFiftySixDecodesAndTwoFiftySevenIsRefusedWhetherOrNotItsBytesFollow() throws {
        let text = [UInt8](repeating: 0x61, count: 256)
        let full = Array(Self.ack[0..<21]) + [0x00, 0x02] + text
        let decoded = try MIDICIMessage.decode(payload: full, limits: .standard)
        guard case let .ack(_, report) = decoded else {
            Issue.record("expected an ACK message")
            return
        }
        #expect(report.text.utf8.count == 256)
        let over = Array(Self.ack[0..<21]) + [0x01, 0x02] + text + [0x61]
        #expect(Self.decodeRefusal(over) == .textTooLong(257))
        let hugeDeclared = Array(Self.ack[0..<21]) + [0x7F, 0x7F]
        #expect(Self.decodeRefusal(hugeDeclared) == .textTooLong(16_383))
        let overWithoutText = Array(Self.ack[0..<21]) + [0x01, 0x02]
        #expect(Self.decodeRefusal(overWithoutText) == .textTooLong(257))
    }

    @Test func everyUnknownSubIDIsRefusedWithItsValueAndEveryKnownOneMapsToItsKind() throws {
        let known: Set<UInt8> = [0x70, 0x71, 0x7D, 0x7E, 0x7F]
        for sub in UInt8(0)...0x7F where !known.contains(sub) {
            let bytes = Self.replacing(Self.discovery11, at: 3, with: sub)
            #expect(Self.decodeRefusal(bytes) == .unknownSubID(sub))
        }
        let kinds: [UInt8: MIDICIKind] = [
            0x70: .discovery, 0x71: .discoveryReply, 0x7D: .ack, 0x7E: .invalidateMUID, 0x7F: .nak
        ]
        let goldens = [Self.discovery11, Self.reply11, Self.ack, Self.invalidate, Self.nak]
        try #require(goldens.count == kinds.count)
        for golden in goldens {
            let message = try MIDICIMessage.decode(payload: golden, limits: .standard)
            #expect(message.kind == kinds[golden[3]])
        }
    }

    @Test func formatsZeroThreeAndAboveAreUnsupportedWhileOneAndTwoDecode() throws {
        for format: UInt8 in [0x00, 0x03, 0x04, 0x7F] {
            let bytes = Self.replacing(Self.discovery11, at: 4, with: format)
            #expect(Self.decodeRefusal(bytes) == .unsupportedFormat(format))
        }
        #expect(Self.decodeRefusal(Self.discovery11) == nil)
        #expect(Self.decodeRefusal(Self.discovery12) == nil)
        let asTwelve = Self.replacing(Self.discovery11, at: 4, with: 0x02)
        #expect(Self.decodeRefusal(asTwelve) == .truncated(need: 30, have: 29))
        let asEleven = Self.replacing(Self.discovery12, at: 4, with: 0x01)
        #expect(Self.decodeRefusal(asEleven) == .trailingBytes(1))
    }

    @Test func aDiscoveryReplyMustBeExactly29BytesInCIOneOneAnd31InCIOneTwo() throws {
        #expect(Self.decodeRefusal(Self.replacing(Self.reply11, at: 4, with: 0x02)) == .truncated(need: 31, have: 29))
        #expect(Self.decodeRefusal(Self.replacing(Self.reply12, at: 4, with: 0x01)) == .trailingBytes(2))
        #expect(Self.decodeRefusal(Array(Self.reply12.dropLast())) == .truncated(need: 31, have: 30))
        #expect(Self.decodeRefusal(Self.reply11 + [0x00]) == .trailingBytes(1))
        #expect(Self.decodeRefusal(Self.reply12 + [0x00]) == .trailingBytes(1))
        let blockZero = Self.replacing(Self.reply12, at: 30, with: 0x00)
        #expect(throws: Never.self) { try MIDICIMessage.decode(payload: blockZero, limits: .standard) }
    }

    @Test func aNAKMustBeExactlyThe13ByteHeaderInCIOneOneAndAtLeast23BytesInCIOneTwo() throws {
        #expect(Self.decodeRefusal(Self.nak11) == nil)
        #expect(Self.decodeRefusal(Array(Self.nak11.dropLast())) == .truncated(need: 13, have: 12))
        #expect(Self.decodeRefusal(Self.nak11 + [0x00]) == .trailingBytes(1))
        let oldLongForm = Self.replacing(Self.nak, at: 4, with: 0x01)
        #expect(Self.decodeRefusal(oldLongForm) == .trailingBytes(10))
        let headerOnly12 = Self.replacing(Self.nak11, at: 4, with: 0x02)
        #expect(Self.decodeRefusal(headerOnly12) == .truncated(need: 23, have: 13))
    }

    @Test func anACKInCIOneOneIsUnsupportedBeforeAShortLengthRefusal() throws {
        let ack11 = Self.replacing(Self.ack, at: 4, with: 0x01)
        #expect(Self.decodeRefusal(ack11) == .unsupportedFormat(1))
        let shortAck11: [UInt8] = [0x7E, 0x7F, 0x0D, 0x7D, 0x01, 0x00]
        #expect(Self.decodeRefusal(shortAck11) == .unsupportedFormat(1))
        let shortAck12: [UInt8] = [0x7E, 0x7F, 0x0D, 0x7D, 0x02, 0x00]
        #expect(Self.decodeRefusal(shortAck12) == .truncated(need: 13, have: 6))
    }

    @Test func aPayloadThatIsNotUniversalNonRealTimeMIDICIIsNotCI() throws {
        let identityReply: [UInt8] = [0x7E, 0x10, 0x06, 0x02, 0x00, 0x20, 0x29]
        let realTime = Self.replacing(Self.discovery11, at: 0, with: 0x7F)
        let otherSubID = Self.replacing(Self.discovery11, at: 2, with: 0x0C)
        #expect(Self.decodeRefusal(identityReply) == .notCI)
        #expect(Self.decodeRefusal(realTime) == .notCI)
        #expect(Self.decodeRefusal(otherSubID) == .notCI)
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0C]) == .notCI)
        #expect(Self.decodeRefusal([0x00]) == .notCI)
        #expect(Self.decodeRefusal([0x7E]) == .truncated(need: 5, have: 1))
        #expect(Self.decodeRefusal([0x7E, 0x10]) == .truncated(need: 5, have: 2))
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0D]) == .truncated(need: 5, have: 3))
    }

    @Test func decodeRefusesBroadcastSourcesReservedMUIDsAndWrongDestinationsForEveryKind() throws {
        for golden in [Self.discovery11, Self.reply11, Self.invalidate, Self.ack, Self.nak, Self.nak11] {
            let broadcastSource = Self.replacing(golden, range: 5..<9, with: Self.broadcastBytes)
            #expect(Self.decodeRefusal(broadcastSource) == .sourceIsBroadcast)
            let reservedSource = Self.replacing(golden, range: 5..<9, with: Self.reservedBytes)
            #expect(Self.decodeRefusal(reservedSource) == .invalidMUID(0x0FFF_FF00))
            let reservedDestination = Self.replacing(golden, range: 9..<13, with: [0x7E, 0x7F, 0x7F, 0x7F])
            #expect(Self.decodeRefusal(reservedDestination) == .invalidMUID(0x0FFF_FFFE))
        }
        let specific = Self.replacing(Self.discovery11, range: 9..<13, with: Self.sourceBytes)
        #expect(Self.decodeRefusal(specific) == .destinationNotBroadcast)
        let invalidateSpecific = Self.replacing(Self.invalidate, range: 9..<13, with: Self.zeroBytes)
        #expect(Self.decodeRefusal(invalidateSpecific) == .destinationNotBroadcast)
        let ackBroadcast = Self.replacing(Self.ack, range: 9..<13, with: Self.broadcastBytes)
        #expect(Self.decodeRefusal(ackBroadcast) == .destinationIsBroadcast)
        let nakBroadcast = Self.replacing(Self.nak, range: 5..<13, with: Self.sourceBytes + Self.broadcastBytes)
        #expect(Self.decodeRefusal(nakBroadcast) == .destinationIsBroadcast)
        let nak11Broadcast = Self.replacing(Self.nak11, range: 5..<13, with: Self.sourceBytes + Self.broadcastBytes)
        #expect(Self.decodeRefusal(nak11Broadcast) == .destinationIsBroadcast)
        let replyBroadcast = Self.replacing(Self.reply11, range: 9..<13, with: Self.broadcastBytes)
        #expect(throws: Never.self) { try MIDICIMessage.decode(payload: replyBroadcast, limits: .standard) }
        let replyUnicast = Self.replacing(Self.reply11, range: 9..<13, with: Self.sourceBytes)
        #expect(throws: Never.self) { try MIDICIMessage.decode(payload: replyUnicast, limits: .standard) }
    }

    @Test func theInvalidateTargetMayNotBeReservedOrBroadcastButMayBeZeroOrTheMaximum() throws {
        let broadcast = Self.replacing(Self.invalidate, range: 13..<17, with: Self.broadcastBytes)
        let reserved = Self.replacing(Self.invalidate, range: 13..<17, with: Self.reservedBytes)
        #expect(Self.decodeRefusal(broadcast) == .targetIsBroadcast)
        #expect(Self.decodeRefusal(reserved) == .invalidMUID(0x0FFF_FF00))
        let zero = Self.replacing(Self.invalidate, range: 13..<17, with: Self.zeroBytes)
        guard case let .invalidateMUID(_, target) = try MIDICIMessage.decode(payload: zero, limits: .standard) else {
            Issue.record("expected an Invalidate MUID message")
            return
        }
        #expect(target.rawValue == 0)
    }

    @Test func aMUIDOfZeroAndTheMaximumAssignableValueDecodeAsSources() throws {
        for (bytes, raw) in [(Self.zeroBytes, UInt32(0)), (Self.maximumBytes, UInt32(0x0FFF_FEFF))] {
            let payload = Self.replacing(Self.reply11, range: 5..<9, with: bytes)
            let decoded = try MIDICIMessage.decode(payload: payload, limits: .standard)
            guard case let .discoveryReply(header, _, _) = decoded else {
                Issue.record("expected a Discovery Reply")
                return
            }
            #expect(header.source.rawValue == raw)
        }
    }

    @Test func decodeBoundsThePayloadAtTheLimitAndOneBeyond() throws {
        let exactly = [0x7E, 0x10, 0x0D, 0x20, 0x01] + [UInt8](repeating: 0x00, count: 4_091)
        #expect(exactly.count == 4_096)
        #expect(Self.decodeRefusal(exactly) == .unknownSubID(0x20))
        #expect(Self.decodeRefusal(exactly + [0x00]) == .payloadTooLarge(4_097))
        let tight = try Self.limits(payload: 29, text: 256)
        #expect(throws: Never.self) { try MIDICIMessage.decode(payload: Self.discovery11, limits: tight) }
        #expect(Self.decodeRefusal(Self.discovery12, limits: tight) == .payloadTooLarge(30))
        let one = try Self.limits(payload: 1, text: 0)
        #expect(Self.decodeRefusal([0x7E], limits: one) == .truncated(need: 5, have: 1))
        #expect(Self.decodeRefusal([0x7E, 0x10], limits: one) == .payloadTooLarge(2))
    }

    @Test func everyAsciiValueIncludingControlBytesInAckTextRoundTripsThroughScalars() throws {
        let scalars = (0..<128).map { Character(Unicode.Scalar(UInt8($0))) }
        let text = String(scalars)
        let message = MIDICIMessage.ack(try Self.header(.ci12, destination: 1), try Self.report(text: text))
        let limits = try Self.limits(payload: 4_096, text: 128)
        let bytes = try message.encode(limits: limits)
        try #require(bytes.count == 23 + 128)
        #expect(Array(bytes[23...]) == Array(0..<128))
        guard case let .ack(_, report) = try MIDICIMessage.decode(payload: bytes, limits: limits) else {
            Issue.record("expected an ACK message")
            return
        }
        #expect(Array(report.text.utf8) == Array(0..<128))
    }

    @Test func aParserDeliveredSysExPayloadDecodesToTheSameMessage() throws {
        var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 4_096))
        var events: [MIDI1Event] = []
        for byte in [0xF0] + Self.discovery12 + [0xF7] {
            if let event = parser.consume(byte) { events.append(event) }
        }
        try #require(events.count == 1)
        guard case let .sysEx(payload) = events[0] else {
            Issue.record("expected a SysEx event")
            return
        }
        #expect(payload == Self.discovery12)
        let all = try Self.messages()
        try #require(all.count > 1)
        #expect(try MIDICIMessage.decode(payload: payload, limits: .standard) == all[1])
    }
}
