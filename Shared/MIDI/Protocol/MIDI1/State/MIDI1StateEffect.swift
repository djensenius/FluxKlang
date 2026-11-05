/// What one accepted message did. Released note lists are ascending.
enum MIDI1StateEffect: Equatable, Sendable {
    case unchanged
    case noteOn(note: UInt8, velocity: UInt8)
    /// `sustained` means the pedal now holds the note instead of releasing it.
    case noteOff(note: UInt8, sustained: Bool)
    case polyPressure(note: UInt8, pressure: UInt8)
    case controller(UInt8, value: UInt8)
    /// Controller is the MSB number 1...31; value is the combined 14-bit value.
    case controller14(UInt8, value: UInt16)
    case bankLatched(msb: UInt8, lsb: UInt8)
    /// Nil after the null function.
    case parameterSelected(MIDI1ParameterNumber?)
    case parameter(MIDI1ParameterNumber, value: UInt16)
    case program(MIDI1ProgramSelection)
    case pitchBend(UInt16)
    case channelPressure(UInt8)
    case sustain(down: Bool, released: [UInt8])
    case allSoundOff(released: [UInt8])
    case allNotesOff(released: [UInt8])
    case controllersReset(released: [UInt8])
    case localControl(Bool)
    case mode(MIDI1ChannelMode, released: [UInt8])
}

/// Channel is 1...16, or nil for system messages, which never change channel state.
struct MIDI1StateUpdate: Equatable, Sendable {
    let channel: UInt8?
    let effect: MIDI1StateEffect
}
