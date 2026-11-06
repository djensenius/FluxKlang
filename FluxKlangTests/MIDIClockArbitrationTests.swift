import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI clock leader arbitration")
struct MIDIClockArbitrationTests {
    private static let sourceA = MIDIInputID(1)
    private static let sourceB = MIDIInputID(2)
    private static let sourceC = MIDIInputID(3)
    private static let nanos = HostTimebase(numer: 1, denom: 1)
    /// 20 ms per pulse: 480,000 µs per quarter.
    private static let period: UInt64 = 20_000_000

    private static func host(_ ticks: UInt64) -> HostStamp { HostStamp(ticks: ticks) }

    private static func policy(sources: Int = 8, reacquire: Int = 4) throws -> MIDIClockArbitrationPolicy {
        try MIDIClockArbitrationPolicy.make(maximumSources: sources, timeoutNanos: 500_000_000,
                                            reacquirePulses: reacquire, jitterTolerancePerMille: 100)
    }

    /// Sources A, B and C registered; `leader` selected unless internal.
    private static func arbiter(leader: MIDIClockLeader = .external(sourceA)) throws -> MIDIClockLeaderArbiter {
        var arbiter = try MIDIClockLeaderArbiter(policy: try policy(), timebase: nanos)
        for id in [sourceC, sourceA, sourceB] { try arbiter.addSource(id) }
        if leader != .internal { _ = try arbiter.selectLeader(leader) }
        return arbiter
    }

    /// Feeds `messages` from `id` one period apart from `start`, returning every event in order.
    private static func feed(_ arbiter: inout MIDIClockLeaderArbiter, _ messages: [MIDIClockMessage],
                             from id: MIDIInputID, start: UInt64 = 0) throws -> [MIDIClockArbitrationEvent] {
        var events: [MIDIClockArbitrationEvent] = []
        for (offset, message) in messages.enumerated() {
            events += try arbiter.receive(message, from: id, at: host(start + UInt64(offset) * period))
        }
        return events
    }

    private static func transport(_ events: [MIDIClockArbitrationEvent]) -> [MIDIClockFollowerEvent] {
        events.compactMap { event in
            if case let .transport(followerEvent) = event { return followerEvent }
            return nil
        }
    }

