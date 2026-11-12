/// MIDI-CI Process Inquiry, sub-id 2 0x40 to 0x44 (M2-101-UM v1.2, section 9), kept apart from `MIDICIMessage`,
/// `MIDICIProfileMessage`, `MIDICIPropertyCapabilityMessage` and `MIDICIEndpointMessage` (whose decoders still refuse
/// 0x40 to 0x44 with `unknownSubID`). An Initiator asks which Process Inquiry features a Responder has (0x40, 0x41),
/// then asks for a report of its current MIDI state (0x42); the Responder opens the report with a Reply (0x43) and
/// closes it with an End of MIDI Message Report (0x44). This type is the codec only: it sends nothing, keeps no state
/// and reports no MIDI data.
///
/// Layout of the payload as `MIDI1Event.sysEx` delivers it (F0 and F7 excluded). The common 13-byte header is
/// `7E, device id, 0D, sub-id 2, format, source MUID (4), destination MUID (4)`, MUIDs 7 bits per byte, least
/// significant first. Then:
/// - 0x40 Inquiry: Process Inquiry Capabilities (Table 40) and 0x44 End of MIDI Message Report (Table 46): nothing.
///   The payload is exactly 13 bytes.
/// - 0x41 Reply to Process Inquiry Capabilities (Tables 41 and 42): the features bitmap (1 byte). 14 bytes.
/// - 0x42 Inquiry: MIDI Message Report (Tables 43 and 44): the Message Data Control, the System Messages bitmap, a
///   reserved byte, the Channel Controller bitmap and the Note Data bitmap (1 byte each). 18 bytes.
/// - 0x43 Reply to MIDI Message Report (Table 45): the four bytes of 0x42 after the Message Data Control. 17 bytes.
///
/// All five exist only from CI 1.2 on (section 1.3): format 0x01 is refused with `unsupportedFormat(1)`, as a CI 1.1
/// ACK is. Decode takes any other format byte as unsupported, too. All five are addressed to one MUID: section 3.3.3
/// lists the messages that may use the Broadcast MUID and none of 0x40 to 0x44 is among them, so a broadcast
/// destination is `destinationIsBroadcast`, on decode and on encode.
///
/// Lenient receive, strict send. Decode keeps every 7-bit device id as received, 0x10 to 0x7D (reserved in Tables 43
/// and 45) included, and ignores the reserved bits of every bitmap and the reserved byte of 0x42 and 0x43. Encode
/// writes those as 0 and refuses any device id but 0x7F, the Function Block, where the specification demands it: for
/// 0x40 and 0x41 (`deviceNotFunctionBlock`; Tables 40 and 41, sections 9.2 and 9.3) and for a 0x42 that asks for
/// System Messages (`systemReportNeedsFunctionBlock`; section 9.5). 0x43 and 0x44 take every device id: a Reply
/// echoes the device id of its Inquiry (section 9.6), which one message cannot know. The rules between messages are
/// not checked here: that a Reply sets only bits that were asked for, that it echoes the device id, and that a
/// channel that is not in use is answered with a NAK.
///
/// Provenance: the layout and the bits follow M2-101-UM v1.2 (11 May 2023), section 9 and Tables 40 to 46. They were
/// cross-checked against ktmidi (`ktmidi-ci/.../ci/CIFactory.kt` `midiCIProcessInquiryCapabilities` to
/// `midiCIEndOfMidiMessage`, the five sizes in `Message.kt` and the bit names in `MidiCIConstants.kt`, commit
/// 5718957), AM_MIDI2.0Lib (`src/midiCIProcessor.cpp` `processPISysex`, which ignores these messages for CI version
/// 1, commit 7fa1b0c) and JUCE (`modules/juce_midi_ci/detail/juce_CIMessageMeta.h`, commit d60b7a7). JUCE alone
/// differs: it writes the Reply to MIDI Message Report like the Inquiry, with the Message Data Control first, which
/// Table 45 does not have. The table wins here, as ktmidi and AM_MIDI2.0Lib agree with it. No byte array was copied
/// from any source.
enum MIDICIProcessInquiryMessage: Equatable, Hashable, Sendable {
    case capabilitiesInquiry(MIDICIHeader)
    case capabilitiesReply(MIDICIHeader, features: MIDICIProcessInquiryFeatures)
    case messageReportInquiry(MIDICIHeader, dataControl: MIDICIReportDataControl, selection: MIDICIReportSelection)
    case messageReportReply(MIDICIHeader, selection: MIDICIReportSelection)
    case messageReportEnd(MIDICIHeader)

