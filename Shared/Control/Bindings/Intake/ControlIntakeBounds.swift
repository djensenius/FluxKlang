/// Every numeric literal of MIDI control intake lives here and nowhere else in the intake files.
enum ControlIntakeBounds: Sendable {
    /// UTF-8 bytes of a `ControlSourceOrigin` token.
    static let originByteRange = 1...32
    /// MIDI 1 channels as `MIDI1StateUpdate` reports them (1-based).
    static let channelRange: ClosedRange<UInt8> = 1...16
    /// Largest raw value of a 7-bit message.
    static let sevenBitMaximum = 127
    /// Largest raw value of a 14-bit message.
    static let fourteenBitMaximum = 16_383
    /// MSB numbers of the CC pairs `MIDI1PerformanceState` reports as `.controller14`.
    static let pairedControllerRange: ClosedRange<UInt8> = 1...31
    /// Every CC number a `ControlSourceKey` of kind `controller` can hold.
    static let plainControllerRange: ClosedRange<UInt8> = 0...127
    /// The CC numbers `MIDI1ChannelState` reports as plain `.controller` (all others are paired, selection, mode or
    /// sustain), so only these are control intake.
    static let reachableControllerRanges: [ClosedRange<UInt8>] = [65...95, 102...119]
    /// Largest MSB or LSB byte of a parameter number.
    static let parameterByteMaximum = 127
    /// Prefix of every source ID.
    static let sourceIDPrefix = "midi."
    /// Key numbers of the parameter kinds: `msb * 128 + lsb`.
    static let parameterNumberRange: ClosedRange<UInt16> = 0...16_383
    /// Key number of the kinds that have no number (pitch bend, channel pressure).
    static let singletonNumberRange: ClosedRange<UInt16> = 0...0

    /// Largest raw value of a message of the given width.
    static func maximum(for width: EncoderBitWidth) -> Int {
        switch width {
        case .seven: sevenBitMaximum
        case .fourteen: fourteenBitMaximum
        }
    }
}
