/// How a received MSB treats its paired LSB for 14-bit controllers 0...31 (except Bank Select) and Data Entry.
enum MIDI1LSBResetPolicy: Equatable, Hashable, Sendable {
    /// MIDI 1.0: "When an MSB is received, the receiver should set its concept of the LSB to zero."
    case resetOnMSB
    /// For senders that transmit the LSB before the MSB.
    case retainLSB
}

/// Receiver profile for one logical MIDI 1 stream. Selection of a profile per sender is #81's concern.
struct MIDI1StatePolicy: Equatable, Hashable, Sendable {
    static let heldNoteBounds = 1...MIDI1HeldNotes.capacity
    static let parameterValueBounds = 1...32_768
    static let standard = MIDI1StatePolicy(
        validatedLSBReset: .resetOnMSB, maximumHeldNotes: 128, maximumParameterValues: 256, nrpnNullDeselects: true
    )

    let lsbReset: MIDI1LSBResetPolicy
    /// Distinct held notes per channel, sounding or sustained.
    let maximumHeldNotes: Int
    /// Distinct stored RPN/NRPN values per channel.
    let maximumParameterValues: Int
    /// RPN 127/127 is always the null function; this extends the same meaning to NRPN 127/127.
    let nrpnNullDeselects: Bool

    init?(
        lsbReset: MIDI1LSBResetPolicy = .resetOnMSB,
        maximumHeldNotes: Int = 128,
        maximumParameterValues: Int = 256,
        nrpnNullDeselects: Bool = true
    ) {
        guard Self.heldNoteBounds.contains(maximumHeldNotes),
              Self.parameterValueBounds.contains(maximumParameterValues) else { return nil }
        self.init(
            validatedLSBReset: lsbReset, maximumHeldNotes: maximumHeldNotes,
            maximumParameterValues: maximumParameterValues, nrpnNullDeselects: nrpnNullDeselects
        )
    }

    private init(validatedLSBReset: MIDI1LSBResetPolicy, maximumHeldNotes: Int, maximumParameterValues: Int,
                 nrpnNullDeselects: Bool) {
        self.lsbReset = validatedLSBReset
        self.maximumHeldNotes = maximumHeldNotes
        self.maximumParameterValues = maximumParameterValues
        self.nrpnNullDeselects = nrpnNullDeselects
    }
}