    /// The exact payload length of each message: the header, then nothing (0x40, 0x44), the features byte (0x41), the
    /// Message Data Control and the selection (0x42) or the selection alone (0x43).
    static let capabilitiesInquiryBytes = MIDICILayout.headerBytes
    static let capabilitiesReplyBytes = MIDICILayout.headerBytes + 1
    static let messageReportInquiryBytes = MIDICILayout.headerBytes + 1 + MIDICIReportSelection.wireByteCount
    static let messageReportReplyBytes = MIDICILayout.headerBytes + MIDICIReportSelection.wireByteCount
    static let messageReportEndBytes = MIDICILayout.headerBytes

    static let destinationRule = MIDICIDestinationRule.oneMUID

    var header: MIDICIHeader {
        switch self {
        case let .capabilitiesInquiry(header), let .capabilitiesReply(header, _),
             let .messageReportInquiry(header, _, _), let .messageReportReply(header, _),
             let .messageReportEnd(header):
            return header
        }
    }

    var kind: MIDICIProcessInquiryKind {
        switch self {
        case .capabilitiesInquiry: return .capabilitiesInquiry
        case .capabilitiesReply: return .capabilitiesReply
        case .messageReportInquiry: return .messageReportInquiry
        case .messageReportReply: return .messageReportReply
        case .messageReportEnd: return .messageReportEnd
        }
    }

    // MARK: Decode

    /// Decodes a payload without F0 and F7. The first failing step wins; steps 1 to 4 are
    /// `MIDICIMessage.checkEnvelope` and steps 1 to 11 follow the shared header order of
    /// `MIDICIMessage.decode(payload:limits:)`:
    ///  1. more than `limits.maximumPayloadBytes` bytes is `payloadTooLarge`; an empty payload is `truncated(1, 0)`;
    ///  2. byte 0 is not 0x7E, or (with 3 bytes or more) byte 2 is not 0x0D: `notCI`;
    ///  3. the first byte from offset 1 on that is 0x80 or more: `dataByteHigh(offset)` (this covers the device id,
    ///     the Message Data Control, every bitmap and the reserved byte);
    ///  4. fewer than 5 bytes: `truncated(5)`;
    ///  5. sub-id 2 (byte 3) not 0x40 to 0x44: `unknownSubID` (0x45 included: Appendix D lists no message there);
    ///  6. format (byte 4) not 2: `unsupportedFormat` (0x01 included: the messages are CI 1.2 only);
    ///  7. fewer than 13 bytes: `truncated(13)`;
    ///  8. the exact length of the kind (13, 14, 18, 17 and 13 bytes for 0x40 to 0x44): fewer is `truncated(expected)`,
    ///     more is `trailingBytes`;
    ///  9. a source or destination MUID that is not assignable: `invalidMUID` (the source first);
    /// 10. addressing: `sourceIsBroadcast`, then `destinationIsBroadcast`;
    /// 11. the device id, wrapped as received: any 7-bit value is kept and no device rule of encode applies;
    /// 12. the body: the Message Data Control kept as received, the bitmaps through their masking initialisers and
    ///     the reserved byte ignored.
    /// The device id wrapper of step 11 and the `fieldOutOfRange` refusal of step 12 are defensive: step 3 makes them
    /// unreachable (by inspection; no test reaches them).
    static func decode(payload: [UInt8], limits: MIDICILimits) throws(MIDICIRefusal) -> MIDICIProcessInquiryMessage {
        try MIDICIMessage.checkEnvelope(payload, limits: limits)
        guard let kind = MIDICIProcessInquiryKind(rawValue: payload[3]) else { throw .unknownSubID(payload[3]) }
        guard MIDICIFormat(rawValue: payload[4]) == .ci12 else { throw .unsupportedFormat(payload[4]) }
        guard payload.count >= MIDICILayout.headerBytes else {
            throw .truncated(need: MIDICILayout.headerBytes, have: payload.count)
        }
        let expected = kind.payloadBytes
        guard payload.count >= expected else { throw .truncated(need: expected, have: payload.count) }
        guard payload.count == expected else { throw .trailingBytes(payload.count - expected) }
        var reader = MIDICIReader(payload, offset: MIDICILayout.prefixBytes)
        let source = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        let destination = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        try MIDICIMessage.validateAddressing(destinationRule, source: source, destination: destination)
        let device = try MIDICIMessage.wrapDevice(payload[1])
        let header = MIDICIHeader(device: device, format: .ci12, source: source, destination: destination)
        return try decodeBody(kind, header: header, reader: &reader)
    }

