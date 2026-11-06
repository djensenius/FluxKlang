//
//  MIDIClockArbitrationError.swift
//  FluxKlang
//
//  Typed refusals of MIDI clock leader arbitration. Every throwing call leaves
//  the arbiter unchanged.
//

/// Why an arbitration policy, table edit, leader selection, message or poll was refused.
enum MIDIClockArbitrationError: Error, Equatable, Sendable {
    case invalidMaximumSources(Int)
    case invalidTimeout(nanos: Int64)
    case invalidReacquirePulses(Int)
    case invalidJitterTolerance(perMille: Int)
    /// The table already holds `capacity` sources.
    case sourceTableFull(capacity: Int)
    case duplicateSource(MIDIInputID)
    case unknownSource(MIDIInputID)
    /// The selected leader cannot be removed; select another leader first.
    case sourceIsLeader(MIDIInputID)
    /// Selecting the current leader again is refused rather than silently resetting it.
    case alreadySelected(MIDIClockLeader)
    /// A source's host time went back.
    case nonMonotonicHost(source: MIDIInputID, previous: UInt64, current: UInt64)
    /// A poll went back before the previous poll or the leader's last message.
    case nonMonotonicPoll(previous: UInt64, current: UInt64)
    /// The follower, tempo estimator or timebase refused.
    case clock(MIDIClockError)
}
