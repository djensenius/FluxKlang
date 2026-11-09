/// One batch answer: the binding and either its packet or the reason it has none.
struct ControlFeedbackMIDI1Item: Equatable, Sendable {
    let binding: BindingID
    let outcome: Result<ControlFeedbackMIDI1Packet, ControlFeedbackMIDI1Refusal>
}

/// Turns the planner's neutral `ControlFeedbackMessage` into the MIDI 1 bytes a controller is sent. The bytes are the
/// exact inverse of `MIDIControlIntake.resolve` plus `EncoderProfile.decode`: fed through `MIDI1PerformanceState` and
/// resolved, they give a sample whose raw value is `packet.step`, which is `ControlFeedbackEcho.step(of:grid:)` of the
/// message position on the profile's resolution (the only rounding). Pure: no port, no clock, no state.
///
/// The profile is the caller's: a message names no profile and none is inferred from a source ID. Refusal order for
/// one message is pinned in `ControlFeedbackMIDI1Refusal`. A 14-bit pair makes the receiver report an intermediate
/// value (high 7 bits only) before the full one; a later send layer decides whether to coalesce the two messages.
enum ControlFeedbackMIDI1Encoder {
    /// Most messages of one batch, the planner's own per-call bound.
    static let maximumMessages = ControlHostTruth.maximumValues

    /// Encodes one message. O(L) in the source ID length (at most 128 bytes) plus constant work.
    /// Pass the same dialect the intake uses: with the wrong one a 14-bit key gets bytes the intake will not read
    /// as that key.
    static func encode(
        _ message: ControlFeedbackMessage,
        profile: EncoderProfile,
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) throws(ControlFeedbackMIDI1Refusal) -> ControlFeedbackMIDI1Packet {
        let key = try ControlFeedbackMIDI1SourceParser.parse(message.source)
        try requireSupported(key.kind, dialect: dialect)
        let resolution = try absoluteResolution(of: profile)
        try requireWidth(of: key.kind, profile: profile)
        try ControlFeedbackMIDI1Packet.requireReadable(key, dialect: dialect)
        // A valid message and resolution always give a step; the refusal keeps the function total.
        guard let step = ControlFeedbackEcho.step(of: message.position, grid: resolution) else {
            throw .invalidProfile(resolution: resolution)
        }
        // `make` repeats the readability check; after the check above it cannot refuse for that reason.
        return try ControlFeedbackMIDI1Packet.make(key: key, step: step, dialect: dialect)
    }

    /// Encodes a batch in input order. More than 4096 messages is refused before anything is allocated. A message
    /// with no profile, or any per-message refusal, fails only its own item; messages are never merged or reordered.
    /// O(N * L) with N <= 4096 and L <= 128. Pass the same dialect the intake uses.
    static func encode(
        all messages: [ControlFeedbackMessage],
        profiles: [BindingID: EncoderProfile],
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) throws(ControlFeedbackMIDI1Refusal) -> [ControlFeedbackMIDI1Item] {
        guard messages.count <= maximumMessages else { throw .tooManyMessages(messages.count) }
        var items: [ControlFeedbackMIDI1Item] = []
        items.reserveCapacity(messages.count)
        for message in messages {
            guard let profile = profiles[message.binding] else {
                items.append(ControlFeedbackMIDI1Item(
                    binding: message.binding, outcome: .failure(.profileMissing(message.binding))))
                continue
            }
            do throws(ControlFeedbackMIDI1Refusal) {
                let packet = try encode(message, profile: profile, dialect: dialect)
                items.append(ControlFeedbackMIDI1Item(binding: message.binding, outcome: .success(packet)))
            } catch {
                items.append(ControlFeedbackMIDI1Item(binding: message.binding, outcome: .failure(error)))
            }
        }
        return items
    }

    private static func requireSupported(
        _ kind: ControlSourceKind, dialect: ControlIntakeDialect
    ) throws(ControlFeedbackMIDI1Refusal) {
        switch kind {
        case .controller, .pitchBend, .channelPressure:
            return
        case .controller14:
            switch dialect {
            case .pairedFourteenBit: return
            case .msbOnlySevenBit: throw .unsupportedKind(kind)
            }
        case .registeredParameter, .nonRegisteredParameter:
            throw .unsupportedKind(kind)
        }
    }

    /// The resolution of an absolute profile in 2...16384; a relative profile has no feedback.
    private static func absoluteResolution(of profile: EncoderProfile) throws(ControlFeedbackMIDI1Refusal) -> Int {
        switch profile {
        case .binaryOffset, .twosComplement, .signMagnitude:
            throw .relativeProfile
        case .absolute(let resolution):
            guard (2...EncoderProfile.maximumResolution).contains(resolution) else {
                throw .invalidProfile(resolution: resolution)
            }
            return resolution
        }
    }

    private static func requireWidth(
        of kind: ControlSourceKind, profile: EncoderProfile
    ) throws(ControlFeedbackMIDI1Refusal) {
        let required = MIDIControlIntake.requiredWidth(of: profile)
        guard kind.width == required else {
            throw .widthMismatch(messageBits: kind.width.rawValue, profileBits: required.rawValue)
        }
    }
}
