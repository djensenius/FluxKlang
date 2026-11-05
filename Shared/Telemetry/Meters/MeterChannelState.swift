//
//  MeterChannelState.swift
//  FluxKlang
//
//  One tap channel of the truthful meter model (#102 M1): which sample was
//  last observed and when, the falling level, the peak hold and the clip
//  latch. Pure and deterministic; time is injected.
//

/// One tap channel's observation, ballistics and clip latch.
///
/// A published sample is identified by its slot `sequence` and `stamp`. It is applied to the level, peak hold
/// and clip latch exactly once, when first observed, so a level never rises without a new reading. Its age is
/// measured from that first observation. Unavailability does not reset the ballistics: they keep falling with
/// time, so a later reading meets the level a continuous meter would have shown.
struct MeterChannelState: Equatable, Sendable {
    /// A published sample and the host time this channel first observed it.
    private struct Observation: Equatable, Sendable {
        let sequence: UInt64
        let stamp: TelemetryStamp
        let firstSeen: MeterInstant
    }

    /// A displayed value at the host time it was set; it falls from there.
    private struct Anchor: Equatable, Sendable {
        let dbfs: Double
        let since: MeterInstant
    }

    private var latest: Observation?
    private var level: Anchor?
    private var peak: Anchor?
    /// Set by a reading at or above the clip threshold; cleared only by `resetClip()` or a new channel state.
    private(set) var clipLatched = false

    init() {}

    mutating func resetClip() {
        clipLatched = false
    }

    /// Classifies `read` at `now`. Precedence: telemetry unavailable, then stale, then invalid reading, then
    /// measured. `now` must not precede any earlier `now`; `MeterDisplayModel` refuses a clock regression.
    mutating func observe(_ read: MeterClassifiedRead, at now: MeterInstant,
                          window: MeterStalenessWindow, ballistics: MeterBallistics) -> MeterChannelSignal {
        let sample: TelemetrySample<MeterTapValue>
        switch read.read {
        case .unavailable(let reason): return .unavailable(MeterUnavailableReason(reason))
        case .measured(let measured): sample = measured
        }
        let observation: Observation
        if let latest, latest.sequence == sample.sequence, latest.stamp == sample.stamp {
            observation = latest
        } else {
            observation = Observation(sequence: sample.sequence, stamp: sample.stamp, firstSeen: now)
            latest = observation
            apply(sample.value, at: now, ballistics: ballistics)
        }
        let age = Self.elapsed(from: observation.firstSeen, to: now)
        guard age <= window.nanoseconds else { return .unavailable(.stale(ageNanoseconds: age)) }
        if let invalid = MeterInvalidReading(peakDBFS: sample.value.peakDBFS) {
            return .unavailable(.invalidReading(invalid))
        }
        // Unreachable: a valid sample was applied when first observed. Unavailable rather than a made-up level.
        guard let level, let peak else { return .unavailable(.neverPublished) }
        return .measured(levelDBFS: Self.fallen(level, at: now, ballistics: ballistics),
                         peakHoldDBFS: Self.held(peak, at: now, ballistics: ballistics))
    }

    /// Applies a newly observed sample. NaN changes nothing. +∞ is an overflow: it latches the clip but leaves the
    /// level and peak hold untouched. A finite reading at or above the threshold latches the clip and is shown
    /// between the floor (−∞ and anything lower is silence) and the ceiling. The level rises to the shown reading
    /// or keeps falling; the peak restarts its hold when the shown reading reaches the held peak.
    private mutating func apply(_ value: MeterTapValue, at now: MeterInstant, ballistics: MeterBallistics) {
        let reading: Double
        switch MeterInvalidReading(peakDBFS: value.peakDBFS) {
        case .notANumber?:
            return
        case .positiveInfinity?:
            clipLatched = true
            return
        case nil:
            reading = value.peakDBFS
        }
        if reading >= ballistics.clipThresholdDBFS {
            clipLatched = true
        }
        let shown = min(max(ballistics.floorDBFS, reading), MeterBallistics.ceilingDBFS)
        let current = level.map { Self.fallen($0, at: now, ballistics: ballistics) } ?? ballistics.floorDBFS
        level = Anchor(dbfs: max(shown, current), since: now)
        if let peak, Self.held(peak, at: now, ballistics: ballistics) > shown {
            return
        }
        peak = Anchor(dbfs: shown, since: now)
    }

    /// Nanoseconds from `start` to `now`. Every anchor and observation is at or before the latest `now`, so the
    /// checked subtraction cannot fail; were it to, no time passes, which never raises a level.
    private static func elapsed(from start: MeterInstant, to now: MeterInstant) -> UInt64 {
        now.nanoseconds(since: start) ?? 0
    }

    private static func fallen(_ level: Anchor, at now: MeterInstant, ballistics: MeterBallistics) -> Double {
        ballistics.fallen(level.dbfs, overNanoseconds: elapsed(from: level.since, to: now))
    }

    /// The peak while its hold lasts (an age equal to the hold is still held), then falling at the decay rate.
    private static func held(_ peak: Anchor, at now: MeterInstant, ballistics: MeterBallistics) -> Double {
        let age = elapsed(from: peak.since, to: now)
        guard age > ballistics.peakHoldNanoseconds else { return peak.dbfs }
        return ballistics.fallen(peak.dbfs, overNanoseconds: age - ballistics.peakHoldNanoseconds)
    }
}
