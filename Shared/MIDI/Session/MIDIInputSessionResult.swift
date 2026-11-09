/// Why a `MIDIInputSession` call was refused. The session adds no reason of its own: it names the registry's refusal
/// or the Active Sensing observer's, and a refused call changes nothing. Not `Hashable`, because
/// `ActiveSensingRefusal` is not.
enum MIDIInputSessionRefusal: Error, Equatable, Sendable {
    /// The registry's refusal: `make`, `register`, `detach`, `resetSource` or the call-level checks of `feed`.
    case source(MIDISourceRefusal)
    /// The input's observer refused the stamp (`tickRegressed`, `deadlineOverflow`); `input` says which one.
    case sensing(input: MIDIInputID, reason: ActiveSensingRefusal)
}

/// What one `feed` or `poll` produced, in the order it happened.
struct MIDIInputSessionResult: Equatable, Sendable {
    /// The loss release first, then the packet's own outputs in event order (a System Reset's release at its own
    /// place). Each message goes to the route its note started on.
    let outputs: [MIDIRoutedOutput]
    /// One entry per trigger that fired, in trigger order, whether or not anything was held.
    let notices: [MIDIInputSessionNotice]
    /// The per-event refusals in event order, with no event index. This is a log for the caller to count, not an
    /// error list: `.ledger(.unownedNote)` and `.ledger(.unownedPedal)` are benign and frequent in normal playing (a
    /// key released after its input was lost, or after a panic). The session does not classify them.
    let rejections: [MIDIInputSessionRejection]
}

/// A trigger the session acted on.
enum MIDIInputSessionNotice: Equatable, Sendable {
    /// Active Sensing was lost under `.requestInputLost`: the input's notes were released.
    case sensingLostReleased(MIDIInputID)
    /// Active Sensing was lost under `.reportOnly`: nothing was released.
    case sensingLostReported(MIDIInputID)
    /// System Reset (0xFF) arrived under the opt-in `.resetSource` profile: the input's notes were released.
    case systemReset(MIDIInputID)
}

/// A per-event refusal that did not stop the call.
enum MIDIInputSessionRejection: Equatable, Sendable {
    /// The registry's refusal of one event, for example `heldNoteLimit`.
    case state(MIDI1StateRefusal)
    /// The ledger's refusal of one event, for example `unownedNote`.
    case ledger(MIDIPerformanceRefusal)
}
