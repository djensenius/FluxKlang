import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI clock leader steady pulses")
struct MIDIClockArbitrationSteadyRunTests {
    private static let sourceA = MIDIInputID(1)
    private static let sourceB = MIDIInputID(2)
    private static let nanos = HostTimebase(numer: 1, denom: 1)
    /// 20 ms per pulse: 480,000 µs per quarter.
    private static let period: UInt64 = 20_000_000
    private static let tempo = MIDIClockTempoEstimate(microsPerQuarter: 480_000, clamped: false)

    private static func host(_ ticks: UInt64) -> HostStamp { HostStamp(ticks: ticks) }

    /// Sources A and B, leader A, 500 ms timeout; `tolerance` is the jitter beyond the lag bound.
    private static func arbiter(reacquire: Int = 4, tolerance: Int = 100,
                                timebase: HostTimebase = nanos) throws -> MIDIClockLeaderArbiter {
        let policy = try MIDIClockArbitrationPolicy.make(maximumSources: 4, timeoutNanos: 500_000_000,
                                                         reacquirePulses: reacquire,
                                                         jitterTolerancePerMille: tolerance)
        var arbiter = try MIDIClockLeaderArbiter(policy: policy, timebase: timebase)
        try arbiter.addSource(sourceA)
        try arbiter.addSource(sourceB)
        _ = try arbiter.selectLeader(.external(sourceA))
        return arbiter
    }

    /// Sends one leader clock at each stamp; returns every event.
    @discardableResult
    private static func clocks(_ arbiter: inout MIDIClockLeaderArbiter,
                               at stamps: [UInt64]) throws -> [MIDIClockArbitrationEvent] {
        var events: [MIDIClockArbitrationEvent] = []
        for stamp in stamps { events += try arbiter.receive(.clock, from: sourceA, at: host(stamp)) }
        return events
    }

    /// `count` stamps one `interval` apart from `start`.
    private static func evenly(_ count: Int, from start: UInt64 = 0, every interval: UInt64 = period) -> [UInt64] {
        (0..<count).map { start + UInt64($0) * interval }
    }

    private static func locks(_ events: [MIDIClockArbitrationEvent]) -> [MIDIClockArbitrationEvent] {
        events.filter { if case .leaderLocked = $0 { true } else { false } }
    }

