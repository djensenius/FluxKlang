/// How `.controller14` effects are read. Only `.controller14` is affected; every other effect resolves identically.
enum ControlIntakeDialect: String, Hashable, Sendable, CaseIterable {
    /// A `.controller14` is a 14-bit message (kind `controller14`). The default and the conservative reading.
    case pairedFourteenBit = "paired14"
    /// For 7-bit-only devices such as the Launch Control XL: `MIDI1PerformanceState` pairs CC 1...31 into 14 bits with
    /// an LSB it resets to zero, so a `.controller14` whose low 7 bits are zero is read as a 7-bit `controller` with
    /// raw `value >> 7`, and one with a non-zero low part is refused `.lsbPresent` (a real LSB arrived).
    case msbOnlySevenBit = "msb7"
}
