//
//  MIDICIMessageTests+Order.swift
//  FluxKlangTests
//
//  Order of refusals when a payload has two defects with different typed refusals (both-defects fixtures), for
//  decode and for encode (#83, slice CI1). The order itself is the doc comment of
//  `MIDICIMessage.decode(payload:limits:)` and of `MIDICIMessage.encode(limits:)`.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    @Test func anOversizedPayloadIsRefusedBySizeBeforeItIsInspectedAsCI() throws {
        let notCI = [UInt8](repeating: 0x00, count: 4_097)
        #expect(Self.decodeRefusal(notCI) == .payloadTooLarge(4_097))
        let highBytes = [UInt8](repeating: 0xFF, count: 4_097)
        #expect(Self.decodeRefusal(highBytes) == .payloadTooLarge(4_097))
        let tiny = try Self.limits(payload: 1, text: 0)
        #expect(Self.decodeRefusal([0x00, 0x00], limits: tiny) == .payloadTooLarge(2))
    }

    @Test func aWrongFirstOrThirdByteIsNotCIEvenWhenAHighByteComesEarlierOrLater() throws {
        #expect(Self.decodeRefusal([0x7F, 0x90, 0x0D, 0x70, 0x01]) == .notCI)
        #expect(Self.decodeRefusal([0x7E, 0x90, 0x0C, 0x70, 0x01]) == .notCI)
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0C, 0x70, 0x01, 0x80]) == .notCI)
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0D, 0x70, 0x01, 0x80]) == .dataByteHigh(offset: 5))
        #expect(Self.decodeRefusal([0x7E, 0x90, 0x0D, 0x70, 0x01]) == .dataByteHigh(offset: 1))
    }

    @Test func aHighByteIsReportedBeforeTruncationAndBeforeSubIDAndFormatChecks() throws {
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0D, 0x90]) == .dataByteHigh(offset: 3))
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0D, 0x70]) == .truncated(need: 5, have: 4))
        let unknownSub = Self.replacing(Self.replacing(Self.discovery11, at: 3, with: 0x20), at: 20, with: 0x90)
        #expect(Self.decodeRefusal(unknownSub) == .dataByteHigh(offset: 20))
        let badFormat = Self.replacing(Self.replacing(Self.discovery11, at: 4, with: 0x05), at: 28, with: 0x90)
        #expect(Self.decodeRefusal(badFormat) == .dataByteHigh(offset: 28))
        let badFormatAlone = Self.replacing(Self.discovery11, at: 4, with: 0x05)
        #expect(Self.decodeRefusal(badFormatAlone) == .unsupportedFormat(0x05))
    }

    @Test func anUnknownSubIDBeatsAnUnsupportedFormatAndBothBeatTruncation() throws {
        let both = Self.replacing(Self.replacing(Self.discovery11, at: 3, with: 0x20), at: 4, with: 0x09)
        #expect(Self.decodeRefusal(both) == .unknownSubID(0x20))
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0D, 0x20, 0x09, 0x00]) == .unknownSubID(0x20))
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0D, 0x72, 0x01, 0x00]) == .unknownSubID(0x72))
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0D, 0x70, 0x09, 0x00]) == .unsupportedFormat(0x09))
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0D, 0x70, 0x01, 0x00]) == .truncated(need: 13, have: 6))
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0D, 0x20, 0x01, 0x00]) == .unknownSubID(0x20))
    }

    @Test func anUnknownSubIDInAFourByteFrameIsRefusedAsTruncatedBeforeItIsJudged() throws {
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0D, 0x20]) == .truncated(need: 5, have: 4))
        #expect(Self.decodeRefusal([0x7E, 0x10, 0x0D, 0x20, 0x01]) == .unknownSubID(0x20))
    }

    @Test func aDeclaredTextOverTheLimitBeatsTruncationOfThatText() throws {
        let declares300 = Array(Self.ack[0..<21]) + [0x2C, 0x02]
        #expect(Self.decodeRefusal(declares300) == .textTooLong(300))
        let declares5Short = Array(Self.ack[0..<21]) + [0x05, 0x00, 0x41]
        let tight = try Self.limits(payload: 4_096, text: 4)
        #expect(Self.decodeRefusal(declares5Short, limits: tight) == .textTooLong(5))
        #expect(Self.decodeRefusal(declares5Short) == .truncated(need: 28, have: 24))
        let declares5Long = Array(Self.ack[0..<21]) + [0x05, 0x00, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46]
        #expect(Self.decodeRefusal(declares5Long, limits: tight) == .textTooLong(5))
        #expect(Self.decodeRefusal(declares5Long) == .trailingBytes(1))
    }

    @Test func lengthIsCheckedBeforeAnyMUIDOrAddressingRule() throws {
        let reservedShort = Self.replacing(Array(Self.discovery11.dropLast()), range: 5..<9, with: Self.reservedBytes)
        #expect(Self.decodeRefusal(reservedShort) == .truncated(need: 29, have: 28))
        let reservedLong = Self.replacing(Self.discovery11 + [0x00], range: 5..<9, with: Self.reservedBytes)
        #expect(Self.decodeRefusal(reservedLong) == .trailingBytes(1))
        let broadcastShort = Self.replacing(Array(Self.ack.dropLast()), range: 5..<9, with: Self.broadcastBytes)
        #expect(Self.decodeRefusal(broadcastShort) == .truncated(need: 25, have: 24))
        let wrongDestinationLong = Self.replacing(Self.invalidate + [0x00], range: 9..<13, with: Self.zeroBytes)
        #expect(Self.decodeRefusal(wrongDestinationLong) == .trailingBytes(1))
    }

    @Test func aReservedSourceIsReportedBeforeAReservedDestinationInBothArrangements() throws {
        let sourceFirst = Self.replacing(
            Self.reply11, range: 5..<13, with: Self.reservedBytes + [0x7E, 0x7F, 0x7F, 0x7F])
        #expect(Self.decodeRefusal(sourceFirst) == .invalidMUID(0x0FFF_FF00))
        let flipped = Self.replacing(
            Self.reply11, range: 5..<13, with: [0x7E, 0x7F, 0x7F, 0x7F] + Self.reservedBytes)
        #expect(Self.decodeRefusal(flipped) == .invalidMUID(0x0FFF_FFFE))
    }

    @Test func aReservedDestinationBeatsABroadcastSourceAndABroadcastSourceBeatsTheDestinationRule() throws {
        let broadcastWithReserved = Self.replacing(
            Self.discovery11, range: 5..<13, with: Self.broadcastBytes + Self.reservedBytes)
        #expect(Self.decodeRefusal(broadcastWithReserved) == .invalidMUID(0x0FFF_FF00))
        let broadcastWithSpecific = Self.replacing(
            Self.discovery11, range: 5..<13, with: Self.broadcastBytes + Self.sourceBytes)
        #expect(Self.decodeRefusal(broadcastWithSpecific) == .sourceIsBroadcast)
        let ackBothBroadcast = Self.replacing(
            Self.ack, range: 5..<13, with: Self.broadcastBytes + Self.broadcastBytes)
        #expect(Self.decodeRefusal(ackBothBroadcast) == .sourceIsBroadcast)
    }

    @Test func theDestinationRuleIsReportedBeforeAnyBodyDefect() throws {
        let specificWithBroadcastTarget = Self.replacing(
            Self.replacing(Self.invalidate, range: 9..<13, with: Self.sourceBytes),
            range: 13..<17, with: Self.broadcastBytes)
        #expect(Self.decodeRefusal(specificWithBroadcastTarget) == .destinationNotBroadcast)
        let specificWithReservedTarget = Self.replacing(
            Self.replacing(Self.invalidate, range: 9..<13, with: Self.sourceBytes),
            range: 13..<17, with: Self.reservedBytes)
        #expect(Self.decodeRefusal(specificWithReservedTarget) == .destinationNotBroadcast)
        let broadcastWithBroadcastTarget = Self.replacing(Self.invalidate, range: 13..<17, with: Self.broadcastBytes)
        #expect(Self.decodeRefusal(broadcastWithBroadcastTarget) == .targetIsBroadcast)
    }

    @Test func encodeReportsASourceBeforeADestinationBeforeABodyDefectBeforeSize() throws {
        let specific = try Self.header(.ci11, destination: 5)
        let broadcastSource = try Self.header(.ci11, source: 0x0FFF_FFFF, destination: 5)
        let pathInEleven = try Self.info(path: 1)
        #expect(Self.encodeRefusal(.discovery(broadcastSource, pathInEleven)) == .sourceIsBroadcast)
        #expect(Self.encodeRefusal(.discovery(specific, pathInEleven)) == .destinationNotBroadcast)
        let ackToAll = MIDICIMessage.ack(try Self.header(.ci12), try Self.report(text: "abc"))
        let tight = try Self.limits(payload: 20, text: 2)
        #expect(Self.encodeRefusal(ackToAll, limits: tight) == .destinationIsBroadcast)
        let ack = try Self.ackMessage(text: "abc")
        #expect(Self.encodeRefusal(ack, limits: tight) == .textTooLong(3))
        let invalidate = MIDICIMessage.invalidateMUID(try Self.header(.ci11, destination: 5), target: .broadcast)
        #expect(Self.encodeRefusal(invalidate) == .destinationNotBroadcast)
        let invalidateAll = MIDICIMessage.invalidateMUID(try Self.header(.ci11), target: .broadcast)
        #expect(Self.encodeRefusal(invalidateAll, limits: try Self.limits(payload: 16, text: 0)) == .targetIsBroadcast)
        let discovery = MIDICIMessage.discovery(try Self.header(.ci11), try Self.info(path: 1))
        #expect(Self.encodeRefusal(discovery, limits: try Self.limits(payload: 28, text: 0)) == .outputPathIDNotAllowed)
    }
}
