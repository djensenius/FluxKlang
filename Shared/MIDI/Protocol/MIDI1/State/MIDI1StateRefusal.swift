/// Snapshot fields that can fail validation when restoring state.
enum MIDI1SnapshotField: Equatable, Hashable, Sendable {
    case channelCount
    case controllers
    case polyPressure
    case pitchBend
    case channelPressure
    case program
    case parameters
    case heldNotes
    case mode
    /// A stored null-function key (RPN 127/127, or NRPN 127/127 when it deselects), which Data Entry never writes.
    case nullParameter(channel: UInt8, number: MIDI1ParameterNumber)
}

/// Every refusal leaves the whole state unchanged. Channels are 1...16.
enum MIDI1StateRefusal: Error, Equatable, Hashable, Sendable {
    /// The raw event or semantic value is not a well-formed MIDI 1 message.
    case malformedEvent
    case heldNoteLimit(channel: UInt8, note: UInt8)
    /// Data Entry or Increment/Decrement with no parameter selected, or after the null function.
    case noParameterSelected(channel: UInt8, controller: UInt8)
    case parameterStoreFull(channel: UInt8)
    case invalidModeValue(channel: UInt8, controller: UInt8, value: UInt8)
    case invalidSnapshot(MIDI1SnapshotField)
}
