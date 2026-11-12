/// Sub-id 2 of the Property Exchange data messages handled by `MIDICIPropertyDataMessage` (Tables 33 to 39).
enum MIDICIPropertyDataKind: UInt8, Sendable {
    case getInquiry = 0x34
    case getReply = 0x35
    case setInquiry = 0x36
    case setReply = 0x37
    case subscription = 0x38
    case subscriptionReply = 0x39
    case notify = 0x3F

    /// True for the two kinds whose property data is fixed by Tables 33 and 36 to `01 00 01 00 00 00` (one chunk of
    /// one, no property data): the Inquiry: Get Property Data and the Reply to Set Property Data.
    var hasNoPropertyData: Bool {
        self == .getInquiry || self == .setReply
    }
}

/// The body every Property Exchange data message shares (M2-101-UM v1.2, section 8 and Tables 33 to 39): the request
/// id, the header data, the chunk fields and the property data of one chunk. The header data and the property data
/// are opaque bytes here (the Common Rules for Property Exchange, M2-102, say what they hold). Every value is kept as
/// received, including a chunk count of 0 (unknown) and a chunk number of 0 (the final chunk of bad data); the rules
/// a sender must follow are checked by `MIDICIPropertyDataMessage.encode`.
///
/// `maximumHeaderBytes` is this codec's own engineering bound for the header data, not a specification limit (the
/// 14-bit length field would allow 16,383 bytes).
struct MIDICIPropertyChunk: Equatable, Hashable, Sendable {
    static let maximumHeaderBytes = 2_048
    /// The largest 14-bit value: a length, a chunk count or a chunk number.
    static let maximumFieldValue = 0x3FFF

    private(set) var requestID: UInt8
    private(set) var headerData: [UInt8]
    private(set) var chunkCount: UInt16
    private(set) var chunkNumber: UInt16
    private(set) var propertyData: [UInt8]

    private init(
        requestID: UInt8, headerData: [UInt8], chunkCount: UInt16, chunkNumber: UInt16, propertyData: [UInt8]
    ) {
        self.requestID = requestID
        self.headerData = headerData
        self.chunkCount = chunkCount
        self.chunkNumber = chunkNumber
        self.propertyData = propertyData
    }

    /// Refuses, in this order: a request id of 0x80 or more, a header above `maximumHeaderBytes`
    /// (`propertyHeaderTooLong`), a header byte of 0x80 or more, a chunk count or number above 0x3FFF, property data
    /// above 0x3FFF bytes (`fieldOutOfRange(.propertyDataLength)`) and a property data byte of 0x80 or more.
    static func make(
        requestID: UInt8, headerData: [UInt8], chunkCount: UInt16, chunkNumber: UInt16, propertyData: [UInt8]
    ) throws(MIDICIRefusal) -> MIDICIPropertyChunk {
        guard requestID < 0x80 else { throw .fieldOutOfRange(.requestID, value: Int(requestID)) }
        guard headerData.count <= maximumHeaderBytes else { throw .propertyHeaderTooLong(headerData.count) }
        if let high = headerData.first(where: { $0 >= 0x80 }) {
            throw .fieldOutOfRange(.headerData, value: Int(high))
        }
        guard Int(chunkCount) <= maximumFieldValue else { throw .fieldOutOfRange(.chunkCount, value: Int(chunkCount)) }
        guard Int(chunkNumber) <= maximumFieldValue else {
            throw .fieldOutOfRange(.chunkNumber, value: Int(chunkNumber))
        }
        guard propertyData.count <= maximumFieldValue else {
            throw .fieldOutOfRange(.propertyDataLength, value: propertyData.count)
        }
        if let high = propertyData.first(where: { $0 >= 0x80 }) {
            throw .fieldOutOfRange(.propertyData, value: Int(high))
        }
        return MIDICIPropertyChunk(
            requestID: requestID, headerData: headerData, chunkCount: chunkCount, chunkNumber: chunkNumber,
            propertyData: propertyData)
    }
}

