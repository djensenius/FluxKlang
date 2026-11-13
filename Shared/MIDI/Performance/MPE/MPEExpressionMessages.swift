/// Builds the one `MIDI1Semantic` a sender emits for each MPE per-note expression: channel pressure, slide (controller
/// 74) and pitch bend. This is the send side of what `MPENoteExpression.apply` receives. #82 slice MPX1. Nothing calls
/// it yet.
///
/// Each builder refuses, in this order: a channel outside 1...16 (`invalidChannel`), a value above the limit
/// (`valueOutOfRange`; nothing is clamped or masked), then a channel with no role under the configuration
/// (`unboundChannel`). A member channel and a manager channel are both accepted; a manager message is zone-wide. The
/// builders do not know which notes are held, so a member channel with no note passes here and the receiving
/// `MPENoteExpression` records its channel values for a later Note On. The order of messages around a Note On is not
/// decided here, and turning a message into bytes is a separate value.
enum MPEExpressionMessages {
    private static let sevenBitLimit: UInt16 = 127
    private static let fourteenBitLimit: UInt16 = 16_383

    /// Channel pressure on `channel`.
    static func pressure(
        channel: UInt8, value: UInt8, in configuration: MPEZoneConfiguration
    ) throws(MPERefusal) -> MIDI1Semantic {
        try check(channel: channel, value: UInt16(value), limit: sevenBitLimit, in: configuration)
        return .channelPressure(channel: channel, pressure: value)
    }

    /// Slide: controller `MPENoteExpression.slideController` (74).
    static func slide(
        channel: UInt8, value: UInt8, in configuration: MPEZoneConfiguration
    ) throws(MPERefusal) -> MIDI1Semantic {
        try check(channel: channel, value: UInt16(value), limit: sevenBitLimit, in: configuration)
        return .controlChange(channel: channel, controller: MPENoteExpression.slideController, value: value)
    }

    /// Pitch bend, 14 bits (0...16_383; 8_192 is neutral).
    static func pitchBend(
        channel: UInt8, value: UInt16, in configuration: MPEZoneConfiguration
    ) throws(MPERefusal) -> MIDI1Semantic {
        try check(channel: channel, value: value, limit: fourteenBitLimit, in: configuration)
        return .pitchBend(channel: channel, value: value)
    }

    private static func check(
        channel: UInt8, value: UInt16, limit: UInt16, in configuration: MPEZoneConfiguration
    ) throws(MPERefusal) {
        let role = try MPEChannelClassifier.role(of: channel, in: configuration)
        guard value <= limit else { throw .valueOutOfRange(value) }
        if role == .unassigned { throw .unboundChannel(channel) }
    }
}
