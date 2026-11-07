//
//  MIDIInternalClockError.swift
//  FluxKlang
//
//  Typed refusals of the internal MIDI clock master (#84): transport transitions, emission plans and
//  host stamps. Every throwing call leaves its inputs unchanged; they are values.
//

/// Why an internal transport transition, an emission plan or a host stamp was refused.
enum MIDIInternalClockError: Error, Equatable, Sendable {
    /// The caller's current clock leader is not the internal clock, so nothing may be emitted.
    case notLeader(MIDIClockLeader)
    /// A map or a transition names a transport generation other than the transport's own.
    case staleTransport
    /// A window, map, plan or host map names a sample-clock generation other than the current one.
    case staleSampleGeneration
    /// The transport generation is at its last value and cannot advance.
    case generationOverflow
    case alreadyRunning
    case alreadyStopped
    case locateWhileRunning
    /// A Stop was requested for `stopFrame` and no plan holding it has settled the transport yet.
    case stopPending(stopFrame: Int64)
    /// A Stop must come at least one frame after the first frame of the run.
    case stopNotAfterStart(startFrame: Int64, stopFrame: Int64)
    /// A frame no plan can hold: a Stop after `MIDIInternalTransport.lastPlannableFrame`, or the first frame of a
    /// run that would leave no frame for its Stop. Refused at the request, so the transport never waits for a Stop
    /// that no window could carry.
    case frameNotPlannable(frame: Int64)
    /// A position outside `0...MIDIClockMath.maximumSongPositionTicks`, or a negative resting position.
    case positionOutOfRange(ticks: Int64)
    /// A Continue position that is not a whole Song Position unit; the remainder is its distance above the floor.
    case positionNotRepresentable(remainderTicks: Int64)
    case windowOutOfRange(startFrame: Int64, frameCount: Int64)
    case capacityExceeded(maximum: Int)
    /// The map places the first tick of the run at `mapFrame`, but the transport began the run at `transportFrame`.
    case runNotAnchored(transportFrame: Int64, mapFrame: Int64)
    case sampleClockMismatch(expected: ClockID, found: ClockID)
    /// A refusal of `MIDIClockMath` or `MIDIClockPulseSchedule`, carried unchanged.
    case clock(MIDIClockError)
    /// A refusal of a clock map, carried unchanged.
    case clockMap(ClockMapError)
}

extension MIDIInternalClockError {
    /// A refusal of the pulse schedule: running out of capacity is the plan's own case, the rest is carried.
    static func schedule(_ error: MIDIClockError) -> MIDIInternalClockError {
        guard case .pulseCapacityExceeded = error else { return .clock(error) }
        return .capacityExceeded(maximum: MIDIInternalClockPlan.maximumPlanEvents)
    }

    /// A refusal while stamping: a stale sample generation is the plan's own case, the rest is carried.
    static func stamping(_ error: ClockMapError) -> MIDIInternalClockError {
        if error == .staleSampleGeneration { return .staleSampleGeneration }
        return .clockMap(error)
    }
}
