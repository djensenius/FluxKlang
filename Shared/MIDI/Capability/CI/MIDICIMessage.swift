/// MIDI-CI message format byte: 0x01 is CI 1.1, 0x02 is CI 1.2 (which adds the output path id to Discovery and
/// Discovery Reply, a function block byte to Discovery Reply and the long status form to NAK).
enum MIDICIFormat: UInt8, Equatable, Hashable, Sendable {
    case ci11 = 1
    case ci12 = 2
}

/// Sub-id 2 of the management messages handled here.
enum MIDICIKind: UInt8, Sendable {
    case discovery = 0x70
    case discoveryReply = 0x71
    case ack = 0x7D
    case invalidateMUID = 0x7E
    case nak = 0x7F
}

/// Payload layout (as `MIDI1Event.sysEx` delivers it: F0 and F7 excluded).
enum MIDICILayout {
    static let universalNonRealTime: UInt8 = 0x7E
    static let ciSubID1: UInt8 = 0x0D
    /// Bytes up to and including the format byte.
    static let prefixBytes = 5
    /// Bytes up to and including the destination MUID.
    static let headerBytes = 13
    static let discoveryBodyBytes = 16
    static let invalidateBodyBytes = 4
    /// Original sub-id, status code, status data, five details bytes and the two length bytes.
    static let statusFixedBytes = 10
    static let statusBytesBeforeText = headerBytes + statusFixedBytes
    static let detailsBytes = 5
    static let manufacturerBytes = 3
    static let revisionBytes = 4
}

struct MIDICIHeader: Equatable, Hashable, Sendable {
    var device: SysExDeviceID
    var format: MIDICIFormat
    var source: MIDICIMUID
    var destination: MIDICIMUID
}

/// Manufacturer (3 bytes as transmitted), family and model (14 bit) and software revision (4 bytes as transmitted).
struct MIDICIDeviceIdentity: Equatable, Hashable, Sendable {
    private(set) var manufacturer: [UInt8]
    private(set) var family: UInt16
    private(set) var model: UInt16
    private(set) var softwareRevision: [UInt8]

    private init(manufacturer: [UInt8], family: UInt16, model: UInt16, softwareRevision: [UInt8]) {
        self.manufacturer = manufacturer
        self.family = family
        self.model = model
        self.softwareRevision = softwareRevision
    }

    static func make(
        manufacturer: [UInt8], family: UInt16, model: UInt16, softwareRevision: [UInt8]
    ) throws(MIDICIRefusal) -> MIDICIDeviceIdentity {
        try requireSevenBit(manufacturer, count: MIDICILayout.manufacturerBytes, field: .manufacturer)
        guard family <= 0x3FFF else { throw .fieldOutOfRange(.family, value: Int(family)) }
        guard model <= 0x3FFF else { throw .fieldOutOfRange(.model, value: Int(model)) }
        try requireSevenBit(softwareRevision, count: MIDICILayout.revisionBytes, field: .softwareRevision)
        return MIDICIDeviceIdentity(
            manufacturer: manufacturer, family: family, model: model, softwareRevision: softwareRevision)
    }
}

/// The body of Discovery and Discovery Reply. `outputPathID` exists only in CI 1.2; the pairing with the header's
/// format is checked by `encode`. `maximumSysExSize` (28 bit) is stored as advertised and never sizes anything.
struct MIDICIDiscoveryInfo: Equatable, Hashable, Sendable {
    private(set) var identity: MIDICIDeviceIdentity
    private(set) var capabilityCategory: UInt8
    private(set) var maximumSysExSize: UInt32
    private(set) var outputPathID: UInt8?

    private init(identity: MIDICIDeviceIdentity, category: UInt8, maximumSysExSize: UInt32, outputPathID: UInt8?) {
        self.identity = identity
        self.capabilityCategory = category
        self.maximumSysExSize = maximumSysExSize
        self.outputPathID = outputPathID
    }

    static func make(
        identity: MIDICIDeviceIdentity, capabilityCategory: UInt8, maximumSysExSize: UInt32, outputPathID: UInt8?
    ) throws(MIDICIRefusal) -> MIDICIDiscoveryInfo {
        guard capabilityCategory < 0x80 else {
            throw .fieldOutOfRange(.capabilityCategory, value: Int(capabilityCategory))
        }
        guard maximumSysExSize <= 0x0FFF_FFFF else {
            throw .fieldOutOfRange(.maximumSysExSize, value: Int(maximumSysExSize))
        }
        if let outputPathID, outputPathID >= 0x80 {
            throw .fieldOutOfRange(.outputPathID, value: Int(outputPathID))
        }
        return MIDICIDiscoveryInfo(
            identity: identity, category: capabilityCategory, maximumSysExSize: maximumSysExSize,
            outputPathID: outputPathID)
    }
}

/// The body of ACK and NAK. The text is 7-bit ASCII on the wire and at most 256 utf8 bytes; a tighter bound is
/// applied by the caller's `MIDICILimits` at encode and decode.
struct MIDICIStatusReport: Equatable, Hashable, Sendable {
    private(set) var originalSubID: UInt8
    private(set) var statusCode: UInt8
    private(set) var statusData: UInt8
    private(set) var details: [UInt8]
    private(set) var text: String

