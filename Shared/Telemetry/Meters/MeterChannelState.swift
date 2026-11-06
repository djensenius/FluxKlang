//
//  MeterChannelState.swift
//  FluxKlang
//
//  One tap channel of the truthful meter model (#102 M1): which sample was
//  last observed and since when it is known to be latest, the falling level,
//  the peak hold and the clip latch. Pure and deterministic; time is injected.
//

/// Why a channel ignored a read: its sample is older than the channel's latest observation (see the ordering
/// contract on `MeterChannelState`). An ignored read changes nothing but its count.
enum MeterIgnoredRead: Equatable, Sendable, CaseIterable {
    /// The sample is from another clock generation than the latest one, and the read was classified before the
    /// latest sample was first classified: a stale read consumed late.
    case classifiedBeforeLatest
    /// The sample is from the same clock generation at an earlier render frame: a frame regression.
    case frameRegressed
    /// The sample is from the same clock generation and render frame with an older slot sequence.
    case sequenceRegressed
}

/// How many reads a channel has ignored since it was created (a new model or `rebind`), per reason. Only
/// `MeterChannelState` counts; a count and `total` wrap (unreachable in practice: 2^64 reads), never trap.
struct MeterIgnoredReadCounts: Equatable, Sendable {
    private(set) var classifiedBeforeLatest: UInt64 = 0
    private(set) var frameRegressed: UInt64 = 0
    private(set) var sequenceRegressed: UInt64 = 0

    fileprivate init() {}

    subscript(reason: MeterIgnoredRead) -> UInt64 {
        switch reason {
        case .classifiedBeforeLatest: classifiedBeforeLatest
        case .frameRegressed: frameRegressed
        case .sequenceRegressed: sequenceRegressed
        }
    }

    /// All ignored reads; wraps (unreachable in practice).
    var total: UInt64 { classifiedBeforeLatest &+ frameRegressed &+ sequenceRegressed }

    fileprivate mutating func record(_ reason: MeterIgnoredRead) {
        switch reason {
        case .classifiedBeforeLatest: classifiedBeforeLatest &+= 1
        case .frameRegressed: frameRegressed &+= 1
        case .sequenceRegressed: sequenceRegressed &+= 1
        }
    }
}

/// One tap channel's observation, ballistics and clip latch.
///
/// A published sample is identified by its slot `sequence` and `stamp`. While it stays the channel's latest
/// observation, its age is measured from the earliest classification time among the reads of it the channel has
/// consumed, never from when the channel consumed them, so a read consumed late is as old as its classification. A
/// sample is applied to the level, peak hold and clip latch each time it becomes the latest observation, and only
/// if it is fresh then; a sample stale at that point stays stale and changes nothing. Rereads while it stays latest
/// are not applied again. Across generations a sample can become latest more than once: displaced by another
/// generation's read, then reread at the same or a later classification time, it is applied again (and can restart
/// the peak hold).
///
/// Ordering contract: reads may be consumed in any order. Each read's sample is compared with the latest one, and a
/// read of an older sample is ignored and counted in `ignoredReads` with its `MeterIgnoredRead` reason; the latest
/// sample stays shown and keeps its age, and the level, peak hold and clip latch are unchanged, so an older read
/// cannot restart the hold, raise the level or peak, or let a fresh reread of the latest sample be applied again.
/// - Across clock generations, reads are ordered only by classification time; generation numbers are compared only
///   for equality (media contract M2). A read from another generation classified before the latest sample was first
///   classified is older (`classifiedBeforeLatest`). One classified at the same time or later is applied as a new
///   sample: equal classification times are ambiguous, and the read consumed later wins.
/// - Within one generation, an earlier render frame is older (`frameRegressed`), whatever its sequence. At the same
///   frame (a stalled render clock), a slot sequence behind by 1 through 2^63 − 1 (serial-number arithmetic across
///   the wrap) is older (`sequenceRegressed`); sequences exactly 2^63 apart are not ordered. A sequence that falls
///   back while the frame advances is a restarted publisher, so it is newer.
///
/// Classification order is only meaningful if the consumer classifies every read with one monotonic host clock, the
/// one `MeterDisplayModel.update(_:at:)` uses. A new channel state (`rebind`) resets the order and the counts.
/// Unavailability does not reset the ballistics: they keep falling with time, so a later reading meets the level a
/// continuous meter would have shown.
struct MeterChannelState: Equatable, Sendable {
    /// A published sample and the earliest host time it is known to have been latest: the earliest classification
    /// time of the reads of it this channel has consumed.
    private struct Observation: Equatable, Sendable {
        let sequence: UInt64
        let stamp: TelemetryStamp
        let firstClassified: MeterInstant
        /// Why the sample's reading cannot be shown (NaN or +∞), or nil.
        let invalid: MeterInvalidReading?

        /// The same sample, dated `firstClassified`.
        func dated(_ firstClassified: MeterInstant) -> Observation {
            Observation(sequence: sequence, stamp: stamp, firstClassified: firstClassified, invalid: invalid)
        }

