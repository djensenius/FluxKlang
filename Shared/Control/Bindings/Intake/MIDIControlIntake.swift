/// Pure MIDI control intake: one `MIDI1StateUpdate` plus an origin and an `EncoderProfile` becomes one
/// `ControlIntakeSample` or one typed `ControlIntakeRefusal`. It holds no state and reads no clock, device or store.
/// Deliberate deviations from "any MIDI message is control": notes, sustain and program effects are refused
/// `.notControlInput`, and there is no widening or narrowing between 7 and 14 bits (no center-at-64 shortcut).
enum MIDIControlIntake {
    /// Checks, first failure wins: profile, channel presence, channel range, control effect, number, raw range,
    /// low-part (dialect), width equality, then the profile decode. A refusal returns nothing; inputs are values.
    static func resolve(
        _ update: MIDI1StateUpdate,
        origin: ControlSourceOrigin,
        profile: EncoderProfile,
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) throws(ControlIntakeRefusal) -> ControlIntakeSample {
        do {
            try profile.validate()
        } catch {
            throw validationRefusal(for: error)
        }
        let (key, raw) = try key(for: update, origin: origin, dialect: dialect)
        let required = requiredWidth(of: profile)
        guard key.kind.width == required else {
            throw .widthMismatch(messageBits: key.kind.width.rawValue, profileBits: required.rawValue)
        }
        do {
            let input = try profile.decode(raw: raw)
            return ControlIntakeSample(key: key, raw: raw, width: required, input: input)
        } catch {
            throw decodeRefusal(for: error)
        }
    }

    /// Runs the checks that need no profile (channel presence through the low-part check) and returns the source key
    /// and the raw value of the message (7-bit or 14-bit according to `key.kind.width`).
    static func key(
        for update: MIDI1StateUpdate,
        origin: ControlSourceOrigin,
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) throws(ControlIntakeRefusal) -> (key: ControlSourceKey, raw: Int) {
        guard let channel = update.channel else { throw .noChannel }
        guard ControlIntakeBounds.channelRange.contains(channel) else { throw .invalidChannel(Int(channel)) }
        let classified = try classify(update.effect, dialect: dialect)
        guard let number = UInt16(exactly: classified.number) else { throw .invalidNumber(classified.number) }
        let key = try ControlSourceKey(origin: origin, channel: channel, kind: classified.kind, number: number)
        return (key, classified.raw)
    }

    /// The width an encoder profile reads: a relative profile names it, an absolute one with at most 128 values is
    /// 7-bit and anything larger 14-bit.
    static func requiredWidth(of profile: EncoderProfile) -> EncoderBitWidth {
        switch profile {
        case .absolute(let resolution):
            resolution <= EncoderBitWidth.seven.valueCount ? .seven : .fourteen
        case .binaryOffset(let width), .twosComplement(let width), .signMagnitude(let width):
            width
        }
    }

    private static func validationRefusal(for error: EncoderDecodeError) -> ControlIntakeRefusal {
        switch error {
        case .invalidResolution(let resolution):
            return .invalidProfile(resolution: resolution)
        case .rawOutOfRange:
            // Unreachable: `validate()` never throws `.rawOutOfRange`.
            return .invalidProfile(resolution: 0)
        }
    }

    private static func decodeRefusal(for error: EncoderDecodeError) -> ControlIntakeRefusal {
        switch error {
        case .invalidResolution(let resolution):
            // Unreachable after a successful `validate()`; mapped rather than trapped.
            return .invalidProfile(resolution: resolution)
        case .rawOutOfRange(let raw, _, let upper):
            return .profileRange(raw: raw, upper: upper)
        }
    }
}
