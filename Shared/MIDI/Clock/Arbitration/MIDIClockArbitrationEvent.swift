//
//  MIDIClockArbitrationEvent.swift
//  FluxKlang
//
//  What arbitration reports: leader follower events for the transport, lock
//  transitions of the leader, and diagnostics for messages it ignored. The
//  leader's `.sourceLost` and `.sourceReacquired` bumps are for its source
//  counter, `source/<MIDIInputID>`; transport bumps are for the transport's.
//

/// Why a message did not reach the transport.
enum MIDIClockIgnoreReason: Equatable, Sendable {
    /// The sender is not the selected leader.
    case notLeader(selected: MIDIClockLeader)
}

/// What a leader's lock follows, which decides whether the lock bumps.
enum MIDIClockLockCause: Equatable, Sendable {
    /// The first lock since the leader was selected; its source generation begins.
    case selection
    /// A relock after `leaderLost`; it pairs with that loss's bump.
    case loss
    /// A relock after a locked leader went idle; nothing was bumped, so nothing is.
    case idle
}

enum MIDIClockArbitrationEvent: Equatable, Sendable {
    /// The leader's follower event; only the selected leader produces these.
    case transport(MIDIClockFollowerEvent)
    /// The leader reached N steady pulses. `tempo` is the estimator's current estimate, nil while pending:
    /// a relock never reports a tempo from before the silence.
    case leaderLocked(MIDIInputID, tempo: MIDIClockTempoEstimate?, after: MIDIClockLockCause)
    /// The leader went silent past the timeout while its transport ran. It stays selected, and `heldTempo` is
    /// the last tempo its estimator reported during the current lock (nil if none), whatever the poll cadence.
    /// Reported once per loss episode.
    case leaderLost(MIDIInputID, reason: MIDIClockDegradedReason, heldTempo: MIDIClockTempoEstimate?)
    /// The leader went silent past the timeout while its transport was stopped. Not a loss: no tempo is
    /// claimed and nothing is bumped.
    case leaderIdle(MIDIInputID, reason: MIDIClockDegradedReason)
    /// The leader's tempo estimator acquired, lost or reacquired its own lock. While the leader is locked, the
    /// status tempo follows it; before `leaderLocked` the leader claims no tempo (`.acquired` can come while
    /// still acquiring), so consumers apply no tempo until `leaderLocked`.
    /// Never bumps: the arbiter's `leaderLost` and `leaderLocked` own the leader's source generation.
    case leaderTempo(MIDIInputID, MIDIClockLockEvent)
    /// The first message of `kind` ignored from a non-leader since the leader was selected;
    /// repeats are only counted in `MIDIClockSourceStatus.ignored`.
    case competingSource(MIDIInputID, MIDIClockMessageKind, MIDIClockIgnoreReason)

    /// The advisory generation bump, if any. Idle, tempo and competing-source events never bump.
    var bumpReason: GenerationBumpReason? {
        switch self {
        case let .transport(event): event.bumpReason
        case let .leaderLocked(_, _, cause): cause == .idle ? nil : .sourceReacquired
        case .leaderLost: .sourceLost
        case .leaderIdle, .leaderTempo, .competingSource: nil
        }
    }
}

/// The result of an explicit leader selection.
struct MIDIClockLeaderChange: Equatable, Sendable {
    let previous: MIDIClockLeader
    let selected: MIDIClockLeader
    /// `.sourceLost` for the previous authority's source counter (`source/<MIDIInputID>`, or for `.internal`
    /// the consumer's internal clock counter); nil when the previous leader's loss was already bumped and it
    /// never relocked. The new leader's generation begins when it locks (`leaderLocked`, `.sourceReacquired`).
    let bumpReason: GenerationBumpReason?
}
