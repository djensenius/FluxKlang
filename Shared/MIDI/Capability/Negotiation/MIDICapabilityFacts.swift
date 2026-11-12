/// A MIDI-CI profile identifier: exactly five bytes, each a 7-bit value. Built only by `make`.
struct MIDICapabilityProfileID: Equatable, Hashable, Sendable {
    static let byteCount = 5

    private let storage: [UInt8]

    /// The five bytes as they were given.
    var bytes: [UInt8] {
        storage
    }

    private init(storage: [UInt8]) {
        self.storage = storage
    }

    /// Refuses with `invalidProfileID`: `offset` 0 when the length is not five, else the position of the first byte
    /// above 0x7F.
    static func make(bytes: [UInt8]) throws(MIDICapabilityRefusal) -> MIDICapabilityProfileID {
        guard bytes.count == byteCount else { throw .invalidProfileID(count: bytes.count, offset: 0) }
        if let offset = bytes.firstIndex(where: { $0 > 0x7F }) {
            throw .invalidProfileID(count: bytes.count, offset: offset)
        }
        return MIDICapabilityProfileID(storage: bytes)
    }
}

/// What the MIDI-CI Discovery exchange produced. `.missing` means no answer arrived (or none was asked for, or the
/// Discovery was answered with a NAK): the device is then treated as a plain MIDI 1.0 byte-stream device. The
/// `profiles` of `.answered` are the advertised ids, enabled and disabled together (see `MIDICapabilityLimits` for the
/// bound). `MIDICapabilityDiscovery` builds this from decoded messages, one Profile Reply per address and transport.
enum MIDICapabilityCIAnswer: Equatable, Sendable {
    case missing
    case answered(MIDICIDiscoveryInfo, profiles: [MIDICapabilityProfileID])

    /// The bit of the Discovery capability category that advertises profile configuration.
    static let profileConfigurationBit: UInt8 = 0x04
}

/// Everything the resolver looks at, as values the caller discovered. The resolver never queries a device.
struct MIDICapabilityFacts: Equatable, Sendable {
    let endpoint: UMPStreamEndpointInfo?
    let functionBlocks: [UMPStreamFunctionBlockInfo]
    let ciAnswer: MIDICapabilityCIAnswer
}
