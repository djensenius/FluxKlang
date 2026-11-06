import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI clock leader dropout and reacquire")
struct MIDIClockArbitrationDropoutTests {
    private static let sourceA = MIDIInputID(1)
    private static let sourceB = MIDIInputID(2)
    private static let nanos = HostTimebase(numer: 1, denom: 1)
    /// 20 ms per pulse: 480,000 µs per quarter.
    private static let period: UInt64 = 20_000_000
    private static let timeout: UInt64 = 500_000_000

    private static func host(_ ticks: UInt64) -> HostStamp { HostStamp(ticks: ticks) }

    /// Sources A and B, leader A, 500 ms timeout and 10 % jitter tolerance.
    private static func arbiter(reacquire: Int = 4) throws -> MIDIClockLeaderArbiter {
        let policy = try MIDIClockArbitrationPolicy.make(maximumSources: 4, timeoutNanos: 500_000_000,
                                                         reacquirePulses: reacquire, jitterTolerancePerMille: 100)
        var arbiter = try MIDIClockLeaderArbiter(policy: policy, timebase: nanos)
        try arbiter.addSource(sourceA)
        try arbiter.addSource(sourceB)
        _ = try arbiter.selectLeader(.external(sourceA))
        return arbiter
    }

    /// Sends leader clocks at `first` and then after each interval in `intervals`; returns every event.
    @discardableResult
    private static func clocks(_ arbiter: inout MIDIClockLeaderArbiter, at first: UInt64, intervals: [UInt64],
                               from id: MIDIInputID = sourceA) throws -> [MIDIClockArbitrationEvent] {
        var now = first
        var events = try arbiter.receive(.clock, from: id, at: host(now))
        for interval in intervals {
            now += interval
            events += try arbiter.receive(.clock, from: id, at: host(now))
        }
        return events
    }

    private static func steady(_ count: Int) -> [UInt64] { Array(repeating: period, count: count) }

    /// Leader A started at 0 and locked by six clocks at 20 ms (N = 4: a seed, a reference and four steady).
    private static func lockedArbiter() throws -> MIDIClockLeaderArbiter {
        var arbiter = try arbiter()
        _ = try arbiter.receive(.start, from: sourceA, at: host(0))
        let events = try clocks(&arbiter, at: period, intervals: steady(5))
        #expect(events.last == .leaderLocked(sourceA, tempo: nil, reacquired: false))
        #expect(arbiter.status == .locked(sourceA, tempo: nil))
        return arbiter
    }

