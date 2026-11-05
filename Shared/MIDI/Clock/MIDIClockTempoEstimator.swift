//
//  MIDIClockTempoEstimator.swift
//  FluxKlang
//
//  Tempo and lock tracking for one external MIDI clock from caller-supplied
//  host times. All arithmetic is exact Int128; the timestamp ring is allocated
//  once at init and observing a pulse never allocates.
//
//  Span-based estimation: the estimator keeps the last W + 1 pulse timestamps
//  (W = 24 by default, policy 6...96) and measures the per-pulse period as
//  (newest - oldest) / (pulses spanned). Clocks sharing one host time (one
//  CoreMIDI packet) are ordinary pulses, so early stamping, late delivery and
//  bursts need no per-gap rule: only the window's endpoints matter, and a
//  timestamp late by at most L moves the period by at most L / W. A window
//  whose span is zero has no estimate and never locks.
//
//  Consistency gate: a source may stamp a pulse up to L pulses late (L = 2 by
//  default). Halves of n1 = W / 2 and n2 = W - n1 intervals then err by at most
//  L / n1 and L / n2 of the period, so their per-pulse periods may differ by at
//  most L (1 / n1 + 1 / n2) of the window estimate: g = 4L / W for even W (1/3
//  for W = 24, L = 2). Measuring the period from the window's own span S keeps
//  the bound exact at every lag vertex, so a lag of at most L always passes. The
//  gate is computed from the configured W and L. A window that fails it holds: it
//  never locks, and while locked it changes neither the reported estimate nor
//  the outlier run. A failing gate alone never reports the source lost.
//
//  Lock: acquisition locks once the window spans W intervals and passes the
//  gate. While locked, a gate-passing window estimate beyond 4L / W of the tracking
//  reference is an outlier and is not reported; any other gate-passing
//  estimate is reported and becomes the reference, so ramps of at most a few
//  percent per pulse are followed. 24 consecutive outliers report the source
//  lost (an abrupt tempo change), and it relocks from the same window once the
//  gate passes. An isolated glitch only moves an endpoint, so it never unlocks.
//  Once the window holds only one tempo, the endpoint error is at most L / W.
//  Transient: after an abrupt change the first jump pulses still pass the gate,
//  so the reported estimate blends both tempos (20 -> 9 ms: 469,000 down to
//  414,000 us per quarter over six pulses) and is then held while the gate
//  fails, until the run reports the source lost and it relocks.
//
//  Dropout: one timeout governs both an arriving gap and the elapsed-time
//  silence check in `poll`; neither is scaled by batching. Endpoint lag can only
//  shorten a window of n intervals: its span T >= (n - L) P, so P <= T / (n - L).
//  The timeout is 4 x T / (n - L), clamped to 50...500 ms and rounded up to whole
//  host ticks, so lag never makes it shorter than 4P while one lagged gap is at
//  most (L + 1) P <= 3P. Before 6 intervals with a positive span there is no
//  window period and the timeout is the 500 ms ceiling (n - L >= 4 whenever a
//  period exists, since n >= 6 and L <= 2). With lag it is at most
//  4 (n + L) / (n - L) P: 4.73P for a full W = 24 window, 8P for a 6-interval
//  window (W = 6 or early acquisition), within the clamp. A dropout resets the
//  window. A source that batches a whole beat behind a silence longer than the
//  timeout is therefore treated as lost, by design.
//

/// A tempo measured from the accepted window, clamped to the `TempoSegment` range.
struct MIDIClockTempoEstimate: Equatable, Sendable {
    let microsPerQuarter: Int64
    /// True when the measured tempo fell outside 60,000...3,000,000 µs per quarter.
    let clamped: Bool
}

enum MIDIClockLock: Equatable, Sendable {
    /// No pulse yet.
    case unlocked
    /// Filling the timestamp window; `goodIntervals` counts the intervals it spans.
    case acquiring(goodIntervals: Int)
    case locked
    /// The clock dropped out; the next pulse starts reacquisition.
    case lost
}

/// A lock transition the transport must see.
enum MIDIClockLockEvent: Equatable, Sendable {
    case acquired(MIDIClockTempoEstimate)
    case lost(lastPulse: HostStamp)
    case reacquired(MIDIClockTempoEstimate)

    var bumpReason: GenerationBumpReason? {
        switch self {
        case .acquired: nil
        case .lost: .sourceLost
        case .reacquired: .sourceReacquired
        }
    }
}

