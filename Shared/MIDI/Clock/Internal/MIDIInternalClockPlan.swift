//
//  MIDIInternalClockPlan.swift
//  FluxKlang
//
//  The deterministic, bounded list of MIDI real-time messages the internal clock master emits for one render
//  window, computed only from the transport, the musical clock map and the window handed in (#84).
//

/// The messages of one window, in the total order of `MIDIInternalClockEvent.precedes`.
///
/// Pulse frames come from `MIDIClockPulseSchedule`, positions from `MIDIClockMath`; nothing here re-derives
/// tick or frame arithmetic. A plan is created only by `make` and is bound to the transport and sample-clock
/// generations it was made for.
struct MIDIInternalClockPlan: Equatable, Sendable {
    /// The longest window a plan may cover: two seconds at 192 kHz.
    static let maximumLookaheadFrames: Int64 = 384_000
    /// The most events one plan may hold: pulses, Song Position, Start or Continue and Stop together.
    static let maximumPlanEvents = 512

    /// The events of a plan and, when they hold the pending Stop, where the transport rests after it.
    typealias Emission = (events: [MIDIInternalClockEvent], restingTicks: Int64?)

    let transportGeneration: Generation
    let sampleGeneration: Generation
    let sampleClock: ClockID
    let window: MIDIInternalClockWindow
    let events: [MIDIInternalClockEvent]
    /// Where the transport rests once this plan's Stop has been delivered: this plan's own map at the REQUESTED Stop
    /// frame, rounded half-up (`MIDIInternalTransport.stopRestingTicks`), not at the frame the Stop is planned at.
    /// The position and the Stop event come from one `plannedStop` result, so a plan has a position exactly when
    /// `events` holds the Stop. `settled(after:)` takes the position from here, so a tempo edit between the request
    /// and the plan moves it together with the clocks the receivers counted. Nil for a plan that holds no Stop.
    let restingTicks: Int64?

    private init(transportGeneration: Generation, sampleGeneration: Generation, sampleClock: ClockID,
                 window: MIDIInternalClockWindow, emission emitted: Emission) {
        self.transportGeneration = transportGeneration
        self.sampleGeneration = sampleGeneration
        self.sampleClock = sampleClock
        self.window = window
        events = emitted.events
        restingTicks = emitted.restingTicks
    }

    /// Plans `window` for a transport driven by `map`.
    ///
    /// Only the internal clock may emit, so `leader` must be `.internal`. The map and the transport must be
    /// current: the map's sample generation is the window's and its transport generation is the transport's. A
    /// stopped transport yields an empty plan. A Continue is planned only at a whole Song Position unit; other
    /// positions are refused for every window of a running run. Once a Stop is pending, only the windows that begin
    /// at or before the run's first frame refuse them (those would emit the Continue); a later window emits no
    /// Continue and does not check the position, so the Stop stays deliverable. Relocating cannot clear a refusal
    /// while a Stop is pending (`locating(toTicks:)` is refused with `stopPending`), so the caller plans the next
    /// window instead of retrying the refused one. When the Start or Continue falls inside the window the map must
    /// place the run's first tick on the frame the run began at; later windows trust the map, because a tempo
    /// change re-anchors it.
    ///
    /// A pending Stop is planned by every window that ends after its frame: at the Stop frame itself, or at the
    /// window's first frame when the Stop's frame has already gone by, so a Stop is never lost. Clocks before the
    /// Stop are planned; the pulse at the Stop frame and every later pulse are suppressed, so a window holding a
    /// late Stop holds no clock. The plan that holds the Stop also carries `restingTicks`, where the transport
    /// rests: this plan's own map at the REQUESTED Stop frame, even when the Stop is planned later because that
    /// frame has gone by. Only that plan evaluates it, so earlier windows plan with a map that could not place the
    /// frame. A map that cannot is refused (`clockMap` when the frame is beyond the tick range,
    /// `positionOutOfRange` when the position is negative) and the caller supplies one that can, for example the
    /// map the Stop was requested with, re-issued for the pending transport generation (`make` requires the map to
    /// belong to it). The caller settles the transport (`settled(after:)`) once the stamped plan that holds the
    /// Stop has been handed over. Loops are not interpreted: the map is planned linearly even if a loop boundary
    /// lies inside the window.
    static func make(transport: MIDIInternalTransport, leader: MIDIClockLeader, map: MusicalClockMap,
                     window: MIDIInternalClockWindow) throws(MIDIInternalClockError) -> MIDIInternalClockPlan {
        guard leader == .internal else { throw .notLeader(leader) }
        guard map.anchor.sample.generation == window.sampleGeneration else { throw .staleSampleGeneration }
        guard map.musical.transport == transport.generation else { throw .staleTransport }
        let emitted: Emission
        switch transport.state {
        case .stopped:
            emitted = (events: [], restingTicks: nil)
        case let .running(run):
            emitted = try emission(of: run, stopFrame: nil, in: map, window: window)
        case let .stopping(run, stopFrame):
            emitted = try emission(of: run, stopFrame: stopFrame, in: map, window: window)
        }
        return MIDIInternalClockPlan(transportGeneration: transport.generation,
                                     sampleGeneration: window.sampleGeneration,
                                     sampleClock: map.anchor.sample.clock, window: window, emission: emitted)
    }

