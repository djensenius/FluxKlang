import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Arrival-jitter reporting in the leader arbiter's per-source status (#84, slice JAW1). Nominal pulse: 125 BPM on a
/// nanosecond timebase, 20_000_000 ticks; hand-computed scaled deviations are `interval * 3_000 - 60_000_000_000`.
extension MIDIClockArbitrationTests {
    private static let jitterA = MIDIInputID(1)
    private static let jitterB = MIDIInputID(2)
    private static let jitterC = MIDIInputID(3)
    private static let jitterTimebase = HostTimebase(numer: 1, denom: 1)
    private static let jitterPulse: UInt64 = 20_000_000

    private struct JitterStep: Equatable {
        let events: [MIDIClockArbitrationEvent]
        let status: MIDIClockLeaderStatus
        let stalePulses: UInt64
        let leader: MIDIClockLeader
    }

    private struct JitterNotMeasured: Error {}

    private struct JitterMeasured {
        let summary: MIDIClockJitterSummary
        let verdict: MIDIClockJitterVerdict
    }

    private static func jitterNominal() throws -> MIDIClockJitterNominal {
        try MIDIClockJitterNominal.make(beatsPerMinute: 125, timebase: jitterTimebase)
    }

    private static func jitterWatch(window: Int = 8, tolerance: Int = 250,
                                    percentile: Int = 100) throws -> MIDIClockJitterWatch {
        let limit = try MIDIClockJitterTolerance.make(perMille: tolerance)
        return try MIDIClockJitterWatch.make(nominal: try jitterNominal(), tolerance: limit,
                                             percentile: percentile, windowStamps: window)
    }

    /// Sources A, B and C registered; A selected unless `leader` says otherwise.
    private static func jitterArbiter(watch: MIDIClockJitterWatch?,
                                      leader: MIDIClockLeader = .external(jitterA)) throws -> MIDIClockLeaderArbiter {
        let policy = try MIDIClockArbitrationPolicy.make(maximumSources: 8, timeoutNanos: 500_000_000,
                                                         reacquirePulses: 30, jitterTolerancePerMille: 100)
        var arbiter = try MIDIClockLeaderArbiter(policy: policy, timebase: jitterTimebase, jitterWatch: watch)
        for id in [jitterC, jitterA, jitterB] { try arbiter.addSource(id) }
        if leader != .internal { _ = try arbiter.selectLeader(leader) }
        return arbiter
    }

    @discardableResult
    private static func jitterFeed(_ arbiter: inout MIDIClockLeaderArbiter, from id: MIDIInputID, at ticks: [UInt64],
                                   message: MIDIClockMessage = .clock) throws -> [MIDIClockArbitrationEvent] {
        var events: [MIDIClockArbitrationEvent] = []
        for tick in ticks { events += try arbiter.receive(message, from: id, at: HostStamp(ticks: tick)) }
        return events
    }

    /// `count` stamps one nominal pulse apart, starting at `start`.
    private static func jitterSteady(_ count: Int, start: UInt64 = 0) -> [UInt64] {
        (0..<count).map { start + UInt64($0) * jitterPulse }
    }

    /// Steady pulses with two small wobbles: inside the policy's 100 per mille, outside a 1 per mille watch.
    private static func jitterWobble(_ count: Int, start: UInt64) -> [UInt64] {
        var ticks = jitterSteady(count, start: start)
        ticks[2] += 100_000
        ticks[5] += 50_000
        return ticks
    }

    private static func jitterReport(_ arbiter: MIDIClockLeaderArbiter, _ id: MIDIInputID) throws
        -> MIDIClockSourceJitter {
        let status = try #require(arbiter.source(id))
        return try #require(status.jitter)
    }

    private static func jitterMeasuredReport(_ arbiter: MIDIClockLeaderArbiter,
                                             _ id: MIDIInputID) throws -> JitterMeasured {
        guard case let .measured(summary, verdict) = try jitterReport(arbiter, id) else {
            throw JitterNotMeasured()
        }
        return JitterMeasured(summary: summary, verdict: verdict)
    }

