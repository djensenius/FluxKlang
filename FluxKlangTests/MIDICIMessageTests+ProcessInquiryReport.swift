//
//  MIDICIMessageTests+ProcessInquiryReport.swift
//  FluxKlangTests
//
//  Process Inquiry, the MIDI Message Report (0x42), its Reply (0x43) and the End of MIDI Message Report (0x44):
//  goldens, typed fixtures, the three bitmaps over all 128 wire values, the reserved byte, the Message Data Control,
//  the device rule of the Inquiry and seeded mutations of every golden (#83, slice CIP2). The shared rules and the two
//  capabilities messages are in `MIDICIMessageTests+ProcessInquiry.swift`.
//
//  Provenance: every vector is written by hand from M2-101-UM v1.2, sections 9.5 to 9.8 and Tables 43 to 46; none
//  comes from another project or from the encoder. The expected bytes of the seeded test are computed by
//  `processNormalised` and `processDeviceRefusal` below, which hold the table rules apart from the codec.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIMessageTests {
    // MARK: Message Report goldens (never produced by the encoder)

    /// Table 43: Message Data Control 0x7F, System 0x05 (MTC Quarter Frame, Song Select), the reserved byte, Channel
    /// Controller 0x12 (Control Change, Program Change) and Note Data 0x09 (Notes, Registered Per-Note Controller).
    /// System Messages are for the Function Block, so the device id is 0x7F.
    static let messageReportInquiryMixed = prefix(0x7F, 0x42, 0x02) + sourceBytes + maximumBytes
        + [0x7F, 0x05, 0x00, 0x12, 0x09]
    /// A channel (device 0x03): Message Data Control 0x01, no System Messages, every Channel Controller and Note Data
    /// bit.
    static let messageReportInquiryChannels = prefix(0x03, 0x42, 0x02) + sourceBytes + maximumBytes
        + [0x01, 0x00, 0x00, 0x3F, 0x1F]
    /// The Group (device 0x7E): Message Data Control 0x00, Pitchbend only.
    static let messageReportInquiryGroup = prefix(0x7E, 0x42, 0x02) + maximumBytes + sourceBytes
        + [0x00, 0x00, 0x00, 0x01, 0x00]
    /// Table 45: the four bytes of the Inquiry after the Message Data Control.
    static let messageReportReplyMixed = prefix(0x7F, 0x43, 0x02) + maximumBytes + sourceBytes
        + [0x05, 0x00, 0x12, 0x09]
    static let messageReportReplyEdges = prefix(0x03, 0x43, 0x02) + maximumBytes + sourceBytes
        + [0x00, 0x00, 0x21, 0x03]
    static let messageReportReplyEmpty = prefix(0x7E, 0x43, 0x02) + maximumBytes + sourceBytes
        + [0x00, 0x00, 0x00, 0x00]
    /// Table 46: no body.
    static let messageReportEndFunctionBlock = prefix(0x7F, 0x44, 0x02) + maximumBytes + sourceBytes
    static let messageReportEndChannel = prefix(0x0F, 0x44, 0x02) + maximumBytes + sourceBytes
    static let messageReportEndGroup = prefix(0x7E, 0x44, 0x02) + sourceBytes + maximumBytes
    static let messageReportGoldens: [[UInt8]] = [
        messageReportInquiryMixed, messageReportInquiryChannels, messageReportInquiryGroup, messageReportReplyMixed,
        messageReportReplyEdges, messageReportReplyEmpty, messageReportEndFunctionBlock, messageReportEndChannel,
        messageReportEndGroup
    ]

    // MARK: Message Report fixtures (the bits are named, not written as numbers)

    static let messageReportSelectionMixed = MIDICIReportSelection(
        system: [.mtcQuarterFrame, .songSelect], channelControllers: [.controlChange, .programChange],
        noteData: [.notes, .registeredPerNoteController])
    static let messageReportSelectionChannels = MIDICIReportSelection(
        channelControllers: [
            .pitchbend, .controlChange, .registeredController, .assignableController, .programChange, .channelPressure
        ],
        noteData: [
            .notes, .polyPressure, .perNotePitchbend, .registeredPerNoteController, .assignablePerNoteController
        ])
    static let messageReportSelectionPitchbend = MIDICIReportSelection(channelControllers: [.pitchbend])
    static let messageReportSelectionEdges = MIDICIReportSelection(
        channelControllers: [.pitchbend, .channelPressure], noteData: [.notes, .polyPressure])

    static func messageReportMessages() throws -> [MIDICIProcessInquiryMessage] {
        let maximum: UInt32 = 0x0FFF_FEFF
        let source: UInt32 = 0x0123_4567
        return [
            .messageReportInquiry(
                try header(.ci12, device: 0x7F, destination: maximum), dataControl: .full,
                selection: messageReportSelectionMixed),
            .messageReportInquiry(
                try header(.ci12, device: 0x03, destination: maximum), dataControl: .nonDefaultValues,
                selection: messageReportSelectionChannels),
            .messageReportInquiry(
                try header(.ci12, device: 0x7E, source: maximum, destination: source), dataControl: .beginEndOnly,
                selection: messageReportSelectionPitchbend),
            .messageReportReply(
                try header(.ci12, device: 0x7F, source: maximum, destination: source),
                selection: messageReportSelectionMixed),
            .messageReportReply(
                try header(.ci12, device: 0x03, source: maximum, destination: source),
                selection: messageReportSelectionEdges),
            .messageReportReply(
                try header(.ci12, device: 0x7E, source: maximum, destination: source),
                selection: MIDICIReportSelection()),
            .messageReportEnd(try header(.ci12, device: 0x7F, source: maximum, destination: source)),
            .messageReportEnd(try header(.ci12, device: 0x0F, source: maximum, destination: source)),
            .messageReportEnd(try header(.ci12, device: 0x7E, destination: maximum))
        ]
    }

    /// The selection of a report Inquiry or Reply; nil for the other kinds.
    static func processSelection(_ message: MIDICIProcessInquiryMessage) -> MIDICIReportSelection? {
        switch message {
        case let .messageReportInquiry(_, _, selection), let .messageReportReply(_, selection): return selection
        default: return nil
        }
    }

    /// The bytes a successful decode of `bytes` must encode to: the reserved bits of each bitmap and the reserved
    /// byte written as 0 (Tables 42, 43 and 45). Offsets follow the layout: 0x41 has the features at 13; 0x42 the
    /// Message Data Control at 13, then System, the reserved byte, Channel and Note at 14 to 17; 0x43 the same from 13.
    static func processNormalised(_ bytes: [UInt8]) -> [UInt8] {
        var copy = bytes
        switch bytes[3] {
        case 0x41:
            copy[13] &= 0x01
        case 0x42:
            copy[14] &= 0x07
            copy[15] = 0x00
            copy[16] &= 0x3F
            copy[17] &= 0x1F
        case 0x43:
            copy[13] &= 0x07
            copy[14] = 0x00
            copy[15] &= 0x3F
            copy[16] &= 0x1F
        default:
            break
        }
        return copy
    }

    /// The refusal `encode` owes for the device id of `bytes`, if any: 0x40, 0x41 and a 0x42 that asks for System
    /// Messages are for the Function Block, 0x7F (sections 9.2, 9.3 and 9.5).
    static func processDeviceRefusal(_ bytes: [UInt8]) -> MIDICIRefusal? {
        let device = bytes[1]
        guard device != 0x7F else { return nil }
        switch bytes[3] {
        case 0x40, 0x41: return .deviceNotFunctionBlock(device)
        case 0x42: return bytes[14] & 0x07 == 0 ? nil : .systemReportNeedsFunctionBlock(device)
        default: return nil
        }
    }

    // MARK: Goldens, decode and encode

    @Test func everyMessageReportMessageEncodesToItsGoldenBytes() throws {
        let messages = try Self.messageReportMessages()
        try #require(messages.count == Self.messageReportGoldens.count)
        for (message, golden) in zip(messages, Self.messageReportGoldens) {
            #expect(try message.encode(limits: .standard) == golden)
        }
        #expect(Self.messageReportGoldens.map(\.count) == [18, 18, 18, 17, 17, 17, 13, 13, 13])
        let inquiry = MIDICIProcessInquiryKind.messageReportInquiry
        let reply = MIDICIProcessInquiryKind.messageReportReply
        let end = MIDICIProcessInquiryKind.messageReportEnd
        #expect(messages.map(\.kind) == [inquiry, inquiry, inquiry, reply, reply, reply, end, end, end])
    }

    @Test func everyMessageReportGoldenDecodesToItsExactTypedValueAndSurvivesTheRoundTrip() throws {
        let messages = try Self.messageReportMessages()
        try #require(messages.count == Self.messageReportGoldens.count)
        for (golden, message) in zip(Self.messageReportGoldens, messages) {
            let decoded = try MIDICIProcessInquiryMessage.decode(payload: golden, limits: .standard)
            #expect(decoded == message)
            #expect(try decoded.encode(limits: .standard) == golden)
        }
        let decoded = try MIDICIProcessInquiryMessage.decode(
            payload: Self.messageReportInquiryMixed, limits: .standard)
        guard case let .messageReportInquiry(header, control, selection) = decoded else {
            Issue.record("expected an Inquiry: MIDI Message Report")
            return
        }
        #expect(header.device.rawValue == 0x7F && header.format == .ci12)
        #expect(header.source.rawValue == 0x0123_4567 && header.destination.rawValue == 0x0FFF_FEFF)
        #expect(control == .full && control.rawValue == 0x7F)
        #expect(selection.system == [.mtcQuarterFrame, .songSelect] && selection.system.rawValue == 0x05)
        #expect(selection.channelControllers == [.controlChange, .programChange])
        #expect(selection.noteData == [.notes, .registeredPerNoteController])
        #expect(selection.wireBytes == [0x05, 0x00, 0x12, 0x09])
    }

    @Test func theReplyHasNoDataControlByteAndAnInquiryShapedReplyHasOneByteTooMany() throws {
        let inquiryShaped = Self.prefix(0x7F, 0x43, 0x02) + Self.maximumBytes + Self.sourceBytes
            + [0x7F, 0x05, 0x00, 0x12, 0x09]
        #expect(Self.processDecodeRefusal(inquiryShaped) == .trailingBytes(1))
        let replyShaped = Self.prefix(0x7F, 0x42, 0x02) + Self.sourceBytes + Self.maximumBytes
            + [0x05, 0x00, 0x12, 0x09]
        #expect(Self.processDecodeRefusal(replyShaped) == .truncated(need: 18, have: 17))
    }

    // MARK: Bitmaps

    /// The named bits of each bitmap with the wire value of the table entry, D0 first (Tables 42, 43 and 45).
    static let messageReportSystemBits: [(bit: MIDICIReportSystemMessages, wire: UInt8)] = [
        (.mtcQuarterFrame, 0x01), (.songPosition, 0x02), (.songSelect, 0x04)
    ]
    static let messageReportChannelBits: [(bit: MIDICIReportChannelControllers, wire: UInt8)] = [
        (.pitchbend, 0x01), (.controlChange, 0x02), (.registeredController, 0x04), (.assignableController, 0x08),
        (.programChange, 0x10), (.channelPressure, 0x20)
    ]
    static let messageReportNoteBits: [(bit: MIDICIReportNoteData, wire: UInt8)] = [
        (.notes, 0x01), (.polyPressure, 0x02), (.perNotePitchbend, 0x04), (.registeredPerNoteController, 0x08),
        (.assignablePerNoteController, 0x10)
    ]

    @Test func everyNamedBitHasTheWireValueOfItsTableEntry() throws {
        #expect(Self.messageReportSystemBits.map(\.bit.rawValue) == Self.messageReportSystemBits.map(\.wire))
        #expect(Self.messageReportChannelBits.map(\.bit.rawValue) == Self.messageReportChannelBits.map(\.wire))
        #expect(Self.messageReportNoteBits.map(\.bit.rawValue) == Self.messageReportNoteBits.map(\.wire))
        #expect(MIDICIProcessInquiryFeatures.midiMessageReport.rawValue == 0x01)
    }

    /// Each bit of one bitmap alone, typed to wire and wire to typed, in an Inquiry (the bitmap at `offset`) and in a
    /// Reply (one byte earlier): the wire value of the table entry is the only non-zero byte of the body, and decode
    /// returns the same message. The expected bytes come from the table, not from the bit under test.
    static func checkSingleBits<Bitmap: OptionSet>(
        _ bits: [(bit: Bitmap, wire: UInt8)], in path: WritableKeyPath<MIDICIReportSelection, Bitmap>, offset: Int
    ) throws where Bitmap.RawValue == UInt8 {
        let inquiryHeader = try header(.ci12, device: 0x7F, destination: 0x0FFF_FEFF)
        let replyHeader = try header(.ci12, device: 0x7F, source: 0x0FFF_FEFF, destination: 0x0123_4567)
        let emptyInquiry = replacing(messageReportInquiryMixed, range: 13..<18, with: [UInt8](repeating: 0, count: 5))
        let emptyReply = replacing(messageReportReplyMixed, range: 13..<17, with: [UInt8](repeating: 0, count: 4))
        for (bit, wire) in bits {
            var selection = MIDICIReportSelection()
            selection[keyPath: path] = bit
            let inquiry = MIDICIProcessInquiryMessage.messageReportInquiry(
                inquiryHeader, dataControl: .beginEndOnly, selection: selection)
            let reply = MIDICIProcessInquiryMessage.messageReportReply(replyHeader, selection: selection)
            let inquiryBytes = replacing(emptyInquiry, at: offset, with: wire)
            let replyBytes = replacing(emptyReply, at: offset - 1, with: wire)
            #expect(try inquiry.encode(limits: .standard) == inquiryBytes)
            #expect(try reply.encode(limits: .standard) == replyBytes)
            #expect(try MIDICIProcessInquiryMessage.decode(payload: inquiryBytes, limits: .standard) == inquiry)
            #expect(try MIDICIProcessInquiryMessage.decode(payload: replyBytes, limits: .standard) == reply)
        }
    }

    @Test func everySingleBitIsWrittenAloneAndReadBackAlone() throws {
        try Self.checkSingleBits(Self.messageReportSystemBits, in: \.system, offset: 14)
        try Self.checkSingleBits(Self.messageReportChannelBits, in: \.channelControllers, offset: 16)
        try Self.checkSingleBits(Self.messageReportNoteBits, in: \.noteData, offset: 17)
    }

    /// All 128 wire values of one bitmap byte: decode keeps `value & mask` and encode writes it back with nothing
    /// else of the message changed; 0x80 or more is refused at that offset.
    static func checkBitmap<Bitmap: OptionSet>(
        _ path: KeyPath<MIDICIReportSelection, Bitmap>, mask: UInt8, golden: [UInt8], offset: Int
    ) throws where Bitmap.RawValue == UInt8 {
        for value in UInt8(0)...0x7F {
            let payload = replacing(golden, at: offset, with: value)
            let decoded = try MIDICIProcessInquiryMessage.decode(payload: payload, limits: .standard)
            let selection = try #require(processSelection(decoded))
            #expect(selection[keyPath: path].rawValue == value & mask)
            #expect(try decoded.encode(limits: .standard) == replacing(golden, at: offset, with: value & mask))
        }
        for value in UInt8(0x80)...0xFF {
            let payload = replacing(golden, at: offset, with: value)
            #expect(processDecodeRefusal(payload) == .dataByteHigh(offset: offset))
        }
    }

    @Test func eachBitmapKeepsItsDefinedBitsAndDropsTheReservedOnes() throws {
        let inquiry = Self.messageReportInquiryMixed
        try Self.checkBitmap(\.system, mask: 0x07, golden: inquiry, offset: 14)
        try Self.checkBitmap(\.channelControllers, mask: 0x3F, golden: inquiry, offset: 16)
        try Self.checkBitmap(\.noteData, mask: 0x1F, golden: inquiry, offset: 17)
        let reply = Self.messageReportReplyMixed
        try Self.checkBitmap(\.system, mask: 0x07, golden: reply, offset: 13)
        try Self.checkBitmap(\.channelControllers, mask: 0x3F, golden: reply, offset: 15)
        try Self.checkBitmap(\.noteData, mask: 0x1F, golden: reply, offset: 16)
    }

    @Test func theBitmapTypesNeverHoldAReservedBit() throws {
        #expect(MIDICIReportSystemMessages(rawValue: 0xFF).rawValue == 0x07)
        #expect(MIDICIReportChannelControllers(rawValue: 0xFF).rawValue == 0x3F)
        #expect(MIDICIReportNoteData(rawValue: 0xFF).rawValue == 0x1F)
        var selection = MIDICIReportSelection()
        selection.system.formUnion(MIDICIReportSystemMessages(rawValue: 0xF8))
        selection.channelControllers.formUnion(MIDICIReportChannelControllers(rawValue: 0xC0))
        selection.noteData.formUnion(MIDICIReportNoteData(rawValue: 0xE0))
        #expect(selection == MIDICIReportSelection())
        #expect(selection.wireBytes == [0x00, 0x00, 0x00, 0x00])
        selection.system.insert(.songPosition)
        selection.channelControllers.insert(.channelPressure)
        selection.noteData.insert(.assignablePerNoteController)
        #expect(selection.wireBytes == [0x02, 0x00, 0x20, 0x10])
        #expect(MIDICIReportSelection.wireByteCount == 4)
    }

    @Test func theReservedByteIsIgnoredOnDecodeAndWrittenAsZero() throws {
        let cases: [(golden: [UInt8], offset: Int)] = [
            (Self.messageReportInquiryMixed, 15), (Self.messageReportReplyMixed, 14)
        ]
        for (golden, offset) in cases {
            let expected = try MIDICIProcessInquiryMessage.decode(payload: golden, limits: .standard)
            #expect(golden[offset] == 0x00)
            for value in UInt8(0)...0x7F {
                let payload = Self.replacing(golden, at: offset, with: value)
                let decoded = try MIDICIProcessInquiryMessage.decode(payload: payload, limits: .standard)
                #expect(decoded == expected)
                #expect(try decoded.encode(limits: .standard) == golden)
            }
            for value in UInt8(0x80)...0xFF {
                let payload = Self.replacing(golden, at: offset, with: value)
                #expect(Self.processDecodeRefusal(payload) == .dataByteHigh(offset: offset))
            }
        }
    }

    // MARK: Message Data Control

    @Test func theDataControlIsKeptAsReceivedFromZeroToSevenF() throws {
        #expect(try MIDICIReportDataControl.make(0x00) == .beginEndOnly)
        #expect(try MIDICIReportDataControl.make(0x01) == .nonDefaultValues)
        #expect(try MIDICIReportDataControl.make(0x7F) == .full)
        for value in UInt8(0)...0x7F {
            let control = try MIDICIReportDataControl.make(value)
            #expect(control.rawValue == value)
            #expect(control.isReserved == (value > 0x01 && value < 0x7F))
            let payload = Self.replacing(Self.messageReportInquiryMixed, at: 13, with: value)
            let decoded = try MIDICIProcessInquiryMessage.decode(payload: payload, limits: .standard)
            guard case let .messageReportInquiry(_, kept, _) = decoded else {
                Issue.record("expected an Inquiry: MIDI Message Report")
                return
            }
            #expect(kept == control)
            #expect(try decoded.encode(limits: .standard) == payload)
        }
        for value in UInt8(0x80)...0xFF {
            #expect(throws: MIDICIRefusal.fieldOutOfRange(.dataControl, value: Int(value))) {
                try MIDICIReportDataControl.make(value)
            }
            let payload = Self.replacing(Self.messageReportInquiryMixed, at: 13, with: value)
            #expect(Self.processDecodeRefusal(payload) == .dataByteHigh(offset: 13))
        }
    }

    // MARK: Device rules of encode

    @Test func anInquiryThatAsksForSystemMessagesIsForTheFunctionBlockOnly() throws {
        for system: UInt8 in [0x01, 0x02, 0x04, 0x07] {
            let selection = MIDICIReportSelection(system: MIDICIReportSystemMessages(rawValue: system))
            for device in UInt8(0)...0x7E {
                let header = try Self.header(.ci12, device: device, destination: 0)
                let message = MIDICIProcessInquiryMessage.messageReportInquiry(
                    header, dataControl: .full, selection: selection)
                #expect(Self.processEncodeRefusal(message) == .systemReportNeedsFunctionBlock(device))
            }
            let functionBlock = try Self.header(.ci12, device: 0x7F, destination: 0)
            let accepted = MIDICIProcessInquiryMessage.messageReportInquiry(
                functionBlock, dataControl: .full, selection: selection)
            #expect(try accepted.encode(limits: .standard)[14] == system)
        }
        let mixedOnAChannel = try Self.header(.ci12, device: 0x03, destination: 0x0FFF_FEFF)
        let mixed = MIDICIProcessInquiryMessage.messageReportInquiry(
            mixedOnAChannel, dataControl: .full, selection: Self.messageReportSelectionMixed)
        #expect(Self.processEncodeRefusal(mixed) == .systemReportNeedsFunctionBlock(0x03))
        let onAChannel = Self.replacing(Self.messageReportInquiryMixed, at: 1, with: 0x03)
        let decoded = try MIDICIProcessInquiryMessage.decode(payload: onAChannel, limits: .standard)
        let selection = Self.processSelection(decoded)
        #expect(decoded.header.device.rawValue == 0x03 && selection == Self.messageReportSelectionMixed)
        #expect(Self.processEncodeRefusal(decoded) == .systemReportNeedsFunctionBlock(0x03))
        let reservedOnly = Self.replacing(onAChannel, at: 14, with: 0x78)
        let reserved = try MIDICIProcessInquiryMessage.decode(payload: reservedOnly, limits: .standard)
        #expect(Self.processSelection(reserved)?.system.isEmpty == true)
        #expect(try reserved.encode(limits: .standard) == Self.replacing(onAChannel, at: 14, with: 0x00))
    }

    @Test func aChannelOnlyInquiryTheReplyAndTheEndAcceptEveryDeviceID() throws {
        for device in UInt8(0)...0x7F {
            let header = try Self.header(.ci12, device: device, destination: 0)
            let messages: [MIDICIProcessInquiryMessage] = [
                .messageReportInquiry(
                    header, dataControl: .nonDefaultValues, selection: Self.messageReportSelectionChannels),
                .messageReportReply(header, selection: Self.messageReportSelectionMixed),
                .messageReportEnd(header)
            ]
            for message in messages {
                let bytes = try message.encode(limits: .standard)
                #expect(bytes[1] == device)
                #expect(try MIDICIProcessInquiryMessage.decode(payload: bytes, limits: .standard) == message)
            }
        }
    }

    // MARK: Seeded mutations

    @Test func seededMutationsOfTheProcessInquiryGoldensDecodeOnlyToCanonicalBytes() throws {
        var random = Xorshift(seed: 0x5049_4332)
        var total = 0
        var decoded = 0
        for golden in Self.processGoldens {
            for _ in 0..<400 {
                var bytes = golden
                let offset = Int(random.next() % UInt64(bytes.count))
                let value = UInt8(truncatingIfNeeded: random.next())
                bytes[offset] = random.next() % 8 == 0 ? value : value & 0x7F
                if random.next() % 4 == 0 { bytes.removeLast() }
                total += 1
                guard let message = try? MIDICIProcessInquiryMessage.decode(payload: bytes, limits: .standard)
                else { continue }
                decoded += 1
                if let refusal = Self.processDeviceRefusal(bytes) {
                    #expect(Self.processEncodeRefusal(message) == refusal)
                } else {
                    #expect(try message.encode(limits: .standard) == Self.processNormalised(bytes))
                }
            }
        }
        // The fixed seed decodes about half of the 5,200 mutations; a quarter of the total keeps the loop from
        // passing by refusing (or skipping) nearly everything, and `total` keeps the refusal side non-empty.
        #expect(total == 5_200)
        #expect(decoded > 1_300 && decoded < total)
    }
}