        /// Why a read of the sample stamped `other` with slot sequence `otherSequence`, classified at `classifiedAt`,
        /// is older than this one, or nil when it is not (see the ordering contract on `MeterChannelState`).
        func olderReason(of other: TelemetryStamp, sequence otherSequence: UInt64,
                         classifiedAt: MeterInstant) -> MeterIgnoredRead? {
            guard other.clockGeneration == stamp.clockGeneration else {
                return classifiedAt < firstClassified ? .classifiedBeforeLatest : nil
            }
            guard other.frame == stamp.frame else { return other.frame < stamp.frame ? .frameRegressed : nil }
            return MeterChannelState.serialWindow.contains(sequence &- otherSequence) ? .sequenceRegressed : nil
        }
    }

    /// How far ahead, modulo 2^64, a slot sequence must be to count as newer: 1 through 2^63 − 1 publications
    /// (RFC 1982 serial-number arithmetic). A distance of exactly 2^63 is not ordered. A computed literal rather
    /// than a `static let`, so first use on a real-time path pays no lazy global initialisation.
    static var serialWindow: ClosedRange<UInt64> { 1...(1 << 63) - 1 }

    /// A displayed value at the host time it was set; it falls from there.
    private struct Anchor: Equatable, Sendable {
        let dbfs: Double
        let since: MeterInstant
    }

    private var latest: Observation?
    private var level: Anchor?
    private var peak: Anchor?
    /// Set by a fresh reading at or above the clip threshold; cleared only by `resetClip()` or a new channel state.
    private(set) var clipLatched = false
    /// Reads ignored because their sample is older than the latest observation, per reason.
    private(set) var ignoredReads = MeterIgnoredReadCounts()

    init() {}

    mutating func resetClip() {
        clipLatched = false
    }

    /// Classifies `read` at `now`. Precedence: telemetry unavailable, then stale, then invalid reading, then
    /// measured. `now` must not precede any earlier `now` or `read.classifiedAt`; `MeterDisplayModel` refuses a
    /// clock regression and a read classified after the update.
    mutating func observe(_ read: MeterClassifiedRead, at now: MeterInstant,
                          window: MeterStalenessWindow, ballistics: MeterBallistics) -> MeterChannelSignal {
        let sample: TelemetrySample<MeterTapValue>
        switch read.read {
        case .unavailable(let reason): return .unavailable(MeterUnavailableReason(reason))
        case .measured(let measured): sample = measured
        }
        let observed: Observation
        let isNew: Bool
        if let latest, latest.sequence == sample.sequence, latest.stamp == sample.stamp {
            // An older read of the same sample, consumed late, makes it older; a newer one never makes it younger.
            observed = latest.dated(min(latest.firstClassified, read.classifiedAt))
            isNew = false
        } else if let latest,
                  let reason = latest.olderReason(of: sample.stamp, sequence: sample.sequence,
                                                  classifiedAt: read.classifiedAt) {
            // A read of an older sample, consumed out of order, is ignored and counted: the latest sample stays
            // shown, aged from its own classification, and nothing is applied again.
            ignoredReads.record(reason)
            observed = latest
            isNew = false
        } else {
            observed = Observation(sequence: sample.sequence, stamp: sample.stamp, firstClassified: read.classifiedAt,
                                   invalid: MeterInvalidReading(peakDBFS: sample.value.peakDBFS))
            isNew = true
        }
        latest = observed
        let age = Self.elapsed(from: observed.firstClassified, to: now)
        guard age <= window.nanoseconds else { return .unavailable(.stale(ageNanoseconds: age)) }
        if isNew {
            apply(sample.value, at: now, ballistics: ballistics)
        }
        if let invalid = observed.invalid {
            return .unavailable(.invalidReading(invalid))
        }
        // Unreachable: a valid sample that is fresh now was fresh when this channel began observing it (its age only
        // grows while it stays the latest observation, and an ignored older read leaves it alone), so it was applied
        // then. Unavailable rather than a made-up level.
        guard let level, let peak else { return .unavailable(.neverPublished) }
        return .measured(levelDBFS: Self.fallen(level, at: now, ballistics: ballistics),
                         peakHoldDBFS: Self.held(peak, at: now, ballistics: ballistics))
    }

    /// Applies a newly observed, fresh sample at `now`, the update that consumes it. NaN changes nothing. +∞ is an
    /// overflow: it latches the clip but leaves the level and peak hold untouched. A finite reading at or above the
    /// threshold latches the clip and is shown between the floor (−∞ and anything lower is silence) and the
    /// ceiling. The level rises to the shown reading or keeps falling; the peak restarts its hold when the shown
    /// reading reaches the held peak.
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

    /// Nanoseconds from `start` to `now`. Every anchor and classification time is at or before the latest `now`
    /// (`MeterDisplayModel` refuses a clock regression and a read classified after the update), so the checked
    /// subtraction cannot fail; were it to, the result is 0.
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