struct MIDIClockTempoEstimator: Sendable {
    static let defaultWindowIntervals = 24
    static let windowIntervalRange = 6...96
    /// L: the pulses a timestamp may lag its due time.
    static let defaultMaximumLagPulses = 2
    static let maximumLagPulsesRange = 1...2
    /// Intervals needed for a window period before the window fills.
    static let minimumEstimateIntervals = 6
    /// Consecutive outlier window estimates while locked that report the source lost.
    static let maximumConsecutiveOutliers = 24
    static let dropoutMeanMultiple: Int128 = 4
    static let minimumDropoutNanos: Int128 = 50_000_000
    static let maximumDropoutNanos: Int128 = 500_000_000

    /// A per-pulse period as an exact ratio of host ticks to pulses; `span` is positive.
    private struct Period: Sendable {
        let span: UInt64
        let intervals: Int
    }

    let timebase: HostTimebase
    /// W: the pulse intervals the window spans once full.
    let windowIntervals: Int
    let maximumLagPulses: Int
    private(set) var lock = MIDIClockLock.unlocked
    private(set) var lastPulse: HostStamp?
    private var stamps: [UInt64]
    private var head = 0
    private var count = 0
    private(set) var consecutiveOutliers = 0
    private var hasLocked = false
    private var reference: Period?
    private var reported: Period?

    /// `maximumLagPulses` is limited to 1...2: a lag of L pulses can stretch one arriving gap to (L + 1)
    /// periods, which must stay below the 4x dropout bound, so L >= 3 would report false dropouts.
    /// `windowIntervals` >= 6 keeps n - L >= 4 for every window period and W >= 2L, which the gate and
    /// outlier band need to admit any lag up to L.
    init(timebase: HostTimebase, windowIntervals: Int = defaultWindowIntervals,
         maximumLagPulses: Int = defaultMaximumLagPulses) throws(MIDIClockError) {
        guard timebase.numer > 0, timebase.denom > 0 else { throw .invalidTimebase }
        guard Self.windowIntervalRange.contains(windowIntervals) else { throw .invalidWindow(windowIntervals) }
        guard Self.maximumLagPulsesRange.contains(maximumLagPulses) else { throw .invalidLag(maximumLagPulses) }
        self.timebase = timebase
        self.windowIntervals = windowIntervals
        self.maximumLagPulses = maximumLagPulses
        stamps = Array(repeating: 0, count: windowIntervals + 1)
    }

    /// The ring's storage size (W + 1 timestamps), fixed at init.
    var windowCapacity: Int { stamps.count }

    /// The last gate-passing, non-outlier window tempo, only while locked.
    var estimate: MIDIClockTempoEstimate? {
        guard lock == .locked, let reported else { return nil }
        let numerator = Int128(reported.span) * Int128(timebase.numer) * Int128(MIDIClockMath.pulsesPerQuarter)
        let denominator = Int128(reported.intervals) * Int128(timebase.denom) * 1_000
        let micros = ExactMath.roundHalfUp(numerator, denominator)
        let range = MIDIClockMath.microsPerQuarterRange
        let clampedMicros = min(max(micros, Int128(range.lowerBound)), Int128(range.upperBound))
        return MIDIClockTempoEstimate(microsPerQuarter: Int64(clampedMicros), clamped: clampedMicros != micros)
    }

    /// Records one clock pulse at `host`. Equal host times are ordinary pulses; decreasing ones throw.
    mutating func observePulse(at host: HostStamp) throws(MIDIClockError) -> MIDIClockLockEvent? {
        guard let lastPulse else {
            self.lastPulse = host
            restart(at: host.ticks)
            return nil
        }
        guard host.ticks >= lastPulse.ticks else {
            throw .nonMonotonicHost(previous: lastPulse.ticks, current: host.ticks)
        }
        let wasLocked = lock == .locked
        self.lastPulse = host
        if lock == .lost || isDropout(gap: host.ticks - lastPulse.ticks) {
            restart(at: host.ticks)
            return wasLocked ? .lost(lastPulse: lastPulse) : nil
        }
        append(host.ticks)
        return wasLocked ? track(previous: lastPulse) : acquire()
    }

    /// Reports a dropout when no pulse arrived within the same bound an arriving gap uses.
    mutating func poll(now: HostStamp) throws(MIDIClockError) -> MIDIClockLockEvent? {
        guard let lastPulse, lock != .lost else { return nil }
        guard now.ticks >= lastPulse.ticks else {
            throw .nonMonotonicHost(previous: lastPulse.ticks, current: now.ticks)
        }
        guard isDropout(gap: now.ticks - lastPulse.ticks) else { return nil }
        let wasLocked = lock == .locked
        clearWindow()
        lock = .lost
        return wasLocked ? .lost(lastPulse: lastPulse) : nil
    }

