//
//  MIDIClockSteadyRun.swift
//  FluxKlang
//
//  The selected leader's run of steady clock pulses, judged against a stable
//  reference period rather than the previous interval: one late pulse costs
//  nothing, and drift accumulates until it resets the run.
//
//  A run starts at an anchor timestamp; pulse k of the run is due at
//  anchor + k * P. The reference P is seeded once per run: from the tempo
//  estimator's period when it has one, otherwise from the first later
//  timestamp as (span / pulses spanned), so clocks sharing a timestamp count
//  by their span, as in the C1 estimator. A pulse is steady when it lands
//  within (L + jitter) * P of its due time. L is C1's lag bound (2): a
//  timestamp may lag its due time by up to L pulses and the anchor may lag
//  too, so a pulse may land up to L pulses early or late; the policy's jitter
//  tolerance adds a fraction of P on top. Neither the anchor nor the pulse
//  that seeds P is judged, so N steady pulses take N + 2 pulses from an
//  interval seed and N + 1 from an estimator seed.
//
//  A pulse outside the tolerance resets the count and starts a new run at its
//  timestamp, keeping the earlier pulses that share it (at most L: more than
//  L + 1 pulses on one timestamp exceed the lag bound). The arithmetic is exact
//  Int128, and a run spans at most L + N + 1 pulses before it locks.
//

struct MIDIClockSteadyRun: Sendable {
    /// A per-pulse period as an exact ratio: `span` host ticks over `pulses` pulses, both positive.
    struct Period: Equatable, Sendable {
        let span: Int128
        let pulses: Int128
    }

    /// L: how many pulses a timestamp may lag its due time (C1's default lag bound).
    static let lagPulses = MIDIClockTempoEstimator.defaultMaximumLagPulses

    /// The run's first timestamp; nil before its first pulse.
    private(set) var anchor: UInt64?
    /// The latest pulse's timestamp and its index k in the run.
    private(set) var latest: UInt64 = 0
    private(set) var pulses = 0
    /// Earlier pulses sharing the latest timestamp, at most L.
    private(set) var sharing = 0
    private(set) var reference: Period?
    private(set) var steadyPulses = 0

    /// Adds the next pulse at `host`. `seed` (the estimator's period, if any) seeds a run that starts here.
    mutating func advance(to host: HostStamp, seed: Period?, tolerancePerMille: Int, cap: Int) {
        guard let anchor else {
            restart(at: host.ticks, keeping: 0, seed: seed)
            return
        }
        sharing = host.ticks == latest ? min(sharing + 1, Self.lagPulses) : 0
        latest = host.ticks
        pulses += 1
        guard let reference else {
            if host.ticks > anchor {
                reference = Period(span: Int128(host.ticks - anchor), pulses: Int128(pulses))
            } else if pulses > Self.lagPulses {
                restart(at: host.ticks, keeping: sharing, seed: seed)
            }
            return
        }
        if Self.isSteady(elapsed: host.ticks - anchor, pulse: pulses, reference: reference,
                         tolerancePerMille: tolerancePerMille) {
            steadyPulses = min(steadyPulses + 1, cap)
        } else {
            restart(at: host.ticks, keeping: sharing, seed: seed)
        }
    }

    /// |elapsed - k * P| <= (L + tolerance / 1000) * P for pulse k, cross-multiplied by 1000 * P.pulses into
    /// exact integers.
    static func isSteady(elapsed: UInt64, pulse index: Int, reference: Period, tolerancePerMille: Int) -> Bool {
        let deviation = Int128(elapsed) * reference.pulses - Int128(index) * reference.span
        let bound = (Int128(lagPulses) * 1_000 + Int128(tolerancePerMille)) * reference.span
        return abs(deviation) * 1_000 <= bound
    }

    private mutating func restart(at ticks: UInt64, keeping shared: Int, seed: Period?) {
        anchor = ticks
        latest = ticks
        pulses = shared
        sharing = shared
        reference = seed
        steadyPulses = 0
    }
}
