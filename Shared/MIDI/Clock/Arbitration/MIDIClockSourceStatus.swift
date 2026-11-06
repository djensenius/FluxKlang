//
//  MIDIClockSourceStatus.swift
//  FluxKlang
//
//  The visible state of MIDI clock arbitration: which source is leader, whether
//  it is locked or degraded (and why), and per source what the arbiter ignored.
//

/// The transport's clock authority: the internal clock or one external source.
enum MIDIClockLeader: Hashable, Sendable {
    case `internal`
    case external(MIDIInputID)
}

/// The clock messages arbitration counts, one per `MIDIClockMessage` case.
enum MIDIClockMessageKind: Int, CaseIterable, Sendable {
    case clock, start, `continue`, stop, songPosition

    init(_ message: MIDIClockMessage) {
        switch message {
        case .clock: self = .clock
        case .start: self = .start
        case .continue: self = .continue
        case .stop: self = .stop
        case .songPosition: self = .songPosition
        }
    }
}

/// Why the selected external leader is degraded. The last tempo is held; no other source takes over.
enum MIDIClockDegradedReason: Equatable, Sendable {
    /// `poll(now:)` found no leader pulse for longer than the timeout.
    case silence(lastPulse: HostStamp, detectedAt: HostStamp)
    /// A leader pulse arrived more than the timeout after the previous one.
    case lateArrival(lastPulse: HostStamp, detectedAt: HostStamp)
}

/// The leader's lock as the transport and UI see it.
enum MIDIClockLeaderStatus: Equatable, Sendable {
    /// The internal clock is leader; every external source is competing.
    case `internal`
    /// An external leader selected and not yet locked since its selection.
    case acquiring(MIDIInputID, steadyPulses: Int)
    /// The leader is locked; `tempo` is its latest estimate, nil until the estimator has one.
    case locked(MIDIInputID, tempo: MIDIClockTempoEstimate?)
    /// The leader was lost: the transport keeps `heldTempo` until `steadyPulses` reaches the policy's N.
    case degraded(MIDIInputID, reason: MIDIClockDegradedReason, heldTempo: MIDIClockTempoEstimate?,
                  steadyPulses: Int)

    var leader: MIDIClockLeader {
        switch self {
        case .internal: .internal
        case let .acquiring(id, _), let .locked(id, _), let .degraded(id, _, _, _): .external(id)
        }
    }

    var isDegraded: Bool {
        if case .degraded = self { return true }
        return false
    }
}

/// Messages ignored from one non-leader source since the leader was last selected, by kind.
/// Fixed size: one saturating counter per `MIDIClockMessageKind`.
struct MIDIClockIgnoredCounts: Equatable, Sendable {
    private var counts = [UInt64](repeating: 0, count: MIDIClockMessageKind.allCases.count)

    init() {}

    subscript(kind: MIDIClockMessageKind) -> UInt64 { counts[kind.rawValue] }

    var total: UInt64 {
        counts.reduce(0) { sum, count in
            let (next, overflow) = sum.addingReportingOverflow(count)
            return overflow ? .max : next
        }
    }

    /// Counts one ignored message; true when it is the first of its kind (the one that is reported).
    mutating func record(_ kind: MIDIClockMessageKind) -> Bool {
        let count = counts[kind.rawValue]
        if count < .max { counts[kind.rawValue] = count + 1 }
        return count == 0
    }
}

/// A snapshot of one registered source.
struct MIDIClockSourceStatus: Equatable, Sendable {
    let id: MIDIInputID
    let isLeader: Bool
    /// The source's own follower: the leader's drives the transport, any other's is a shadow for display.
    let followerState: MIDIClockFollower.State
    let nextPulseTicks: Int64
    /// The host time of the source's last accepted message.
    let lastHost: HostStamp?
    let ignored: MIDIClockIgnoredCounts
}