    /// Whether `gap` host ticks exceed the shared arrival and `poll` timeout.
    func isDropout(gap: UInt64) -> Bool {
        Int128(gap) > dropoutTicks
    }

    /// The timeout in host ticks: 4x the lag-tolerant period bound T / (n - L) of the window's n intervals
    /// spanning T, clamped to 50...500 ms and rounded up (the 500 ms ceiling without a window period).
    private var dropoutTicks: Int128 {
        let numer = Int128(timebase.numer)
        let denom = Int128(timebase.denom)
        guard let mean = windowPeriod else { return ExactMath.ceilDiv(Self.maximumDropoutNanos * denom, numer) }
        let lagFree = Int128(mean.intervals - maximumLagPulses)
        let scale = lagFree * denom
        let lower = Self.minimumDropoutNanos * scale
        let upper = Self.maximumDropoutNanos * scale
        let threshold = min(max(Self.dropoutMeanMultiple * Int128(mean.span) * numer, lower), upper)
        return ExactMath.ceilDiv(threshold, lagFree * numer)
    }

    private mutating func acquire() -> MIDIClockLockEvent? {
        lock = .acquiring(goodIntervals: count - 1)
        guard let period = consistentWindowPeriod else { return nil }
        lock = .locked
        reference = period
        reported = period
        consecutiveOutliers = 0
        guard let estimate else { return nil }
        defer { hasLocked = true }
        return hasLocked ? .reacquired(estimate) : .acquired(estimate)
    }

    private mutating func track(previous: HostStamp) -> MIDIClockLockEvent? {
        guard let period = consistentWindowPeriod, let reference else { return nil }
        guard isOutlier(period, against: reference) else {
            consecutiveOutliers = 0
            reported = period
            self.reference = period
            return nil
        }
        consecutiveOutliers += 1
        guard consecutiveOutliers >= Self.maximumConsecutiveOutliers else { return nil }
        consecutiveOutliers = 0
        self.reference = nil
        reported = nil
        lock = .acquiring(goodIntervals: count - 1)
        return .lost(lastPulse: previous)
    }

    /// The window's per-pulse period once it spans the minimum intervals with a positive span.
    private var windowPeriod: Period? {
        guard count - 1 >= Self.minimumEstimateIntervals else { return nil }
        return period(from: 0, to: count - 1)
    }

    /// The full window's period when its halves' per-pulse periods differ by at most L (1 / n1 + 1 / n2) of it:
    /// |s1 / n1 - s2 / n2| <= L * S / (n1 * n2), cross-multiplied into exact integers.
    private var consistentWindowPeriod: Period? {
        guard count - 1 == windowIntervals, let whole = period(from: 0, to: windowIntervals) else { return nil }
        let middle = windowIntervals / 2
        let older = Int128(middle)
        let newer = Int128(windowIntervals - middle)
        let olderSpan = Int128(stamp(middle) - stamp(0))
        let newerSpan = Int128(stamp(windowIntervals) - stamp(middle))
        let difference = abs(olderSpan * newer - newerSpan * older)
        return difference <= Int128(maximumLagPulses) * Int128(whole.span) ? whole : nil
    }

    private func period(from first: Int, to last: Int) -> Period? {
        let span = stamp(last) - stamp(first)
        guard span > 0 else { return nil }
        return Period(span: span, intervals: last - first)
    }

    /// Beyond 4L / W of the per-pulse `reference` (the gate tolerance for even W). Lagged estimates differ
    /// by at most 2L / (W - L) of each other, within the band whenever W >= 2L.
    private func isOutlier(_ period: Period, against reference: Period) -> Bool {
        let difference = abs(Int128(period.span) * Int128(reference.intervals)
            - Int128(reference.span) * Int128(period.intervals))
        let tolerance = 4 * Int128(maximumLagPulses) * Int128(reference.span) * Int128(period.intervals)
        return difference * Int128(windowIntervals) > tolerance
    }

    private func stamp(_ offset: Int) -> UInt64 {
        stamps[(head + offset) % stamps.count]
    }

    private mutating func restart(at ticks: UInt64) {
        clearWindow()
        append(ticks)
        lock = .acquiring(goodIntervals: 0)
    }

    private mutating func clearWindow() {
        head = 0
        count = 0
        consecutiveOutliers = 0
        reference = nil
        reported = nil
    }

    private mutating func append(_ ticks: UInt64) {
        if count == stamps.count {
            head = (head + 1) % stamps.count
        } else {
            count += 1
        }
        stamps[(head + count - 1) % stamps.count] = ticks
    }
}
