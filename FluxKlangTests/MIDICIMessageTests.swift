//
//  MIDICIMessageTests.swift
//  FluxKlangTests
//
//  Golden bytes, typed fixtures and the encoder/factory tests for the MIDI-CI envelope and management messages
//  (#83, slice CI1). Decode, refusal order, MUID and hostile-input tests are in the `MIDICIMessageTests+...` files.
//
//  Provenance: the lengths and field order were cross-checked against the public ktmidi and JUCE sources (not
//  against the MIDI Association specification, which was not reachable). No byte array was copied from either
//  source; every field value below is this slice's own. The full refusal order is the doc comment of
//  `MIDICIMessage.decode(payload:limits:)`.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct MIDICIMessageTests {
    // MARK: Golden bytes (written by hand from the layout, never produced by the encoder)

    /// MUID 0x01234567 coded 7 bits per byte, least significant first.
    static let sourceBytes: [UInt8] = [0x67, 0x0A, 0x0D, 0x09]
    static let broadcastBytes: [UInt8] = [0x7F, 0x7F, 0x7F, 0x7F]
    /// MUID 0x0FFFFEFF, the largest assignable value.
    static let maximumBytes: [UInt8] = [0x7F, 0x7D, 0x7F, 0x7F]
    static let zeroBytes: [UInt8] = [0x00, 0x00, 0x00, 0x00]
    /// MUID 0x0FFFFF00, the first reserved value.
    static let reservedBytes: [UInt8] = [0x00, 0x7E, 0x7F, 0x7F]
    static let discoveryBody: [UInt8] = [
        0x00, 0x20, 0x29, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0E, 0x00, 0x20, 0x00, 0x00
    ]
    static let ackBody: [UInt8] = [0x70, 0x01, 0x02, 0x01, 0x02, 0x03, 0x04, 0x05, 0x02, 0x00, 0x4F, 0x4B]
    static let nakBody: [UInt8] = [0x34, 0x04, 0x05, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x00, 0x00]

    static func prefix(_ device: UInt8, _ subID: UInt8, _ format: UInt8) -> [UInt8] {
        [0x7E, device, 0x0D, subID, format]
    }

    static let discovery11 = prefix(0x10, 0x70, 0x01) + sourceBytes + broadcastBytes + discoveryBody
    static let discovery12 = prefix(0x10, 0x70, 0x02) + sourceBytes + broadcastBytes + discoveryBody + [0x03]
    static let reply11 = prefix(0x10, 0x71, 0x01) + sourceBytes + maximumBytes + discoveryBody
    static let reply12 = prefix(0x7F, 0x71, 0x02) + sourceBytes + broadcastBytes + discoveryBody + [0x7F, 0x05]
    static let invalidate = prefix(0x7F, 0x7E, 0x01) + sourceBytes + broadcastBytes + maximumBytes
    static let ack = prefix(0x10, 0x7D, 0x02) + sourceBytes + zeroBytes + ackBody
    static let nak = prefix(0x00, 0x7F, 0x02) + maximumBytes + sourceBytes + nakBody
    static let nak11 = prefix(0x10, 0x7F, 0x01) + maximumBytes + sourceBytes
    static let goldens: [[UInt8]] = [discovery11, discovery12, reply11, reply12, invalidate, ack, nak, nak11]

    // MARK: Typed fixtures

    static func muid(_ raw: UInt32) throws -> MIDICIMUID {
        try MIDICIMUID.make(raw)
    }

    static func header(
        _ format: MIDICIFormat, device: UInt8 = 0x10, source: UInt32 = 0x0123_4567, destination: UInt32 = 0x0FFF_FFFF
    ) throws -> MIDICIHeader {
        MIDICIHeader(
            device: try SysExDeviceID(device), format: format, source: try muid(source),
            destination: try muid(destination))
    }

    static func identity() throws -> MIDICIDeviceIdentity {
        try MIDICIDeviceIdentity.make(
            manufacturer: [0x00, 0x20, 0x29], family: 0x0101, model: 0x0203, softwareRevision: [5, 6, 7, 8])
    }

    static func info(path: UInt8? = nil, size: UInt32 = 4_096) throws -> MIDICIDiscoveryInfo {
        try MIDICIDiscoveryInfo.make(
            identity: try identity(), capabilityCategory: 0x0E, maximumSysExSize: size, outputPathID: path)
    }

    static func report(
        original: UInt8 = 0x70, code: UInt8 = 0x01, data: UInt8 = 0x02, text: String = "OK"
    ) throws -> MIDICIStatusReport {
        try MIDICIStatusReport.make(
            originalSubID: original, statusCode: code, statusData: data, details: [1, 2, 3, 4, 5], text: text)
    }

    static func ackMessage(text: String = "OK") throws -> MIDICIMessage {
        .ack(try header(.ci12, destination: 0), try report(text: text))
    }

    static func decodeRefusal(_ payload: [UInt8], limits: MIDICILimits = .standard) -> MIDICIRefusal? {
        do {
            _ = try MIDICIMessage.decode(payload: payload, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func encodeRefusal(_ message: MIDICIMessage, limits: MIDICILimits = .standard) -> MIDICIRefusal? {
        do {
            _ = try message.encode(limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func limits(payload: Int, text: Int) throws -> MIDICILimits {
        try MIDICILimits.make(maximumPayloadBytes: payload, maximumTextBytes: text)
    }

    static func messages() throws -> [MIDICIMessage] {
        [
            .discovery(try header(.ci11), try info()),
            .discovery(try header(.ci12), try info(path: 0x03)),
            .discoveryReply(try header(.ci11, destination: 0x0FFF_FEFF), try info(), functionBlock: nil),
            .discoveryReply(try header(.ci12, device: 0x7F), try info(path: 0x7F), functionBlock: 0x05),
            .invalidateMUID(try header(.ci11, device: 0x7F), target: try muid(0x0FFF_FEFF)),
            try ackMessage(),
            .nak(
                try header(.ci12, device: 0, source: 0x0FFF_FEFF, destination: 0x0123_4567),
                try MIDICIStatusReport.make(
                    originalSubID: 0x34, statusCode: 0x04, statusData: 0x05, details: [10, 11, 12, 13, 14], text: "")),
            .nak(try header(.ci11, source: 0x0FFF_FEFF, destination: 0x0123_4567), nil)
        ]
    }

    // MARK: Encoding

    @Test func everyMessageEncodesToItsHandWrittenGoldenBytes() throws {
        let messages = try Self.messages()
        try #require(messages.count == Self.goldens.count)
        for (message, golden) in zip(messages, Self.goldens) {
            #expect(try message.encode(limits: .standard) == golden)
        }
        #expect(Self.discovery11.count == 29 && Self.discovery12.count == 30 && Self.invalidate.count == 17)
        #expect(Self.reply11.count == 29 && Self.reply12.count == 31)
        #expect(Self.ack.count == 25 && Self.nak.count == 23 && Self.nak11.count == 13)
    }

    @Test func everyDeviceIDFromZeroToAllCallIsWrittenAtOffsetOne() throws {
        for device in UInt8(0)...0x7F {
            let message = MIDICIMessage.discovery(try Self.header(.ci11, device: device), try Self.info())
            let bytes = try message.encode(limits: .standard)
            try #require(bytes.count > 1)
            #expect(bytes[1] == device)
            #expect(try MIDICIMessage.decode(payload: bytes, limits: .standard) == message)
        }
    }

    @Test func aMUIDIsCodedSevenBitsPerByteLeastSignificantFirstAtOffsetsFiveAndNine() throws {
        let cases: [(UInt32, [UInt8])] = [
            (0, Self.zeroBytes), (1, [1, 0, 0, 0]), (0x80, [0, 1, 0, 0]), (0x4000, [0, 0, 1, 0]),
            (0x20_0000, [0, 0, 0, 1]), (0x0123_4567, Self.sourceBytes), (0x0FFF_FEFF, Self.maximumBytes)
        ]
        for (raw, expected) in cases {
            let message = MIDICIMessage.discoveryReply(
                try Self.header(.ci11, source: raw, destination: raw), try Self.info(), functionBlock: nil)
            let bytes = try message.encode(limits: .standard)
            try #require(bytes.count >= 13)
            #expect(Array(bytes[5..<9]) == expected)
            #expect(Array(bytes[9..<13]) == expected)
        }
        let distinct = MIDICIMessage.discoveryReply(
            try Self.header(.ci11, source: 0x0123_4567, destination: 0x0FFF_FEFF), try Self.info(), functionBlock: nil)
        let distinctBytes = try distinct.encode(limits: .standard)
        try #require(distinctBytes.count >= 13)
        #expect(Array(distinctBytes[5..<9]) == Self.sourceBytes)
        #expect(Array(distinctBytes[9..<13]) == Self.maximumBytes)
    }

    @Test func theFormatByteFollowsTheMessageAndOutputPathIDPairsWithCIOneTwoOnly() throws {
        let withPath11 = MIDICIMessage.discovery(try Self.header(.ci11), try Self.info(path: 0))
        let withoutPath12 = MIDICIMessage.discovery(try Self.header(.ci12), try Self.info())
        #expect(Self.encodeRefusal(withPath11) == .outputPathIDNotAllowed)
        #expect(Self.encodeRefusal(withoutPath12) == .outputPathIDRequired)
        let zeroPath = MIDICIMessage.discovery(try Self.header(.ci12), try Self.info(path: 0))
        let bytes = try zeroPath.encode(limits: .standard)
        try #require(bytes.count == 30)
        #expect(bytes[4] == 0x02 && bytes[29] == 0)
    }

    @Test func aDiscoveryReplyIs29BytesInCIOneOneAndCarriesAFunctionBlockInCIOneTwoFor31() throws {
        let plain = MIDICIMessage.discoveryReply(try Self.header(.ci11), try Self.info(), functionBlock: nil)
        let long = MIDICIMessage.discoveryReply(try Self.header(.ci12), try Self.info(path: 4), functionBlock: 0x7F)
        let zero = MIDICIMessage.discoveryReply(try Self.header(.ci12), try Self.info(path: 4), functionBlock: 0)
        let plainBytes = try plain.encode(limits: .standard)
        let longBytes = try long.encode(limits: .standard)
        let zeroBytes = try zero.encode(limits: .standard)
        try #require(longBytes.count == 31 && zeroBytes.count == 31)
        #expect(plainBytes.count == 29)
        #expect(longBytes[29] == 4 && longBytes[30] == 0x7F && zeroBytes[30] == 0)
        for message in [plain, long, zero] {
            let bytes = try message.encode(limits: .standard)
            #expect(try MIDICIMessage.decode(payload: bytes, limits: .standard) == message)
        }
    }

    @Test func aDiscoveryReplyRefusesAFunctionBlockInCIOneOneAndRequiresOneInCIOneTwo() throws {
        let info11 = try Self.info()
        let info12 = try Self.info(path: 1)
        let notAllowed = MIDICIMessage.discoveryReply(try Self.header(.ci11), info11, functionBlock: 0)
        let required = MIDICIMessage.discoveryReply(try Self.header(.ci12), info12, functionBlock: nil)
        #expect(Self.encodeRefusal(notAllowed) == .functionBlockNotAllowed)
        #expect(Self.encodeRefusal(required) == .functionBlockRequired)
        let high = MIDICIMessage.discoveryReply(try Self.header(.ci12), info12, functionBlock: 0x80)
        #expect(Self.encodeRefusal(high) == .fieldOutOfRange(.functionBlock, value: 0x80))
        let highest = MIDICIMessage.discoveryReply(try Self.header(.ci12), info12, functionBlock: 0xFF)
        #expect(Self.encodeRefusal(highest) == .fieldOutOfRange(.functionBlock, value: 0xFF))
    }

    @Test func theOutputPathRuleIsCheckedBeforeTheFunctionBlockRuleWhenBothAreBroken() throws {
        let bothBroken = MIDICIMessage.discoveryReply(try Self.header(.ci12), try Self.info(), functionBlock: nil)
        #expect(Self.encodeRefusal(bothBroken) == .outputPathIDRequired)
        let blockOutOfRange = MIDICIMessage.discoveryReply(
            try Self.header(.ci11), try Self.info(), functionBlock: 0x90)
        #expect(Self.encodeRefusal(blockOutOfRange) == .functionBlockNotAllowed)
    }

    @Test func aNAKIsTheThirteenByteHeaderInCIOneOneAndTheLongFormInCIOneTwo() throws {
        let short = MIDICIMessage.nak(try Self.header(.ci11, destination: 5), nil)
        let long = MIDICIMessage.nak(try Self.header(.ci12, destination: 5), try Self.report(text: ""))
        #expect(try short.encode(limits: .standard).count == 13)
        #expect(try long.encode(limits: .standard).count == 23)
        let withReport11 = MIDICIMessage.nak(try Self.header(.ci11, destination: 5), try Self.report())
        let without12 = MIDICIMessage.nak(try Self.header(.ci12, destination: 5), nil)
        #expect(Self.encodeRefusal(withReport11) == .statusReportNotAllowed)
        #expect(Self.encodeRefusal(without12) == .statusReportRequired)
    }

    @Test func anACKInCIOneOneIsRefusedByEncodeBeforeTheSourceBroadcastRefusal() throws {
        let plain = MIDICIMessage.ack(try Self.header(.ci11, destination: 5), try Self.report())
        #expect(Self.encodeRefusal(plain) == .unsupportedFormat(1))
        let bothBroken = MIDICIMessage.ack(try Self.header(.ci11, source: 0x0FFF_FFFF), try Self.report())
        #expect(Self.encodeRefusal(bothBroken) == .unsupportedFormat(1))
        let ci12 = MIDICIMessage.ack(try Self.header(.ci12, destination: 5), try Self.report())
        #expect(Self.encodeRefusal(ci12) == nil)
    }

    @Test func encodeRefusesABroadcastSourceAndTheWrongDestinationForEachKind() throws {
        let target = try Self.muid(0x0FFF_FEFF)
        let broadcast = UInt32(0x0FFF_FFFF)
        let info = try Self.info()
        let report = try Self.report()
        let sourceCases: [MIDICIMessage] = [
            .discovery(try Self.header(.ci11, source: broadcast), info),
            .discoveryReply(try Self.header(.ci11, source: broadcast, destination: 5), info, functionBlock: nil),
            .invalidateMUID(try Self.header(.ci11, source: broadcast), target: target),
            .ack(try Self.header(.ci12, source: broadcast, destination: 5), report),
            .nak(try Self.header(.ci12, source: broadcast, destination: 5), report),
            .nak(try Self.header(.ci11, source: broadcast, destination: 5), nil)
        ]
        for message in sourceCases { #expect(Self.encodeRefusal(message) == .sourceIsBroadcast) }
        let specific = try Self.header(.ci11, destination: 5)
        let bad: [(MIDICIMessage, MIDICIRefusal)] = [
            (.discovery(specific, info), .destinationNotBroadcast),
            (.invalidateMUID(specific, target: target), .destinationNotBroadcast),
            (.ack(try Self.header(.ci12), report), .destinationIsBroadcast),
            (.nak(try Self.header(.ci12), report), .destinationIsBroadcast),
            (.nak(try Self.header(.ci11), nil), .destinationIsBroadcast)
        ]
        for (message, refusal) in bad { #expect(Self.encodeRefusal(message) == refusal) }
        #expect(Self.encodeRefusal(.discoveryReply(try Self.header(.ci11), info, functionBlock: nil)) == nil)
        #expect(Self.encodeRefusal(.discoveryReply(specific, info, functionBlock: nil)) == nil)
    }

    @Test func encodeRefusesABroadcastInvalidateTarget() throws {
        let message = MIDICIMessage.invalidateMUID(try Self.header(.ci11), target: MIDICIMUID.broadcast)
        #expect(Self.encodeRefusal(message) == .targetIsBroadcast)
    }

    @Test func encodeBoundsTextByUTF8BytesAtTheCallersLimitAndAcceptsEmptyText() throws {
        let zero = try Self.limits(payload: 4_096, text: 0)
        let one = try Self.limits(payload: 4_096, text: 1)
        #expect(try Self.ackMessage(text: "").encode(limits: zero).count == 23)
        #expect(Self.encodeRefusal(try Self.ackMessage(text: "a"), limits: zero) == .textTooLong(1))
        #expect(try Self.ackMessage(text: "a").encode(limits: one).count == 24)
        #expect(Self.encodeRefusal(try Self.ackMessage(text: "ab"), limits: one) == .textTooLong(2))
        let lineBreak = "\r\n"
        #expect(lineBreak.count == 1 && lineBreak.utf8.count == 2)
        #expect(Self.encodeRefusal(try Self.ackMessage(text: lineBreak), limits: one) == .textTooLong(2))
        let full = String(repeating: "x", count: 256)
        let bytes = try Self.ackMessage(text: full).encode(limits: .standard)
        try #require(bytes.count == 23 + 256)
        #expect(bytes[21] == 0x00 && bytes[22] == 0x02)
    }

    @Test func encodeRefusesAPayloadOverTheCallersLimitAtNPlusOne() throws {
        let message = MIDICIMessage.discovery(try Self.header(.ci11), try Self.info())
        let fits = try Self.limits(payload: 29, text: 256)
        let tooSmall = try Self.limits(payload: 28, text: 256)
        #expect(try message.encode(limits: fits).count == 29)
        #expect(Self.encodeRefusal(message, limits: tooSmall) == .payloadTooLarge(29))
        let ack = try Self.ackMessage()
        #expect(try ack.encode(limits: Self.limits(payload: 25, text: 256)).count == 25)
        #expect(Self.encodeRefusal(ack, limits: try Self.limits(payload: 24, text: 256)) == .payloadTooLarge(25))
    }

    // MARK: Validated values

    @Test func theLimitsFactoryAcceptsBothCeilingsAndFloorsAndRefusesOneBeyond() throws {
        let low = try Self.limits(payload: 1, text: 0)
        let high = try Self.limits(payload: 4_096, text: 256)
        #expect(low.maximumPayloadBytes == 1 && low.maximumTextBytes == 0)
        #expect(high == MIDICILimits.standard)
        #expect(throws: MIDICIRefusal.limits(.maximumPayloadBytes)) { try Self.limits(payload: 0, text: 0) }
        #expect(throws: MIDICIRefusal.limits(.maximumPayloadBytes)) { try Self.limits(payload: 4_097, text: 0) }
        #expect(throws: MIDICIRefusal.limits(.maximumPayloadBytes)) { try Self.limits(payload: -1, text: 0) }
        #expect(throws: MIDICIRefusal.limits(.maximumTextBytes)) { try Self.limits(payload: 1, text: 257) }
        #expect(throws: MIDICIRefusal.limits(.maximumTextBytes)) { try Self.limits(payload: 1, text: -1) }
        #expect(throws: MIDICIRefusal.limits(.maximumPayloadBytes)) { try Self.limits(payload: 0, text: 257) }
    }

    @Test func theStatusReportBoundsTextByUTF8BytesAndRefusesNonSevenBitText() throws {
        func make(_ text: String) throws -> MIDICIStatusReport {
            try Self.report(text: text)
        }
        #expect(try make("").text.isEmpty)
        #expect(try make(String(repeating: "z", count: 256)).text.utf8.count == 256)
        #expect(throws: MIDICIRefusal.textTooLong(257)) { try make(String(repeating: "z", count: 257)) }
        let accents = String(repeating: "é", count: 129)
        #expect(accents.count == 129 && accents.utf8.count == 258)
        #expect(throws: MIDICIRefusal.textTooLong(258)) { try make(accents) }
        let exactlyFull = String(repeating: "é", count: 128)
        #expect(throws: MIDICIRefusal.textNotSevenBit(offset: 0)) { try make(exactlyFull) }
        #expect(throws: MIDICIRefusal.textNotSevenBit(offset: 2)) { try make("ab\u{00E9}") }
        #expect(throws: MIDICIRefusal.textNotSevenBit(offset: 1)) { try make("a\u{1F600}") }
    }

    @Test func theStatusReportFactoryRefusesEachOutOfRangeField() throws {
        func refusal(_ original: UInt8, _ code: UInt8, _ data: UInt8, _ details: [UInt8]) -> MIDICIRefusal? {
            do {
                _ = try MIDICIStatusReport.make(
                    originalSubID: original, statusCode: code, statusData: data, details: details, text: "")
                return nil
            } catch {
                return error
            }
        }
        let five: [UInt8] = [0, 0, 0, 0, 0]
        #expect(refusal(0x80, 1, 2, five) == .fieldOutOfRange(.originalSubID, value: 0x80))
        #expect(refusal(0x7F, 0x80, 2, five) == .fieldOutOfRange(.statusCode, value: 0x80))
        #expect(refusal(0, 0x81, 2, five) == .fieldOutOfRange(.statusCode, value: 0x81))
        #expect(refusal(0, 0, 0x80, five) == .fieldOutOfRange(.statusData, value: 0x80))
        #expect(refusal(0, 0, 0xFF, five) == .fieldOutOfRange(.statusData, value: 0xFF))
        #expect(refusal(0, 0, 0, [0, 0, 0x80, 0, 0]) == .fieldOutOfRange(.details, value: 0x80))
        #expect(refusal(0, 0, 0, [0, 0, 0, 0]) == .fieldLength(.details, expected: 5, actual: 4))
        #expect(refusal(0, 0, 0, five + [0]) == .fieldLength(.details, expected: 5, actual: 6))
        #expect(refusal(0, 0, 0, [0, 0, 0x90, 0, 0]) == .fieldOutOfRange(.details, value: 0x90))
        #expect(refusal(0x7F, 0x7F, 0x7F, [0x7F, 0x7F, 0x7F, 0x7F, 0x7F]) == nil)
        #expect(refusal(0, 0, 0, five) == nil)
    }

    @Test func theIdentityAndDiscoveryFactoriesRefuseEveryOutOfRangeField() throws {
        func identity(
            _ manufacturer: [UInt8], _ family: UInt16, _ model: UInt16, _ revision: [UInt8]
        ) -> MIDICIRefusal? {
            do {
                _ = try MIDICIDeviceIdentity.make(
                    manufacturer: manufacturer, family: family, model: model, softwareRevision: revision)
                return nil
            } catch {
                return error
            }
        }
        let good: [UInt8] = [0, 0, 0]
        let four: [UInt8] = [0, 0, 0, 0]
        #expect(identity(good, 0x3FFF, 0x3FFF, four) == nil)
        #expect(identity(good, 0x4000, 0, four) == .fieldOutOfRange(.family, value: 0x4000))
        #expect(identity(good, 0, 0x4000, four) == .fieldOutOfRange(.model, value: 0x4000))
        #expect(identity([0, 0], 0, 0, four) == .fieldLength(.manufacturer, expected: 3, actual: 2))
        #expect(identity(four, 0, 0, four) == .fieldLength(.manufacturer, expected: 3, actual: 4))
        #expect(identity([0, 0x80, 0], 0, 0, four) == .fieldOutOfRange(.manufacturer, value: 0x80))
        #expect(identity(good, 0, 0, good) == .fieldLength(.softwareRevision, expected: 4, actual: 3))
        #expect(identity(good, 0, 0, [0, 0, 0, 0xFE]) == .fieldOutOfRange(.softwareRevision, value: 0xFE))
        let valid = try Self.identity()
        func discovery(_ category: UInt8, _ size: UInt32, _ path: UInt8?) -> MIDICIRefusal? {
            do {
                _ = try MIDICIDiscoveryInfo.make(
                    identity: valid, capabilityCategory: category, maximumSysExSize: size, outputPathID: path)
                return nil
            } catch {
                return error
            }
        }
        #expect(discovery(0x7F, 0x0FFF_FFFF, 0x7F) == nil)
        #expect(discovery(0x80, 0, nil) == .fieldOutOfRange(.capabilityCategory, value: 0x80))
        #expect(discovery(0, 0x1000_0000, nil) == .fieldOutOfRange(.maximumSysExSize, value: 0x1000_0000))
        #expect(discovery(0, 0, 0x80) == .fieldOutOfRange(.outputPathID, value: 0x80))
    }
}
