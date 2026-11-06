/// Channel and data checks `MIDINoteLedger.route` applies before routing an event.
extension MIDI1Semantic {
    /// Channel 1...16 claimed by a channel voice message, or nil for system messages.
    var routedChannel: UInt8? {
        switch self {
        case let .noteOff(channel, _, _), let .noteOn(channel, _, _), let .polyphonicPressure(channel, _, _),
             let .controlChange(channel, _, _), let .programChange(channel, _), let .channelPressure(channel, _),
             let .pitchBend(channel, _):
            channel
        case .systemCommon, .realTime, .sysEx:
            nil
        }
    }

    /// The semantic cases are constructible directly, so data ranges are checked here as `MIDI1PerformanceState` does.
    var hasRoutableData: Bool {
        switch self {
        case let .noteOn(_, first, second), let .noteOff(_, first, second),
             let .polyphonicPressure(_, first, second), let .controlChange(_, first, second):
            first < 0x80 && second < 0x80
        case let .programChange(_, value), let .channelPressure(_, value):
            value < 0x80
        case let .pitchBend(_, value):
            value <= MIDI1ChannelState.maximum14BitValue
        case .systemCommon, .realTime, .sysEx:
            false
        }
    }
}