    /// The plan with the lookahead host tick of every event: the earliest tick of `hostMap` whose frame is at
    /// least the event's frame (`MIDIHostStamping`). `current` is the current sample-clock generation; the plan and
    /// the host map must both belong to it, and the host map to the plan's sample clock. The host map is checked
    /// before any event, so an empty plan refuses a stale host map like any other. All events are stamped or none
    /// are. The resting position is carried over unchanged, so settling after the stamped plan rests where
    /// settling after the unstamped one would.
    func stamped(with hostMap: SampleClockMap, current: Generation) throws(MIDIInternalClockError)
        -> MIDIInternalClockPlan {
        guard sampleGeneration == current else { throw .staleSampleGeneration }
        let hostClock = hostMap.anchor.sample.clock
        guard hostClock == sampleClock else { throw .sampleClockMismatch(expected: sampleClock, found: hostClock) }
        guard hostMap.anchor.sample.generation == current else { throw .stamping(.staleSampleGeneration) }
        var result: [MIDIInternalClockEvent] = []
        result.reserveCapacity(events.count)
        for event in events {
            let host: HostStamp
            do throws(ClockMapError) {
                host = try MIDIHostStamping.hostStamp(forFrame: event.frame, in: hostMap, current: current)
            } catch {
                throw .stamping(error)
            }
            result.append(event.stamped(host))
        }
        return MIDIInternalClockPlan(transportGeneration: transportGeneration, sampleGeneration: sampleGeneration,
                                     sampleClock: sampleClock, window: window,
                                     emission: (events: result, restingTicks: restingTicks))
    }
}

private extension MIDIInternalClockPlan {
    /// The events of `run` inside `window` and the resting position of its Stop: Song Position and Start or
    /// Continue at the run's first frame, the Stop and its position as `plannedStop` gives them, and the clocks
    /// before the Stop, sorted into the documented order.
    static func emission(of run: MIDIInternalTransport.Run, stopFrame: Int64?, in map: MusicalClockMap,
                         window: MIDIInternalClockWindow) throws(MIDIInternalClockError) -> Emission {
        let pointer = try plannedSongPositionPointer(for: run, stopFrame: stopFrame, in: window)
        guard run.atFrame < window.endFrame else { return (events: [], restingTicks: nil) }
        var events: [MIDIInternalClockEvent] = []
        if run.atFrame >= window.startFrame {
            try requireAnchored(run, in: map)
            events += startEvents(of: run, pointer: pointer)
        }
        let stop = try plannedStop(stopFrame, in: map, window: window)
        if let stop {
            events.append(MIDIInternalClockEvent(frame: stop.frame, message: .stop))
        }
        let pulseEvents = try clocks(of: run, stopAt: stop?.frame, in: map, window: window, reserved: events.count)
        return (events: (events + pulseEvents).sorted(by: MIDIInternalClockEvent.precedes),
                restingTicks: stop?.restingTicks)
    }

