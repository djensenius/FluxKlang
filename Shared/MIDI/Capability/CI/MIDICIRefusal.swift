/// Typed refusals of the MIDI-CI envelope: decoding, encoding, value factories and the MUID allocator.
/// A refusal carries no partial result; the caller's inputs are values and are never changed.
enum MIDICIRefusal: Error, Equatable, Hashable, Sendable {
    enum Field: Equatable, Hashable, Sendable {
        case maximumPayloadBytes
        case maximumTextBytes
        case manufacturer
        case family
        case model
        case softwareRevision
        case capabilityCategory
        case maximumSysExSize
        case outputPathID
        case functionBlock
        case originalSubID
        case statusCode
        case statusData
        case details
        case channelCount
        case simultaneousRequests
        case propertyExchangeMajorVersion
        case propertyExchangeMinorVersion
        case endpointStatus
        case endpointInformation
    }

    /// Not a MIDI-CI payload: the first byte is not 0x7E or the third byte is not 0x0D.
    case notCI
    /// The format byte is not 0x01 or 0x02, or it is 0x01 on an ACK (no source reviewed defines a CI 1.1 ACK) or on an
    /// Endpoint Information Inquiry or Reply (0x72 and 0x73 exist from CI 1.2 on).
    case unsupportedFormat(UInt8)
    /// The sub-id 2 byte is not one the called decoder handles (`MIDICIMessage`: 0x70, 0x71, 0x7D-0x7F;
    /// `MIDICIProfileMessage`: 0x20, 0x21, 0x24-0x27; `MIDICIPropertyCapabilityMessage`: the Property Exchange
    /// Capabilities Inquiry and Reply 0x30 and 0x31; `MIDICIEndpointMessage`: the Endpoint Information Inquiry and
    /// Reply 0x72 and 0x73). This also covers valid MIDI-CI sub-ids none decodes (for example Set Profile On and
    /// Off 0x22 and 0x23, and the property data, subscription and notify messages 0x34 to 0x3F).
    case unknownSubID(UInt8)
    /// The message needs `need` bytes in total but only `have` were given.
    case truncated(need: Int, have: Int)
    /// This many bytes follow a complete message.
    case trailingBytes(Int)
    /// The first byte at payload offset 1 or later that is not a 7-bit data byte. A byte of 0x80 or more at offset 2
    /// is `notCI` instead, because the third byte is compared with 0x0D first.
    case dataByteHigh(offset: Int)
    case invalidMUID(UInt32)
    case sourceIsBroadcast
    /// Discovery, Invalidate MUID and the profile reports (0x24 to 0x27) must be addressed to the broadcast MUID.
    case destinationNotBroadcast
    /// ACK, NAK and the Endpoint Information Inquiry and Reply must be addressed to one MUID.
    case destinationIsBroadcast
    case targetIsBroadcast
    /// The text has this many utf8 bytes (encode) or declares this length (decode).
    case textTooLong(Int)
    /// The text contains a byte of 0x80 or more at this utf8 offset.
    case textNotSevenBit(offset: Int)
    case payloadTooLarge(Int)
    case noFreeMUID
    case limits(Field)
    /// A value outside its range. On decode this and `fieldLength` are defensive checks: the earlier scan has already
    /// refused every byte of 0x80 or more and the reader returns exact lengths, so decode cannot reach them
    /// (by inspection; no test reaches them). The factories and encode do raise them.
    case fieldOutOfRange(Field, value: Int)
    case fieldLength(Field, expected: Int, actual: Int)
    case outputPathIDNotAllowed
    case outputPathIDRequired
    /// A Discovery Reply carries a function block byte in CI 1.2 only.
    case functionBlockNotAllowed
    case functionBlockRequired
    /// A NAK carries a status report in CI 1.2 only (the CI 1.1 NAK is the 13-byte header).
    case statusReportNotAllowed
    case statusReportRequired
    /// A Reply to Profile Inquiry list (enabled or disabled) declares or holds `count` profiles, more than `limit`
    /// (`MIDICIProfileMessage.maximumProfilesPerList`). On decode this is checked against the declared 14-bit
    /// count before any profile id is read.
    case tooManyProfiles(count: Int, limit: Int)
    /// A Profile Enabled or Disabled Report carries a channel count in CI 1.2 only (the CI 1.1 form, from JUCE, ends
    /// after the profile id): `channelCountNotAllowed` is a CI 1.1 report with a count, `channelCountRequired` a
    /// CI 1.2 report without one. Raised by `encode` only; on decode a mismatch is a length refusal
    /// (`trailingBytes` / `truncated`).
    case channelCountNotAllowed
    case channelCountRequired
    /// A Property Exchange Capabilities Inquiry or Reply carries the Property Exchange major and minor version in
    /// CI 1.2 only: `propertyVersionNotAllowed` is a CI 1.1 message with a version, `propertyVersionRequired` a
    /// CI 1.2 message without one. Raised by `encode` only; on decode a mismatch is a length refusal
    /// (`trailingBytes` / `truncated`).
    case propertyVersionNotAllowed
    case propertyVersionRequired
    /// A Reply to Endpoint Information declares or holds `count` information bytes, more than `limit`
    /// (`MIDICIEndpointMessage.maximumInformationBytes`). On decode this is checked against the declared 14-bit
    /// length before any information byte is read.
    case informationTooLong(count: Int, limit: Int)
}

/// Caller-chosen bounds for decoding and encoding. Built only through `make`, so a value is always within the
/// hard ceilings (payload 1...4,096 bytes, ACK/NAK text 0...256 utf8 bytes).
struct MIDICILimits: Equatable, Hashable, Sendable {
    static let payloadBytesRange = 1...4_096
    static let textBytesRange = 0...256
    static let standard = MIDICILimits(payload: 4_096, text: 256)

    private let payload: Int
    private let text: Int

    var maximumPayloadBytes: Int { payload }
    var maximumTextBytes: Int { text }

    private init(payload: Int, text: Int) {
        self.payload = payload
        self.text = text
    }

    static func make(maximumPayloadBytes: Int, maximumTextBytes: Int) throws(MIDICIRefusal) -> MIDICILimits {
        guard payloadBytesRange.contains(maximumPayloadBytes) else { throw .limits(.maximumPayloadBytes) }
        guard textBytesRange.contains(maximumTextBytes) else { throw .limits(.maximumTextBytes) }
        return MIDICILimits(payload: maximumPayloadBytes, text: maximumTextBytes)
    }
}
