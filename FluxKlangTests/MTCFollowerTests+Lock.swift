import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MTCFollowerTests {
    private static let spacing: UInt64 = 1_000

    /// Plain pieces (nibble 0) in the given order, stamped consecutively from `start`.
    private static func plainPieces(_ numbers: [UInt8], start: UInt64) throws -> [Stamped] {
        try numbers.enumerated().map { (frame: try MTCQuarterFrame(piece: $0.element, nibble: 0),
                                        ticks: start + UInt64($0.offset) * spacing) }
    }

    @Test func lockPositionsOneTwoAndEightLockOnExactlyThatPosition() throws {
        for lock in [1, 2, 8] {
            var subject = try Self.follower(Self.policy(lock: lock))
            for (index, sequence) in try Self.stream(rate: .fps25, count: lock).enumerated() {
                let events = try Self.feed(&subject, sequence)
                if index + 1 < lock {
                    #expect(events.isEmpty)
                    #expect(subject.state == .acquiring)
                    #expect(subject.consecutivePositions == index + 1)
                } else {
                    #expect(events == [.locked(frameCount: 1000 + 2 * index + 2)])
                    #expect(subject.state == .locked)
                }
            }
        }
    }

    @Test func eightPiecesGiveTheEncodedTimePlusOrMinusTwoFramesForEveryRateAndDirection() throws {
        for rate in SMPTEFrameRate.allCases {
            for direction in [MTCDirection.forward, .reverse] {
                let offset = direction == .forward ? 2 : -2
                let result = try Self.locked(rate: rate, direction: direction, positions: 1, firstEncoded: 3000,
                                             policy: Self.policy(lock: 1))
                #expect(result.events == [.locked(frameCount: 3000 + offset)])
                #expect(result.follower.direction == direction)
                #expect(result.follower.rate == rate)
                #expect(try result.follower.frameCount(at: Self.stamp(result.last)) == 3000 + offset)
            }
        }
    }

    @Test func positionsAcrossMidnightAreContinuousInBothDirections() throws {
        for rate in SMPTEFrameRate.allCases {
            let day = rate.framesPerDay
            var forward = try Self.follower(Self.policy(lock: 3))
            let wrapForward = try Self.stream(rate: rate, firstEncoded: day - 4, count: 3)
            #expect(try Self.feed(&forward, wrapForward) == [.locked(frameCount: 2)])
            var reverse = try Self.follower(Self.policy(lock: 3))
            let wrapReverse = try Self.stream(rate: rate, direction: .reverse, firstEncoded: 4, count: 3)
            #expect(try Self.feed(&reverse, wrapReverse) == [.locked(frameCount: day - 2)])
        }
    }

    @Test func toleranceNAcceptsAndNPlusOneRelocatesInBothSigns() throws {
        for tolerance in [0, 1, 4] {
            for sign in [1, -1] {
                for (offset, accepted) in [(tolerance, true), (tolerance + 1, false)] {
                    var subject = try Self.follower(Self.policy(tolerance: tolerance))
                    let frameTicks = Self.ticksPerFrame(.fps25)
                    try Self.feed(&subject, Self.sequence(encoded: 1000, rate: .fps25))
                    let skewed = 1002 + sign * offset
                    let second = try Self.sequence(encoded: skewed, rate: .fps25,
                                                   start: Self.streamStart + 2 * frameTicks)
                    let events = try Self.feed(&subject, second)
                    if accepted {
                        #expect(events == [.locked(frameCount: skewed + 2)])
                        #expect(subject.state == .locked)
                    } else {
                        #expect(events == [.relocated(frameCount: skewed + 2)])
                        #expect(subject.state == .acquiring)
                        #expect(subject.consecutivePositions == 1)
                    }
                }
            }
        }
    }

    @Test func aRelocationRestartsAcquisitionAndTheNextContinuousPositionLocks() throws {
        var subject = try Self.follower()
        let frameTicks = Self.ticksPerFrame(.fps25)
        try Self.feed(&subject, Self.sequence(encoded: 1000, rate: .fps25))
        let jump = try Self.sequence(encoded: 5000, rate: .fps25, start: Self.streamStart + 2 * frameTicks)
        #expect(try Self.feed(&subject, jump) == [.relocated(frameCount: 5002)])
        let next = try Self.sequence(encoded: 5002, rate: .fps25, start: Self.streamStart + 4 * frameTicks)
        #expect(try Self.feed(&subject, next) == [.locked(frameCount: 5004)])
    }

    @Test func aRelocationWhileLockedDropsTheLockUntilTheNextPositionsAgree() throws {
        var result = try Self.locked(rate: .fps25, positions: 2, firstEncoded: 1000)
        #expect(result.follower.state == .locked)
        let frameTicks = Self.ticksPerFrame(.fps25)
        let start = result.last - 7 * frameTicks / 4 + 2 * frameTicks
        let jump = try Self.sequence(encoded: 9000, rate: .fps25, start: start)
        #expect(try Self.feed(&result.follower, jump) == [.relocated(frameCount: 9002)])
        #expect(result.follower.state == .acquiring)
        #expect(result.follower.consecutivePositions == 1)
        let next = try Self.sequence(encoded: 9002, rate: .fps25, start: start + 2 * frameTicks)
        #expect(try Self.feed(&result.follower, next) == [.locked(frameCount: 9004)])
    }

    @Test func distanceIsModularOverTheDayInBothDirections() throws {
        let day = SMPTEFrameRate.fps25.framesPerDay
        let frameTicks = Self.ticksPerFrame(.fps25)
        // Expected current day - 1, actual 0 (one frame past midnight); and expected 0, actual day - 1.
        for (first, skew) in [(day - 5, 1), (day - 4, -1)] {
            var subject = try Self.follower()
            try Self.feed(&subject, Self.sequence(encoded: first, rate: .fps25))
            let second = try Self.sequence(encoded: first + 2 + skew, rate: .fps25,
                                           start: Self.streamStart + 2 * frameTicks)
            let events = try Self.feed(&subject, second)
            #expect(events == [.locked(frameCount: Self.wrapped(first + 2 + skew + 2, .fps25))])
        }
    }

    @Test func aDirectionFlipRestartsAcquisitionAtCountOne() throws {
        var result = try Self.locked(rate: .fps25, positions: 2, firstEncoded: 1000)
        let frameTicks = Self.ticksPerFrame(.fps25)
        let start = result.last + frameTicks
        let first = try Self.sequence(encoded: 1004, rate: .fps25, direction: .reverse, start: start)
        let events = try Self.feed(&result.follower, first)
        #expect(events == [.directionChanged(from: .forward, to: .reverse)])
        #expect(result.follower.state == .acquiring)
        #expect(result.follower.consecutivePositions == 1)
        #expect(result.follower.direction == .reverse)
        let second = try Self.sequence(encoded: 1002, rate: .fps25, direction: .reverse,
                                       start: start + 2 * frameTicks)
        #expect(try Self.feed(&result.follower, second) == [.locked(frameCount: 1000)])
    }

    @Test func aRateChangeRestartsAcquisitionWithoutARelocation() throws {
        var result = try Self.locked(rate: .fps25, positions: 2, firstEncoded: 1000)
        let start = result.last + 1_000_000
        let first = try Self.sequence(encoded: 1200, rate: .fps30, start: start)
        #expect(try Self.feed(&result.follower, first) == [.rateChanged(from: .fps25, to: .fps30)])
        #expect(result.follower.state == .acquiring)
        #expect(result.follower.consecutivePositions == 1)
        #expect(result.follower.rate == .fps30)
        let second = try Self.sequence(encoded: 1202, rate: .fps30,
                                       start: start + 2 * Self.ticksPerFrame(.fps30))
        #expect(try Self.feed(&result.follower, second) == [.locked(frameCount: 1204)])
    }

    @Test func aDirectionAndRateChangeTogetherReportBothInOrder() throws {
        var result = try Self.locked(rate: .fps25, positions: 2, firstEncoded: 1000)
        let first = try Self.sequence(encoded: 1200, rate: .fps24, direction: .reverse, start: result.last + 1_000_000)
        #expect(try Self.feed(&result.follower, first) == [
            .directionChanged(from: .forward, to: .reverse), .rateChanged(from: .fps25, to: .fps24)
        ])
    }

    @Test func aGapDropsTheLockToCountZeroAndTheNextPositionsRelock() throws {
        var result = try Self.locked(rate: .fps25, positions: 2, firstEncoded: 1000)
        let start = result.last + 100_000
        let broken = try Self.plainPieces([0, 1, 2, 4], start: start)
        let events = try Self.feed(&result.follower, broken)
        #expect(events == [.pieceDiscarded(.gap(expected: 3, received: 4))])
        #expect(result.follower.state == .acquiring)
        #expect(result.follower.consecutivePositions == 0)
        #expect(result.follower.counters.discards == 1)
        let fresh = try Self.stream(rate: .fps25, firstEncoded: 1008, count: 2, start: start + 5_000)
        #expect(try Self.feed(&result.follower, fresh) == [.locked(frameCount: 1012)])
    }

    @Test func everyAssemblerDiagnosticBecomesAPieceDiscardedEvent() throws {
        var unsynchronized = try Self.follower()
        let lone = try Self.plainPieces([3], start: 10)
        #expect(try Self.feed(&unsynchronized, lone) == [.pieceDiscarded(.unsynchronized(piece: 3))])
        #expect(unsynchronized.state == .acquiring)

        var direction = try Self.follower()
        let backwards = try Self.plainPieces([0, 1, 0], start: 10)
        #expect(try Self.feed(&direction, backwards) == [.pieceDiscarded(.directionChange(from: .forward))])

        var invalid = try Self.follower()
        let nibbles: [UInt8] = [0, 0, 0, 0, 0x0C, 0x03, 0, 0x02]
        let pieces = try nibbles.enumerated().map {
            (frame: try MTCQuarterFrame(piece: UInt8($0.offset), nibble: $0.element), ticks: UInt64($0.offset))
        }
        let expected = TimecodeError.fieldOutOfRange(.minutes, value: 60)
        #expect(try Self.feed(&invalid, pieces) == [.pieceDiscarded(.invalidTime(expected))])
        #expect(invalid.consecutivePositions == 0)
        #expect(invalid.counters.discards == 1)
        #expect(invalid.state == .acquiring)
    }

    @Test func aLockedFollowerReportsLockedOnlyOnce() throws {
        var subject = try Self.follower()
        let events = try Self.feed(&subject, Self.stream(rate: .fps30, count: 6))
        #expect(events == [.locked(frameCount: 1004)])
        #expect(subject.consecutivePositions == 2)
        #expect(subject.counters == MTCFollowerCounters())
    }

    // MARK: Discards keep judging direction and rate; relocation needs continuity

    /// A locked forward 25 fps follower, a lone piece that is discarded, then one complete sequence.
    private struct Discarded {
        var follower: MTCFollower
        let events: [Event]
        let start: UInt64
    }

    private static func discardThenSequence(rate: SMPTEFrameRate, direction: MTCDirection) throws -> Discarded {
        var result = try Self.locked(rate: .fps25, positions: 2, firstEncoded: 1000)
        let lone = try Self.plainPieces([3], start: result.last + 1_000)
        #expect(try Self.feed(&result.follower, lone) == [.pieceDiscarded(.unsynchronized(piece: 3))])
        #expect(result.follower.state == .acquiring)
        #expect(result.follower.consecutivePositions == 0)
        let start = result.last + 10_000_000
        let sequence = try Self.sequence(encoded: 4000, rate: rate, direction: direction, start: start)
        let events = try Self.feed(&result.follower, sequence)
        return Discarded(follower: result.follower, events: events, start: start)
    }

    @Test func afterADiscardAReverseThirtyFpsPositionReportsBothChangesAndNeedsTheLockCountAgain() throws {
        var outcome = try Self.discardThenSequence(rate: .fps30, direction: .reverse)
        #expect(outcome.events == [
            .directionChanged(from: .forward, to: .reverse), .rateChanged(from: .fps25, to: .fps30)
        ])
        #expect(outcome.follower.state == .acquiring)
        #expect(outcome.follower.consecutivePositions == 1)
        #expect(outcome.follower.direction == .reverse)
        let next = try Self.sequence(encoded: 3998, rate: .fps30, direction: .reverse,
                                     start: outcome.start + 2 * Self.ticksPerFrame(.fps30))
        #expect(try Self.feed(&outcome.follower, next) == [.locked(frameCount: 3996)])
    }

    @Test func afterADiscardADirectionOnlyChangeAndARateOnlyChangeAreEachReported() throws {
        let direction = try Self.discardThenSequence(rate: .fps25, direction: .reverse)
        #expect(direction.events == [.directionChanged(from: .forward, to: .reverse)])
        #expect(direction.follower.state == .acquiring)
        #expect(direction.follower.consecutivePositions == 1)
        let rate = try Self.discardThenSequence(rate: .fps30, direction: .forward)
        #expect(rate.events == [.rateChanged(from: .fps25, to: .fps30)])
        #expect(rate.follower.state == .acquiring)
        #expect(rate.follower.consecutivePositions == 1)
    }

    @Test func afterADiscardARelocatedPositionOfTheSameDirectionAndRateIsNotJudgedAsRelocated() throws {
        let outcome = try Self.discardThenSequence(rate: .fps25, direction: .forward)
        #expect(outcome.events.isEmpty)
        #expect(outcome.follower.state == .acquiring)
        #expect(outcome.follower.consecutivePositions == 1)
        #expect(outcome.follower.counters.discards == 1)
    }

    // MARK: Relocation tolerates the rounding of individually stamped quarter frames

    private static let coarseMicrosecondTimebase = HostTimebase(numer: 1_000, denom: 1)

    private enum Rounding { case floor, nearest, ceil }

    /// Eight sequences whose quarter frames are stamped at `k * quarter`, each stamp rounded alone to a whole tick.
    private static func quantizedStream(rate: SMPTEFrameRate, direction: MTCDirection, timebase: HostTimebase,
                                        rounding: Rounding) throws -> [[Stamped]] {
        let real = MTCRealRate(rate)
        let step = direction == .forward ? 2 : -2
        return try (0..<8).map { index in
            let pieces = try sequence(encoded: 1000 + step * index, rate: rate, direction: direction).map(\.frame)
            return pieces.enumerated().map { piece in
                let quarters = UInt64(8 * index + piece.offset)
                let numerator = quarters * UInt64(real.denominator) * 1_000_000_000 * UInt64(timebase.denom)
                let denominator = 4 * UInt64(real.numerator) * UInt64(timebase.numer)
                let ticks = switch rounding {
                case .floor: numerator / denominator
                case .nearest: (2 * numerator + denominator) / (2 * denominator)
                case .ceil: (numerator + denominator - 1) / denominator
                }
                return (frame: piece.element, ticks: streamStart + ticks)
            }
        }
    }

    private struct LockedFrames {
        let policy: MTCFollowerPolicy
        let forward: Int
        let reverse: Int
    }

    @Test func aTimebaseJustFinerThanTheLimitStillLocksIdealRoundedStreamsWithoutAnyRelocation() throws {
        let boundary = HostTimebase(numer: 16_666_666, denom: 1)
        let expectations = [
            LockedFrames(policy: try Self.policy(lock: 8, tolerance: 0), forward: 1016, reverse: 984),
            LockedFrames(policy: .standard, forward: 1004, reverse: 996)
        ]
        for rate in [SMPTEFrameRate.fps24, .fps25, .fps30, .fps2997DropFrame] {
            for direction in [MTCDirection.forward, .reverse] {
                for rounding in [Rounding.floor, .nearest, .ceil] {
                    for expectation in expectations {
                        let sequences = try Self.quantizedStream(rate: rate, direction: direction,
                                                                 timebase: boundary, rounding: rounding)
                        var subject = try Self.follower(expectation.policy, timebase: boundary)
                        let events = try Self.feed(&subject, sequences)
                        let locked = direction == .forward ? expectation.forward : expectation.reverse
                        #expect(events == [.locked(frameCount: locked)])
                        #expect(subject.state == .locked)
                    }
                }
            }
        }
    }

    @Test func individuallyRoundedIdealStreamsLockAfterEightPositionsWithoutAnyRelocationAtToleranceZero() throws {
        let timebases = [Self.nanosecondTimebase, Self.appleTimebase, Self.coarseMicrosecondTimebase]
        for rate in SMPTEFrameRate.allCases {
            for timebase in timebases {
                for direction in [MTCDirection.forward, .reverse] {
                    for nearest in [false, true] {
                        let sequences = try Self.quantizedStream(
                            rate: rate, direction: direction, timebase: timebase, rounding: nearest ? .nearest : .floor)
                        var subject = try Self.follower(Self.policy(lock: 8, tolerance: 0), timebase: timebase)
                        let events = try Self.feed(&subject, sequences)
                        let last = direction == .forward ? 1016 : 984
                        #expect(events == [.locked(frameCount: last)])
                        #expect(subject.state == .locked)
                    }
                }
            }
        }
    }

    /// Two 25 fps sequences on a 1 ns timebase whose completing pieces are `elapsed` ticks apart.
    private static func twoPositions(elapsed: UInt64, second: Int,
                                     direction: MTCDirection) throws -> [Event] {
        var subject = try Self.follower(Self.policy(lock: 8, tolerance: 0), timebase: Self.nanosecondTimebase)
        let first = try Self.sequence(encoded: 1000, rate: .fps25, direction: direction,
                                      start: Self.streamStart, ticksPerFrame: 40_000_000)
        let next = try Self.sequence(encoded: second, rate: .fps25, direction: direction,
                                     start: Self.streamStart + elapsed, ticksPerFrame: 40_000_000)
        return try Self.feed(&subject, [first, next])
    }

    @Test func theRelocationSlackIsExactlyOneTickAroundTwoFramesOfElapsedTime() throws {
        let twoFrames: UInt64 = 80_000_000
        for direction in [MTCDirection.forward, .reverse] {
            let encoded = direction == .forward ? 1002 : 998
            let moved = direction == .forward ? 1004 : 996
            #expect(try Self.twoPositions(elapsed: twoFrames, second: encoded, direction: direction).isEmpty)
            #expect(try Self.twoPositions(elapsed: twoFrames - 1, second: encoded, direction: direction).isEmpty)
            let events = try Self.twoPositions(elapsed: twoFrames - 2, second: encoded, direction: direction)
            #expect(events == [.relocated(frameCount: moved)])
        }
    }

    @Test func aGenuineOneFrameRelocationOfAContinuousStreamIsStillFlaggedAtToleranceZero() throws {
        for direction in [MTCDirection.forward, .reverse] {
            let sign = direction == .forward ? 1 : -1
            for offset in [1, -1] {
                let second = 1000 + sign * 2 + offset
                let events = try Self.twoPositions(elapsed: 80_000_000, second: second, direction: direction)
                #expect(events == [.relocated(frameCount: second + sign * 2)])
            }
        }
    }
}