    /// The Stop `window` plans for a Stop requested at `stopFrame`: at that frame, or at the window's first frame
    /// once it has gone by, so a Stop is never lost, with the resting position of the REQUESTED frame in `map`. The
    /// Stop event and the position both come from this one result, so a plan holds one exactly when it holds the
    /// other. Nil when there is no Stop or it lies at or after the window's end: only the plan that holds the Stop
    /// evaluates the position, so earlier windows plan with a map that could not place it.
    static func plannedStop(_ stopFrame: Int64?, in map: MusicalClockMap, window: MIDIInternalClockWindow)
        throws(MIDIInternalClockError) -> (frame: Int64, restingTicks: Int64)? {
        guard let stopFrame, stopFrame < window.endFrame else { return nil }
        let resting = try MIDIInternalTransport.stopRestingTicks(atFrame: stopFrame, in: map)
        return (frame: max(stopFrame, window.startFrame), restingTicks: resting)
    }

    /// The Song Position Pointer `window` needs of `run`: nil for a Start; a position that is not a whole unit is
    /// refused. Once a Stop is pending and the run's first frame lies behind the window, the Continue is not emitted
    /// here, so the position is not checked: an unaligned Continue must not keep its Stop from being delivered.
    static func plannedSongPositionPointer(for run: MIDIInternalTransport.Run, stopFrame: Int64?,
                                           in window: MIDIInternalClockWindow) throws(MIDIInternalClockError)
        -> UInt16? {
        guard stopFrame == nil || run.atFrame >= window.startFrame else { return nil }
        return try songPositionPointer(for: run)
    }

    /// The Song Position Pointer a Continue needs; nil for a Start. A position that is not a whole unit is refused.
    static func songPositionPointer(for run: MIDIInternalTransport.Run) throws(MIDIInternalClockError) -> UInt16? {
        guard run.origin == .continue else { return nil }
        let neighbours = try MIDISongPositionNeighbours.around(ticks: run.fromTicks)
        guard neighbours.floor.ticks == run.fromTicks else {
            throw .positionNotRepresentable(remainderTicks: run.fromTicks - neighbours.floor.ticks)
        }
        return neighbours.floor.position
    }

    /// The map must put the run's first tick on the frame the run began at.
    static func requireAnchored(_ run: MIDIInternalTransport.Run, in map: MusicalClockMap)
        throws(MIDIInternalClockError) {
        let mapFrame: Int64
        do throws(ClockMapError) {
            mapFrame = try map.frame(atTicks: run.fromTicks)
        } catch {
            throw .clockMap(error)
        }
        guard mapFrame == run.atFrame else {
            throw .runNotAnchored(transportFrame: run.atFrame, mapFrame: mapFrame)
        }
    }

    static func startEvents(of run: MIDIInternalTransport.Run, pointer: UInt16?) -> [MIDIInternalClockEvent] {
        var events: [MIDIInternalClockEvent] = []
        if let pointer {
            events.append(MIDIInternalClockEvent(frame: run.atFrame, message: .songPosition(pointer)))
        }
        events.append(MIDIInternalClockEvent(frame: run.atFrame, message: run.origin.message))
        return events
    }

    /// The clocks of `run` in `[max(window start, run start), min(window end, Stop frame))`. `stopAt` is the frame
    /// the plan places its Stop at, if any: the pulse at that frame and every later pulse are suppressed. `reserved`
    /// events of the plan are not clocks and count against `maximumPlanEvents`.
    static func clocks(of run: MIDIInternalTransport.Run, stopAt: Int64?, in map: MusicalClockMap,
                       window: MIDIInternalClockWindow, reserved: Int) throws(MIDIInternalClockError)
        -> [MIDIInternalClockEvent] {
        let first = max(window.startFrame, run.atFrame)
        let end = min(window.endFrame, stopAt ?? window.endFrame)
        guard first < end else { return [] }
        let pulses: [MIDIClockPulseFrame]
        do throws(MIDIClockError) {
            // `end - first` is at most the window's frame count, so it cannot overflow.
            pulses = try MIDIClockPulseSchedule.pulses(in: map, startFrame: first, frameCount: end - first,
                                                       capacity: maximumPlanEvents - reserved)
        } catch {
            throw .schedule(error)
        }
        return pulses.map { MIDIInternalClockEvent(frame: $0.frame, message: .clock, pulseIndex: $0.pulseIndex) }
    }
}