    private static func jitterRefusal(_ arbiter: inout MIDIClockLeaderArbiter, from id: MIDIInputID,
                                      at tick: UInt64) -> MIDIClockArbitrationError? {
        do throws(MIDIClockArbitrationError) {
            _ = try arbiter.receive(.clock, from: id, at: HostStamp(ticks: tick))
            return nil
        } catch {
            return error
        }
    }

    private static func jitterStep(_ arbiter: MIDIClockLeaderArbiter,
                                   _ events: [MIDIClockArbitrationEvent]) -> JitterStep {
        JitterStep(events: events, status: arbiter.status, stalePulses: arbiter.stalePulses, leader: arbiter.leader)
    }

    private static func jitterRunSteady(_ start: MIDIClockLeaderArbiter) throws -> MIDIClockLeaderArbiter {
        var arbiter = start
        try jitterFeed(&arbiter, from: jitterA, at: jitterSteady(6))
        try jitterFeed(&arbiter, from: jitterB, at: jitterSteady(4, start: 5_000_000))
        return arbiter
    }

    /// Lock, a silent poll, a relock and a takeover, with every step's visible state recorded. The wobble keeps
    /// each interval inside the policy's 100 per mille and outside a 1 per mille watch.
    private static func jitterTranscript(_ start: MIDIClockLeaderArbiter) throws
        -> (arbiter: MIDIClockLeaderArbiter, steps: [JitterStep]) {
        var arbiter = start
        var steps: [JitterStep] = []
        for tick in jitterWobble(40, start: 0) {
            let events = try jitterFeed(&arbiter, from: jitterA, at: [tick])
            steps.append(jitterStep(arbiter, events))
            let shadow = try jitterFeed(&arbiter, from: jitterB, at: [tick + 5_000_000])
            steps.append(jitterStep(arbiter, shadow))
        }
        let silent = try arbiter.poll(now: HostStamp(ticks: 1_400_000_000))
        steps.append(jitterStep(arbiter, silent))
        for tick in jitterWobble(40, start: 1_500_000_000) {
            let events = try jitterFeed(&arbiter, from: jitterA, at: [tick])
            steps.append(jitterStep(arbiter, events))
        }
        _ = try arbiter.selectLeader(.external(jitterB))
        steps.append(jitterStep(arbiter, []))
        for tick in jitterWobble(40, start: 2_400_000_000) {
            let events = try jitterFeed(&arbiter, from: jitterB, at: [tick])
            steps.append(jitterStep(arbiter, events))
        }
        return (arbiter, steps)
    }

    private static func jitterLockedWithTempo(_ status: MIDIClockLeaderStatus) -> Bool {
        if case let .locked(_, tempo) = status { return tempo != nil }
        return false
    }

    private static func jitterLockTempoFlags(_ events: [MIDIClockArbitrationEvent]) -> [Bool] {
        events.compactMap { if case let .leaderLocked(_, tempo, _) = $0 { tempo != nil } else { nil } }
    }

    private static func jitterIdleCount(_ events: [MIDIClockArbitrationEvent]) -> Int {
        events.filter { if case .leaderIdle = $0 { true } else { false } }.count
    }

