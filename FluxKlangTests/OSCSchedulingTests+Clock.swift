import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The injected wall-to-host mapping: uncertainty and rate widen the window
/// outward, horizons compare exactly, and mapping changes re-resolve pending
/// batches with typed refusal events.
extension OSCSchedulingTests {
    @Test func mappingValidationIsBounded() throws {
        let limit = OSC.WallClockMapping.rateLimitPartsPerBillion
        #expect(try Fixture.mapping(rate: limit).ratePartsPerBillion == limit)
        #expect(try Fixture.mapping(rate: -limit).ratePartsPerBillion == -limit)
        #expect(throws: Refusal.rateOutOfRange(partsPerBillion: limit + 1)) { try Fixture.mapping(rate: limit + 1) }
        #expect(throws: Refusal.rateOutOfRange(partsPerBillion: -limit - 1)) { try Fixture.mapping(rate: -limit - 1) }
        #expect(try Fixture.mapping(rateUncertainty: limit).rateUncertaintyPartsPerBillion == limit)
        #expect(throws: Refusal.rateUncertaintyOutOfRange(partsPerBillion: -1)) {
            try Fixture.mapping(rateUncertainty: -1)
        }
        #expect(throws: Refusal.rateUncertaintyOutOfRange(partsPerBillion: limit + 1)) {
            try Fixture.mapping(rateUncertainty: limit + 1)
        }
        let most = OSC.WallClockMapping.maximumUncertaintyNanoseconds
        #expect(try Fixture.mapping(uncertainty: most).uncertaintyNanoseconds == most)
        #expect(throws: Refusal.uncertaintyOutOfRange(nanoseconds: most + 1)) {
            try Fixture.mapping(uncertainty: most + 1)
        }
    }

    @Test func schedulerRefusesDegenerateTimebases() throws {
        #expect(throws: Refusal.invalidTimebase(numer: 0, denom: 1)) {
            try Fixture.scheduler(timebase: HostTimebase(numer: 0, denom: 1))
        }
        #expect(throws: Refusal.invalidTimebase(numer: 1, denom: 0)) {
            try Fixture.scheduler(timebase: HostTimebase(numer: 1, denom: 0))
        }
        #expect(throws: Refusal.invalidTimebase(numer: 1, denom: 0)) {
            try Fixture.mapping().hostBounds(of: Fixture.wall(), timebase: HostTimebase(numer: 1, denom: 0))
        }
    }

    @Test func uncertaintyWidensBothSides() throws {
        let mapping = try Fixture.mapping(uncertainty: 1_000)
        let unit = try mapping.hostBounds(of: Fixture.instant(after: 2), timebase: Fixture.unitTimebase)
        #expect(Fixture.offsets(unit) == [1_999_999_000, 2_000_001_001])
        let apple = try mapping.hostBounds(of: Fixture.instant(after: 1), timebase: Fixture.appleTimebase)
        #expect(Fixture.offsets(apple) == [23_999_976, 24_000_025])
        let tight = try Fixture.mapping(uncertainty: 1)
        let sub = try tight.hostBounds(of: Fixture.instant(after: 1), timebase: Fixture.appleTimebase)
        #expect(Fixture.offsets(sub) == [23_999_999, 24_000_001])
    }

    /// Arguments: (rate, rate uncertainty) in ppb and the expected offsets two seconds out.
    @Test(arguments: zip(
        [(1_000, 0), (-1_000, 0), (0, 500), (1_000, 500)] as [(Int, Int)],
        [[2_000_002_000, 2_000_002_001], [1_999_998_000, 1_999_998_001], [1_999_999_000, 2_000_001_001],
         [2_000_001_000, 2_000_003_001]] as [[Int64]]
    ))
    func rateAndRateUncertaintyScaleTheDistanceFromTheAnchor(rates: (Int, Int), expected: [Int64]) throws {
        let mapping = try Fixture.mapping(rate: rates.0, rateUncertainty: rates.1)
        let bounds = try mapping.hostBounds(of: Fixture.instant(after: 2), timebase: Fixture.unitTimebase)
        #expect(Fixture.offsets(bounds) == expected)
    }

    @Test func rateUncertaintyWidensOutwardBeforeTheAnchor() throws {
        var scheduler = try Fixture.scheduler(mapping: Fixture.mapping(rateUncertainty: 1_000))
        let packet = try Fixture.timed(Fixture.tag(after: -1, fraction: 1 << 31), 0)
        let batch = try #require(try scheduler.admit(packet, now: Fixture.host(0)).first)
        #expect(Fixture.offsets(batch.window) == [-500_000_500, -499_999_499])
        #expect(batch.timing == .late(by: 499_999_499))
    }

    @Test(arguments: [(101, OSCSchedulingTimingCase.late(100)), (102, .refused)] as [(Int64, OSCSchedulingTimingCase)])
    func lateHorizonIsInclusive(now: Int64, expected: OSCSchedulingTimingCase) throws {
        let scheduler = try Fixture.scheduler(policy: Fixture.policy(late: 100))
        try expectAdmission(scheduler, now: now, expected: expected, refusal: Refusal.tooLate)
    }

    @Test(arguments: [(-100, OSCSchedulingTimingCase.late(0)), (-101, .refused)] as [(Int64, OSCSchedulingTimingCase)])
    func futureHorizonIsInclusive(now: Int64, expected: OSCSchedulingTimingCase) throws {
        let scheduler = try Fixture.scheduler(policy: Fixture.policy(future: 100))
        try expectAdmission(scheduler, now: now, expected: expected, refusal: Refusal.tooFarInFuture)
    }

    /// With 125/3 ns ticks a 100 ns horizon admits two ticks and refuses three;
    /// a 125 ns horizon is exactly three ticks and is still inclusive.
    @Test(arguments: zip(
        [(100, 3), (100, 4), (125, 4), (125, 5)] as [(UInt64, Int64)],
        [.late(2), .refused, .late(3), .refused] as [OSCSchedulingTimingCase]
    ))
    func appleTimebaseLateHorizonComparesExactly(
        edge: (horizon: UInt64, now: Int64), expected: OSCSchedulingTimingCase
    ) throws {
        let (horizon, now) = edge
        let policy = try Fixture.policy(late: horizon)
        let scheduler = try Fixture.scheduler(timebase: Fixture.appleTimebase, policy: policy)
        try expectAdmission(scheduler, now: now, expected: expected, refusal: Refusal.tooLate)
    }

    @Test(arguments: zip(
        [(125, -3), (125, -4), (124, -3)] as [(UInt64, Int64)],
        [.late(0), .refused, .refused] as [OSCSchedulingTimingCase]
    ))
    func appleTimebaseFutureHorizonComparesExactly(
        edge: (horizon: UInt64, now: Int64), expected: OSCSchedulingTimingCase
    ) throws {
        let (horizon, now) = edge
        let policy = try Fixture.policy(future: horizon)
        let scheduler = try Fixture.scheduler(timebase: Fixture.appleTimebase, policy: policy)
        try expectAdmission(scheduler, now: now, expected: expected, refusal: Refusal.tooFarInFuture)
    }

    @Test func zeroHorizonsAdmitOnlyWindowsContainingNow() throws {
        let scheduler = try Fixture.scheduler(policy: Fixture.policy(late: 0, future: 0))
        try expectAdmission(scheduler, now: 0, expected: .late(0), refusal: Refusal.tooLate)
        try expectAdmission(scheduler, now: 1, expected: .late(0), refusal: Refusal.tooLate)
        try expectAdmission(scheduler, now: 2, expected: .refused, refusal: Refusal.tooLate)
        try expectAdmission(scheduler, now: -1, expected: .refused, refusal: Refusal.tooFarInFuture)
    }

    @Test func forwardWallStepMovesPendingBatchesEarlier() throws {
        var scheduler = try Fixture.scheduler()
        let original = scheduler.mapping
        let first = try Fixture.single(&scheduler, Fixture.timed(Fixture.tag(after: 10), 1))
        let next = try Fixture.stepped(by: 1)
        let shift = try scheduler.updateMapping(next, now: Fixture.host(5))
        let moved = try #require(scheduler.pending.first)
        #expect(Fixture.offsets(moved.window) == [9 * Fixture.second, 9 * Fixture.second + 1])
        #expect(moved.id == first.id && moved.wall == first.wall && moved.timeTag == first.timeTag)
        let move = try #require(shift.moves.first)
        #expect(shift.moves.count == 1 && move.id == first.id && move.from == first.window && move.to == moved.window)
        #expect(shift.refused.isEmpty && shift.now == Fixture.host(5) && shift.current == next)
        #expect(shift.previous == original && scheduler.mapping == next && scheduler.lastClockShift == shift)
        #expect(scheduler.latestNow == Fixture.host(5))
    }

    @Test func backwardWallStepMovesPendingBatchesLater() throws {
        var scheduler = try Fixture.scheduler()
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 10), 0), now: Fixture.host(0))
        _ = try scheduler.updateMapping(Fixture.stepped(by: -1), now: Fixture.host(0))
        let window = try #require(scheduler.pending.first).window
        #expect(Fixture.offsets(window) == [11 * Fixture.second, 11 * Fixture.second + 1])
    }

    @Test func rateChangeRescalesPendingBatches() throws {
        var scheduler = try Fixture.scheduler()
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 10), 0), now: Fixture.host(0))
        _ = try scheduler.updateMapping(Fixture.mapping(rate: 1_000, rateUncertainty: 100), now: Fixture.host(0))
        let window = try #require(scheduler.pending.first).window
        #expect(Fixture.offsets(window) == [10_000_009_000, 10_000_011_001])
    }

    @Test func shiftRefusesBatchesItMakesTooLateOrTooFar() throws {
        var scheduler = try Fixture.scheduler()
        let early = Fixture.tag(after: 1)
        let late = Fixture.tag(after: 50)
        _ = try scheduler.admit(Fixture.timed(early, 1), now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 30), 2), now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.timed(late, 3), now: Fixture.host(0))
        let shift = try scheduler.updateMapping(Fixture.stepped(by: 3), now: Fixture.host(0))
        #expect(shift.refused.map(\.refusal) == [.tooLate(early)])
        #expect(Fixture.values(scheduler.pending.flatMap(\.messages)) == [2, 3] && scheduler.pendingMessageCount == 2)
        let second = try scheduler.updateMapping(Fixture.stepped(by: -20), now: Fixture.host(0))
        #expect(second.refused.map(\.refusal) == [.tooFarInFuture(late)])
        #expect(second.refused.map { Fixture.values($0.batch.messages) } == [[3]])
        #expect(Fixture.values(scheduler.pending.flatMap(\.messages)) == [2] && scheduler.pendingMessageCount == 1)
        #expect(second.moves.map(\.id) == scheduler.pending.map(\.id))
    }

    @Test func shiftRefusesBatchesItCannotRepresent() throws {
        let start = UInt64.max - 30 * UInt64(Fixture.second)
        var scheduler = try Fixture.scheduler(mapping: Fixture.mapping(host: start))
        let tag = Fixture.tag(after: 10)
        _ = try scheduler.admit(Fixture.timed(tag, 0), now: HostStamp(ticks: start))
        let next = try Fixture.mapping(host: start + 25 * UInt64(Fixture.second))
        let top = try scheduler.updateMapping(next, now: HostStamp(ticks: start))
        #expect(top.refused.map(\.refusal) == [.hostTimeOutOfRange(tag)] && scheduler.pendingMessageCount == 0)
    }

    /// A shift places the admitted wall instant on the new mapping and never
    /// re-resolves the raw tag: here re-resolving would flip it into the past era.
    @Test func shiftKeepsTheAdmittedInstant() throws {
        let edge = Int64(1 << 31)
        var scheduler = try Fixture.scheduler(policy: Fixture.policy(future: 10 * UInt64(Fixture.second)))
        let now = Fixture.host((edge - 5) * Fixture.second)
        let tag = Fixture.tag(after: edge - 1)
        let admitted = try #require(try scheduler.admit(Fixture.timed(tag, 0), now: now).first)
        #expect(admitted.wall == (try Fixture.wall(era: 1, seconds: tag.seconds)))
        let shift = try scheduler.updateMapping(Fixture.stepped(by: -2), now: now)
        let moved = try #require(scheduler.pending.first)
        #expect(shift.refused.isEmpty && moved.wall == admitted.wall && moved.timeTag == tag)
        #expect(Fixture.offsets(moved.window) == [(edge + 1) * Fixture.second, (edge + 1) * Fixture.second + 1])
    }

    @Test func immediateBatchesKeepTheirWindowAndMayBeOvertaken() throws {
        var scheduler = try Fixture.scheduler()
        let now = try #require(try scheduler.admit(Fixture.message(1), now: Fixture.host(5)).first)
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 0, fraction: 1 << 31), 2), now: Fixture.host(5))
        #expect(Fixture.values(scheduler.pending.flatMap(\.messages)) == [1, 2])
        let shift = try scheduler.updateMapping(Fixture.stepped(by: 1), now: Fixture.host(10))
        let move = try #require(shift.moves.first)
        #expect(move.id == now.id && move.from == now.window && move.to == now.window)
        #expect(Fixture.values(scheduler.pending.flatMap(\.messages)) == [2, 1])
        #expect(scheduler.pending.map(\.timing) == [.late(by: 500_000_009), .late(by: 5)])
    }

    @Test func shiftRefusesStaleImmediateBatches() throws {
        var scheduler = try Fixture.scheduler()
        _ = try scheduler.admit(Fixture.message(), now: Fixture.host(0))
        let shift = try scheduler.updateMapping(Fixture.mapping(), now: Fixture.host(Fixture.second + 1))
        #expect(shift.refused.map(\.refusal) == [.tooLate(.immediate)] && scheduler.pending.isEmpty)
    }

    @Test func shiftAcrossTheWrapKeepsEraAndOrder() throws {
        let mapping = try Fixture.mapping(wall: Fixture.wall(seconds: .max - 9))
        var scheduler = try Fixture.scheduler(mapping: mapping, policy: Fixture.policy(late: 10_000_000_000))
        _ = try scheduler.admit(Fixture.timed(OSC.TimeTag(seconds: 5, fraction: 0), 1), now: Fixture.host(0))
        _ = try scheduler.admit(Fixture.timed(OSC.TimeTag(seconds: .max - 4, fraction: 0), 2), now: Fixture.host(0))
        _ = try scheduler.updateMapping(Fixture.mapping(wall: Fixture.wall(era: 1, seconds: 0)), now: Fixture.host(0))
        #expect(scheduler.pending.map { $0.wall?.era } == [0, 1])
        let second = Fixture.second
        #expect(scheduler.pending.map { Fixture.offsets($0.window) } == [[-5 * second, -5 * second + 1],
                                                                         [5 * second, 5 * second + 1]])
    }

    @Test func injectedNowMustNotRegress() throws {
        var scheduler = try Fixture.scheduler()
        _ = try scheduler.admit(Fixture.timed(Fixture.tag(after: 1), 0), now: Fixture.host(10))
        let regressed = Refusal.nowRegressed(previous: Fixture.host(10), now: Fixture.host(9))
        #expect(Fixture.refusal(scheduler) { try $0.admit(Fixture.message(), now: Fixture.host(9)) } == regressed)
        #expect(Fixture.refusal(scheduler) { try $0.due(now: Fixture.host(9)) } == regressed)
        let mapping = try Fixture.mapping()
        #expect(Fixture.refusal(scheduler) { try $0.updateMapping(mapping, now: Fixture.host(9)) } == regressed)
        #expect(try scheduler.due(now: Fixture.host(10)).dispatch.isEmpty)
    }

    @Test func emptyShiftStillRecordsEvidence() throws {
        var scheduler = try Fixture.scheduler()
        #expect(scheduler.lastClockShift == nil && scheduler.latestNow == nil)
        let next = try Fixture.mapping(uncertainty: 5)
        let shift = try scheduler.updateMapping(next, now: Fixture.host(0))
        #expect(shift.moves.isEmpty && shift.refused.isEmpty && scheduler.lastClockShift == shift)
        #expect(scheduler.mapping == next)
    }

    /// Admits one `/go` message timed at the reference second, `now` ticks from the
    /// anchor, and checks the timing (`.late(0)` meaning on time) or the refusal
    /// `refusal(tag)` with the scheduler unchanged.
    private func expectAdmission(
        _ scheduler: OSC.BundleScheduler, now: Int64, expected: OSCSchedulingTimingCase,
        refusal: (OSC.TimeTag) -> Refusal, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let tag = Fixture.tag(after: 0)
        let packet = try Fixture.timed(tag, 0)
        switch expected {
        case .refused:
            let actual = Fixture.refusal(scheduler) { try $0.admit(packet, now: Fixture.host(now)) }
            #expect(actual == refusal(tag), sourceLocation: sourceLocation)
        case .late(let ticks):
            var copy = scheduler
            let batch = try Fixture.single(&copy, packet, at: now, sourceLocation: sourceLocation)
            #expect(batch.timing == (ticks == 0 ? .onTime : .late(by: ticks)), sourceLocation: sourceLocation)
        }
    }
}

/// Expected outcome of one admission at a horizon edge.
enum OSCSchedulingTimingCase: Sendable, Hashable, CustomTestStringConvertible {
    case late(UInt64)
    case refused

    var testDescription: String {
        switch self {
        case .late(let ticks): ticks == 0 ? "onTime" : "late(by: \(ticks))"
        case .refused: "refused"
        }
    }
}
