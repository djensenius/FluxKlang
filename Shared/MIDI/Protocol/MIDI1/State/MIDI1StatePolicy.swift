/// How a received MSB treats its paired LSB for 14-bit controllers 0...31 (except Bank Select) and Data Entry.
enum MIDI1LSBResetPolicy: Equatable, Hashable, Sendable {
    /// MIDI 1.0: "When an MSB is received, the receiver should set its concept of the LSB to zero."
    case resetOnMSB
    /// For senders that transmit the LSB before the MSB.
    case retainLSB
}

/// How CC 0...119 other than Sustain (64) are interpreted. Channel mode messages (120...127, including the RP-015
/// reset of 121) and Sustain behave the same under both.
enum MIDI1ControllerPairing: Equatable, Hashable, Sendable {
    /// MIDI 1.0: 14-bit MSB/LSB pairs, Bank Select latch, RPN/NRPN selection and Data Entry/Increment/Decrement.
    case standard
    /// For senders without 14-bit pairs or parameter numbers (e.g. Novation Launch Control XL): every CC 0...119
    /// except 64 is stored and reported as a plain 7-bit `.controller`, so `noParameterSelected` never fires and
    /// no parameter is ever selected or stored. Program Change still reads controllers 0 and 32 as its bank.
    case unpaired
}

/// Receiver profile for one logical MIDI 1 stream. Selection of a profile per sender is #81's concern.
struct MIDI1StatePolicy: Equatable, Hashable, Sendable {
    static let heldNoteBounds = 1...MIDI1HeldNotes.capacity
    static let parameterValueBounds = 1...32_768
    static let standard = MIDI1StatePolicy(
        validatedLSBReset: .resetOnMSB, maximumHeldNotes: 128, maximumParameterValues: 256, nrpnNullDeselects: true,
        controllerPairing: .standard
    )

    let lsbReset: MIDI1LSBResetPolicy
    /// Distinct held notes per channel, sounding or sustained.
    let maximumHeldNotes: Int
    /// Distinct stored RPN/NRPN values per channel.
    let maximumParameterValues: Int
    /// RPN 127/127 is always the null function; this extends the same meaning to NRPN 127/127.
    let nrpnNullDeselects: Bool
    let controllerPairing: MIDI1ControllerPairing

    init?(
        lsbReset: MIDI1LSBResetPolicy = .resetOnMSB,
        maximumHeldNotes: Int = 128,
        maximumParameterValues: Int = 256,
        nrpnNullDeselects: Bool = true,
        controllerPairing: MIDI1ControllerPairing = .standard
    ) {
        guard Self.heldNoteBounds.contains(maximumHeldNotes),
              Self.parameterValueBounds.contains(maximumParameterValues) else { return nil }
        self.init(
            validatedLSBReset: lsbReset, maximumHeldNotes: maximumHeldNotes,
            maximumParameterValues: maximumParameterValues, nrpnNullDeselects: nrpnNullDeselects,
            controllerPairing: controllerPairing
        )
    }

    private init(validatedLSBReset: MIDI1LSBResetPolicy, maximumHeldNotes: Int, maximumParameterValues: Int,
                 nrpnNullDeselects: Bool, controllerPairing: MIDI1ControllerPairing) {
        self.lsbReset = validatedLSBReset
        self.maximumHeldNotes = maximumHeldNotes
        self.maximumParameterValues = maximumParameterValues
        self.nrpnNullDeselects = nrpnNullDeselects
        self.controllerPairing = controllerPairing
    }
}
