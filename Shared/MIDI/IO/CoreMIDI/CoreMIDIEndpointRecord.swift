/// What CoreMIDI reported about one source endpoint in one enumeration (#81). A nil field means the property could
/// not be read. Identity is `fingerprint`, never `ref` or `displayName`.
struct CoreMIDIEndpointRecord: Sendable, Equatable {
    /// The `MIDIEndpointRef`: a handle to connect or disconnect this source, never evidence of which unit it is.
    let ref: UInt32
    /// `kMIDIPropertyUniqueID`.
    let uniqueID: Int32?
    /// `kMIDIPropertyDisplayName`, or "Unknown MIDI source" when it cannot be read. Only the name filter uses it.
    let displayName: String
    /// `kMIDIPropertyManufacturer`.
    let manufacturer: String?
    /// `kMIDIPropertyModel`.
    let model: String?
    /// `kMIDIPropertyDriverOwner`.
    let driverOwner: String?
    /// `kMIDIPropertyOffline`: true when the value is non-zero.
    let isOffline: Bool?
    /// `kMIDIPropertyProtocolID`, as reported. Evidence only: neither identity nor eligibility.
    let protocolID: Int32?

    /// `protocolID` mapped; see `MIDIEndpointProtocol.init(protocolID:)`.
    var endpointProtocol: MIDIEndpointProtocol { MIDIEndpointProtocol(protocolID: protocolID) }
}

extension MIDIEndpointProtocol {
    /// Maps a raw `kMIDIPropertyProtocolID`: 1 (`MIDIProtocolID._1_0`) is `midi1` and 2 (`._2_0`) is `midi2`. Anything
    /// else, including an unreadable property and 0, is `unknown`, never assumed to be MIDI 1.0.
    init(protocolID: Int32?) {
        switch protocolID {
        case 1?: self = .midi1
        case 2?: self = .midi2
        default: self = .unknown
        }
    }
}
