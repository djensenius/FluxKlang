/// Sub-id 2 of the endpoint information messages handled by `MIDICIEndpointMessage`.
enum MIDICIEndpointKind: UInt8, Sendable {
    case inquiry = 0x72
    case reply = 0x73
}

/// The 7-bit status byte of an Endpoint Information Inquiry and its Reply: which information is asked for. Only
/// 0x00 (Product Instance ID) is defined in MIDI-CI 1.2 (JUCE: "Only status 0 is defined at time of writing";
/// ktmidi `ENDPOINT_STATUS_PRODUCT_INSTANCE_ID = 0`). Any other 7-bit value is kept as received, not refused:
/// ktmidi answers an unknown status with a Reply that carries the same status and no data, and refusing it would
/// lose that answer. Whether to act on an unknown status is the caller's decision.
struct MIDICIEndpointStatus: Equatable, Hashable, Sendable {
    static let productInstanceID = MIDICIEndpointStatus(validated: 0x00)

    private let storage: UInt8

    var rawValue: UInt8 { storage }

    private init(validated storage: UInt8) {
        self.storage = storage
    }

    static func make(_ raw: UInt8) throws(MIDICIRefusal) -> MIDICIEndpointStatus {
        guard raw < 0x80 else { throw .fieldOutOfRange(.endpointStatus, value: Int(raw)) }
        return MIDICIEndpointStatus(validated: raw)
    }
}

/// The body of a Reply to Endpoint Information: the status it answers and the information data, raw 7-bit bytes in
/// wire order, at most `MIDICIEndpointMessage.maximumInformationBytes`. The codec does not judge the data;
/// `productInstanceID` is the typed view for status 0x00.
struct MIDICIEndpointInformation: Equatable, Hashable, Sendable {
    /// The longest Product Instance ID, and its characters (inclusive): JUCE `DeviceOptions` stores it in a
    /// `std::array<char, 16>` of characters 32 to 126; ktmidi `Messenger` requires at most 16 characters, each 32
    /// to 126, and invalidates the responder's MUID otherwise.
    static let maximumProductInstanceIDBytes = 16
    static let productInstanceIDCharacters: ClosedRange<UInt8> = 0x20...0x7E

    private(set) var status: MIDICIEndpointStatus
    private(set) var data: [UInt8]

    private init(status: MIDICIEndpointStatus, data: [UInt8]) {
        self.status = status
        self.data = data
    }

    /// Refuses data longer than `MIDICIEndpointMessage.maximumInformationBytes` (`informationTooLong`, checked
    /// before any byte is read), then the first byte of 0x80 or more (`fieldOutOfRange(.endpointInformation)`).
    static func make(status: MIDICIEndpointStatus, data: [UInt8]) throws(MIDICIRefusal) -> MIDICIEndpointInformation {
        let limit = MIDICIEndpointMessage.maximumInformationBytes
        guard data.count <= limit else { throw .informationTooLong(count: data.count, limit: limit) }
        if let high = data.first(where: { $0 >= 0x80 }) {
            throw .fieldOutOfRange(.endpointInformation, value: Int(high))
        }
        return MIDICIEndpointInformation(status: status, data: data)
    }

    /// The Product Instance ID as text, or nil when the status is not 0x00, the data is empty (ktmidi sends empty
    /// data when it has no id), longer than 16 bytes, or holds a byte outside 0x20...0x7E. A nil here is not a
    /// decode refusal: the raw `data` stays available.
    var productInstanceID: String? {
        guard status == .productInstanceID, !data.isEmpty, data.count <= Self.maximumProductInstanceIDBytes,
              data.allSatisfy(Self.productInstanceIDCharacters.contains) else { return nil }
        var scalars = String.UnicodeScalarView()
        for byte in data { scalars.append(Unicode.Scalar(byte)) }
        return String(scalars)
    }
}

