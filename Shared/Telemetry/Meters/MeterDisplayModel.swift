//
//  MeterDisplayModel.swift
//  FluxKlang
//
//  The truthful meter display model (#102 M1): classified telemetry reads,
//  each with its injected classification time, plus an injected monotonic
//  host time in, one display per meter out. Pure value type; no clocks,
//  timers, Foundation or global state.
//

/// One tap channel's display. Only `MeterDisplayModel` builds one, so a measured level cannot be made up.
struct MeterChannelDisplay: Equatable, Sendable {
    let signal: MeterChannelSignal
    /// A clip latched since the last `resetClip()` or source change; kept while the channel is unavailable.
    let clipLatched: Bool

    fileprivate init(signal: MeterChannelSignal, clipLatched: Bool) {
        self.signal = signal
        self.clipLatched = clipLatched
    }
}

/// A meter's display state machine.
///
/// The only signal input is a `MeterClassifiedRead` from a measured tap, so every sample has passed the kernel's
/// render-stamp staleness rule before host-time staleness applies here. Host-time age is measured from each read's
/// classification time, so a read held back past the window is stale whether this model, a new one or a rebound one
/// consumes it, and it never feeds the level, peak hold or clip latch. Fader or gain positions are control values
/// with no entry point: a `faderTravelOnly` or gated source shows "Unavailable" with that reason and refuses any
/// reads. Refused calls leave the model unchanged.
struct MeterDisplayModel: Equatable, Sendable {
    let staleness: MeterStalenessWindow
    let ballistics: MeterBallistics
    private(set) var source: MeterSource
    /// The host time of the last accepted update; later updates must not be earlier.
    private(set) var lastUpdate: MeterInstant?
    /// One state per tap channel, in channel order; empty for a source that is not measured.
    private var channels: [MeterChannelState]

    init(source: MeterSource, staleness: MeterStalenessWindow, ballistics: MeterBallistics) {
        self.source = source
        self.staleness = staleness
        self.ballistics = ballistics
        channels = Array(repeating: MeterChannelState(), count: source.channelCount)
    }

    /// Shows the meter at `now` from one read per tap channel, in channel order.
    ///
    /// Checks, in order: `now` is not earlier than the last update (`.clockRegressed`), a source that is not
    /// measured receives no reads (`.readsForUnmeasuredSource`), a tap receives exactly one read per channel
    /// (`.channelCountMismatch`), and no read was classified after `now` (`.classifiedAfterUpdate`, first offending
    /// channel). An equal `now` and a classification time equal to `now` are accepted.
    mutating func update(_ reads: [MeterClassifiedRead],
                         at now: MeterInstant) throws(MeterDisplayRefusal) -> MeterDisplay {
        if let lastUpdate, now < lastUpdate {
            throw .clockRegressed(last: lastUpdate, now: now)
        }
        if let reason = source.unavailableReason {
            guard reads.isEmpty else { throw .readsForUnmeasuredSource(reason, count: reads.count) }
            lastUpdate = now
            return .unavailable(reason)
        }
        guard reads.count == channels.count else {
            throw .channelCountMismatch(expected: channels.count, received: reads.count)
        }
        if let channel = reads.firstIndex(where: { now < $0.classifiedAt }) {
            throw .classifiedAfterUpdate(channel: channel, classifiedAt: reads[channel].classifiedAt, now: now)
        }
        lastUpdate = now
        var displays: [MeterChannelDisplay] = []
        displays.reserveCapacity(channels.count)
        for index in channels.indices {
            let signal = channels[index].observe(reads[index], at: now, window: staleness, ballistics: ballistics)
            displays.append(MeterChannelDisplay(signal: signal, clipLatched: channels[index].clipLatched))
        }
        return .channels(displays)
    }

    /// Clears every channel's clip latch; levels, peak holds and observations are unchanged.
    mutating func resetClip() {
        for index in channels.indices {
            channels[index].resetClip()
        }
    }

    /// Binds the meter to `source`, which counts as a source change even when equal to the current one: every
    /// channel's observation, level, peak hold and clip latch starts afresh. The last update time is kept, so
    /// host time stays monotonic across the change, and reads are still aged from their classification time, so a
    /// rebind never makes a late read fresh.
    mutating func rebind(to source: MeterSource) {
        self.source = source
        channels = Array(repeating: MeterChannelState(), count: source.channelCount)
    }
}