    @Test
    func withoutAWatchEverySourceReportsNoJitterAfterThirtyClocks() throws {
        var arbiter = try Self.jitterArbiter(watch: nil)
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: Self.jitterSteady(30))
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: Self.jitterSteady(30))
        let sources = arbiter.sources
        #expect(sources.count == 3)
        #expect(arbiter.jitterWatch == nil)
        for status in sources { #expect(status.jitter == nil) }
    }

    @Test
    func aWatchedRunEqualsTheUnwatchedRunOnceJitterIsCleared() throws {
        var plain = try Self.jitterArbiter(watch: nil)
        var watched = try Self.jitterArbiter(watch: try Self.jitterWatch())
        plain = try Self.jitterRunSteady(plain)
        watched = try Self.jitterRunSteady(watched)
        let plainSources = plain.sources
        let watchedSources = watched.sources
        #expect(plainSources != watchedSources)
        var cleared = watchedSources
        for position in cleared.indices {
            #expect(cleared[position].jitter != nil)
            cleared[position].jitter = nil
        }
        #expect(cleared == plainSources)
    }

    @Test
    func aSourceWithFewerThanTwoClocksIsCollectingAndTwoClocksAreMeasured() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch())
        let none = try Self.jitterReport(arbiter, Self.jitterA)
        #expect(none == .collecting(stamps: 0))
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: [0])
        let one = try Self.jitterReport(arbiter, Self.jitterA)
        #expect(one == .collecting(stamps: 1))
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: [20_000_000])
        let two = try Self.jitterMeasuredReport(arbiter, Self.jitterA)
        #expect(two.summary.intervalCount == 1)
        let other = try Self.jitterReport(arbiter, Self.jitterB)
        #expect(other == .collecting(stamps: 0))
    }

    @Test
    func steadyTwentyMillisecondClocksAreMeasuredWithNoDeviationAndWithinTolerance() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch())
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: Self.jitterSteady(5))
        let measured = try Self.jitterMeasuredReport(arbiter, Self.jitterA)
        let span: Int128 = 60_000_000_000
        let pulses: Int128 = 3_000
        let noDeviation: Int128 = 0
        #expect(measured.summary.intervalCount == 4)
        #expect(measured.summary.minimumInterval == 20_000_000)
        #expect(measured.summary.maximumInterval == 20_000_000)
        #expect(measured.summary.totalTicks == 80_000_000)
        #expect(measured.summary.maximumDeviationScaled == noDeviation)
        #expect(measured.summary.percentile == 100)
        #expect(measured.summary.nominal.spanTicks == span)
        #expect(measured.summary.nominal.pulses == pulses)
        #expect(measured.verdict == .withinTolerance)
    }

    @Test
    func oneTwentySixMillisecondIntervalExceedsTwoHundredFiftyPerMilleAndKeepsThePercentile() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch(tolerance: 250, percentile: 50))
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: [0, 20_000_000, 46_000_000, 66_000_000])
        let measured = try Self.jitterMeasuredReport(arbiter, Self.jitterA)
        let largest: Int128 = 18_000_000_000
        let median: Int128 = 0
        #expect(measured.summary.intervalCount == 3)
        #expect(measured.summary.minimumInterval == 20_000_000)
        #expect(measured.summary.maximumInterval == 26_000_000)
        #expect(measured.summary.maximumDeviationScaled == largest)
        #expect(measured.summary.percentile == 50)
        #expect(measured.summary.percentileDeviationScaled == median)
        #expect(measured.verdict == .exceeded)
    }

    @Test
    func aDeviationEqualToTheToleranceIsWithinAndOnePerMilleLessIsExceeded() throws {
        let ticks: [UInt64] = [0, 20_000_000, 46_000_000, 66_000_000]
        var atEdge = try Self.jitterArbiter(watch: try Self.jitterWatch(tolerance: 300))
        try Self.jitterFeed(&atEdge, from: Self.jitterA, at: ticks)
        let edge = try Self.jitterMeasuredReport(atEdge, Self.jitterA)
        #expect(edge.verdict == .withinTolerance)
        var below = try Self.jitterArbiter(watch: try Self.jitterWatch(tolerance: 299))
        try Self.jitterFeed(&below, from: Self.jitterA, at: ticks)
        let under = try Self.jitterMeasuredReport(below, Self.jitterA)
        #expect(under.verdict == .exceeded)
    }

    @Test
    func theLeaderAndACompetingSourceAreBothReportedAndAnIdleSourceIsCollecting() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch())
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: Self.jitterSteady(5))
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: Self.jitterSteady(3, start: 10_000_000))
        let leader = try #require(arbiter.source(Self.jitterA))
        let competing = try #require(arbiter.source(Self.jitterB))
        #expect(leader.isLeader)
        #expect(!competing.isLeader)
        let leaderReport = try Self.jitterMeasuredReport(arbiter, Self.jitterA)
        let competingReport = try Self.jitterMeasuredReport(arbiter, Self.jitterB)
        #expect(leaderReport.summary.intervalCount == 4)
        #expect(competingReport.summary.intervalCount == 2)
        let idle = try Self.jitterReport(arbiter, Self.jitterC)
        #expect(idle == .collecting(stamps: 0))
    }

    @Test
    func startStopContinueAndSongPositionDoNotEnterTheWindow() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch())
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: [1_000_000], message: .start)
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: [2_000_000], message: .continue)
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: [3_000_000], message: .stop)
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: [4_000_000], message: .songPosition(8))
        let before = try Self.jitterReport(arbiter, Self.jitterB)
        #expect(before == .collecting(stamps: 0))
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: [10_000_000])
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: [20_000_000], message: .start)
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: [30_000_000], message: .stop)
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: [70_000_000])
        let after = try Self.jitterMeasuredReport(arbiter, Self.jitterB)
        #expect(after.summary.intervalCount == 1)
        #expect(after.summary.minimumInterval == 60_000_000)
        #expect(after.summary.maximumInterval == 60_000_000)
    }

    @Test
    func aWindowOfEightHoldsTheLatestEightStampsInOrderAfterTwentyAreRecorded() throws {
        var window = MIDIClockStampWindow(watch: try Self.jitterWatch(window: 8))
        for tick in 1...3 as ClosedRange<UInt64> { window.record(HostStamp(ticks: tick * 10)) }
        let growing = window.stamps.map(\.ticks)
        #expect(growing == [10, 20, 30])
        for tick in 4...8 as ClosedRange<UInt64> { window.record(HostStamp(ticks: tick * 10)) }
        let full = window.stamps.map(\.ticks)
        #expect(full == [10, 20, 30, 40, 50, 60, 70, 80])
        window.record(HostStamp(ticks: 90))
        let wrapped = window.stamps.map(\.ticks)
        #expect(wrapped == [20, 30, 40, 50, 60, 70, 80, 90])
        for tick in 10...20 as ClosedRange<UInt64> { window.record(HostStamp(ticks: tick * 10)) }
        let latest = window.stamps.map(\.ticks)
        #expect(latest == [130, 140, 150, 160, 170, 180, 190, 200])
    }

    @Test
    func aWindowOfTwoWrapsAfterFiveStampsAndAWindowOf1024HoldsTheLast1024() throws {
        var small = MIDIClockStampWindow(watch: try Self.jitterWatch(window: 2))
        for tick in 1...5 as ClosedRange<UInt64> { small.record(HostStamp(ticks: tick * 10)) }
        let pair = small.stamps.map(\.ticks)
        #expect(pair == [40, 50])
        var large = MIDIClockStampWindow(watch: try Self.jitterWatch(window: 1_024))
        for tick in 1...1_025 as ClosedRange<UInt64> { large.record(HostStamp(ticks: tick)) }
        let held = large.stamps.map(\.ticks)
        #expect(held.count == 1_024)
        #expect(held.first == 2)
        #expect(held.last == 1_025)
    }

    @Test
    func theArbiterReportsTheLatestEightOfTwentyClocksOnNonUniformGaps() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch(window: 8))
        let ticks: [UInt64] = (0..<20).map { UInt64($0 * $0) * 1_000_000 }
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: ticks)
        let measured = try Self.jitterMeasuredReport(arbiter, Self.jitterA)
        #expect(measured.summary.intervalCount == 7)
        #expect(measured.summary.totalTicks == 217_000_000)
        #expect(measured.summary.minimumInterval == 25_000_000)
        #expect(measured.summary.maximumInterval == 37_000_000)
    }

    @Test
    func theArbiterReportsOnlyTheLastTwoOfFiveClocksWithAWindowOfTwo() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch(window: 2))
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: [0, 20_000_000, 40_000_000, 70_000_000, 100_000_000])
        let measured = try Self.jitterMeasuredReport(arbiter, Self.jitterA)
        #expect(measured.summary.intervalCount == 1)
        #expect(measured.summary.totalTicks == 30_000_000)
    }

    @Test
    func aWatchKeepsEveryValueItWasGivenAndAcceptsTheWindowBounds() throws {
        let watch = try Self.jitterWatch(window: 8, tolerance: 250, percentile: 50)
        let span: Int128 = 60_000_000_000
        let pulses: Int128 = 3_000
        #expect(watch.windowStamps == 8)
        #expect(watch.percentile == 50)
        #expect(watch.tolerance.perMille == 250)
        #expect(watch.nominal.spanTicks == span)
        #expect(watch.nominal.pulses == pulses)
        let largest = try Self.jitterWatch(window: 1_024)
        let smallest = try Self.jitterWatch(window: 2)
        #expect(largest.windowStamps == 1_024)
        #expect(smallest.windowStamps == 2)
        #expect(try Self.jitterWatch(percentile: 1).percentile == 1)
        #expect(try Self.jitterWatch(percentile: 100).percentile == 100)
    }

    @Test
    func aWatchRefusesWindowsAndPercentilesJustOutsideTheBoundsWithTheValueGiven() throws {
        #expect(throws: MIDIClockJitterRefusal.tooManyStamps(1_025)) { try Self.jitterWatch(window: 1_025) }
        #expect(throws: MIDIClockJitterRefusal.tooFewStamps(1)) { try Self.jitterWatch(window: 1) }
        #expect(throws: MIDIClockJitterRefusal.tooFewStamps(0)) { try Self.jitterWatch(window: 0) }
        #expect(throws: MIDIClockJitterRefusal.percentileOutOfRange(0)) { try Self.jitterWatch(percentile: 0) }
        #expect(throws: MIDIClockJitterRefusal.percentileOutOfRange(101)) { try Self.jitterWatch(percentile: 101) }
    }

    @Test
    func aWatchWithBothTooManyStampsAndABadPercentileReportsTheStampsAndOneStampOutranksThePercentile() throws {
        #expect(throws: MIDIClockJitterRefusal.tooManyStamps(1_025)) {
            try Self.jitterWatch(window: 1_025, percentile: 0)
        }
        #expect(throws: MIDIClockJitterRefusal.tooFewStamps(1)) {
            try Self.jitterWatch(window: 1, percentile: 0)
        }
    }

    @Test
    func aNonMonotonicRefusalRecordsNothingInTheWindowOrTheStatus() throws {
        for id in [Self.jitterA, Self.jitterB] {
            var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch())
            try Self.jitterFeed(&arbiter, from: id, at: [100_000_000, 120_000_000, 140_000_000])
            let before = arbiter.sources
            let refusal = Self.jitterRefusal(&arbiter, from: id, at: 50_000_000)
            #expect(refusal == .nonMonotonicHost(source: id, previous: 140_000_000, current: 50_000_000))
            let after = arbiter.sources
            #expect(after == before)
            try Self.jitterFeed(&arbiter, from: id, at: [160_000_000])
            let measured = try Self.jitterMeasuredReport(arbiter, id)
            #expect(measured.summary.intervalCount == 3)
            #expect(measured.summary.totalTicks == 60_000_000)
        }
    }

    @Test
    func aFollowerRefusalRecordsNothingInTheWindowOrTheStatus() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch(), leader: .internal)
        _ = try arbiter.selectLeader(.external(Self.jitterB), resumingAt: Int64.max)
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: [1_000_000], message: .continue)
        let before = arbiter.sources
        let refusal = Self.jitterRefusal(&arbiter, from: Self.jitterB, at: 2_000_000)
        #expect(refusal == .clock(.positionOverflow))
        let report = try Self.jitterReport(arbiter, Self.jitterB)
        #expect(report == .collecting(stamps: 0))
        let after = arbiter.sources
        #expect(after == before)
    }

    @Test
    func equalClockStampsAreMeasuredWithAZeroInterval() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch())
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: [0, 0, 20_000_000])
        let measured = try Self.jitterMeasuredReport(arbiter, Self.jitterA)
        #expect(measured.summary.intervalCount == 2)
        #expect(measured.summary.minimumInterval == 0)
        #expect(measured.summary.totalTicks == 20_000_000)
    }

    @Test
    func anUnknownSourceIsRefusedAndRecordsNothing() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch())
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: Self.jitterSteady(3))
        let before = arbiter.sources
        let status = arbiter.status
        let stranger = MIDIInputID(9)
        let refusal = Self.jitterRefusal(&arbiter, from: stranger, at: 500_000_000)
        #expect(refusal == .unknownSource(stranger))
        let after = arbiter.sources
        #expect(after == before)
        #expect(arbiter.status == status)
        #expect(arbiter.source(stranger) == nil)
    }

    @Test
    func aWatchWithTheTightestToleranceChangesNoStatusEventStaleCountOrLeaderOverLockSilenceAndTakeover() throws {
        let tight = try Self.jitterWatch(window: 40, tolerance: 1)
        let plain = try Self.jitterTranscript(try Self.jitterArbiter(watch: nil))
        let watched = try Self.jitterTranscript(try Self.jitterArbiter(watch: tight))
        #expect(plain.steps == watched.steps)
        let lockedSteps = watched.steps.filter { Self.jitterLockedWithTempo($0.status) }
        #expect(!lockedSteps.isEmpty)
        let allEvents = watched.steps.flatMap(\.events)
        let lockFlags = Self.jitterLockTempoFlags(allEvents)
        let finalLeader = MIDIClockLeader.external(Self.jitterB)
        #expect(lockFlags == [true, true, true])
        #expect(Self.jitterIdleCount(allEvents) == 1)
        #expect(watched.arbiter.leader == finalLeader)
        let reported = try Self.jitterMeasuredReport(watched.arbiter, Self.jitterB)
        #expect(reported.verdict == .exceeded)
        let leaderReport = try Self.jitterMeasuredReport(watched.arbiter, Self.jitterA)
        #expect(leaderReport.verdict == .exceeded)
    }

    @Test
    func selectingAnotherLeaderKeepsEverySourcesWindow() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch())
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: Self.jitterSteady(5))
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: Self.jitterSteady(3, start: 10_000_000))
        let before = arbiter.sources.map(\.jitter)
        _ = try arbiter.selectLeader(.external(Self.jitterB))
        let after = arbiter.sources.map(\.jitter)
        #expect(after == before)
        let kept = try Self.jitterMeasuredReport(arbiter, Self.jitterA)
        #expect(kept.summary.intervalCount == 4)
    }

    @Test
    func aSilenceGapReadsExceededUntilItLeavesTheWindowThenReadsWithinAgain() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch(window: 8))
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: Self.jitterSteady(5))
        let resume: UInt64 = 1_080_000_000
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: Self.jitterSteady(7, start: resume))
        let gap = try Self.jitterMeasuredReport(arbiter, Self.jitterA)
        let width: UInt64 = 1_000_000_000
        #expect(gap.summary.maximumInterval == width)
        #expect(gap.verdict == .exceeded)
        let next: UInt64 = resume + 140_000_000
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: [next])
        let recovered = try Self.jitterMeasuredReport(arbiter, Self.jitterA)
        #expect(recovered.summary.maximumInterval == 20_000_000)
        #expect(recovered.verdict == .withinTolerance)
    }

    @Test
    func eachSourceKeepsItsOwnWindowSoDifferentIntervalsGiveDifferentSummaries() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch())
        try Self.jitterFeed(&arbiter, from: Self.jitterA, at: Self.jitterSteady(5))
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: [0, 10_000_000, 20_000_000, 30_000_000, 40_000_000])
        let leader = try Self.jitterMeasuredReport(arbiter, Self.jitterA)
        let competing = try Self.jitterMeasuredReport(arbiter, Self.jitterB)
        #expect(leader.summary.intervalCount == 4)
        #expect(competing.summary.intervalCount == 4)
        #expect(leader.summary.maximumInterval == 20_000_000)
        #expect(competing.summary.maximumInterval == 10_000_000)
        #expect(leader.verdict == .withinTolerance)
        #expect(competing.verdict == .exceeded)
    }

    @Test
    func aRemovedAndReRegisteredSourceStartsWithAnEmptyWindow() throws {
        var arbiter = try Self.jitterArbiter(watch: try Self.jitterWatch())
        try Self.jitterFeed(&arbiter, from: Self.jitterB, at: Self.jitterSteady(4))
        let before = try Self.jitterMeasuredReport(arbiter, Self.jitterB)
        #expect(before.summary.intervalCount == 3)
        try arbiter.removeSource(Self.jitterB)
        #expect(arbiter.source(Self.jitterB) == nil)
        try arbiter.addSource(Self.jitterB)
        let again = try Self.jitterReport(arbiter, Self.jitterB)
        #expect(again == .collecting(stamps: 0))
    }
}