    @Test
    func theLeaderLocksAfterExactlyNSteadyPulsesAndNotBefore() throws {
        var arbiter = try Self.arbiter()
        // The anchor, the pulse that seeds the reference, then N - 1 = 3 steady pulses: no lock.
        let early = try Self.clocks(&arbiter, at: Self.evenly(5))
        #expect(early.isEmpty)
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 3))
        let locked = try Self.clocks(&arbiter, at: [5 * Self.period])
        #expect(locked == [.leaderLocked(Self.sourceA, tempo: nil, after: .selection)])
        #expect(locked.first?.bumpReason == .sourceReacquired)
        #expect(arbiter.status == .locked(Self.sourceA, tempo: nil) && !arbiter.status.isDegraded)
        // Once locked, pulses far outside the band never unlock it.
        let jittered = Self.evenly(10, from: 6 * Self.period) + [16 * Self.period + 70_000_000,
                                                                 16 * Self.period + 70_000_000]
        let more = try Self.clocks(&arbiter, at: jittered)
        #expect(more.isEmpty && arbiter.status == .locked(Self.sourceA, tempo: nil))
    }

    @Test(arguments: [2, 96])
    func lockNeedsNSteadyPulsesAndNotNMinusOne(_ reacquire: Int) throws {
        var arbiter = try Self.arbiter(reacquire: reacquire)
        let early = try Self.clocks(&arbiter, at: Self.evenly(reacquire + 1))
        #expect(Self.locks(early).isEmpty)
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: reacquire - 1))
        let locked = try Self.clocks(&arbiter, at: [UInt64(reacquire + 1) * Self.period])
        // N = 96 outlasts the estimator's 24-interval window, so its tempo is ready by the lock.
        let tempo = reacquire > 24 ? Self.tempo : nil
        #expect(locked == [.leaderLocked(Self.sourceA, tempo: tempo, after: .selection)])
    }

    @Test
    func aPulseWithinTheLagAndJitterBandOfItsDueTimeIsSteady() throws {
        // L = 2 pulses plus 10 % of the 20 ms reference: a pulse may land up to 42 ms from its due time.
        var late = try Self.arbiter()
        try Self.clocks(&late, at: [0, Self.period, 2 * Self.period + 42_000_000])
        #expect(late.status == .acquiring(Self.sourceA, steadyPulses: 1))
        // Pulses 2 to 5 share 58 ms; pulse 5 is due at 100 ms, 42 ms later, and is still steady.
        var early = try Self.arbiter()
        let lockedEarly = try Self.clocks(&early, at: [0, Self.period] + Array(repeating: 58_000_000, count: 4))
        #expect(lockedEarly == [.leaderLocked(Self.sourceA, tempo: nil, after: .selection)])
    }

    @Test
    func aPulseBeyondTheBandResetsTheCountAndTheReference() throws {
        var late = try Self.arbiter()
        let lateStamp = 2 * Self.period + 42_000_001
        try Self.clocks(&late, at: [0, Self.period, lateStamp])
        #expect(late.status == .acquiring(Self.sourceA, steadyPulses: 0))
        // The late pulse anchors a new run: the next pulse seeds the reference and N more are needed.
        let again = try Self.clocks(&late, at: Self.evenly(4, from: lateStamp + Self.period))
        #expect(again.isEmpty && late.status == .acquiring(Self.sourceA, steadyPulses: 3))
        let locked = try Self.clocks(&late, at: [lateStamp + 5 * Self.period])
        #expect(locked == [.leaderLocked(Self.sourceA, tempo: nil, after: .selection)])

        var early = try Self.arbiter()
        try Self.clocks(&early, at: [0, Self.period] + Array(repeating: 57_999_999, count: 4))
        #expect(early.status == .acquiring(Self.sourceA, steadyPulses: 0))
    }

    @Test
    func oneLatePulseDoesNotResetTheSteadyCount() throws {
        // 3 ms late is 15 % of the 20 ms period: more than 10 % off the previous interval, well inside the band.
        var arbiter = try Self.arbiter(reacquire: 24)
        try Self.clocks(&arbiter, at: Self.evenly(21))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 19))
        try Self.clocks(&arbiter, at: [21 * Self.period + 3_000_000])
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 20))
        try Self.clocks(&arbiter, at: [22 * Self.period])
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 21))
    }

    @Test
    func pairedDeliveryLocksAtTheEstimatorsTempo() throws {
        // Two clocks per host time every 40 ms: 400 pulses at 480,000 µs per quarter.
        var arbiter = try Self.arbiter(reacquire: 24)
        let events = try Self.clocks(&arbiter, at: (0..<400).map { UInt64($0 / 2) * 2 * Self.period })
        #expect(Self.locks(events) == [.leaderLocked(Self.sourceA, tempo: Self.tempo, after: .selection)])
        #expect(events.contains(.leaderTempo(Self.sourceA, .acquired(Self.tempo))))
        #expect(arbiter.status == .locked(Self.sourceA, tempo: Self.tempo))
    }

    @Test
    func batchedDeliveryAtTwentyBPMIsNotALossUnderTheStandardTimeout() throws {
        // 20 BPM is 125 ms per pulse. Triplets every 375 ms exercise the maximum (L + 1) * P gap for L = 2.
        // The standard 500 ms timeout covers it; a 200 ms timeout reads the same gap as a loss.
        let batches = (0..<60).map { UInt64($0 / 3) * 375_000_000 }
        let gaps = zip(batches, batches.dropFirst()).map { $1 - $0 }
        #expect(gaps.max() == 375_000_000)
        var standard = try MIDIClockLeaderArbiter(policy: .standard, timebase: Self.nanos)
        try standard.addSource(Self.sourceA)
        _ = try standard.selectLeader(.external(Self.sourceA))
        _ = try standard.receive(.start, from: Self.sourceA, at: Self.host(0))
        let events = try Self.clocks(&standard, at: batches)
        let slowest = MIDIClockTempoEstimate(microsPerQuarter: 3_000_000, clamped: false)
        #expect(events.filter { $0.bumpReason == .sourceLost }.isEmpty)
        #expect(Self.locks(events) == [.leaderLocked(Self.sourceA, tempo: slowest, after: .selection)])
        #expect(standard.status == .locked(Self.sourceA, tempo: slowest))
        let short = try MIDIClockArbitrationPolicy.make(maximumSources: 16, timeoutNanos: 200_000_000,
                                                        reacquirePulses: 24, jitterTolerancePerMille: 250)
        var tight = try MIDIClockLeaderArbiter(policy: short, timebase: Self.nanos)
        try tight.addSource(Self.sourceA)
        _ = try tight.selectLeader(.external(Self.sourceA))
        _ = try tight.receive(.start, from: Self.sourceA, at: Self.host(0))
        let tightEvents = try Self.clocks(&tight, at: Array(batches.prefix(6)))
        #expect(tightEvents.contains { if case .leaderLost = $0 { true } else { false } })
    }

    @Test
    func pulsesSharingAHostTimeCountByTheirSpanUpToTheLagBound() throws {
        // Three clocks per host time every 60 ms: two may lag the third by L = 2, so the run locks.
        var triples = try Self.arbiter()
        let tripled = try Self.clocks(&triples, at: (0..<9).map { UInt64($0 / 3) * 3 * Self.period })
        #expect(Self.locks(tripled) == [.leaderLocked(Self.sourceA, tempo: nil, after: .selection)])
        // Four per host time exceed the lag bound: no reference holds for N pulses.
        var quadruples = try Self.arbiter()
        let quadrupled = try Self.clocks(&quadruples, at: (0..<40).map { UInt64($0 / 4) * 4 * Self.period })
        #expect(Self.locks(quadrupled).isEmpty)
    }

    @Test
    func aBurstBeyondTheLagBoundCountsAsOnlyLPlusOnePulses() throws {
        // Five clocks on one host time: only L + 1 = 3 fit the lag bound, so the clock 60 ms later is pulse 3 and
        // seeds 20 ms. Counting all five would seed 12 ms, and the 140 ms pulse would land 32 ms late and reset.
        var arbiter = try Self.arbiter()
        try Self.clocks(&arbiter, at: Array(repeating: 0, count: 5) + Self.evenly(4, from: 3 * Self.period))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 3))
        let locked = try Self.clocks(&arbiter, at: [7 * Self.period])
        #expect(locked == [.leaderLocked(Self.sourceA, tempo: nil, after: .selection)])
    }

    @Test
    func aResetInsideASharedHostTimeKeepsTheEarlierPulsesInTheNewRun() throws {
        // Seeded at 30 ms, pairs every 40 ms land earlier each time: the second clock at 140 ms is 70 ms early
        // and resets. The new run counts its pair partner, so the next pair seeds 20 ms and N = 8 more lock it.
        var arbiter = try Self.arbiter(reacquire: 8)
        let pairs = (0..<15).map { 60_000_000 + UInt64($0 / 2) * 40_000_000 }
        try Self.clocks(&arbiter, at: [0, 30_000_000] + pairs.prefix(6))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 0))
        try Self.clocks(&arbiter, at: Array(pairs[6..<14]))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 7))
        let locked = try Self.clocks(&arbiter, at: [pairs[14]])
        #expect(locked == [.leaderLocked(Self.sourceA, tempo: nil, after: .selection)])
    }

    @Test
    func intervalsGrowingTwentyPercentPerPulseNeverLock() throws {
        // 1 ms growing 20 % per pulse to 8.9 ms: each interval is within 25 % of the one before, but the
        // pulses leave any reference's band within a few pulses.
        var arbiter = try Self.arbiter(reacquire: 8, tolerance: 250)
        var stamps: [UInt64] = [0]
        var now: UInt64 = 0
        var interval: UInt64 = 1_000_000
        for _ in 0..<13 {
            now += interval
            stamps.append(now)
            interval = interval * 6 / 5
        }
        #expect(stamps[13] - stamps[12] > 8_900_000)
        let events = try Self.clocks(&arbiter, at: stamps)
        #expect(Self.locks(events).isEmpty)
    }

    @Test
    func driftAccumulatingPastTheBandResetsTheRun() throws {
        // Seeded at 20 ms, 22 ms intervals drift 2 ms per pulse: pulse k lands 2 (k - 1) ms late, steady through
        // k = 22 (42 ms) and reset at k = 23, although every interval matches the one before it.
        var arbiter = try Self.arbiter(reacquire: 24)
        try Self.clocks(&arbiter, at: [0] + Self.evenly(22, from: Self.period, every: 22_000_000))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 21))
        try Self.clocks(&arbiter, at: [Self.period + 22 * 22_000_000])
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 0))
    }

    @Test(arguments: [HostTimebase(numer: 1, denom: 1), HostTimebase(numer: 125, denom: 3)])
    func aResetAfterTheEstimatorLocksSeedsTheReferenceFromItsPeriod(_ timebase: HostTimebase) throws {
        // A 21 ms first interval seeds a reference 5 % slow: 20 ms pulses drift 1 ms per pulse and reset it at
        // pulse 46, when the estimator holds exactly 480,000 µs per quarter. Its 20 ms period seeds the new
        // run, so the next pulse is already steady and N = 96 more lock it.
        func ticks(_ nanos: UInt64) -> UInt64 { nanos * UInt64(timebase.denom) / UInt64(timebase.numer) }
        var arbiter = try Self.arbiter(reacquire: 96, timebase: timebase)
        let first = ticks(1_000_000)
        let pulse = ticks(Self.period)
        try Self.clocks(&arbiter, at: [0] + Self.evenly(46, from: first + pulse, every: pulse))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 0))
        let reset = first + 46 * pulse
        try Self.clocks(&arbiter, at: Self.evenly(95, from: reset + pulse, every: pulse))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 95))
        let locked = try Self.clocks(&arbiter, at: [reset + 96 * pulse])
        #expect(locked == [.leaderLocked(Self.sourceA, tempo: Self.tempo, after: .selection)])
    }

    @Test
    func aClampedEstimateDoesNotSeedTheReference() throws {
        // The same drift at 1 ms per pulse: the estimator clamps 24,000 µs per quarter to 60,000 (2.5 ms per
        // pulse), which would reset every run. It seeds nothing, so the next interval seeds the new run.
        var arbiter = try Self.arbiter(reacquire: 96)
        let pulse: UInt64 = 1_000_000
        let first: UInt64 = 50_000
        let early = try Self.clocks(&arbiter, at: [0] + Self.evenly(46, from: first + pulse, every: pulse))
        let clamped = MIDIClockTempoEstimate(microsPerQuarter: 60_000, clamped: true)
        #expect(early.contains(.leaderTempo(Self.sourceA, .acquired(clamped))))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 0))
        let reset = first + 46 * pulse
        try Self.clocks(&arbiter, at: Self.evenly(96, from: reset + pulse, every: pulse))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 95))
        let locked = try Self.clocks(&arbiter, at: [reset + 97 * pulse])
        #expect(locked == [.leaderLocked(Self.sourceA, tempo: clamped, after: .selection)])
    }
}
