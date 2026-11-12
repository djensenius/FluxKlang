/// The three Stream messages that carry text.
enum UMPStreamTextKind: Equatable, Sendable {
    case endpointName
    case productInstanceID
    case functionBlockName

    /// The 10-bit status of the message.
    var status: UInt16 {
        switch self {
        case .endpointName: return 0x003
        case .productInstanceID: return 0x004
        case .functionBlockName: return 0x012
        }
    }

    /// Text bytes per packet: 14, or 13 when word 0 also carries the function block index.
    var bytesPerPacket: Int {
        switch self {
        case .endpointName, .productInstanceID: return 14
        case .functionBlockName: return 13
        }
    }

    /// Packets one text may use (M2-104-UM; not checked against the specification text).
    var maximumPackets: Int {
        switch self {
        case .endpointName: return 7
        case .productInstanceID: return 3
        case .functionBlockName: return 7
        }
    }

    /// Longest text in bytes: 98, 42 or 91.
    var specificationMaximumBytes: Int { bytesPerPacket * maximumPackets }

    init?(status: UInt16) {
        switch status {
        case 0x003: self = .endpointName
        case 0x004: self = .productInstanceID
        case 0x012: self = .functionBlockName
        default: return nil
        }
    }
}

/// A validated text limit, in utf8 bytes, 1...255. It is built only by `make`, so every holder is in range.
struct UMPStreamLimits: Equatable, Sendable {
    static let maximumTextBytesRange = 1...255

    private let storedMaximumTextBytes: Int

    private init(validatedMaximumTextBytes: Int) {
        storedMaximumTextBytes = validatedMaximumTextBytes
    }

    /// Refuses a limit outside 1...255; there is no default.
    static func make(maximumTextBytes: Int) throws(UMPStreamRefusal) -> UMPStreamLimits {
        guard maximumTextBytesRange.contains(maximumTextBytes) else {
            throw .invalidLimit(.maximumTextBytes, value: maximumTextBytes)
        }
        return UMPStreamLimits(validatedMaximumTextBytes: maximumTextBytes)
    }

    var maximumTextBytes: Int { storedMaximumTextBytes }

    /// The byte bound that applies to one text: the caller's limit, but never above the message's own maximum.
    func maximumBytes(for kind: UMPStreamTextKind) -> Int {
        min(storedMaximumTextBytes, kind.specificationMaximumBytes)
    }
}