    private static func decodeBody(
        _ kind: MIDICIProcessInquiryKind, header: MIDICIHeader, reader: inout MIDICIReader
    ) throws(MIDICIRefusal) -> MIDICIProcessInquiryMessage {
        switch kind {
        case .capabilitiesInquiry:
            return .capabilitiesInquiry(header)
        case .capabilitiesReply:
            return .capabilitiesReply(header, features: MIDICIProcessInquiryFeatures(rawValue: try reader.byte()))
        case .messageReportInquiry:
            let dataControl = try MIDICIReportDataControl.make(reader.byte())
            return .messageReportInquiry(header, dataControl: dataControl, selection: try .read(&reader))
        case .messageReportReply:
            return .messageReportReply(header, selection: try .read(&reader))
        case .messageReportEnd:
            return .messageReportEnd(header)
        }
    }

    // MARK: Encode

    /// The canonical payload (without F0 and F7). Refusal order: a CI 1.1 header (`unsupportedFormat(1)`),
    /// `sourceIsBroadcast`, `destinationIsBroadcast`, the device rules (`deviceNotFunctionBlock`,
    /// `systemReportNeedsFunctionBlock`), last `payloadTooLarge`. A bitmap cannot hold a reserved bit and the Message
    /// Data Control is 7-bit by construction (`make`); the reserved byte is written as 0x00.
    func encode(limits: MIDICILimits) throws(MIDICIRefusal) -> [UInt8] {
        let header = self.header
        guard header.format == .ci12 else { throw .unsupportedFormat(header.format.rawValue) }
        try MIDICIMessage.validateAddressing(
            Self.destinationRule, source: header.source, destination: header.destination)
        try checkDevice()
        let body = self.body
        let total = MIDICILayout.headerBytes + body.count
        guard total <= limits.maximumPayloadBytes else { throw .payloadTooLarge(total) }
        let prefix: [UInt8] = [
            MIDICILayout.universalNonRealTime, header.device.rawValue, MIDICILayout.ciSubID1,
            kind.rawValue, header.format.rawValue
        ]
        return prefix + MIDICIWire.encode(header.source.rawValue, byteCount: 4)
            + MIDICIWire.encode(header.destination.rawValue, byteCount: 4) + body
    }

    /// The two device rules of encode. 0x40, 0x41 and a 0x42 that asks for System Messages are for the Function
    /// Block only; the other messages take any device id.
    private func checkDevice() throws(MIDICIRefusal) {
        let device = header.device
        switch self {
        case .capabilitiesInquiry, .capabilitiesReply:
            guard device.isAllCall else { throw .deviceNotFunctionBlock(device.rawValue) }
        case let .messageReportInquiry(_, _, selection):
            guard device.isAllCall || selection.system.isEmpty else {
                throw .systemReportNeedsFunctionBlock(device.rawValue)
            }
        case .messageReportReply, .messageReportEnd:
            break
        }
    }

    private var body: [UInt8] {
        switch self {
        case .capabilitiesInquiry, .messageReportEnd:
            return []
        case let .capabilitiesReply(_, features):
            return [features.rawValue]
        case let .messageReportInquiry(_, dataControl, selection):
            return [dataControl.rawValue] + selection.wireBytes
        case let .messageReportReply(_, selection):
            return selection.wireBytes
        }
    }
}