    @Test
    func policyValuesAreValidatedAtEveryBound() throws {
        let standard = MIDIClockArbitrationPolicy.standard
        #expect(standard.maximumSources == 16 && standard.timeoutNanos == 500_000_000)
        #expect(standard.reacquirePulses == 24 && standard.jitterTolerancePerMille == 250)
        func make(_ sources: Int = 8, _ timeout: Int64 = 500_000_000, _ pulses: Int = 4,
                  _ tolerance: Int = 100) throws(MIDIClockArbitrationError) -> MIDIClockArbitrationPolicy {
            try .make(maximumSources: sources, timeoutNanos: timeout, reacquirePulses: pulses,
                      jitterTolerancePerMille: tolerance)
        }
        #expect(try make(1).maximumSources == 1)
        #expect(try make(64).maximumSources == 64)
        #expect(throws: MIDIClockArbitrationError.invalidMaximumSources(0)) { try make(0) }
        #expect(throws: MIDIClockArbitrationError.invalidMaximumSources(65)) { try make(65) }
        #expect(try make(8, 50_000_000).timeoutNanos == 50_000_000)
        #expect(try make(8, 2_000_000_000).timeoutNanos == 2_000_000_000)
        #expect(throws: MIDIClockArbitrationError.invalidTimeout(nanos: 49_999_999)) { try make(8, 49_999_999) }
        #expect(throws: MIDIClockArbitrationError.invalidTimeout(nanos: 2_000_000_001)) {
            try make(8, 2_000_000_001)
        }
        #expect(try make(8, 500_000_000, 2).reacquirePulses == 2)
        #expect(try make(8, 500_000_000, 96).reacquirePulses == 96)
        #expect(throws: MIDIClockArbitrationError.invalidReacquirePulses(1)) { try make(8, 500_000_000, 1) }
        #expect(throws: MIDIClockArbitrationError.invalidReacquirePulses(97)) { try make(8, 500_000_000, 97) }
        #expect(try make(8, 500_000_000, 4, 1).jitterTolerancePerMille == 1)
        #expect(try make(8, 500_000_000, 4, 500).jitterTolerancePerMille == 500)
        #expect(throws: MIDIClockArbitrationError.invalidJitterTolerance(perMille: 0)) {
            try make(8, 500_000_000, 4, 0)
        }
        #expect(throws: MIDIClockArbitrationError.invalidJitterTolerance(perMille: 501)) {
            try make(8, 500_000_000, 4, 501)
        }
    }

    @Test
    func invalidTimebaseIsRefusedAndTheTimeoutRoundsUpToHostTicks() throws {
        #expect(throws: MIDIClockArbitrationError.clock(.invalidTimebase)) {
            try MIDIClockLeaderArbiter(timebase: HostTimebase(numer: 0, denom: 1))
        }
        #expect(throws: MIDIClockArbitrationError.clock(.invalidTimebase)) {
            try MIDIClockLeaderArbiter(timebase: HostTimebase(numer: 1, denom: 0))
        }
        // 500 ms at 3 ns per tick is 166,666,666.7 ticks, rounded up.
        #expect(try MIDIClockLeaderArbiter(timebase: HostTimebase(numer: 3, denom: 1)).timeoutTicks == 166_666_667)
        // 125/3 ns per tick: 12,000,000 ticks exactly.
        #expect(try MIDIClockLeaderArbiter(timebase: HostTimebase(numer: 125, denom: 3)).timeoutTicks == 12_000_000)
    }

    @Test
    func theSourceTableIsBoundedSortedAndOverflowIsRefused() throws {
        var arbiter = try MIDIClockLeaderArbiter(policy: try Self.policy(sources: 2), timebase: Self.nanos)
        try arbiter.addSource(Self.sourceB)
        #expect(throws: MIDIClockArbitrationError.duplicateSource(Self.sourceB)) {
            try arbiter.addSource(Self.sourceB)
        }
        try arbiter.addSource(Self.sourceA)
        #expect(throws: MIDIClockArbitrationError.sourceTableFull(capacity: 2)) { try arbiter.addSource(Self.sourceC) }
        #expect(arbiter.sources.map(\.id) == [Self.sourceA, Self.sourceB])
        #expect(arbiter.source(Self.sourceC) == nil)

        var widest = try MIDIClockLeaderArbiter(policy: try Self.policy(sources: 64), timebase: Self.nanos)
        for raw in (1...64).reversed() { try widest.addSource(MIDIInputID(UInt32(raw))) }
        #expect(throws: MIDIClockArbitrationError.sourceTableFull(capacity: 64)) {
            try widest.addSource(MIDIInputID(65))
        }
        #expect(widest.sources.map(\.id.rawValue) == Array(1...64))
    }

    @Test
    func removingASourceIsExplicitAndTheLeaderCannotBeRemoved() throws {
        var arbiter = try Self.arbiter()
        #expect(throws: MIDIClockArbitrationError.sourceIsLeader(Self.sourceA)) {
            try arbiter.removeSource(Self.sourceA)
        }
        #expect(throws: MIDIClockArbitrationError.unknownSource(MIDIInputID(9))) {
            try arbiter.removeSource(MIDIInputID(9))
        }
        try arbiter.removeSource(Self.sourceB)
        #expect(arbiter.sources.map(\.id) == [Self.sourceA, Self.sourceC])
        #expect(throws: MIDIClockArbitrationError.unknownSource(Self.sourceB)) {
            try arbiter.receive(.clock, from: Self.sourceB, at: Self.host(0))
        }
        try arbiter.addSource(Self.sourceB)
        #expect(arbiter.sources.map(\.id) == [Self.sourceA, Self.sourceB, Self.sourceC])
    }

    @Test
    func onlyTheLeadersMessagesReachTheTransport() throws {
        var arbiter = try Self.arbiter()
        var reference = try MIDIClockFollower()
        let messages: [MIDIClockMessage] = [.start, .clock, .clock, .songPosition(4), .clock, .stop, .continue]
        let events = try Self.feed(&arbiter, messages, from: Self.sourceA)
        var expected: [MIDIClockFollowerEvent] = []
        for (offset, message) in messages.enumerated() {
            if let event = try reference.receive(message, at: Self.host(UInt64(offset) * Self.period)) {
                expected.append(event)
            }
        }
        #expect(!expected.isEmpty)
        #expect(events == expected.map { .transport($0) })
        #expect(arbiter.source(Self.sourceA)?.isLeader == true)
        #expect(arbiter.source(Self.sourceA)?.ignored.total == 0)
    }

    @Test
    func pulsesFromANonLeaderProduceOnlyDeduplicatedCompetingDiagnostics() throws {
        var arbiter = try Self.arbiter()
        _ = try Self.feed(&arbiter, [.start, .clock], from: Self.sourceA)
        let competing = try Self.feed(&arbiter, [.start] + Array(repeating: .clock, count: 40), from: Self.sourceB)
        let reason = MIDIClockIgnoreReason.notLeader(selected: .external(Self.sourceA))
        #expect(competing == [.competingSource(Self.sourceB, .start, reason),
                              .competingSource(Self.sourceB, .clock, reason)])
        #expect(competing.allSatisfy { $0.bumpReason == nil })
        let statusB = try #require(arbiter.source(Self.sourceB))
        #expect(statusB.ignored[.clock] == 40 && statusB.ignored[.start] == 1 && statusB.ignored.total == 41)
        #expect(!statusB.isLeader)
        // The non-leader's shadow follower runs; the leader's is untouched and never counted as competing.
        #expect(statusB.followerState == .running && statusB.nextPulseTicks == 40 * 640)
        #expect(arbiter.source(Self.sourceA)?.nextPulseTicks == 640)
        #expect(arbiter.status == .acquiring(Self.sourceA, steadyPulses: 0))
        // The leader's next clock still plays its own next tick.
        let next = try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(41 * Self.period))
        #expect(Self.transport(next) == [.pulse(ticks: 640, host: Self.host(41 * Self.period), located: false)])
        // A third source reports its own first diagnostic.
        let third = try arbiter.receive(.clock, from: Self.sourceC, at: Self.host(0))
        #expect(third == [.competingSource(Self.sourceC, .clock, reason)])
    }

    @Test
    func startStopContinueAndSongPositionFromANonLeaderAreIgnoredWithAReason() throws {
        var arbiter = try Self.arbiter()
        _ = try Self.feed(&arbiter, [.start, .clock, .clock], from: Self.sourceA)
        let ignored = try Self.feed(&arbiter, [.stop, .songPosition(8), .start, .continue, .stop],
                                    from: Self.sourceB, start: 3 * Self.period)
        let reason = MIDIClockIgnoreReason.notLeader(selected: .external(Self.sourceA))
        #expect(ignored == [.competingSource(Self.sourceB, .stop, reason),
                            .competingSource(Self.sourceB, .songPosition, reason),
                            .competingSource(Self.sourceB, .start, reason),
                            .competingSource(Self.sourceB, .continue, reason)])
        #expect(arbiter.source(Self.sourceB)?.ignored[.stop] == 2)
        #expect(arbiter.source(Self.sourceA)?.followerState == .running)
        let next = try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(10 * Self.period))
        #expect(Self.transport(next) == [.pulse(ticks: 1_280, host: Self.host(10 * Self.period), located: false)])
    }

    @Test
    func anInternalLeaderIgnoresEveryExternalSource() throws {
        var arbiter = try Self.arbiter(leader: .internal)
        #expect(arbiter.status == .internal && arbiter.status.leader == .internal && !arbiter.status.isDegraded)
        let events = try Self.feed(&arbiter, [.start, .clock, .clock], from: Self.sourceA)
        let reason = MIDIClockIgnoreReason.notLeader(selected: .internal)
        #expect(events == [.competingSource(Self.sourceA, .start, reason),
                           .competingSource(Self.sourceA, .clock, reason)])
        #expect(try arbiter.poll(now: Self.host(10_000_000_000)) == nil)
        #expect(arbiter.sources.allSatisfy { !$0.isLeader })
    }

    @Test
    func changingTheLeaderIsExplicitResetsItsFollowerAndBumps() throws {
        var arbiter = try Self.arbiter()
        _ = try Self.feed(&arbiter, [.start, .clock, .clock], from: Self.sourceA)
        _ = try Self.feed(&arbiter, [.start, .clock, .clock, .clock], from: Self.sourceB)
        #expect(arbiter.source(Self.sourceB)?.followerState == .running)
        let change = try arbiter.selectLeader(.external(Self.sourceB), resumingAt: 15_360)
        #expect(change == MIDIClockLeaderChange(previous: .external(Self.sourceA), selected: .external(Self.sourceB)))
        #expect(change.bumpReason == .sourceLost)
        #expect(arbiter.leader == .external(Self.sourceB))
        #expect(arbiter.status == .acquiring(Self.sourceB, steadyPulses: 0))
        let statusB = try #require(arbiter.source(Self.sourceB))
        #expect(statusB.isLeader && statusB.followerState == .stopped && statusB.nextPulseTicks == 15_360)
        #expect(statusB.ignored.total == 0)
        // The old leader keeps its shadow follower and is now competing.
        #expect(arbiter.source(Self.sourceA)?.followerState == .running)
        let fromA = try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(10 * Self.period))
        #expect(fromA == [.competingSource(Self.sourceA, .clock, .notLeader(selected: .external(Self.sourceB)))])
        let fromB = try Self.feed(&arbiter, [.continue, .clock], from: Self.sourceB, start: 10 * Self.period)
        #expect(Self.transport(fromB) == [.continued(ticks: 15_360, relocated: true),
                                          .pulse(ticks: 15_360, host: Self.host(11 * Self.period), located: false)])
        let back = try arbiter.selectLeader(.internal)
        #expect(back == MIDIClockLeaderChange(previous: .external(Self.sourceB), selected: .internal))
        #expect(arbiter.status == .internal)
    }

    @Test
    func refusedSelectionsLeaveTheArbiterUnchanged() throws {
        var arbiter = try Self.arbiter()
        _ = try Self.feed(&arbiter, [.start, .clock], from: Self.sourceA)
        _ = try Self.feed(&arbiter, [.clock], from: Self.sourceB)
        let status = arbiter.status
        let sources = arbiter.sources
        #expect(throws: MIDIClockArbitrationError.alreadySelected(.external(Self.sourceA))) {
            try arbiter.selectLeader(.external(Self.sourceA))
        }
        #expect(throws: MIDIClockArbitrationError.unknownSource(MIDIInputID(9))) {
            try arbiter.selectLeader(.external(MIDIInputID(9)))
        }
        #expect(throws: MIDIClockArbitrationError.clock(.negativeTicks(-1))) {
            try arbiter.selectLeader(.external(Self.sourceB), resumingAt: -1)
        }
        #expect(arbiter.status == status && arbiter.sources == sources && arbiter.leader == .external(Self.sourceA))
        var idle = try Self.arbiter(leader: .internal)
        #expect(throws: MIDIClockArbitrationError.alreadySelected(.internal)) { try idle.selectLeader(.internal) }
    }

    @Test
    func timeGoingBackIsRefusedAndLeavesTheStateUnchanged() throws {
        var arbiter = try Self.arbiter()
        _ = try Self.feed(&arbiter, [.start, .clock, .clock, .clock], from: Self.sourceA)
        _ = try Self.feed(&arbiter, [.clock, .clock], from: Self.sourceB, start: 5 * Self.period)
        let status = arbiter.status
        let sources = arbiter.sources
        let lastA = 3 * Self.period
        #expect(throws: MIDIClockArbitrationError.nonMonotonicHost(source: Self.sourceA, previous: lastA,
                                                                      current: lastA - 1)) {
            try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(lastA - 1))
        }
        let lastB = 6 * Self.period
        #expect(throws: MIDIClockArbitrationError.nonMonotonicHost(source: Self.sourceB, previous: lastB,
                                                                      current: lastB - 1)) {
            try arbiter.receive(.stop, from: Self.sourceB, at: Self.host(lastB - 1))
        }
        #expect(arbiter.status == status && arbiter.sources == sources)
        // Sources are independent: A may still use a time before B's last one.
        let events = try arbiter.receive(.clock, from: Self.sourceA, at: Self.host(lastA))
        #expect(Self.transport(events) == [.pulse(ticks: 1_920, host: Self.host(lastA), located: false)])
    }

    @Test
    func aRefusedFollowerMessageLeavesTheStateUnchanged() throws {
        var arbiter = try Self.arbiter()
        _ = try Self.feed(&arbiter, [.start, .clock], from: Self.sourceA)
        let status = arbiter.status
        let sources = arbiter.sources
        #expect(throws: MIDIClockArbitrationError.clock(.songPositionOutOfRange(16_384))) {
            try arbiter.receive(.songPosition(16_384), from: Self.sourceA, at: Self.host(Self.period * 2))
        }
        #expect(throws: MIDIClockArbitrationError.clock(.songPositionOutOfRange(16_384))) {
            try arbiter.receive(.songPosition(16_384), from: Self.sourceB, at: Self.host(Self.period * 2))
        }
        #expect(arbiter.status == status && arbiter.sources == sources)
    }
}
