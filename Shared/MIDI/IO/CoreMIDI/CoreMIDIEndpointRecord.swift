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

/// What one CoreMIDI binding receives and what its endpoint could lose on the way (#81, #83; media-contract §9.1).
/// Pure: a function of the mapped endpoint protocol and the input backend's batch format. Nothing here is observed.
struct CoreMIDIReceiveFidelity: Sendable, Equatable {
    let endpoint: MIDIEndpointProtocol
    /// The input backend's batch format. `midi1UMP` means `receive` is declared by the port; `bytes` means it is
    /// SDK convention.
    let format: MIDIPacketBatch.Format
    /// The protocol the input port receives: MIDI 1.0 for both backends. The UMP backend's port is created with
    /// `MIDIProtocolID._1_0`. The byte backend's port declares no protocol; reading its MIDI 1.0 bytes as a MIDI 1.0
    /// receive is the SDK's legacy convention, not a property CoreMIDI reports.
    let receive: MIDIPortProtocol
    /// False exactly when the endpoint protocol is `unknown`.
    let verified: Bool
    /// §9.1 `translatedBy == os`, derived and never observed: the endpoint protocol (`unknown` counts as `midi1`)
    /// differs from `receive`. Whether CoreMIDI converts exactly then is media-contract open question 8.
    let translatedByOS: Bool
    /// What a derived MIDI 2.0 → 1.0 translation could lose (`MIDICapabilityResolver.midi2ToMIDI1Losses`); empty when
    /// no translation is derived. Possible losses only: nothing is counted. `receive` is always `midi1`, so a derived
    /// translation is always downward. Meaningful only when `verified`: for an `unknown` endpoint it is empty because
    /// no translation is derived, but the real losses are unknown, not none.
    let possibleTranslationLosses: [UMPTranslationLossReason]

    init(endpoint: MIDIEndpointProtocol, format: MIDIPacketBatch.Format) {
        self.endpoint = endpoint
        self.format = format
        switch format {
        case .bytes, .midi1UMP: receive = .midi1
        }
        verified = endpoint != .unknown
        let assumed: MIDIPortProtocol = endpoint == .midi2 ? .midi2 : .midi1
        translatedByOS = assumed != receive
        possibleTranslationLosses = translatedByOS ? MIDICapabilityResolver.midi2ToMIDI1Losses : []
    }
}
