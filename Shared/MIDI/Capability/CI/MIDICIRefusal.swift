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
    }

    /// Not a MIDI-CI payload: the first byte is not 0x7E or the third byte is not 0x0D.
    case notCI
    /// The format byte is not 0x01 or 0x02, or it is 0x01 on an ACK (no source reviewed defines a CI 1.1 ACK).
    case unsupportedFormat(UInt8)
    /// The sub-id 2 byte is not one of the five handled here. This also covers valid MIDI-CI sub-ids this slice
    /// does not decode (for example 0x72 and 0x73, and the profile and property exchange messages).
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
    /// Discovery and Invalidate MUID must be addressed to the broadcast MUID.
    case destinationNotBroadcast
    /// ACK and NAK must be addressed to one MUID.
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
