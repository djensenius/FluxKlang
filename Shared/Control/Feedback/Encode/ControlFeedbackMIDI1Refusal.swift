/// Why a feedback message was not turned into MIDI 1 bytes. Payloads are integers, kinds and binding IDs only.
/// For one message the refusals are checked in this order, each over the whole input before the next:
/// `notMIDISource`, `malformedSource`, `unsupportedKind`, `relativeProfile`, `invalidProfile`, `widthMismatch`,
/// `controllerNotReadable`. A batch checks `tooManyMessages` first, then `profileMissing` for each item.
/// Deliberately not `Codable`: nothing persists a refusal.
enum ControlFeedbackMIDI1Refusal: Error, Hashable, Sendable {
    /// The source ID does not start with `midi.`: it is not a MIDI source, so this encoder has nothing to say.
    case notMIDISource
    /// The source ID starts with `midi.` but is not the canonical form of any `ControlSourceKey`.
    case malformedSource
    /// The kind has no feedback encoding: RPN and NRPN, or a 14-bit pair under the seven-bit-only dialect.
    case unsupportedKind(ControlSourceKind)
    /// A relative encoder shows no position, so it has no feedback.
    case relativeProfile
    /// An absolute resolution outside 2...16384 (or a grid that gives no step).
    case invalidProfile(resolution: Int)
    /// The kind's width differs from the width the profile reads.
    case widthMismatch(messageBits: Int, profileBits: Int)
    /// MIDI intake cannot read this controller number back as the same key.
    case controllerNotReadable(number: Int)
    /// The step is outside 0...maximum for the kind's width.
    case stepOutOfRange(step: Int, maximum: Int)
    /// A batch of more than 4096 messages.
    case tooManyMessages(Int)
    /// A batch message names a binding that has no profile.
    case profileMissing(BindingID)
}
