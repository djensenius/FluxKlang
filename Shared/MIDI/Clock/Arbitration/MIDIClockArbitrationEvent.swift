//
//  MIDIClockArbitrationEvent.swift
//  FluxKlang
//
//  What arbitration reports: leader follower events for the transport, lock
//  transitions of the leader, and diagnostics for messages it ignored.
//

/// Why a message did not reach the transport.
enum MIDIClockIgnoreReason: Equatable, Sendable {
    /// The sender is not the selected leader.
    case notLeader(selected: MIDIClockLeader)
}

enum MIDIClockArbitrationEvent: Equatable, Sendable {
    /// The leader's follower event; only the selected leader produces these.
    case transport(MIDIClockFollowerEvent)
    /// The leader reached N consecutive steady pulses; `reacquired` when it had been lost.
    case leaderLocked(MIDIInputID, tempo: MIDIClockTempoEstimate?, reacquired: Bool)
    /// The leader went silent past the timeout. It stays selected and the tempo is held.
    case leaderLost(MIDIInputID, reason: MIDIClockDegradedReason, heldTempo: MIDIClockTempoEstimate?)
    /// The first message of `kind` ignored from a non-leader since the leader was selected;
    /// repeats are only counted in `MIDIClockSourceStatus.ignored`.
    case competingSource(MIDIInputID, MIDIClockMessageKind, MIDIClockIgnoreReason)

    /// The advisory generation bump, if any. Competing sources never bump.
    var bumpReason: GenerationBumpReason? {
        switch self {
        case let .transport(event): event.bumpReason
        case .leaderLocked: .sourceReacquired
        case .leaderLost: .sourceLost
        case .competingSource: nil
        }
    }
}

/// The result of an explicit leader selection.
struct MIDIClockLeaderChange: Equatable, Sendable {
    let previous: MIDIClockLeader
    let selected: MIDIClockLeader

    /// The previous authority's source generation ends; the new leader's begins when it locks
    /// (`leaderLocked`, `.sourceReacquired`).
    var bumpReason: GenerationBumpReason { .sourceLost }
}
