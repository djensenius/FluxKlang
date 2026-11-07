/// Why MIDI control intake refused an input. Payloads are integers only (counts, offsets, numbers, values); no refusal
/// carries a string, a token or a byte payload. Deliberately not `Codable`: nothing persists a refusal.
enum ControlIntakeRefusal: Error, Hashable, Sendable {
    /// The origin token has `length` UTF-8 bytes, which is outside `ControlIntakeBounds.originByteRange`.
    case invalidOrigin(length: Int)
    /// The origin token has a byte outside `a...z`, `0...9`, `-` at this 0-based UTF-8 offset (the first such byte).
    case invalidOriginByte(offset: Int)
    /// The encoder profile is invalid (an absolute resolution outside 2...16_384); `resolution` is that value.
    case invalidProfile(resolution: Int)
    /// The update has no channel (a system message).
    case noChannel
    /// The channel is outside 1...16.
    case invalidChannel(Int)
    /// The effect is not a control position: notes, sustain, program, resets, bank and selection effects.
    case notControlInput
    /// The controller or parameter number cannot be a control source of its kind.
    case invalidNumber(Int)
    /// The raw value is above the largest value of its own message width.
    case rawOutOfRange(raw: Int, maximum: Int)
    /// `msbOnlySevenBit` read a 14-bit controller pair whose low 7 bits are not zero; `raw` is those low 7 bits.
    case lsbPresent(raw: Int)
    /// The message width does not equal the profile width (7 or 14 bits each).
    case widthMismatch(messageBits: Int, profileBits: Int)
    /// The profile cannot decode `raw`; `upper` is the profile's largest raw value.
    case profileRange(raw: Int, upper: Int)
}