    @Test
    func theLeaderLocksAfterExactlyNSteadyPulsesAndNotBefore() throws {
        var arbiter = try Self.arbiter()
        // A seed, a reference interval, then N - 1 = 3 steady pulses: no lock.
        let early = try Self.clocks(&arbiter, at: 0, intervals: Self.steady(4))
        #expect(early.isEmpty)
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 3))
        let locked = try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(5 * Self.period))
        #expect(locked == [.leaderLocked(Self.sourceA, tempo: nil, reacquired: false)])
        #expect(locked.first?.bumpReason == .sourceReacquired)
        #expect(arbiter.status == .locked(Self.sourceA, tempo: nil) && !arbiter.status.isDegraded)
        let more = try Self.clocks(&arbiter, at: 6 * Self.period, intervals: Self.steady(10))
        #expect(more.isEmpty)
    }

    @Test(arguments: [2, 96])
    func theReacquireCountBoundaryHoldsAtNAndNPlusOne(_ reacquire: Int) throws {
        var arbiter = try Self.arbiter(reacquire: reacquire)
        let early = try Self.clocks(&arbiter, at: 0, intervals: Self.steady(reacquire))
        #expect(early.isEmpty)
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: reacquire - 1))
        let locked = try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(UInt64(reacquire + 1) * Self.period))
        #expect(locked.count == 1)
        guard case .leaderLocked(Self.sourceA, _, reacquired: false)? = locked.first else {
            Issue.record("expected a first lock, got \(locked)")
            return
        }
    }

    @Test
    func intervalsAtTheToleranceCountAndJustOutsideItResetTheCount() throws {
        // 10 % of 20 ms is 2 ms: 22 ms and 18 ms are steady.
        var atBound = try Self.arbiter()
        try Self.clocks(&atBound, at: 0, intervals: [Self.period, Self.period, 22_000_000])
        #expect(atBound.status == .acquiring(Self.sourceA, steadyPulses: 2))
        // 22 ms is now the reference: 19.8 ms is exactly 10 % of it below, and 21.78 ms 10 % above 19.8 ms.
        let lockedUp = try Self.clocks(&atBound, at: 62_000_000 + 19_800_000, intervals: [21_780_000])
        #expect(lockedUp == [.leaderLocked(Self.sourceA, tempo: nil, reacquired: false)])

        var fast = try Self.arbiter()
        try Self.clocks(&fast, at: 0, intervals: [Self.period, Self.period, 18_000_000])
        #expect(fast.status == .acquiring(Self.sourceA, steadyPulses: 2))

        var overLong = try Self.arbiter()
        try Self.clocks(&overLong, at: 0, intervals: [Self.period, Self.period, Self.period, 22_000_001])
        #expect(overLong.status == .acquiring(Self.sourceA, steadyPulses: 0))
        var overShort = try Self.arbiter()
        try Self.clocks(&overShort, at: 0, intervals: [Self.period, Self.period, Self.period, 17_999_999])
        #expect(overShort.status == .acquiring(Self.sourceA, steadyPulses: 0))
        // After a reset the jittered interval is the reference and N steady pulses are needed again.
        let jittered: UInt64 = 17_999_999
        let again = try Self.clocks(&overShort, at: 60_000_000 + 2 * jittered, intervals: [jittered, jittered])
        #expect(again.isEmpty && overShort.status == .acquiring(Self.sourceA, steadyPulses: 3))
        let locked = try Self.clocks(&overShort, at: 60_000_000 + 5 * jittered, intervals: [])
        #expect(locked == [.leaderLocked(Self.sourceA, tempo: nil, reacquired: false)])
    }

    @Test
    func pulsesSharingAHostTimeRestartTheCount() throws {
        var arbiter = try Self.arbiter()
        try Self.clocks(&arbiter, at: 0, intervals: Self.steady(3) + [0])
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 0))
        // The next positive interval only seeds the reference again; the one after it is steady.
        try Self.clocks(&arbiter, at: 4 * Self.period, intervals: [])
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 0))
        try Self.clocks(&arbiter, at: 5 * Self.period, intervals: [])
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 1))
        // Repeated shared host times never count as steady, even against each other.
        try Self.clocks(&arbiter, at: 6 * Self.period, intervals: [0, 0])
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 0))
    }

    @Test
    func aGapLongerThanTheTimeoutLosesTheLeaderExactlyOnceAndNeverSwitches() throws {
        var arbiter = try Self.lockedArbiter()
        let last = 6 * Self.period
        let late = last + Self.timeout + 1
        let events = try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(late))
        let reason = MIDIClockDegradedReason.lateArrival(lastPulse: Self.host(last), detectedAt: Self.host(late))
        #expect(events == [.leaderLost(Self.sourceA, reason: reason, heldTempo: nil),
                           .transport(.pulse(ticks: 3_840, host: Self.host(late), located: false))])
        #expect(events.first?.bumpReason == .sourceLost)
        #expect(arbiter.status == .degraded(Self.sourceA, reason: reason, heldTempo: nil, steadyPulses: 0))
        #expect(arbiter.status.isDegraded && arbiter.leader == .external(Self.sourceA))
        // A steady competing source never takes over, and no second loss is reported.
        let competing = try Self.clocks(&arbiter, at: late, intervals: Self.steady(40), from: Self.sourceB)
        #expect(competing == [.competingSource(Self.sourceB, .clock, .notLeader(selected: .external(Self.sourceA)))])
        #expect(try arbiter.poll(now: Self.host(late + 10 * Self.timeout)) == nil)
        #expect(arbiter.leader == .external(Self.sourceA) && arbiter.status.isDegraded)
    }

    @Test
    func aGapOfExactlyTheTimeoutIsNotALoss() throws {
        var arbiter = try Self.lockedArbiter()
        let last = 6 * Self.period
        #expect(try arbiter.poll(now: Self.host(last + Self.timeout)) == nil)
        let events = try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(last + Self.timeout))
        #expect(events == [.transport(.pulse(ticks: 3_840, host: Self.host(last + Self.timeout), located: false))])
        #expect(arbiter.status == .locked(Self.sourceA, tempo: nil))
    }

    @Test
    func pollReportsSilenceOnceAndTheLatePulseDoesNotRepeatIt() throws {
        var arbiter = try Self.lockedArbiter()
        let last = 6 * Self.period
        let detected = last + Self.timeout + 1
        let lost = try arbiter.poll(now: Self.host(detected))
        let reason = MIDIClockDegradedReason.silence(lastPulse: Self.host(last), detectedAt: Self.host(detected))
        #expect(lost == .leaderLost(Self.sourceA, reason: reason, heldTempo: nil))
        #expect(try arbiter.poll(now: Self.host(detected)) == nil)
        #expect(try arbiter.poll(now: Self.host(detected + 3 * Self.timeout)) == nil)
        let late = try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(detected + 4 * Self.timeout))
        #expect(late == [.transport(.pulse(ticks: 3_840, host: Self.host(detected + 4 * Self.timeout),
                                           located: false))])
        #expect(arbiter.status == .degraded(Self.sourceA, reason: reason, heldTempo: nil, steadyPulses: 0))
    }

    @Test
    func reacquiringNeedsNSteadyPulsesAndReportsTheRelock() throws {
        var arbiter = try Self.lockedArbiter()
        let start = 6 * Self.period + Self.timeout + 1
        let lostEvents = try Self.clocks(&arbiter, at: start, intervals: Self.steady(4))
        #expect(lostEvents.filter { if case .leaderLost = $0 { true } else { false } }.count == 1)
        guard case let .degraded(_, reason, _, steadyPulses) = arbiter.status else {
            Issue.record("expected degraded, got \(arbiter.status)")
            return
        }
        #expect(steadyPulses == 3)
        let relock = try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(start + 5 * Self.period))
        #expect(relock.last == .leaderLocked(Self.sourceA, tempo: nil, reacquired: true))
        #expect(relock.last?.bumpReason == .sourceReacquired)
        #expect(reason == .lateArrival(lastPulse: Self.host(6 * Self.period), detectedAt: Self.host(start)))
        #expect(arbiter.status == .locked(Self.sourceA, tempo: nil))
    }

    @Test
    func theLastTempoIsHeldWhileDegradedAndReplacedOnRelock() throws {
        var arbiter = try Self.arbiter(reacquire: 24)
        let tempo = MIDIClockTempoEstimate(microsPerQuarter: 480_000, clamped: false)
        let locked = try Self.clocks(&arbiter, at: 0, intervals: Self.steady(25))
        #expect(locked == [.leaderLocked(Self.sourceA, tempo: tempo, reacquired: false)])
        #expect(arbiter.status == .locked(Self.sourceA, tempo: tempo))
        let last = 25 * Self.period
        let lost = try arbiter.poll(now: Self.host(last + Self.timeout + 1))
        let reason = MIDIClockDegradedReason.silence(lastPulse: Self.host(last),
                                                     detectedAt: Self.host(last + Self.timeout + 1))
        #expect(lost == .leaderLost(Self.sourceA, reason: reason, heldTempo: tempo))
        // Slower pulses while reacquiring leave the held tempo alone.
        let slower: UInt64 = 25_000_000
        let restart = last + 2 * Self.timeout
        try Self.clocks(&arbiter, at: restart, intervals: Array(repeating: slower, count: 24))
        #expect(arbiter.status == .degraded(Self.sourceA, reason: reason, heldTempo: tempo, steadyPulses: 23))
        let relock = try Self.clocks(&arbiter, at: restart + 25 * slower, intervals: [])
        let newTempo = MIDIClockTempoEstimate(microsPerQuarter: 600_000, clamped: false)
        #expect(relock == [.leaderLocked(Self.sourceA, tempo: newTempo, reacquired: true)])
        #expect(arbiter.status == .locked(Self.sourceA, tempo: newTempo))
    }

    @Test
    func silenceWhileAcquiringRestartsTheCountWithoutAnEvent() throws {
        var arbiter = try Self.arbiter()
        try Self.clocks(&arbiter, at: 0, intervals: Self.steady(4))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 3))
        #expect(try arbiter.poll(now: Self.host(4 * Self.period + Self.timeout + 1)) == nil)
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 0))
        var gapped = try Self.arbiter()
        let events = try Self.clocks(&gapped, at: 0, intervals: Self.steady(4) + [Self.timeout + 1] + Self.steady(1))
        #expect(events.isEmpty && gapped.status == .acquiring(Self.sourceA, steadyPulses: 0))
    }

    @Test
    func pollRefusesTimeGoingBackAndLeavesTheStateUnchanged() throws {
        var arbiter = try Self.lockedArbiter()
        _ = try arbiter.poll(now: Self.host(7 * Self.period))
        let status = arbiter.status
        let sources = arbiter.sources
        #expect(throws: MIDIClockArbitrationError.nonMonotonicPoll(previous: 7 * Self.period,
                                                                      current: 7 * Self.period - 1)) {
            try arbiter.poll(now: Self.host(7 * Self.period - 1))
        }
        _ = try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(9 * Self.period))
        let afterPulse = arbiter.status
        #expect(throws: MIDIClockArbitrationError.nonMonotonicPoll(previous: 9 * Self.period,
                                                                      current: 8 * Self.period)) {
            try arbiter.poll(now: Self.host(8 * Self.period))
        }
        #expect(status == .locked(Self.sourceA, tempo: nil) && afterPulse == status)
        #expect(arbiter.sources != sources && arbiter.status == afterPulse)
        #expect(try arbiter.poll(now: Self.host(9 * Self.period)) == nil)
    }

    @Test
    func aLockedLeadersTempoFollowsTheEstimator() throws {
        var arbiter = try Self.arbiter(reacquire: 24)
        try Self.clocks(&arbiter, at: 0, intervals: Self.steady(25))
        #expect(arbiter.status == .locked(Self.sourceA, tempo: MIDIClockTempoEstimate(microsPerQuarter: 480_000,
                                                                                      clamped: false)))
        // A 5 % slower window: 21 ms per pulse is 504,000 µs per quarter.
        let slower: UInt64 = 21_000_000
        let ramp = try Self.clocks(&arbiter, at: 25 * Self.period + slower, intervals: Array(repeating: slower,
                                                                                           count: 23))
        #expect(ramp.isEmpty)
        #expect(arbiter.status == .locked(Self.sourceA, tempo: MIDIClockTempoEstimate(microsPerQuarter: 504_000,
                                                                                      clamped: false)))
    }

    @Test
    func aNewLeaderStartsWithoutTheOldLeadersLockTempoOrTiming() throws {
        var arbiter = try Self.arbiter()
        try Self.clocks(&arbiter, at: 0, intervals: Self.steady(25))
        let tempo = MIDIClockTempoEstimate(microsPerQuarter: 480_000, clamped: false)
        #expect(arbiter.status == .locked(Self.sourceA, tempo: tempo))
        _ = try arbiter.selectLeader(.external(Self.sourceB))
        #expect(arbiter.status == .acquiring(Self.sourceB, steadyPulses: 0))
        // B's stamps may precede A's last one: B has its own steady run and tempo estimator, and no tempo yet.
        let events = try Self.clocks(&arbiter, at: Self.period, intervals: Array(repeating: 25_000_000, count: 5),
                                     from: Self.sourceB)
        #expect(events == [.leaderLocked(Self.sourceB, tempo: nil, reacquired: false)])
        #expect(arbiter.status == .locked(Self.sourceB, tempo: nil))
    }

    @Test
    func aDegradedLeaderIsReplacedOnlyByAnExplicitSelection() throws {
        var arbiter = try Self.lockedArbiter()
        _ = try arbiter.poll(now: Self.host(6 * Self.period + Self.timeout + 1))
        #expect(arbiter.status.isDegraded)
        let change = try arbiter.selectLeader(.external(Self.sourceB))
        #expect(change.previous == .external(Self.sourceA) && change.selected == .external(Self.sourceB))
        #expect(arbiter.status == .acquiring(Self.sourceB, steadyPulses: 0) && !arbiter.status.isDegraded)
        #expect(try arbiter.poll(now: Self.host(10 * Self.timeout)) == nil)
    }
}