/// MIDI-CI Inquiry: Endpoint Information (sub-id 2 0x72) and Reply to Endpoint Information (0x73), kept apart from
/// `MIDICIMessage`, `MIDICIProfileMessage` and `MIDICIPropertyCapabilityMessage` (whose decoders still refuse 0x72
/// and 0x73 with `unknownSubID`). The Reply with status 0x00 carries the Product Instance ID, which tells apart two
/// units of the same product that share manufacturer, family, model and revision.
///
/// Layout of the payload as `MIDI1Event.sysEx` delivers it (F0 and F7 excluded). The common 13-byte header is
/// `7E, device id, 0D, sub-id 2, format, source MUID (4), destination MUID (4)`, MUIDs 7 bits per byte, least
/// significant first. Then:
/// - 0x72 Inquiry: the status (1 byte). The payload is exactly 14 bytes.
/// - 0x73 Reply: the status (1 byte), the information length (2 bytes, 14 bit, least significant first) and that
///   many information bytes. The payload is exactly 16 plus the declared length.
/// Both exist only from CI 1.2 on: format 0x01 is refused with `unsupportedFormat(1)`, as a CI 1.1 ACK is.
/// The device id is wrapped as received; the references send 0x7F.
///
/// Provenance: the MIDI Association specification was not reachable. The layout was cross-checked against
/// AM_MIDI2.0Lib (`src/midiCIMessageCreate.cpp` `sendEndpointInfoRequest` / `sendEndpointInfoReply`, which return
/// 0 bytes for CI version 1; `src/midiCIProcessor.cpp`, which reads the status at offset 13 and the 14-bit length
/// at 14 and 15), JUCE (`modules/juce_midi_ci/detail/juce_CIMessageMeta.h`, a status byte and a span with two size
/// bytes, written in every version) and ktmidi (`ktmidi-ci/.../ci/CIFactory.kt` `midiCIEndpointMessage` /
/// `midiCIEndpointMessageReply`, 14 and 16 + n bytes, and `Messenger.kt`, "only available in MIDI-CI 1.2 or
/// later"). No byte array was copied from any source.
enum MIDICIEndpointMessage: Equatable, Hashable, Sendable {
    case inquiry(MIDICIHeader, status: MIDICIEndpointStatus)
    case reply(MIDICIHeader, MIDICIEndpointInformation)

    /// The inclusive bound of the information data, far below the 14-bit length field (16,383). The only defined
    /// item, the Product Instance ID, is at most 16 bytes; AM_MIDI2.0Lib copies the data into a 256-byte buffer.
    static let maximumInformationBytes = 256
    /// Bytes of the Inquiry, of the Reply before its information data, and of the information length.
    static let inquiryBytes = MIDICILayout.headerBytes + 1
    static let replyBytesBeforeData = MIDICILayout.headerBytes + 3
    static let lengthBytes = 2

    /// The three references address the Inquiry to the MUID that answered Discovery (JUCE `sendEndpointInquiry`,
    /// ktmidi `sendEndpointMessage`) and the Reply to the inquirer's source MUID (JUCE `getReplyHeader`, ktmidi
    /// `getEndpointReplyForInquiry`), so both need one MUID: a broadcast destination is `destinationIsBroadcast`,
    /// as for ACK and NAK. No reference refuses a broadcast destination on receipt; this codec is stricter.
    static let destinationRule = MIDICIDestinationRule.oneMUID

    var header: MIDICIHeader {
        switch self {
        case let .inquiry(header, _), let .reply(header, _):
            return header
        }
    }

    var status: MIDICIEndpointStatus {
        switch self {
        case let .inquiry(_, status): return status
        case let .reply(_, information): return information.status
        }
    }

    var kind: MIDICIEndpointKind {
        switch self {
        case .inquiry: return .inquiry
        case .reply: return .reply
        }
    }

    // MARK: Decode

