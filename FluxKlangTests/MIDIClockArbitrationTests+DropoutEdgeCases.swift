import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIClockArbitrationDropoutTests {
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
