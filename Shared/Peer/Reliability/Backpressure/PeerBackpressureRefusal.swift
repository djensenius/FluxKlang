//
//  PeerBackpressureRefusal.swift
//  FluxKlang
//
//  The one typed refusal of the peer backpressure values (#97, R3): the inbound
//  budget, the outbound backlog and the telemetry window. Every refusal leaves
//  the value that threw it unchanged.
//

/// Why a backpressure value refused to be built or to take an operation.
enum PeerBackpressureRefusal: Error, Hashable, Sendable {
    /// The limit a factory refused. Factories name the first bad limit, in parameter order.
    enum Field: Hashable, Sendable {
        case commandsPerWindow
        case windowTicks
        case maxInFlight
        case maxPendingDeltas
        case maxPendingChanges
        case capacity
    }

    /// A limit is outside its documented range (zero included).
    case invalidLimit(Field)
    /// `now` is below the last accepted tick.
    case tickRegressed
    /// The window already holds its `commandsPerWindow` admissions.
    case overBudget
    /// `maxInFlight` tickets are outstanding.
    case inFlightFull
    /// Ticket ids or sequences are used up, or a count is negative or overflowed.
    case overflow
    /// The delta belongs to another host or connection epoch.
    case sessionMismatch
    /// The delta is not the one right after the newest recorded sequence.
    case sequenceGap(expected: PeerSequence, found: PeerSequence)
    /// Recording the delta would exceed the pending delta or pending change limit.
    case backlogFull
    /// A collapse snapshot sequence below the newest recorded delta would hide that delta.
    case snapshotBehind(newest: PeerSequence, found: PeerSequence)
}
