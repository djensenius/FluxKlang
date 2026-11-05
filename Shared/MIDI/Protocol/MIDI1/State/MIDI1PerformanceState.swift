/// Persistent MIDI 1 state for the 16 channels of one logical stream. Per-source keying and sender cleanup,
/// including the response to System Reset (FF), belong to #81; system messages never change this state.
struct MIDI1PerformanceState: Equatable, Sendable {
    static let channelCount = 16

    let policy: MIDI1StatePolicy
    private(set) var channels: [MIDI1ChannelState]

    init(policy: MIDI1StatePolicy = .standard) {
        self.policy = policy
        channels = Array(repeating: MIDI1ChannelState(), count: Self.channelCount)
    }

    /// Channel 1...16.
    func channel(_ number: UInt8) -> MIDI1ChannelState? {
        guard (1...UInt8(Self.channelCount)).contains(number) else { return nil }
        return channels[Int(number) - 1]
    }

    /// Raw events the semantic layer refuses are `.malformedEvent`.
    mutating func apply(_ event: MIDI1Event) throws(MIDI1StateRefusal) -> MIDI1StateUpdate {
        guard let semantic = event.semantic else { throw .malformedEvent }
        return try apply(semantic)
    }

    mutating func apply(_ semantic: MIDI1Semantic) throws(MIDI1StateRefusal) -> MIDI1StateUpdate {
        guard let channel = semantic.stateChannel else { return MIDI1StateUpdate(channel: nil, effect: .unchanged) }
        guard (1...UInt8(Self.channelCount)).contains(channel), semantic.hasValidChannelData else {
            throw .malformedEvent
        }
        let effect = try channels[Int(channel) - 1].apply(semantic, channel: channel, policy: policy)
        return MIDI1StateUpdate(channel: channel, effect: effect)
    }
}

/// A value copy of the whole state, including held notes. Parameters and notes are in ascending order.
struct MIDI1PerformanceSnapshot: Equatable, Sendable {
    var policy: MIDI1StatePolicy
    var channels: [MIDI1ChannelSnapshot]
}

struct MIDI1ChannelSnapshot: Equatable, Sendable {
    var controllers: [UInt8]
    var polyPressure: [UInt8]
    var pitchBend: UInt16
    var channelPressure: UInt8
    var program: MIDI1ProgramSelection?
    var activeParameterKind: MIDI1ParameterKind?
    var parameters: [MIDI1ParameterValue]
    var heldNotes: [MIDI1HeldNote]
    var mode: MIDI1ChannelMode
    var localControl: Bool
}

extension MIDI1PerformanceState {
    var snapshot: MIDI1PerformanceSnapshot {
        MIDI1PerformanceSnapshot(policy: policy, channels: channels.map(\.snapshot))
    }

    init(snapshot: MIDI1PerformanceSnapshot) throws(MIDI1StateRefusal) {
        guard snapshot.channels.count == Self.channelCount else { throw .invalidSnapshot(.channelCount) }
        var restored: [MIDI1ChannelState] = []
        for channel in snapshot.channels {
            restored.append(try MIDI1ChannelState(snapshot: channel, policy: snapshot.policy))
        }
        policy = snapshot.policy
        channels = restored
    }
}

private extension MIDI1Semantic {
    /// Channel 1...16 claimed by a channel voice message, or nil for system messages.
    var stateChannel: UInt8? {
        switch self {
        case let .noteOff(channel, _, _), let .noteOn(channel, _, _), let .polyphonicPressure(channel, _, _),
             let .controlChange(channel, _, _):
            channel
        case let .programChange(channel, _), let .channelPressure(channel, _), let .pitchBend(channel, _):
            channel
        case .systemCommon, .realTime, .sysEx:
            nil
        }
    }

    /// The semantic cases are constructible directly, so data ranges are checked again here.
    var hasValidChannelData: Bool {
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