    /// Decodes a payload without F0 and F7. The first failing step wins; steps 1 to 4 are
    /// `MIDICIMessage.checkEnvelope` and steps 1 to 11 follow the shared header order of
    /// `MIDICIMessage.decode(payload:limits:)`:
    ///  1. more than `limits.maximumPayloadBytes` bytes is `payloadTooLarge`; an empty payload is `truncated(1, 0)`;
    ///  2. byte 0 is not 0x7E, or (with 3 bytes or more) byte 2 is not 0x0D: `notCI`;
    ///  3. the first byte from offset 1 on that is 0x80 or more: `dataByteHigh(offset)` (this covers the device id,
    ///     the status, both length bytes and every information byte);
    ///  4. fewer than 5 bytes: `truncated(5)`;
    ///  5. sub-id 2 (byte 3) not 0x72 or 0x73: `unknownSubID`;
    ///  6. format (byte 4) not 2: `unsupportedFormat` (0x01 included: the messages are CI 1.2 only);
    ///  7. fewer than 13 bytes: `truncated(13)`;
    ///  8. the length. An Inquiry is exactly 14 bytes. A Reply: fewer than 16 bytes is `truncated(16)`; a declared
    ///     length above `maximumInformationBytes` is `informationTooLong`; fewer bytes than declared is
    ///     `truncated(16 + n)`; more is `trailingBytes`. The declared length is compared with the bound before the
    ///     length it implies and before any data byte is read, so a hostile length drives no work;
    ///  9. a source or destination MUID that is not assignable: `invalidMUID` (the source first);
    /// 10. addressing: `sourceIsBroadcast`, then `destinationIsBroadcast`;
    /// 11. the device id (always 7-bit by then; 0x7E and 0x7F are accepted as they are);
    /// 12. the body: the status, then the information data, both kept as received.
    /// The device id wrapper of step 11 and the `fieldOutOfRange` and `informationTooLong` refusals of step 12 are
    /// defensive: steps 3 and 8 make them unreachable (by inspection; no test reaches them).
    static func decode(payload: [UInt8], limits: MIDICILimits) throws(MIDICIRefusal) -> MIDICIEndpointMessage {
        try MIDICIMessage.checkEnvelope(payload, limits: limits)
        guard let kind = MIDICIEndpointKind(rawValue: payload[3]) else { throw .unknownSubID(payload[3]) }
        guard MIDICIFormat(rawValue: payload[4]) == .ci12 else { throw .unsupportedFormat(payload[4]) }
        guard payload.count >= MIDICILayout.headerBytes else {
            throw .truncated(need: MIDICILayout.headerBytes, have: payload.count)
        }
        let declared = try checkLength(payload, kind: kind)
        var reader = MIDICIReader(payload, offset: MIDICILayout.prefixBytes)
        let source = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        let destination = try MIDICIMUID.make(reader.wireValue(byteCount: 4))
        try MIDICIMessage.validateAddressing(destinationRule, source: source, destination: destination)
        let device = try MIDICIMessage.wrapDevice(payload[1])
        let header = MIDICIHeader(device: device, format: .ci12, source: source, destination: destination)
        let status = try MIDICIEndpointStatus.make(reader.byte())
        switch kind {
        case .inquiry:
            return .inquiry(header, status: status)
        case .reply:
            _ = try reader.wireValue(byteCount: lengthBytes)
            let data = try reader.take(declared)
            return .reply(header, try MIDICIEndpointInformation.make(status: status, data: data))
        }
    }

    /// Step 8. Returns the declared information length (0 for an Inquiry).
    private static func checkLength(_ payload: [UInt8], kind: MIDICIEndpointKind) throws(MIDICIRefusal) -> Int {
        var declared = 0
        var expected = inquiryBytes
        if kind == .reply {
            guard payload.count >= replyBytesBeforeData else {
                throw .truncated(need: replyBytesBeforeData, have: payload.count)
            }
            declared = Int(MIDICIWire.decode(Array(payload[MIDICILayout.headerBytes + 1..<replyBytesBeforeData])))
            guard declared <= maximumInformationBytes else {
                throw .informationTooLong(count: declared, limit: maximumInformationBytes)
            }
            expected = replyBytesBeforeData + declared
        }
        guard payload.count >= expected else { throw .truncated(need: expected, have: payload.count) }
        guard payload.count == expected else { throw .trailingBytes(payload.count - expected) }
        return declared
    }

    // MARK: Encode

    /// The canonical payload (without F0 and F7). Refusal order: a CI 1.1 header (`unsupportedFormat(1)`),
    /// `sourceIsBroadcast`, `destinationIsBroadcast`, last `payloadTooLarge`. The status and the information data
    /// are 7-bit and bounded by construction (`make`).
    func encode(limits: MIDICILimits) throws(MIDICIRefusal) -> [UInt8] {
        let header = self.header
        guard header.format == .ci12 else { throw .unsupportedFormat(header.format.rawValue) }
        try MIDICIMessage.validateAddressing(
            Self.destinationRule, source: header.source, destination: header.destination)
        var body = [status.rawValue]
        if case let .reply(_, information) = self {
            body += MIDICIWire.encode(UInt32(information.data.count), byteCount: Self.lengthBytes) + information.data
        }
        let total = MIDICILayout.headerBytes + body.count
        guard total <= limits.maximumPayloadBytes else { throw .payloadTooLarge(total) }
        let prefix: [UInt8] = [
            MIDICILayout.universalNonRealTime, header.device.rawValue, MIDICILayout.ciSubID1,
            kind.rawValue, header.format.rawValue
        ]
        return prefix + MIDICIWire.encode(header.source.rawValue, byteCount: 4)
            + MIDICIWire.encode(header.destination.rawValue, byteCount: 4) + body
    }
}
