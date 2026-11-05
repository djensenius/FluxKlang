import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct MIDIClockTempoEstimatorTests {
    static let nanos = HostTimebase(numer: 1, denom: 1)
    static let period: UInt64 = 20_000_000
    static let trueTempo = MIDIClockTempoEstimate(microsPerQuarter: 480_000, clamped: false)

    /// Observes one pulse at `start` and one after each interval; returns the non-nil events.
    @discardableResult
    private static func pulse(_ estimator: inout MIDIClockTempoEstimator, from start: UInt64 = 0,
                              intervals: [UInt64], estimates: inout [Int64]) throws -> [MIDIClockLockEvent] {
        var events: [MIDIClockLockEvent] = []
        var host = start
        if estimator.lastPulse == nil { _ = try estimator.observePulse(at: HostStamp(ticks: host)) } else {
            host = try #require(estimator.lastPulse).ticks
        }
        for interval in intervals {
            host += interval
            if let event = try estimator.observePulse(at: HostStamp(ticks: host)) { events.append(event) }
            if let estimate = estimator.estimate { estimates.append(estimate.microsPerQuarter) }
        }
        return events
    }

    @discardableResult
    private static func pulse(_ estimator: inout MIDIClockTempoEstimator, from start: UInt64 = 0,
                              intervals: [UInt64]) throws -> [MIDIClockLockEvent] {
        var ignored: [Int64] = []
        return try pulse(&estimator, from: start, intervals: intervals, estimates: &ignored)
    }

    private static func locked(at interval: UInt64) throws -> MIDIClockTempoEstimator {
        var estimator = try MIDIClockTempoEstimator(timebase: nanos)
        try pulse(&estimator, intervals: Array(repeating: interval, count: 24))
        return estimator
    }

    private static func window(sum: UInt64, base: UInt64) -> [UInt64] {
        Array(repeating: base, count: 23) + [sum - 23 * base]
    }

    private static func repeated(_ cycle: [UInt64], _ times: Int) -> [UInt64] {
        Array(Array(repeating: cycle, count: times).joined())
    }

    /// Late-delivery jitter: pulse `i` is due at `i * period` and stamped up to two periods late.
    private static func jittered(count: Int) -> [UInt64] {
        var state: UInt64 = 0x5EED
        var previous: UInt64 = 0
        var intervals: [UInt64] = []
        for index in 1...count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let stamp = max(previous, UInt64(index) * period + (state >> 33) % (2 * period + 1))
            intervals.append(stamp - previous)
            previous = stamp
        }
        return intervals
    }

    /// Pulse `i` stamped at `i * period + lag[i % 7]`, the lag pattern from the Copilot review of #327.
    private static func lagged(count: Int) -> [UInt64] {
        let lags: [UInt64] = [40_000_000, 20_000_000, 0, 0, 0, 0, 0]
        return (1..<count).map { index in
            UInt64(index) * period + lags[index % 7] - UInt64(index - 1) * period - lags[(index - 1) % 7]
        }
    }

    @Test
    func locksOnceTheWindowSpansItsIntervals() throws {
        var estimator = try MIDIClockTempoEstimator(timebase: Self.nanos)
        #expect(estimator.lock == .unlocked && estimator.windowCapacity == 25)
        #expect(try Self.pulse(&estimator, intervals: Array(repeating: 20_833_333, count: 23)).isEmpty)
        #expect(estimator.lock == .acquiring(goodIntervals: 23) && estimator.estimate == nil)
        let events = try Self.pulse(&estimator, intervals: [20_833_333])
        let tempo = MIDIClockTempoEstimate(microsPerQuarter: 500_000, clamped: false)
        #expect(events == [.acquired(tempo)] && events.first?.bumpReason == nil)
        #expect(estimator.lock == .locked && estimator.estimate == tempo)

        var short = try MIDIClockTempoEstimator(timebase: Self.nanos, windowIntervals: 6)
        #expect(try Self.pulse(&short, intervals: Array(repeating: Self.period, count: 5)).isEmpty)
        #expect(try Self.pulse(&short, intervals: [Self.period]) == [.acquired(Self.trueTempo)])
    }

    @Test
    func estimatesRoundHalfUpAndClampAtBothTempoEdges() throws {
        let cases: [(sum: UInt64, base: UInt64)] = [
            (59_999_500, 2_499_979), (59_999_499, 2_499_979), (3_000_000_499, 125_000_000), (3_000_000_500, 125_000_000)
        ]
        let edges: [(Int64, Bool)] = [(60_000, false), (60_000, true), (3_000_000, false), (3_000_000, true)]
        let expected = edges.map { MIDIClockTempoEstimate(microsPerQuarter: $0.0, clamped: $0.1) }
        for (item, tempo) in zip(cases, expected) {
            var estimator = try MIDIClockTempoEstimator(timebase: Self.nanos)
            try Self.pulse(&estimator, intervals: Self.window(sum: item.sum, base: item.base))
            #expect(estimator.estimate == tempo)
        }
        var silicon = try MIDIClockTempoEstimator(timebase: HostTimebase(numer: 125, denom: 3))
        try Self.pulse(&silicon, from: .max - 24 * 500_000, intervals: Array(repeating: 500_000, count: 24))
        #expect(silicon.estimate == MIDIClockTempoEstimate(microsPerQuarter: 500_000, clamped: false))
    }

    @Test
    func windowSlidesOverTheLastTwentyFourIntervals() throws {
        var estimator = try Self.locked(at: Self.period)
        try Self.pulse(&estimator, intervals: Array(repeating: 21_000_000, count: 12))
        #expect(estimator.estimate?.microsPerQuarter == 492_000)
        try Self.pulse(&estimator, intervals: Array(repeating: 21_000_000, count: 500))
        #expect(estimator.estimate?.microsPerQuarter == 504_000)
    }

    @Test
    func gatePassingEstimatesBeyondAThirdOfTheTrackingReferenceAreOutliers() throws {
        var fast = try Self.locked(at: Self.period)
        try Self.pulse(&fast, intervals: Array(repeating: 9_000_000, count: 20))
        #expect(fast.consecutiveOutliers == 0 && fast.estimate?.microsPerQuarter == 414_000)
        var edge = fast
        try Self.pulse(&edge, intervals: [36_000_000])
        #expect(edge.consecutiveOutliers == 0 && edge.estimate?.microsPerQuarter == 276_000)
        try Self.pulse(&fast, intervals: [35_999_999])
        #expect(fast.consecutiveOutliers == 1 && fast.estimate?.microsPerQuarter == 414_000)

        var slow = try Self.locked(at: Self.period)
        try Self.pulse(&slow, intervals: [Self.period] + Array(repeating: 38_000_000, count: 16))
        #expect(slow.consecutiveOutliers == 0 && slow.estimate?.microsPerQuarter == 570_000)
        edge = slow
        try Self.pulse(&edge, intervals: [12_000_000])
        #expect(edge.consecutiveOutliers == 0 && edge.estimate?.microsPerQuarter == 760_000)
        try Self.pulse(&slow, intervals: [12_000_001])
        #expect(slow.consecutiveOutliers == 1 && slow.estimate?.microsPerQuarter == 570_000)
    }

    @Test
    func acquisitionWaitsForHalvesWithinTheLagGate() throws {
        var estimator = try MIDIClockTempoEstimator(timebase: Self.nanos)
        let mixed = Array(repeating: UInt64(10_000_000), count: 12) + Array(repeating: 30_000_000, count: 18)
        #expect(try Self.pulse(&estimator, intervals: mixed).isEmpty)
        #expect(estimator.lock == .acquiring(goodIntervals: 24))
        let events = try Self.pulse(&estimator, intervals: [30_000_000])
        #expect(events == [.acquired(MIDIClockTempoEstimate(microsPerQuarter: 620_000, clamped: false))])

        // Halves of 20 and 28 ms differ by exactly 4L / W = 1/3 of the 24 ms window period.
        let halves = Array(repeating: Self.period, count: 12) + Array(repeating: 28_000_000, count: 11)
        var edge = try MIDIClockTempoEstimator(timebase: Self.nanos)
        let tempo = MIDIClockTempoEstimate(microsPerQuarter: 576_000, clamped: false)
        #expect(try Self.pulse(&edge, intervals: halves + [28_000_000]) == [.acquired(tempo)])
        var beyond = try MIDIClockTempoEstimator(timebase: Self.nanos)
        #expect(try Self.pulse(&beyond, intervals: halves + [28_000_001]).isEmpty)
        #expect(beyond.lock == .acquiring(goodIntervals: 24))
    }

    @Test
    func anAbruptTempoJumpIsReportedLostThenReacquired() throws {
        var estimator = try Self.locked(at: Self.period)
        // Six jump pulses pass the gate and move the reference to 414,000; the gate then holds.
        #expect(try Self.pulse(&estimator, intervals: Array(repeating: 9_000_000, count: 20)).isEmpty)
        #expect(estimator.consecutiveOutliers == 0 && estimator.estimate?.microsPerQuarter == 414_000)
        #expect(try Self.pulse(&estimator, intervals: Array(repeating: 9_000_000, count: 23)).isEmpty)
        #expect(estimator.consecutiveOutliers == 23 && estimator.estimate?.microsPerQuarter == 414_000)
        let last = try #require(estimator.lastPulse)
        let lost = try Self.pulse(&estimator, intervals: [9_000_000])
        #expect(lost == [.lost(lastPulse: last)] && lost.first?.bumpReason == .sourceLost)
        #expect(estimator.lock == .acquiring(goodIntervals: 24) && estimator.estimate == nil)
        let back = try Self.pulse(&estimator, intervals: [9_000_000])
        #expect(back == [.reacquired(MIDIClockTempoEstimate(microsPerQuarter: 216_000, clamped: false))])
        #expect(back.first?.bumpReason == .sourceReacquired)
    }

    @Test
    func aGoodEstimateBreaksTheOutlierRun() throws {
        var estimator = try Self.locked(at: Self.period)
        let run = Array(repeating: UInt64(8_000_000), count: 43)
        // 47 ms fails the gate and holds; 20 ms pulses hold until a window passes within the band.
        let back = [UInt64(47_000_000)] + Array(repeating: Self.period, count: 15)
        #expect(try Self.pulse(&estimator, intervals: run + back).isEmpty)
        #expect(estimator.consecutiveOutliers == 23 && estimator.estimate?.microsPerQuarter == 420_000)
        try Self.pulse(&estimator, intervals: [Self.period])
        #expect(estimator.consecutiveOutliers == 0 && estimator.estimate?.microsPerQuarter == 423_000)
        #expect(try Self.pulse(&estimator, intervals: run).isEmpty)
        #expect(estimator.consecutiveOutliers == 23 && estimator.lock == .locked)
        let last = try #require(estimator.lastPulse)
        #expect(try Self.pulse(&estimator, intervals: [8_000_000]) == [.lost(lastPulse: last)])
    }

    @Test
    func aOnePercentPerPulseRampIsTrackedWithoutLoss() throws {
        var intervals: [UInt64] = []
        var interval = Self.period
        while interval > 9_000_000 {
            interval = max(9_000_000, (interval * 99 + 50) / 100)
            intervals.append(interval)
        }
        intervals += Array(repeating: 9_000_000, count: 40)
        var estimator = try Self.locked(at: Self.period)
        var host = try #require(estimator.lastPulse).ticks
        var worst = 0.0
        for interval in intervals {
            host += interval
            #expect(try estimator.observePulse(at: HostStamp(ticks: host)) == nil)
            let estimate = try #require(estimator.estimate)
            let now = Double(interval) * 24 / 1_000
            worst = max(worst, abs(Double(estimate.microsPerQuarter) - now) / now)
        }
        // The 24-pulse window of a 1%-per-pulse ramp averages 12.4% above the newest period.
        #expect(worst <= 0.13 && estimator.estimate?.microsPerQuarter == 216_000)
        #expect(estimator.consecutiveOutliers == 0)
    }

    @Test
    func anIsolatedGlitchStaysLocked() throws {
        var estimator = try Self.locked(at: Self.period)
        var estimates: [Int64] = []
        let glitch = [UInt64(5_000_000), 35_000_000] + Array(repeating: Self.period, count: 30)
        #expect(try Self.pulse(&estimator, intervals: glitch, estimates: &estimates).isEmpty)
        #expect(estimates.allSatisfy { abs($0 - 480_000) <= 15_000 } && estimates.last == 480_000)
        #expect(estimator.consecutiveOutliers == 0)
    }

    @Test(arguments: [[UInt64(0), 40_000_000], [20_000_000, 20_000_000, 0, 40_000_000], [0, 0, 60_000_000],
                      [20_000_000, 40_000_000, 0, 20_000_000]])
    func batchedClocksLockAtTheTruePulseRate(cycle: [UInt64]) throws {
        let intervals = Self.repeated(cycle, 48)
        var fresh = try MIDIClockTempoEstimator(timebase: Self.nanos)
        var estimates: [Int64] = []
        #expect(try Self.pulse(&fresh, intervals: intervals, estimates: &estimates) == [.acquired(Self.trueTempo)])
        #expect(fresh.lock == .locked && estimates.allSatisfy { $0 == 480_000 })
        var running = try Self.locked(at: Self.period)
        estimates = []
        #expect(try Self.pulse(&running, intervals: intervals, estimates: &estimates).isEmpty)
        // Endpoints stamped up to two periods off move the per-pulse estimate by at most 2/24.
        #expect(estimates.allSatisfy { abs($0 - 480_000) <= 40_000 } && estimates.last == 480_000)
    }

    @Test
    func jitteredLateDeliveryStaysWithinTheEndpointBound() throws {
        let intervals = Self.jittered(count: 400)
        var fresh = try MIDIClockTempoEstimator(timebase: Self.nanos)
        var estimates: [Int64] = []
        let events = try Self.pulse(&fresh, intervals: intervals, estimates: &estimates)
        #expect(events.count == 1 && events.first?.bumpReason == nil && fresh.lock == .locked)
        // Lag of at most two periods over a 24-pulse window: within 2/24 of the true tempo.
        #expect(!estimates.isEmpty && estimates.allSatisfy { abs($0 - 480_000) <= 40_000 })
        var running = try Self.locked(at: Self.period)
        estimates = []
        #expect(try Self.pulse(&running, intervals: intervals, estimates: &estimates).isEmpty)
        #expect(estimates.allSatisfy { abs($0 - 480_000) <= 40_000 })
    }

    @Test
    func aBurstWithinTheBoundLocksAndOneBeyondItIsLostEverywhere() throws {
        var fresh = try MIDIClockTempoEstimator(timebase: Self.nanos)
        var estimates: [Int64] = []
        let burst = Array(repeating: UInt64(0), count: 23) + [24 * Self.period]
        // The gate holds while any burst pulse is in the window, then the window is exact.
        #expect(try Self.pulse(&fresh, intervals: burst + Array(repeating: Self.period, count: 23)).isEmpty)
        #expect(fresh.lock == .acquiring(goodIntervals: 24) && fresh.estimate == nil)
        let events = try Self.pulse(&fresh, intervals: Array(repeating: Self.period, count: 25), estimates: &estimates)
        #expect(events == [.acquired(Self.trueTempo)])
        #expect(estimates.count == 25 && estimates.allSatisfy { abs($0 - 480_000) <= 40_000 })

        var running = try Self.locked(at: Self.period)
        let last = try #require(running.lastPulse)
        for (gap, lost) in [(UInt64(87_272_728), false), (87_272_729, true), (24 * Self.period, true)] {
            var arriving = running
            var polled = running
            let expected: [MIDIClockLockEvent] = lost ? [.lost(lastPulse: last)] : []
            #expect(try Self.pulse(&arriving, intervals: [gap]) == expected)
            #expect(try polled.poll(now: HostStamp(ticks: last.ticks + gap)) == expected.first)
        }
        let after = try Self.pulse(&running, intervals: [24 * Self.period] + Array(repeating: 0, count: 23)
            + Array(repeating: Self.period, count: 48))
        #expect(after.count == 2 && after.last?.bumpReason == .sourceReacquired)
        #expect(running.estimate == Self.trueTempo)
    }

    @Test
    func aZeroSpanWindowHasNoEstimateAndNeverLocks() throws {
        var estimator = try MIDIClockTempoEstimator(timebase: Self.nanos)
        #expect(try Self.pulse(&estimator, from: 7, intervals: Array(repeating: 0, count: 40)).isEmpty)
        #expect(estimator.lock == .acquiring(goodIntervals: 24) && estimator.estimate == nil)
        #expect(!estimator.isDropout(gap: 500_000_000) && estimator.isDropout(gap: 500_000_001))
    }

    @Test
    func dropoutBoundIsFourMeansClampedToFiftyAndFiveHundredMilliseconds() throws {
        // 4 x T / (W - L) rounded up: 4 x 480 ms / 22 = 87.2727... ms for a clean 20 ms window.
        for (interval, threshold) in [(UInt64(2_500_000), UInt64(50_000_000)), (Self.period, 87_272_728),
                                      (130_000_000, 500_000_000)] {
            var estimator = try Self.locked(at: interval)
            let last = try #require(estimator.lastPulse)
            var arriving = estimator
            #expect(try Self.pulse(&arriving, intervals: [threshold]).isEmpty && arriving.lock == .locked)
            arriving = estimator
            #expect(try Self.pulse(&arriving, intervals: [threshold + 1]) == [.lost(lastPulse: last)])
            #expect(arriving.lock == .acquiring(goodIntervals: 0))
            #expect(try Self.pulse(&arriving, intervals: Array(repeating: interval, count: 23)).isEmpty)
            #expect(arriving.lock == .acquiring(goodIntervals: 23))
            #expect(try Self.pulse(&arriving, intervals: [interval]).first?.bumpReason == .sourceReacquired)
            #expect(try estimator.poll(now: HostStamp(ticks: last.ticks + threshold)) == nil)
            #expect(estimator.lock == .locked)
            #expect(try estimator.poll(now: HostStamp(ticks: last.ticks + threshold + 1)) == .lost(lastPulse: last))
            #expect(estimator.lock == .lost && estimator.estimate == nil)
            #expect(!estimator.isDropout(gap: 500_000_000) && estimator.isDropout(gap: 500_000_001))
            #expect(try estimator.poll(now: HostStamp(ticks: last.ticks + threshold * 2)) == nil)
            #expect(try Self.pulse(&estimator, intervals: [threshold * 3]).isEmpty)
            #expect(estimator.lock == .acquiring(goodIntervals: 0))
            #expect(try Self.pulse(&estimator, intervals: Array(repeating: interval, count: 23)).isEmpty)
            let events = try Self.pulse(&estimator, intervals: [interval])
            #expect(events.count == 1 && events.first?.bumpReason == .sourceReacquired)
        }
    }

    @Test
    func theWindowPeriodSetsTheDropoutBoundFromSixIntervals() throws {
        var estimator = try MIDIClockTempoEstimator(timebase: Self.nanos)
        try Self.pulse(&estimator, intervals: Array(repeating: Self.period, count: 5))
        #expect(!estimator.isDropout(gap: 500_000_000) && estimator.isDropout(gap: 500_000_001))
        try Self.pulse(&estimator, intervals: [Self.period])
        #expect(!estimator.isDropout(gap: 120_000_000) && estimator.isDropout(gap: 120_000_001))
    }

    @Test
    func anEmptyWindowWaitsFiveHundredMillisecondsAndAcquisitionLossIsQuiet() throws {
        var estimator = try MIDIClockTempoEstimator(timebase: Self.nanos)
        #expect(try estimator.poll(now: HostStamp(ticks: 1)) == nil)
        _ = try estimator.observePulse(at: HostStamp(ticks: 1_000))
        #expect(try estimator.poll(now: HostStamp(ticks: 500_001_000)) == nil)
        #expect(estimator.lock == .acquiring(goodIntervals: 0))
        #expect(try estimator.poll(now: HostStamp(ticks: 500_001_001)) == nil)
        #expect(estimator.lock == .lost)
        #expect(estimator.isDropout(gap: .max))
    }

    @Test
    func refusalsLeaveTheEstimatorUnchanged() throws {
        #expect(throws: MIDIClockError.invalidTimebase) {
            try MIDIClockTempoEstimator(timebase: HostTimebase(numer: 0, denom: 1))
        }
        #expect(throws: MIDIClockError.invalidTimebase) {
            try MIDIClockTempoEstimator(timebase: HostTimebase(numer: 1, denom: 0))
        }
        for window in [5, 97] {
            #expect(throws: MIDIClockError.invalidWindow(window)) {
                try MIDIClockTempoEstimator(timebase: Self.nanos, windowIntervals: window)
            }
        }
        #expect(try MIDIClockTempoEstimator(timebase: Self.nanos, windowIntervals: 96).windowCapacity == 97)
        // The dropout bound of 4 periods must exceed the (L + 1)-period gap a lag of L can produce.
        for lag in [0, 3] {
            #expect(throws: MIDIClockError.invalidLag(lag)) {
                try MIDIClockTempoEstimator(timebase: Self.nanos, maximumLagPulses: lag)
            }
        }
        for lag in [1, 2] {
            #expect(try MIDIClockTempoEstimator(timebase: Self.nanos, windowIntervals: 6, maximumLagPulses: lag)
                .maximumLagPulses == lag)
        }
        var estimator = try Self.locked(at: Self.period)
        let last = try #require(estimator.lastPulse)
        #expect(throws: MIDIClockError.nonMonotonicHost(previous: last.ticks, current: last.ticks - 1)) {
            try estimator.observePulse(at: HostStamp(ticks: last.ticks - 1))
        }
        #expect(throws: MIDIClockError.nonMonotonicHost(previous: last.ticks, current: last.ticks - 1)) {
            try estimator.poll(now: HostStamp(ticks: last.ticks - 1))
        }
        #expect(estimator.lock == .locked && estimator.lastPulse == last && estimator.estimate == Self.trueTempo)
        var extreme = try MIDIClockTempoEstimator(timebase: HostTimebase(numer: .max, denom: .max))
        try Self.pulse(&extreme, from: .max - 24 * Self.period, intervals: Array(repeating: Self.period, count: 24))
        #expect(extreme.estimate == Self.trueTempo)
        #expect(try extreme.poll(now: HostStamp(ticks: .max)) == nil)
        var slow = try MIDIClockTempoEstimator(timebase: HostTimebase(numer: .max, denom: 1))
        try Self.pulse(&slow, from: 0, intervals: [1, .max - 1])
        #expect(slow.lock == .acquiring(goodIntervals: 0))
    }

    @Test(arguments: [24, 6])
    func lagWithinTwoPulsesNeverTimesOut(window: Int) throws {
        var estimator = try MIDIClockTempoEstimator(timebase: Self.nanos, windowIntervals: window)
        var host: UInt64 = 40_000_000
        _ = try estimator.observePulse(at: HostStamp(ticks: host))
        var events: [MIDIClockLockEvent] = []
        var acquired = 0
        for interval in Self.lagged(count: 701) {
            #expect(try estimator.poll(now: HostStamp(ticks: host + interval)) == nil)
            host += interval
            if let event = try estimator.observePulse(at: HostStamp(ticks: host)) { events.append(event) }
            if case .acquiring(let good) = estimator.lock {
                #expect(good > acquired && events.isEmpty)
                acquired = good
            } else {
                #expect(estimator.lock == .locked)
            }
        }
        #expect(events.count == 1 && events.first?.bumpReason == nil && estimator.lock == .locked)
        // The window's upper period bound is at most (n + L) / (n - L) P, so a real silence is caught by then.
        let bound: UInt64 = window == 24 ? 94_545_456 : 160_000_001
        let last = try #require(estimator.lastPulse)
        var arriving = estimator
        #expect(try Self.pulse(&arriving, intervals: [bound]) == [.lost(lastPulse: last)])
        #expect(try estimator.poll(now: HostStamp(ticks: last.ticks + bound)) == .lost(lastPulse: last))
    }

    @Test
    func aSixIntervalWindowTimesOutAtFourUpperBoundPeriods() throws {
        var estimator = try MIDIClockTempoEstimator(timebase: Self.nanos, windowIntervals: 6)
        try Self.pulse(&estimator, intervals: Array(repeating: Self.period, count: 6))
        let last = try #require(estimator.lastPulse)
        // 4 x 120 ms / (6 - 2) = 120 ms.
        for (gap, lost) in [(UInt64(120_000_000), false), (120_000_001, true)] {
            var arriving = estimator
            var polled = estimator
            let expected: [MIDIClockLockEvent] = lost ? [.lost(lastPulse: last)] : []
            #expect(try Self.pulse(&arriving, intervals: [gap]) == expected)
            #expect(try polled.poll(now: HostStamp(ticks: last.ticks + gap)) == expected.first)
        }
    }

    @Test
    func anOddWindowGateAdmitsTheLagBoundAtUnequalHalves() throws {
        // W = 7, L = 1: the oldest and newest pulses each one period late; halves of 3 and 4 intervals.
        let gaps: [UInt64] = [0] + Array(repeating: Self.period, count: 5)
        var edge = try MIDIClockTempoEstimator(timebase: Self.nanos, windowIntervals: 7, maximumLagPulses: 1)
        #expect(try Self.pulse(&edge, from: Self.period, intervals: gaps + [40_000_000]) == [.acquired(Self.trueTempo)])
        var beyond = try MIDIClockTempoEstimator(timebase: Self.nanos, windowIntervals: 7, maximumLagPulses: 1)
        #expect(try Self.pulse(&beyond, from: Self.period, intervals: gaps + [40_000_001]).isEmpty)
        #expect(beyond.lock == .acquiring(goodIntervals: 7))
    }
}
