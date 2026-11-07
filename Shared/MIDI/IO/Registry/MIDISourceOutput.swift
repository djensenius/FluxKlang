/// One note a source held when it was reset or detached, for the caller to feed to `MIDINoteLedger.inputLost`.
/// Reports are ascending by channel (1...16), then note.
struct MIDISourceRelease: Equatable, Hashable, Sendable {
    let channel: UInt8
    let note: UInt8
    /// `.keyDown` (the key is still down) or `.sustained` (held by the pedal only).
    let phase: MIDI1HeldNotePhase
}

/// What the source's state did with one emitted event.
enum MIDISourceOutcome: Equatable, Sendable {
    case applied(MIDI1StateUpdate)
    /// The state refused this event (and is unchanged by it); later bytes of the feed continue.
    case refused(MIDI1StateRefusal)
    /// System Reset (FF) on a source whose profile resets: every held note, ascending, and fresh state afterwards.
    case systemReset(released: [MIDISourceRelease])
}

/// One emitted MIDI 1 event of one source. Outputs of a feed are in byte order, at most one per input byte.
struct MIDISourceOutput: Equatable, Sendable {
    let input: MIDIInputID
    let event: MIDI1Event
    let outcome: MIDISourceOutcome

    /// The event for a note ledger: only an applied channel voice message. Nil for system, real-time and SysEx
    /// events, refused events and resets.
    var performanceEvent: MIDIPerformanceEvent? {
        guard case let .applied(update) = outcome, update.channel != nil, let message = event.semantic else {
            return nil
        }
        return MIDIPerformanceEvent(input: input, message: message)
    }
}
