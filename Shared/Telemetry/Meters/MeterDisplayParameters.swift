//
//  MeterDisplayParameters.swift
//  FluxKlang
//
//  Injected time and validated parameters of the truthful meter display model
//  (#102 M1). The model never reads a clock and has no default staleness
//  window (#55 open question 5): every value here is passed in.
//

/// An injected monotonic host time in nanoseconds. The meter model never reads a clock.
struct MeterInstant: Comparable, Hashable, Sendable {
    let nanoseconds: UInt64

    static func < (lhs: MeterInstant, rhs: MeterInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// Nanoseconds from `earlier` to `self` with checked arithmetic; nil when `earlier` is later.
    func nanoseconds(since earlier: MeterInstant) -> UInt64? {
        let (elapsed, overflow) = nanoseconds.subtractingReportingOverflow(earlier.nanoseconds)
        return overflow ? nil : elapsed
    }
}

/// How long a sample may be shown after the earliest classification of it that its channel has consumed, before the
/// channel shows `.stale(ageNanoseconds:)`: its producer stopped replacing it, or its read was consumed late.
///
/// The window answers #55 open question 5 per caller; there is deliberately no default. An age equal to the
/// window is still fresh; one nanosecond more is stale.
struct MeterStalenessWindow: Equatable, Sendable {
    /// 1 ms through 60 s inclusive. Shorter windows go stale between UI frames; longer ones show dead telemetry.
    static let allowedNanoseconds: ClosedRange<Int64> = 1_000_000...60_000_000_000

    let nanoseconds: UInt64

    private init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    static func make(nanoseconds: Int64) throws(MeterDisplayRefusal) -> MeterStalenessWindow {
        guard allowedNanoseconds.contains(nanoseconds) else {
            throw .stalenessWindowOutOfRange(nanoseconds: nanoseconds)
        }
        return MeterStalenessWindow(nanoseconds: UInt64(nanoseconds))
    }
}

/// Peak hold, decay, floor and clip threshold of a meter, validated together.
///
/// Levels are dBFS. The displayed level rises only on a new reading and otherwise falls at
/// `decayDecibelsPerSecond`; the peak hold stays for `peakHoldNanoseconds` and then falls at the same rate.
/// Neither ever drops below `floorDBFS`, and a level at the floor is measured silence. Neither is ever shown above
/// `ceilingDBFS`. A reading at or above `clipThresholdDBFS` latches the channel's clip indicator.
struct MeterBallistics: Equatable, Sendable {
    /// 0 (no hold) through 30 s inclusive.
    static let allowedPeakHoldNanoseconds: ClosedRange<Int64> = 0...30_000_000_000
    /// 1 through 1000 dB/s inclusive.
    static let allowedDecayDecibelsPerSecond: ClosedRange<Double> = 1...1_000
    /// −200 through −20 dBFS inclusive.
    static let allowedFloorDBFS: ClosedRange<Double> = -200 ... -20
    /// Highest displayed level and peak hold (inclusive). A larger finite reading is shown here, and because no
    /// clip threshold is above the ceiling, it always latches the clip.
    static let ceilingDBFS: Double = 24
    /// The clip threshold must be above the floor and at most this (the ceiling).
    static let maximumClipThresholdDBFS: Double = ceilingDBFS

    let peakHoldNanoseconds: UInt64
    let decayDecibelsPerSecond: Double
    let floorDBFS: Double
    let clipThresholdDBFS: Double

    private init(peakHoldNanoseconds: UInt64, decayDecibelsPerSecond: Double, floorDBFS: Double,
                 clipThresholdDBFS: Double) {
        self.peakHoldNanoseconds = peakHoldNanoseconds
        self.decayDecibelsPerSecond = decayDecibelsPerSecond
        self.floorDBFS = floorDBFS
        self.clipThresholdDBFS = clipThresholdDBFS
    }

    /// Checks, in order: peak hold, decay rate, floor, clip threshold; the first failure is thrown.
    static func make(peakHoldNanoseconds: Int64, decayDecibelsPerSecond: Double, floorDBFS: Double,
                     clipThresholdDBFS: Double) throws(MeterDisplayRefusal) -> MeterBallistics {
        guard allowedPeakHoldNanoseconds.contains(peakHoldNanoseconds) else {
            throw .peakHoldOutOfRange(nanoseconds: peakHoldNanoseconds)
        }
        guard decayDecibelsPerSecond.isFinite else { throw .parameterNotFinite(.decayRate) }
        guard allowedDecayDecibelsPerSecond.contains(decayDecibelsPerSecond) else {
            throw .decayRateOutOfRange(decayDecibelsPerSecond)
        }
        guard floorDBFS.isFinite else { throw .parameterNotFinite(.floor) }
        guard allowedFloorDBFS.contains(floorDBFS) else { throw .floorOutOfRange(floorDBFS) }
        guard clipThresholdDBFS.isFinite else { throw .parameterNotFinite(.clipThreshold) }
        guard clipThresholdDBFS > floorDBFS, clipThresholdDBFS <= maximumClipThresholdDBFS else {
            throw .clipThresholdOutOfRange(clipThresholdDBFS, floorDBFS: floorDBFS)
        }
        return MeterBallistics(peakHoldNanoseconds: UInt64(peakHoldNanoseconds),
                               decayDecibelsPerSecond: decayDecibelsPerSecond, floorDBFS: floorDBFS,
                               clipThresholdDBFS: clipThresholdDBFS)
    }

    /// `dbfs` after falling for `elapsed` nanoseconds, never below the floor.
    func fallen(_ dbfs: Double, overNanoseconds elapsed: UInt64) -> Double {
        max(floorDBFS, dbfs - decayDecibelsPerSecond * Double(elapsed) / 1_000_000_000)
    }
}