/// MIDI-CI Property Exchange data messages (M2-101-UM v1.2, section 8): Inquiry and Reply for Get Property Data
/// (0x34, 0x35), Inquiry and Reply for Set Property Data (0x36, 0x37), Subscription and its Reply (0x38, 0x39) and
/// Notify (0x3F), kept apart from the other CI decoders (which still refuse these sub-ids with `unknownSubID`; so
/// does this one for the sub-ids 0x3A to 0x3E, which Appendix D lists as reserved). The Property Exchange
/// Capabilities Inquiry and Reply (0x30, 0x31) are `MIDICIPropertyCapabilityMessage`. This type is the codec of one
/// message (one chunk) only: it sends nothing, keeps no state, does not reassemble chunks, does not pair a reply's
/// request id with its inquiry, and does not parse the header data (JSON) or the property data (Mcoded7).
///
/// Layout of the payload as `MIDI1Event.sysEx` delivers it (F0 and F7 excluded). The common 13-byte header is
/// `7E, device id, 0D, sub-id 2, format, source MUID (4), destination MUID (4)`, MUIDs 7 bits per byte, least
/// significant first. The body is the same for all seven kinds (Tables 33 to 39), every length and chunk field a
/// 14-bit value in two 7-bit bytes, least significant first:
/// - the Request ID (1 byte), from offset 13;
/// - the length H of the header data (2 bytes) and the header data (H bytes);
/// - the Number of Chunks in Message (2 bytes; 0 means unknown);
/// - the Number of This Chunk (2 bytes; counts from 1; 0 marks the final chunk of bad data, Table 29);
/// - the length D of the property data (2 bytes) and the property data (D bytes).
/// The payload is exactly `22 + H + D` bytes. Both CI formats (0x01 and 0x02) carry this layout unchanged.
///
/// Device id. Section 5.2.1 says the values 0x00 to 0x0F and 0x7E "shall not be used for Property Exchange messages"
/// (they are "only valid when sent to a whole Function Block 0x7F") and Tables 33 to 39 show 0x7F. Section 8.2 says
/// 0x0F, which in version 1.2 is MIDI channel 16 and contradicts both; it is read as a stale sentence. Lenient
/// receive, strict send: decode keeps any 7-bit device id as received and `encode` refuses all but 0x7F with
/// `deviceNotFunctionBlock`.
///
/// Lenient receive, strict send, throughout. Decode refuses only what makes the bytes unreadable (the envelope, a
/// length, a MUID, the addressing, a byte of 0x80 or more, a header above 2,048 bytes). It keeps the chunk fields
/// and, for 0x34 and 0x37, a non-empty property data or chunk fields other than 1 and 1, which Tables 33 and 36 and
/// section 8.3.2 forbid a sender, so a decoded message may be refused by `encode`. All seven are addressed to one
/// MUID: section 3.3.3 lists the messages that may use the Broadcast MUID and none is a Property Exchange message, so
/// a broadcast destination is `destinationIsBroadcast`, on decode and on encode.
///
/// Provenance: the layout follows M2-101-UM v1.2 (11 May 2023), sections 5.2.1 and 8 and Tables 33 to 39. The Common
/// Rules for Property Exchange (M2-102) were not available. No byte array was copied from any other source.
enum MIDICIPropertyDataMessage: Equatable, Hashable, Sendable {
    case getInquiry(MIDICIHeader, MIDICIPropertyChunk)
    case getReply(MIDICIHeader, MIDICIPropertyChunk)
    case setInquiry(MIDICIHeader, MIDICIPropertyChunk)
    case setReply(MIDICIHeader, MIDICIPropertyChunk)
    case subscription(MIDICIHeader, MIDICIPropertyChunk)
    case subscriptionReply(MIDICIHeader, MIDICIPropertyChunk)
    case notify(MIDICIHeader, MIDICIPropertyChunk)

    static let destinationRule = MIDICIDestinationRule.oneMUID

    var header: MIDICIHeader {
        switch self {
        case let .getInquiry(header, _), let .getReply(header, _), let .setInquiry(header, _),
             let .setReply(header, _), let .subscription(header, _), let .subscriptionReply(header, _),
             let .notify(header, _):
            return header
        }
    }

    var chunk: MIDICIPropertyChunk {
        switch self {
        case let .getInquiry(_, chunk), let .getReply(_, chunk), let .setInquiry(_, chunk),
             let .setReply(_, chunk), let .subscription(_, chunk), let .subscriptionReply(_, chunk),
             let .notify(_, chunk):
            return chunk
        }
    }

    var kind: MIDICIPropertyDataKind {
        switch self {
        case .getInquiry: return .getInquiry
        case .getReply: return .getReply
        case .setInquiry: return .setInquiry
        case .setReply: return .setReply
        case .subscription: return .subscription
        case .subscriptionReply: return .subscriptionReply
        case .notify: return .notify
        }
    }

    static func make(
        _ kind: MIDICIPropertyDataKind, header: MIDICIHeader, chunk: MIDICIPropertyChunk
    ) -> MIDICIPropertyDataMessage {
        switch kind {
        case .getInquiry: return .getInquiry(header, chunk)
        case .getReply: return .getReply(header, chunk)
        case .setInquiry: return .setInquiry(header, chunk)
        case .setReply: return .setReply(header, chunk)
        case .subscription: return .subscription(header, chunk)
        case .subscriptionReply: return .subscriptionReply(header, chunk)
        case .notify: return .notify(header, chunk)
        }
    }
}
