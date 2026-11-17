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
}