    private init(originalSubID: UInt8, statusCode: UInt8, statusData: UInt8, details: [UInt8], text: String) {
        self.originalSubID = originalSubID
        self.statusCode = statusCode
        self.statusData = statusData
        self.details = details
        self.text = text
    }

    static func make(
        originalSubID: UInt8, statusCode: UInt8, statusData: UInt8, details: [UInt8], text: String
    ) throws(MIDICIRefusal) -> MIDICIStatusReport {
        guard originalSubID < 0x80 else { throw .fieldOutOfRange(.originalSubID, value: Int(originalSubID)) }
        guard statusCode < 0x80 else { throw .fieldOutOfRange(.statusCode, value: Int(statusCode)) }
        guard statusData < 0x80 else { throw .fieldOutOfRange(.statusData, value: Int(statusData)) }
        try requireSevenBit(details, count: MIDICILayout.detailsBytes, field: .details)
        let byteCount = text.utf8.count
        guard byteCount <= MIDICILimits.textBytesRange.upperBound else { throw .textTooLong(byteCount) }
        if let offset = text.utf8.firstIndex(where: { $0 >= 0x80 }) {
            throw .textNotSevenBit(offset: text.utf8.distance(from: text.utf8.startIndex, to: offset))
        }
        return MIDICIStatusReport(
            originalSubID: originalSubID, statusCode: statusCode, statusData: statusData, details: details, text: text)
    }
}

private func requireSevenBit(_ bytes: [UInt8], count: Int, field: MIDICIRefusal.Field) throws(MIDICIRefusal) {
    guard bytes.count == count else { throw .fieldLength(field, expected: count, actual: bytes.count) }
    if let high = bytes.first(where: { $0 >= 0x80 }) { throw .fieldOutOfRange(field, value: Int(high)) }
}

/// One MIDI-CI management message. Decode and encode are in `MIDICIMessage+Decode` and `MIDICIMessage+Encode`.
enum MIDICIMessage: Equatable, Sendable {
    case discovery(MIDICIHeader, MIDICIDiscoveryInfo)
    case discoveryReply(MIDICIHeader, MIDICIDiscoveryInfo, functionBlock: UInt8?)
    case invalidateMUID(MIDICIHeader, target: MIDICIMUID)
    /// CI 1.2 only; encode and decode refuse a CI 1.1 ACK with `unsupportedFormat(1)`.
    case ack(MIDICIHeader, MIDICIStatusReport)
    /// The report is required in CI 1.2 and absent in CI 1.1 (the NAK is then the 13-byte header only).
    case nak(MIDICIHeader, MIDICIStatusReport?)

    var header: MIDICIHeader {
        switch self {
        case let .discovery(header, _), let .discoveryReply(header, _, _), let .invalidateMUID(header, _),
             let .ack(header, _), let .nak(header, _):
            return header
        }
    }

    var kind: MIDICIKind {
        switch self {
        case .discovery: return .discovery
        case .discoveryReply: return .discoveryReply
        case .invalidateMUID: return .invalidateMUID
        case .ack: return .ack
        case .nak: return .nak
        }
    }

    /// Source and destination rules shared by decode and encode. The source is never broadcast; Discovery and
    /// Invalidate MUID are addressed to broadcast, ACK and NAK to one MUID; a Discovery Reply may be either.
    static func validateAddressing(
        _ kind: MIDICIKind, source: MIDICIMUID, destination: MIDICIMUID
    ) throws(MIDICIRefusal) {
        let rule: MIDICIDestinationRule
        switch kind {
        case .discovery, .invalidateMUID: rule = .broadcast
        case .ack, .nak: rule = .oneMUID
        case .discoveryReply: rule = .either
        }
        try validateAddressing(rule, source: source, destination: destination)
    }

    /// The same rule by destination kind, for messages outside `MIDICIKind` (see `MIDICIProfileKind.destinationRule`,
    /// `MIDICIPropertyCapabilityMessage.destinationRule`, `MIDICIEndpointMessage.destinationRule` and
    /// `MIDICIProcessInquiryMessage.destinationRule`): `sourceIsBroadcast` first, then `destinationNotBroadcast` or
    /// `destinationIsBroadcast`.
    static func validateAddressing(
        _ rule: MIDICIDestinationRule, source: MIDICIMUID, destination: MIDICIMUID
    ) throws(MIDICIRefusal) {
        if source.isBroadcast { throw .sourceIsBroadcast }
        switch rule {
        case .broadcast:
            if !destination.isBroadcast { throw .destinationNotBroadcast }
        case .oneMUID:
            if destination.isBroadcast { throw .destinationIsBroadcast }
        case .either:
            break
        }
    }
}

/// Which destination MUID a message may carry: only broadcast, only one assignable MUID, or either.
enum MIDICIDestinationRule: Sendable {
    case broadcast
    case oneMUID
    case either
}
