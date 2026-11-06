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
    private static let tempo = MIDIClockTempoEstimate(microsPerQuarter: 480_000, clamped: false)

    private static func host(_ ticks: UInt64) -> HostStamp { HostStamp(ticks: ticks) }

    /// Sources A and B, leader A, `timeout` (500 ms by default) and 10 % jitter tolerance.
    private static func arbiter(reacquire: Int = 4, timeout: Int64 = 500_000_000) throws -> MIDIClockLeaderArbiter {
        let policy = try MIDIClockArbitrationPolicy.make(maximumSources: 4, timeoutNanos: timeout,
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

    /// Every event but the transport's.
    private static func arbitration(_ events: [MIDIClockArbitrationEvent]) -> [MIDIClockArbitrationEvent] {
        events.filter { if case .transport = $0 { false } else { true } }
    }

    /// Leader A started at 0 and locked by six clocks at 20 ms (N = 4: an anchor, a seed and four steady).
    private static func lockedArbiter(timeout: Int64 = 500_000_000) throws -> MIDIClockLeaderArbiter {
        var arbiter = try arbiter(timeout: timeout)
        _ = try arbiter.receive(.start, from: sourceA, at: host(0))
        let events = try clocks(&arbiter, at: period, intervals: steady(5))
        #expect(arbitration(events) == [.leaderLocked(sourceA, tempo: nil, after: .selection)])
        #expect(arbiter.status == .locked(sourceA, tempo: nil))
        return arbiter
    }

    /// Leader A started at 0 with 26 clocks at 20 ms (to 500 ms): locked, and its estimator too.
    private static func trackedArbiter(timeout: Int64 = 500_000_000) throws -> MIDIClockLeaderArbiter {
        var arbiter = try arbiter(timeout: timeout)
        _ = try arbiter.receive(.start, from: sourceA, at: host(0))
        let events = try clocks(&arbiter, at: 0, intervals: steady(25))
        #expect(arbitration(events) == [.leaderLocked(sourceA, tempo: nil, after: .selection),
                                        .leaderTempo(sourceA, .acquired(tempo))])
        #expect(arbiter.status == .locked(sourceA, tempo: tempo))
        return arbiter
    }

    @Test
    func aGapLongerThanTheTimeoutLosesARunningLeaderExactlyOnceAndNeverSwitches() throws {
        var arbiter = try Self.lockedArbiter()
        let last = 6 * Self.period
        let late = last + Self.timeout + 1
        let events = try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(late))
        let reason = MIDIClockDegradedReason.lateArrival(lastMessage: Self.host(last), detectedAt: Self.host(late))
        #expect(events == [.leaderLost(Self.sourceA, reason: reason, heldTempo: nil),
                           .transport(.pulse(ticks: 3_840, host: Self.host(late), located: false))])
        #expect(events.first?.bumpReason == .sourceLost)
        #expect(arbiter.status == .degraded(Self.sourceA, reason: reason, heldTempo: nil, steadyPulses: 0))
        #expect(arbiter.status.isDegraded && arbiter.leader == .external(Self.sourceA))
        // A steady competing source never takes over, and no second loss is reported.
        let competing = try Self.clocks(&arbiter, at: late, intervals: Self.steady(40), from: Self.sourceB)
        #expect(competing == [.competingSource(Self.sourceB, .clock, .notLeader(selected: .external(Self.sourceA)))])
        #expect(try arbiter.poll(now: Self.host(late + 10 * Self.timeout)).isEmpty)
        #expect(arbiter.leader == .external(Self.sourceA) && arbiter.status.isDegraded)
    }

    @Test
    func aGapOfExactlyTheTimeoutIsNotALoss() throws {
        var arbiter = try Self.lockedArbiter()
        let last = 6 * Self.period
        #expect(try arbiter.poll(now: Self.host(last + Self.timeout)).isEmpty)
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
        let reason = MIDIClockDegradedReason.silence(lastMessage: Self.host(last), detectedAt: Self.host(detected))
        #expect(lost == [.leaderLost(Self.sourceA, reason: reason, heldTempo: nil)])
        #expect(try arbiter.poll(now: Self.host(detected)).isEmpty)
        #expect(try arbiter.poll(now: Self.host(detected + 3 * Self.timeout)).isEmpty)
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
        #expect(relock.last == .leaderLocked(Self.sourceA, tempo: nil, after: .loss))
        #expect(relock.last?.bumpReason == .sourceReacquired)
        #expect(reason == .lateArrival(lastMessage: Self.host(6 * Self.period), detectedAt: Self.host(start)))
        #expect(arbiter.status == .locked(Self.sourceA, tempo: nil))
    }

    @Test
    func theReportedTempoIsHeldWhileDegradedAndTheRelockReportsTheEstimators() throws {
        var arbiter = try Self.arbiter(reacquire: 24)
        _ = try arbiter.receive(.start, from: Self.sourceA, at: Self.host(0))
        let locked = Self.arbitration(try Self.clocks(&arbiter, at: 0, intervals: Self.steady(25)))
        #expect(locked == [.leaderTempo(Self.sourceA, .acquired(Self.tempo)),
                           .leaderLocked(Self.sourceA, tempo: Self.tempo, after: .selection)])
        let last = 25 * Self.period
        let detected = last + Self.timeout + 1
        let lost = try arbiter.poll(now: Self.host(detected))
        let reason = MIDIClockDegradedReason.silence(lastMessage: Self.host(last), detectedAt: Self.host(detected))
        // The estimator's own dropout comes first and never bumps; the arbiter's loss holds the reported tempo.
        #expect(lost == [.leaderTempo(Self.sourceA, .lost(lastPulse: Self.host(last))),
                         .leaderLost(Self.sourceA, reason: reason, heldTempo: Self.tempo)])
        #expect(lost.map(\.bumpReason) == [nil, .sourceLost])
        // Slower pulses while reacquiring leave the held tempo alone.
        let slower: UInt64 = 25_000_000
        let restart = last + 2 * Self.timeout
        try Self.clocks(&arbiter, at: restart, intervals: Array(repeating: slower, count: 24))
        #expect(arbiter.status == .degraded(Self.sourceA, reason: reason, heldTempo: Self.tempo, steadyPulses: 23))
        let relock = Self.arbitration(try Self.clocks(&arbiter, at: restart + 25 * slower, intervals: []))
        let newTempo = MIDIClockTempoEstimate(microsPerQuarter: 600_000, clamped: false)
        #expect(relock == [.leaderLocked(Self.sourceA, tempo: newTempo, after: .loss)])
        #expect(arbiter.status == .locked(Self.sourceA, tempo: newTempo))
    }

    @Test
    func aRelockAfterSilenceNeverReportsThePreLossTempo() throws {
        var arbiter = try Self.trackedArbiter()
        let last = 25 * Self.period
        let detected = last + Self.timeout + 1
        let reason = MIDIClockDegradedReason.silence(lastMessage: Self.host(last), detectedAt: Self.host(detected))
        #expect(try arbiter.poll(now: Self.host(detected)).last
                    == .leaderLost(Self.sourceA, reason: reason, heldTempo: Self.tempo))
        // Six pulses at 25 ms relock (N = 4) long before the estimator has a window: the tempo is pending.
        let relock = try Self.clocks(&arbiter, at: last + 2 * Self.timeout,
                                     intervals: Array(repeating: 25_000_000, count: 5))
        #expect(Self.arbitration(relock) == [.leaderLocked(Self.sourceA, tempo: nil, after: .loss)])
        #expect(arbiter.status == .locked(Self.sourceA, tempo: nil))
    }

    @Test
    func aSilenceShorterThanTheEstimatorsDropoutStillRestartsItsTempo() throws {
        // A 50 ms timeout loses the leader on a 60 ms gap, which the estimator's 87 ms dropout would keep.
        var arbiter = try Self.trackedArbiter(timeout: 50_000_000)
        let late = 25 * Self.period + 60_000_000
        let lost = try Self.clocks(&arbiter, at: late, intervals: Self.steady(4))
        let reason = MIDIClockDegradedReason.lateArrival(lastMessage: Self.host(25 * Self.period),
                                                         detectedAt: Self.host(late))
        #expect(Self.arbitration(lost) == [.leaderLost(Self.sourceA, reason: reason, heldTempo: Self.tempo)])
        let relock = try Self.clocks(&arbiter, at: late + 5 * Self.period, intervals: [])
        #expect(Self.arbitration(relock) == [.leaderLocked(Self.sourceA, tempo: nil, after: .loss)])
        #expect(arbiter.status == .locked(Self.sourceA, tempo: nil))
    }

    @Test
    func aGapThatDropsTheEstimatorMakesTheLockedTempoPending() throws {
        // 200 ms is under the 500 ms timeout but past the estimator's dropout: still locked, tempo pending.
        var arbiter = try Self.trackedArbiter()
        let last = 25 * Self.period
        let resume = last + 200_000_000
        let dropped = Self.arbitration(try Self.clocks(&arbiter, at: resume, intervals: Self.steady(4)))
        #expect(dropped == [.leaderTempo(Self.sourceA, .lost(lastPulse: Self.host(last)))])
        #expect(dropped.allSatisfy { $0.bumpReason == nil })
        #expect(arbiter.status == .locked(Self.sourceA, tempo: nil))
        // The status follows the estimator back once it re-acquires, 24 intervals after the gap.
        let back = try Self.clocks(&arbiter, at: resume + 5 * Self.period, intervals: Self.steady(19))
        #expect(Self.arbitration(back) == [.leaderTempo(Self.sourceA, .reacquired(Self.tempo))])
        #expect(arbiter.status == .locked(Self.sourceA, tempo: Self.tempo))
        // A poll inside the timeout forwards the estimator's dropout too.
        var polled = try Self.trackedArbiter()
        let dropout = try polled.poll(now: Self.host(last + 100_000_000))
        #expect(dropout == [.leaderTempo(Self.sourceA, .lost(lastPulse: Self.host(last)))])
        #expect(polled.status == .locked(Self.sourceA, tempo: nil))
    }

    @Test
    func anAcquiringLeaderSilentWhileRunningIsLost() throws {
        var arbiter = try Self.arbiter()
        _ = try arbiter.receive(.start, from: Self.sourceA, at: Self.host(0))
        try Self.clocks(&arbiter, at: Self.period, intervals: Self.steady(2))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 1))
        let detected = 3 * Self.period + Self.timeout + 1
        let reason = MIDIClockDegradedReason.silence(lastMessage: Self.host(3 * Self.period),
                                                     detectedAt: Self.host(detected))
        let lost = try arbiter.poll(now: Self.host(detected))
        #expect(lost == [.leaderLost(Self.sourceA, reason: reason, heldTempo: nil)])
        #expect(lost.first?.bumpReason == .sourceLost)
        #expect(arbiter.status == .degraded(Self.sourceA, reason: reason, heldTempo: nil, steadyPulses: 0))
        let relock = try Self.clocks(&arbiter, at: detected, intervals: Self.steady(5))
        #expect(Self.arbitration(relock) == [.leaderLocked(Self.sourceA, tempo: nil, after: .loss)])
        // Start alone arms the transport, so silence after it is a loss too.
        var armed = try Self.arbiter()
        _ = try armed.receive(.start, from: Self.sourceA, at: Self.host(0))
        let armedReason = MIDIClockDegradedReason.silence(lastMessage: Self.host(0),
                                                          detectedAt: Self.host(Self.timeout + 1))
        #expect(try armed.poll(now: Self.host(Self.timeout + 1))
                    == [.leaderLost(Self.sourceA, reason: armedReason, heldTempo: nil)])
    }

    @Test
    func aStoppedLeaderSilentPastTheTimeoutIsIdleAndBumpsNothing() throws {
        var arbiter = try Self.arbiter()
        _ = try arbiter.receive(.start, from: Self.sourceA, at: Self.host(0))
        try Self.clocks(&arbiter, at: Self.period, intervals: Self.steady(9))
        #expect(arbiter.status == .locked(Self.sourceA, tempo: nil))
        let stop = 11 * Self.period
        _ = try arbiter.receive(.stop, from: Self.sourceA, at: Self.host(stop))
        let detected = stop + 600_000_000
        let reason = MIDIClockDegradedReason.silence(lastMessage: Self.host(stop), detectedAt: Self.host(detected))
        let idle = try arbiter.poll(now: Self.host(detected))
        #expect(idle == [.leaderIdle(Self.sourceA, reason: reason)])
        #expect(idle.first?.bumpReason == nil)
        #expect(arbiter.status == .idle(Self.sourceA) && !arbiter.status.isDegraded)
        #expect(arbiter.status.leader == .external(Self.sourceA))
        #expect(try arbiter.poll(now: Self.host(detected)).isEmpty)
        // Clocks resume while stopped: a fresh run relocks with no bump.
        let first = try Self.clocks(&arbiter, at: detected, intervals: [])
        #expect(first.isEmpty && arbiter.status == .acquiring(Self.sourceA, steadyPulses: 0))
        let relock = try Self.clocks(&arbiter, at: detected + Self.period, intervals: Self.steady(4))
        #expect(relock == [.leaderLocked(Self.sourceA, tempo: nil, after: .idle)])
        #expect(relock.first?.bumpReason == nil)
        #expect(arbiter.status == .locked(Self.sourceA, tempo: nil))
    }

    @Test
    func aNeverStartedLeaderGoesIdleAndItsFirstLockStillBumps() throws {
        var arbiter = try Self.arbiter()
        try Self.clocks(&arbiter, at: 0, intervals: Self.steady(4))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 3))
        let detected = 4 * Self.period + Self.timeout + 1
        let reason = MIDIClockDegradedReason.silence(lastMessage: Self.host(4 * Self.period),
                                                     detectedAt: Self.host(detected))
        #expect(try arbiter.poll(now: Self.host(detected)) == [.leaderIdle(Self.sourceA, reason: reason)])
        #expect(arbiter.status == .idle(Self.sourceA))
        // It never locked, so its first lock still begins its source generation.
        let locked = try Self.clocks(&arbiter, at: detected, intervals: Self.steady(5))
        #expect(locked == [.leaderLocked(Self.sourceA, tempo: nil, after: .selection)])
        #expect(locked.first?.bumpReason == .sourceReacquired)
        // A late clock reports the idle on arrival and anchors the fresh run.
        var gapped = try Self.arbiter()
        let late = 4 * Self.period + Self.timeout + 1
        let events = try Self.clocks(&gapped, at: 0, intervals: Self.steady(4) + [Self.timeout + 1] + Self.steady(1))
        let lateReason = MIDIClockDegradedReason.lateArrival(lastMessage: Self.host(4 * Self.period),
                                                             detectedAt: Self.host(late))
        #expect(events == [.leaderIdle(Self.sourceA, reason: lateReason)])
        #expect(gapped.status == .acquiring(Self.sourceA, steadyPulses: 0))
    }

    @Test
    func eachLossEpisodeBumpsExactlyOnce() throws {
        var arbiter = try Self.lockedArbiter()
        let last = 6 * Self.period
        var events = try arbiter.poll(now: Self.host(last + Self.timeout + 1))
        events += try arbiter.poll(now: Self.host(last + 2 * Self.timeout))
        events += try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(last + 3 * Self.timeout))
        events += try arbiter.poll(now: Self.host(last + 5 * Self.timeout))
        // Stopping after the loss does not turn it into an idle: it stays lost until it relocks.
        events += try arbiter.receive(.stop, from: Self.sourceA, at: Self.host(last + 6 * Self.timeout))
        events += try arbiter.poll(now: Self.host(last + 8 * Self.timeout))
        #expect(events.filter { $0.bumpReason == .sourceLost }.count == 1)
        #expect(arbiter.status.isDegraded)
        // The relock pairs with it, and the next episode bumps once more.
        let restart = last + 9 * Self.timeout
        events += try arbiter.receive(.continue, from: Self.sourceA, at: Self.host(restart))
        events += try Self.clocks(&arbiter, at: restart, intervals: Self.steady(5))
        let relocked = restart + 5 * Self.period
        events += try arbiter.poll(now: Self.host(relocked + Self.timeout + 1))
        events += try arbiter.poll(now: Self.host(relocked + 3 * Self.timeout))
        #expect(events.filter { $0.bumpReason == .sourceLost }.count == 2)
        #expect(events.filter { $0.bumpReason == .sourceReacquired }.count == 1)
    }

    @Test
    func pulsesStampedBeforeASilentPollAreCountedAndCannotRelock() throws {
        // N = 4 and a 500 ms timeout: clocks at 0 to 100 ms lock and a poll at 1 s reports the loss. Clocks
        // stamped 120 to 220 ms were queued behind that poll.
        var arbiter = try Self.arbiter()
        _ = try arbiter.receive(.start, from: Self.sourceA, at: Self.host(0))
        let locked = try Self.clocks(&arbiter, at: 0, intervals: Self.steady(5))
        #expect(Self.arbitration(locked) == [.leaderLocked(Self.sourceA, tempo: nil, after: .selection)])
        let second: UInt64 = 1_000_000_000
        let reason = MIDIClockDegradedReason.silence(lastMessage: Self.host(5 * Self.period),
                                                     detectedAt: Self.host(second))
        #expect(try arbiter.poll(now: Self.host(second)) == [.leaderLost(Self.sourceA, reason: reason,
                                                                          heldTempo: nil)])
        let queued = try Self.clocks(&arbiter, at: 6 * Self.period, intervals: Self.steady(5))
        // They still reach the follower, but only count: no relock, and no second loss at the same poll.
        #expect(Self.arbitration(queued).isEmpty && queued.count == 6)
        #expect(arbiter.stalePulses == 6)
        #expect(arbiter.status == .degraded(Self.sourceA, reason: reason, heldTempo: nil, steadyPulses: 0))
        #expect(try arbiter.poll(now: Self.host(second)).isEmpty)
        // A pulse stamped at the poll itself is not stale.
        try Self.clocks(&arbiter, at: second, intervals: Self.steady(2))
        #expect(arbiter.stalePulses == 6)
        #expect(arbiter.status == .degraded(Self.sourceA, reason: reason, heldTempo: nil, steadyPulses: 1))
        // A new selection forgets the poll and the count: B's pulses stamped before the poll lock B.
        _ = try arbiter.selectLeader(.external(Self.sourceB))
        #expect(arbiter.stalePulses == 0)
        let fresh = try Self.clocks(&arbiter, at: Self.period, intervals: Self.steady(5), from: Self.sourceB)
        #expect(fresh == [.leaderLocked(Self.sourceB, tempo: nil, after: .selection)])
    }

    @Test
    func aLateMessageIsJudgedByTheTransportStateBeforeIt() throws {
        // A Stop arriving after a silence that began while running reports the loss.
        var running = try Self.lockedArbiter()
        let late = 6 * Self.period + Self.timeout + 1
        let stopped = try running.receive(.stop, from: Self.sourceA, at: Self.host(late))
        let reason = MIDIClockDegradedReason.lateArrival(lastMessage: Self.host(6 * Self.period),
                                                         detectedAt: Self.host(late))
        #expect(Self.arbitration(stopped) == [.leaderLost(Self.sourceA, reason: reason, heldTempo: nil)])
        // A Continue arriving after a silence that began while stopped reports the idle; silence after it loses.
        var idle = try Self.lockedArbiter()
        _ = try idle.receive(.stop, from: Self.sourceA, at: Self.host(7 * Self.period))
        let resumed = 7 * Self.period + Self.timeout + 1
        let continued = try idle.receive(.continue, from: Self.sourceA, at: Self.host(resumed))
        let idleReason = MIDIClockDegradedReason.lateArrival(lastMessage: Self.host(7 * Self.period),
                                                             detectedAt: Self.host(resumed))
        #expect(Self.arbitration(continued) == [.leaderIdle(Self.sourceA, reason: idleReason)])
        #expect(idle.status == .idle(Self.sourceA))
        let detected = resumed + Self.timeout + 1
        let silent = MIDIClockDegradedReason.silence(lastMessage: Self.host(resumed), detectedAt: Self.host(detected))
        let lost = try idle.poll(now: Self.host(detected))
        #expect(lost == [.leaderLost(Self.sourceA, reason: silent, heldTempo: nil)])
        #expect(lost.first?.bumpReason == .sourceLost)
    }

    @Test
    func anAcquiringLeaderHoldsNoTempoEvenOnceItsEstimatorHasOne() throws {
        // N = 96 outlasts the estimator's window: it locks at the 25th clock while the leader still acquires.
        var arbiter = try Self.arbiter(reacquire: 96)
        _ = try arbiter.receive(.start, from: Self.sourceA, at: Self.host(0))
        try Self.clocks(&arbiter, at: 0, intervals: Self.steady(30))
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 29))
        let last = 30 * Self.period
        let detected = last + Self.timeout + 1
        let reason = MIDIClockDegradedReason.silence(lastMessage: Self.host(last), detectedAt: Self.host(detected))
        #expect(try arbiter.poll(now: Self.host(detected))
                    == [.leaderTempo(Self.sourceA, .lost(lastPulse: Self.host(last))),
                        .leaderLost(Self.sourceA, reason: reason, heldTempo: nil)])
    }

    @Test
    func switchingAwayFromALostLeaderDoesNotBumpItAgain() throws {
        var arbiter = try Self.lockedArbiter()
        _ = try arbiter.poll(now: Self.host(6 * Self.period + Self.timeout + 1))
        #expect(arbiter.status.isDegraded)
        let fromLost = try arbiter.selectLeader(.external(Self.sourceB))
        #expect(fromLost == MIDIClockLeaderChange(previous: .external(Self.sourceA), selected: .external(Self.sourceB),
                                                  bumpReason: nil))
        #expect(arbiter.status == .acquiring(Self.sourceB, steadyPulses: 0) && !arbiter.status.isDegraded)
        #expect(try arbiter.poll(now: Self.host(10 * Self.timeout)).isEmpty)
        #expect(try arbiter.selectLeader(.internal).bumpReason == .sourceLost)
        #expect(try arbiter.selectLeader(.external(Self.sourceA))
                    == MIDIClockLeaderChange(previous: .internal, selected: .external(Self.sourceA),
                                             bumpReason: .sourceLost))
        // A leader that relocked after its loss ends a new generation when switched away.
        let start = 11 * Self.timeout
        _ = try arbiter.receive(.start, from: Self.sourceA, at: Self.host(start))
        try Self.clocks(&arbiter, at: start, intervals: Self.steady(5))
        let detected = start + 5 * Self.period + Self.timeout + 1
        _ = try arbiter.poll(now: Self.host(detected))
        try Self.clocks(&arbiter, at: detected, intervals: Self.steady(5))
        #expect(arbiter.status == .locked(Self.sourceA, tempo: nil))
        #expect(try arbiter.selectLeader(.external(Self.sourceB)).bumpReason == .sourceLost)
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
        #expect(try arbiter.poll(now: Self.host(9 * Self.period)).isEmpty)
    }

    @Test
    func aLockedLeadersTempoFollowsTheEstimator() throws {
        var arbiter = try Self.arbiter(reacquire: 24)
        try Self.clocks(&arbiter, at: 0, intervals: Self.steady(25))
        #expect(arbiter.status == .locked(Self.sourceA, tempo: Self.tempo))
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
        #expect(arbiter.status == .locked(Self.sourceA, tempo: Self.tempo))
        _ = try arbiter.selectLeader(.external(Self.sourceB))
        #expect(arbiter.status == .acquiring(Self.sourceB, steadyPulses: 0))
        // B's stamps may precede A's last one: B has its own steady run and tempo estimator, and no tempo yet.
        let events = try Self.clocks(&arbiter, at: Self.period, intervals: Array(repeating: 25_000_000, count: 5),
                                     from: Self.sourceB)
        #expect(events == [.leaderLocked(Self.sourceB, tempo: nil, after: .selection)])
        #expect(arbiter.status == .locked(Self.sourceB, tempo: nil))
    }
}
