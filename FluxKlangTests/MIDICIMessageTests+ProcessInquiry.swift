//
//  MIDICIMessageTests+ProcessInquiry.swift
//  FluxKlangTests
//
//  Process Inquiry (0x40 to 0x44), the rules all five messages share: the goldens and typed fixtures of the Process
//  Inquiry Capabilities Inquiry and Reply, the sub-ids, the CI 1.2-only format, every length, byte, MUID, addressing
//  and device rule in decoder order, the encode refusal order and the size bound (#83, slice CIP2). The three report
//  messages (0x42, 0x43 and 0x44) and their bitmaps are in `MIDICIMessageTests+ProcessInquiryReport.swift`.
//
//  Provenance: every vector is written by hand from M2-101-UM v1.2, section 9 and Tables 40 to 46; none comes from
//  another project or from the encoder. The full refusal order is the doc comment of
//  `MIDICIProcessInquiryMessage.decode(payload:limits:)`.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    // MARK: Capabilities goldens (never produced by the encoder)

    /// Table 40: for the Function Block (0x7F), from MUID 0x01234567 to the Responder 0x0FFFFEFF; no body.
    static let processCapabilitiesInquiry = prefix(0x7F, 0x40, 0x02) + sourceBytes + maximumBytes
    static let processCapabilitiesInquiryReversed = prefix(0x7F, 0x40, 0x02) + maximumBytes + zeroBytes
    /// Tables 41 and 42: the features bitmap has D0, MIDI Message Report, set.
    static let processCapabilitiesReply = prefix(0x7F, 0x41, 0x02) + maximumBytes + sourceBytes + [0x01]
    static let processCapabilitiesReplyEmpty = prefix(0x7F, 0x41, 0x02) + sourceBytes + maximumBytes + [0x00]
    static let processCapabilityGoldens: [[UInt8]] = [
        processCapabilitiesInquiry, processCapabilitiesInquiryReversed, processCapabilitiesReply,
        processCapabilitiesReplyEmpty
    ]
    static let processGoldens: [[UInt8]] = processCapabilityGoldens + messageReportGoldens

    // MARK: Process Inquiry fixtures

    static func processCapabilityMessages() throws -> [MIDICIProcessInquiryMessage] {
        let maximum: UInt32 = 0x0FFF_FEFF
        let source: UInt32 = 0x0123_4567
        return [
            .capabilitiesInquiry(try header(.ci12, device: 0x7F, destination: maximum)),
            .capabilitiesInquiry(try header(.ci12, device: 0x7F, source: maximum, destination: 0)),
            .capabilitiesReply(
                try header(.ci12, device: 0x7F, source: maximum, destination: source), features: .midiMessageReport),
            .capabilitiesReply(try header(.ci12, device: 0x7F, destination: maximum), features: [])
        ]
    }

    /// One message of each kind (0x40 to 0x44) around `header`. The 0x42 asks for no System Messages, so only the
    /// header decides the refusals of the rules all five kinds share.
    static func processKinds(_ header: MIDICIHeader) -> [MIDICIProcessInquiryMessage] {
        [
            .capabilitiesInquiry(header), .capabilitiesReply(header, features: .midiMessageReport),
            .messageReportInquiry(header, dataControl: .full, selection: MIDICIReportSelection()),
            .messageReportReply(header, selection: MIDICIReportSelection()), .messageReportEnd(header)
        ]
    }

    static func processDecodeRefusal(_ payload: [UInt8], limits: MIDICILimits = .standard) -> MIDICIRefusal? {
        do {
            _ = try MIDICIProcessInquiryMessage.decode(payload: payload, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    static func processEncodeRefusal(
        _ message: MIDICIProcessInquiryMessage, limits: MIDICILimits = .standard
    ) -> MIDICIRefusal? {
        do {
            _ = try message.encode(limits: limits)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Goldens, decode and encode

    @Test func everyProcessCapabilitiesMessageEncodesToItsGoldenBytes() throws {
        let messages = try Self.processCapabilityMessages()
        try #require(messages.count == Self.processCapabilityGoldens.count)
        for (message, golden) in zip(messages, Self.processCapabilityGoldens) {
            #expect(try message.encode(limits: .standard) == golden)
        }
        #expect(Self.processCapabilityGoldens.map(\.count) == [13, 13, 14, 14])
        let kinds: [MIDICIProcessInquiryKind] = [
            .capabilitiesInquiry, .capabilitiesInquiry, .capabilitiesReply, .capabilitiesReply
        ]
        #expect(messages.map(\.kind) == kinds)
    }

    @Test func everyProcessCapabilitiesGoldenDecodesToItsExactTypedValueAndSurvivesTheRoundTrip() throws {
        let messages = try Self.processCapabilityMessages()
        try #require(messages.count == Self.processCapabilityGoldens.count)
        for (golden, message) in zip(Self.processCapabilityGoldens, messages) {
            let decoded = try MIDICIProcessInquiryMessage.decode(payload: golden, limits: .standard)
            #expect(decoded == message)
            #expect(try decoded.encode(limits: .standard) == golden)
        }
        let reply = try MIDICIProcessInquiryMessage.decode(payload: Self.processCapabilitiesReply, limits: .standard)
        guard case let .capabilitiesReply(header, features) = reply else {
            Issue.record("expected a Reply to Process Inquiry Capabilities")
            return
        }
        #expect(header.device.rawValue == 0x7F && header.format == .ci12)
        #expect(header.source.rawValue == 0x0FFF_FEFF && header.destination.rawValue == 0x0123_4567)
        #expect(features == .midiMessageReport && features.rawValue == 0x01)
        let inquiry = try MIDICIProcessInquiryMessage.decode(
            payload: Self.processCapabilitiesInquiry, limits: .standard)
        #expect(inquiry == .capabilitiesInquiry(try Self.header(.ci12, device: 0x7F, destination: 0x0FFF_FEFF)))
    }

    @Test func eachKindHasItsSubIDItsLengthAndItsHeader() throws {
        let header = try Self.header(.ci12, device: 0x7F, destination: 0)
        let messages = Self.processKinds(header)
        let subIDs: [UInt8] = [0x40, 0x41, 0x42, 0x43, 0x44]
        let lengths = [13, 14, 18, 17, 13]
        #expect(messages.map(\.header) == [MIDICIHeader](repeating: header, count: 5))
        #expect(messages.map(\.kind.rawValue) == subIDs)
        for (index, message) in messages.enumerated() {
            let bytes = try message.encode(limits: .standard)
            #expect(bytes.count == lengths[index] && bytes[3] == subIDs[index])
            #expect(MIDICIProcessInquiryKind(rawValue: subIDs[index])?.payloadBytes == lengths[index])
        }
        #expect(MIDICIProcessInquiryKind(rawValue: 0x3F) == nil && MIDICIProcessInquiryKind(rawValue: 0x45) == nil)
        #expect(MIDICIProcessInquiryMessage.destinationRule == .oneMUID)
    }

    @Test func theFeaturesBitmapKeepsOnlyTheMIDIMessageReportBit() throws {
        for value in UInt8(0)...0x7F {
            let payload = Self.replacing(Self.processCapabilitiesReply, at: 13, with: value)
            let decoded = try MIDICIProcessInquiryMessage.decode(payload: payload, limits: .standard)
            guard case let .capabilitiesReply(_, features) = decoded else {
                Issue.record("expected a Reply to Process Inquiry Capabilities")
                return
            }
            #expect(features.rawValue == value & 0x01)
            #expect(features.contains(.midiMessageReport) == (value & 0x01 == 0x01))
            let canonical = Self.replacing(Self.processCapabilitiesReply, at: 13, with: value & 0x01)
            #expect(try decoded.encode(limits: .standard) == canonical)
        }
        for value in UInt8(0x80)...0xFF {
            let payload = Self.replacing(Self.processCapabilitiesReply, at: 13, with: value)
            #expect(Self.processDecodeRefusal(payload) == .dataByteHigh(offset: 13))
        }
        #expect(MIDICIProcessInquiryFeatures(rawValue: 0xFF) == .midiMessageReport)
        #expect(MIDICIProcessInquiryFeatures(rawValue: 0xFE).isEmpty)
        var features = MIDICIProcessInquiryFeatures()
        features.formUnion(MIDICIProcessInquiryFeatures(rawValue: 0xFE))
        #expect(features.isEmpty)
    }

    // MARK: Sub-ids and format

    @Test func theOtherDecodersStillRefuseTheProcessInquirySubIDs() throws {
        for golden in Self.processGoldens {
            let sub = try #require(golden.dropFirst(3).first)
            #expect(Self.decodeRefusal(golden) == .unknownSubID(sub))
            #expect(Self.profileDecodeRefusal(golden) == .unknownSubID(sub))
            #expect(Self.propertyDecodeRefusal(golden) == .unknownSubID(sub))
            #expect(Self.endpointDecodeRefusal(golden) == .unknownSubID(sub))
        }
        let others = Self.goldens + Self.profileGoldens + Self.reportGoldens + Self.setProfileGoldens
            + Self.propertyGoldens + Self.endpointGoldens
        for golden in others {
            let sub = try #require(golden.dropFirst(3).first)
            #expect(Self.processDecodeRefusal(golden) == .unknownSubID(sub))
        }
    }

    @Test func aSubIDOutsideTheProcessInquiryRangeIsUnknownBeforeTheFormatAndTheLength() throws {
        let others: [UInt8] = [0x00, 0x20, 0x30, 0x3F, 0x45, 0x46, 0x4F, 0x50, 0x70, 0x71, 0x72, 0x73, 0x7D, 0x7E, 0x7F]
        for sub in others {
            for golden in Self.processGoldens {
                #expect(Self.processDecodeRefusal(Self.replacing(golden, at: 3, with: sub)) == .unknownSubID(sub))
            }
            let legacyAndShort = Self.replacing(Array(Self.processCapabilitiesInquiry.prefix(6)), at: 3, with: sub)
            #expect(Self.processDecodeRefusal(Self.replacing(legacyAndShort, at: 4, with: 0x01)) == .unknownSubID(sub))
        }
    }

    @Test func processInquiryMessagesExistOnlyFromCI12On() throws {
        for golden in Self.processGoldens {
            for format: UInt8 in [0x00, 0x01, 0x03, 0x10, 0x7F] {
                #expect(Self.processDecodeRefusal(Self.replacing(golden, at: 4, with: format)) ==
                    .unsupportedFormat(format))
                let short = Array(Self.replacing(golden, at: 4, with: format).prefix(8))
                #expect(Self.processDecodeRefusal(short) == .unsupportedFormat(format))
            }
            #expect(Self.processDecodeRefusal(Array(Self.replacing(golden, at: 4, with: 0x01).prefix(5))) ==
                .unsupportedFormat(1))
        }
        let legacy = try Self.header(.ci11, device: 0x10, source: 0x0FFF_FFFF, destination: 0x0FFF_FFFF)
        let tiny = try Self.limits(payload: 1, text: 0)
        for message in Self.processKinds(legacy) {
            #expect(Self.processEncodeRefusal(message, limits: tiny) == .unsupportedFormat(1))
        }
        let legacyFunctionBlock = try Self.header(.ci11, device: 0x7F, destination: 0)
        for message in Self.processKinds(legacyFunctionBlock) {
            #expect(Self.processEncodeRefusal(message) == .unsupportedFormat(1))
        }
    }

    // MARK: Length

    @Test func everyPrefixOfAProcessInquiryMessageIsTruncated() throws {
        #expect(Self.processDecodeRefusal([]) == .truncated(need: 1, have: 0))
        for golden in Self.processGoldens {
            for length in 1..<golden.count {
                let need: Int
                switch length {
                case 1..<5: need = 5
                case 5..<13: need = 13
                default: need = golden.count
                }
                #expect(Self.processDecodeRefusal(Array(golden.prefix(length))) ==
                    .truncated(need: need, have: length))
            }
            #expect(Self.processDecodeRefusal(golden + [0x00]) == .trailingBytes(1))
            #expect(Self.processDecodeRefusal(golden + [0x00, 0x7F]) == .trailingBytes(2))
            #expect(Self.processDecodeRefusal(golden + [0x00, 0x80]) == .dataByteHigh(offset: golden.count + 1))
            #expect(Self.processDecodeRefusal(golden) == nil)
        }
    }

    @Test func theLengthDependsOnTheSubIDOfTheMessage() throws {
        let kinds: [(sub: UInt8, length: Int)] = [(0x40, 13), (0x41, 14), (0x42, 18), (0x43, 17), (0x44, 13)]
        for golden in Self.processGoldens {
            for (sub, length) in kinds {
                let refusal = Self.processDecodeRefusal(Self.replacing(golden, at: 3, with: sub))
                if golden.count < length {
                    #expect(refusal == .truncated(need: length, have: golden.count))
                } else if golden.count > length {
                    #expect(refusal == .trailingBytes(golden.count - length))
                } else {
                    #expect(refusal == nil)
                }
            }
        }
    }

    // MARK: Bytes, MUIDs, addressing and the device id

    @Test func aHighProcessInquiryByteAnywhereIsRefusedAtItsOffset() throws {
        for golden in Self.processGoldens {
            for offset in 1..<golden.count {
                for value: UInt8 in [0x80, 0xFF] {
                    let high = Self.replacing(golden, at: offset, with: value)
                    #expect(Self.processDecodeRefusal(high) == (offset == 2 ? .notCI : .dataByteHigh(offset: offset)))
                }
            }
            #expect(Self.processDecodeRefusal(Self.replacing(golden, at: 0, with: 0x7F)) == .notCI)
            #expect(Self.processDecodeRefusal(Self.replacing(golden, at: 2, with: 0x0C)) == .notCI)
            let last = golden.count - 2
            let highAndShort = Self.replacing(Array(golden.dropLast()), at: last, with: 0xC1)
            #expect(Self.processDecodeRefusal(highAndShort) == .dataByteHigh(offset: last))
        }
    }

    @Test func aReservedMUIDIsRefusedSourceFirstAndAfterTheLength() throws {
        let reservedHigh: [UInt8] = [0x01, 0x7E, 0x7F, 0x7F]
        for golden in Self.processGoldens {
            let reservedSource = Self.replacing(golden, range: 5..<9, with: Self.reservedBytes)
            #expect(Self.processDecodeRefusal(reservedSource) == .invalidMUID(0x0FFF_FF00))
            #expect(Self.processDecodeRefusal(Array(reservedSource.dropLast())) ==
                .truncated(need: golden.count, have: golden.count - 1))
            #expect(Self.processDecodeRefusal(reservedSource + [0x00]) == .trailingBytes(1))
            let reservedDestination = Self.replacing(golden, range: 9..<13, with: Self.reservedBytes)
            #expect(Self.processDecodeRefusal(reservedDestination) == .invalidMUID(0x0FFF_FF00))
            let bothReserved = Self.replacing(reservedSource, range: 9..<13, with: reservedHigh)
            #expect(Self.processDecodeRefusal(bothReserved) == .invalidMUID(0x0FFF_FF00))
            let swapped = Self.replacing(Self.replacing(golden, range: 5..<9, with: reservedHigh),
                                         range: 9..<13, with: Self.reservedBytes)
            #expect(Self.processDecodeRefusal(swapped) == .invalidMUID(0x0FFF_FF01))
        }
    }

    @Test func processAddressingRefusesABroadcastSourceThenABroadcastDestination() throws {
        for golden in Self.processGoldens {
            let broadcastSource = Self.replacing(golden, range: 5..<9, with: Self.broadcastBytes)
            #expect(Self.processDecodeRefusal(broadcastSource) == .sourceIsBroadcast)
            let broadcastToReserved = Self.replacing(broadcastSource, range: 9..<13, with: Self.reservedBytes)
            #expect(Self.processDecodeRefusal(broadcastToReserved) == .invalidMUID(0x0FFF_FF00))
            let broadcastBoth = Self.replacing(broadcastSource, range: 9..<13, with: Self.broadcastBytes)
            #expect(Self.processDecodeRefusal(broadcastBoth) == .sourceIsBroadcast)
            let toBroadcast = Self.replacing(golden, range: 9..<13, with: Self.broadcastBytes)
            #expect(Self.processDecodeRefusal(toBroadcast) == .destinationIsBroadcast)
            #expect(Self.processDecodeRefusal(Array(toBroadcast.dropLast())) ==
                .truncated(need: golden.count, have: golden.count - 1))
            for destination in [Self.zeroBytes, Self.maximumBytes, Self.sourceBytes] {
                #expect(Self.processDecodeRefusal(Self.replacing(golden, range: 9..<13, with: destination)) == nil)
            }
        }
    }

    @Test func decodeKeepsEveryDeviceIDOfEveryKind() throws {
        for golden in Self.processGoldens {
            for device in UInt8(0)...0x7F {
                let decoded = try MIDICIProcessInquiryMessage.decode(
                    payload: Self.replacing(golden, at: 1, with: device), limits: .standard)
                #expect(decoded.header.device.rawValue == device)
            }
        }
    }

    @Test func thePayloadLimitIsCheckedBeforeEveryProcessInquiryRule() throws {
        for golden in Self.processGoldens {
            let exact = try Self.limits(payload: golden.count, text: 0)
            #expect(Self.processDecodeRefusal(golden, limits: exact) == nil)
            let short = try Self.limits(payload: golden.count - 1, text: 0)
            #expect(Self.processDecodeRefusal(golden, limits: short) == .payloadTooLarge(golden.count))
            let badFormat = Self.replacing(golden, at: 4, with: 0x01)
            #expect(Self.processDecodeRefusal(badFormat, limits: short) == .payloadTooLarge(golden.count))
        }
        let hostile = [UInt8](repeating: 0xFF, count: 4_097)
        #expect(Self.processDecodeRefusal(hostile) == .payloadTooLarge(4_097))
    }

    // MARK: Encode refusals

    @Test func processEncodeChecksTheFormatThenTheAddressingThenTheDeviceThenTheSize() throws {
        let tiny = try Self.limits(payload: 1, text: 0)
        let fromBroadcast = try Self.header(.ci12, device: 0x10, source: 0x0FFF_FFFF, destination: 0x0FFF_FFFF)
        for message in Self.processKinds(fromBroadcast) {
            #expect(Self.processEncodeRefusal(message, limits: tiny) == .sourceIsBroadcast)
        }
        let toBroadcast = try Self.header(.ci12, device: 0x10)
        for message in Self.processKinds(toBroadcast) {
            #expect(Self.processEncodeRefusal(message, limits: tiny) == .destinationIsBroadcast)
        }
        let channel = try Self.header(.ci12, device: 0x10, destination: 0)
        let refusals: [MIDICIRefusal] = [
            .deviceNotFunctionBlock(0x10), .deviceNotFunctionBlock(0x10), .payloadTooLarge(18), .payloadTooLarge(17),
            .payloadTooLarge(13)
        ]
        for (message, refusal) in zip(Self.processKinds(channel), refusals) {
            #expect(Self.processEncodeRefusal(message, limits: tiny) == refusal)
        }
    }

    @Test func encodeRefusesAPayloadOverTheLimitAndAcceptsTheExactLimit() throws {
        let functionBlock = try Self.header(.ci12, device: 0x7F, destination: 0)
        let lengths = [13, 14, 18, 17, 13]
        for (message, length) in zip(Self.processKinds(functionBlock), lengths) {
            let exact = try Self.limits(payload: length, text: 0)
            #expect(try message.encode(limits: exact).count == length)
            let short = try Self.limits(payload: length - 1, text: 0)
            #expect(Self.processEncodeRefusal(message, limits: short) == .payloadTooLarge(length))
        }
    }

    @Test func theCapabilitiesMessagesAreForTheFunctionBlockOnly() throws {
        for device in UInt8(0)...0x7E {
            let header = try Self.header(.ci12, device: device, destination: 0)
            #expect(Self.processEncodeRefusal(.capabilitiesInquiry(header)) == .deviceNotFunctionBlock(device))
            let reply = MIDICIProcessInquiryMessage.capabilitiesReply(header, features: .midiMessageReport)
            #expect(Self.processEncodeRefusal(reply) == .deviceNotFunctionBlock(device))
        }
        let functionBlock = try Self.header(.ci12, device: 0x7F, destination: 0)
        let accepted: [MIDICIProcessInquiryMessage] = [
            .capabilitiesInquiry(functionBlock), .capabilitiesReply(functionBlock, features: [])
        ]
        for message in accepted {
            #expect(try message.encode(limits: .standard)[1] == 0x7F)
        }
    }
}
