import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MTCFollowerTests {
    /// Ticks of a 1 s freewheel under `exactTimebase` (a tick is a third of a nanosecond).
    private static let freewheelTicks: UInt64 = 3_000_000_000

    @discardableResult
    private static func poll(_ follower: inout MTCFollower, _ ticks: UInt64) throws -> [MTCFollowerEvent] {
        try follower.poll(at: Self.stamp(ticks))
    }

    @Test func silenceOfExactlyTheDropoutDurationIsNoDropoutAndOneTickMoreStartsFreewheel() throws {
        for rate in SMPTEFrameRate.allCases {
            var result = try Self.locked(rate: rate)
            let threshold = 2 * Self.ticksPerFrame(rate)
            #expect(try Self.poll(&result.follower, result.last + threshold).isEmpty)
            #expect(result.follower.state == .locked)
            #expect(try Self.poll(&result.follower, result.last + threshold + 1) == [.freewheelStarted])
            #expect(result.follower.state == .freewheeling)
            #expect(result.follower.counters.dropouts == 1)
            #expect(try Self.poll(&result.follower, result.last + threshold + 2).isEmpty)
            #expect(result.follower.counters.dropouts == 1)
        }
    }

    @Test func freewheelContinuesAtTheExactRealRate() throws {
        for rate in SMPTEFrameRate.allCases {
            var result = try Self.locked(rate: rate)
            let frameTicks = Self.ticksPerFrame(rate)
            try Self.poll(&result.follower, result.last + 2 * frameTicks + 1)
            #expect(result.follower.state == .freewheeling)
            for frames in [1, 2, 3, 29, 30] {
                let boundary = result.last + UInt64(frames) * frameTicks
                #expect(try result.follower.frameCount(at: Self.stamp(boundary - 1)) == result.current + frames - 1)
                #expect(try result.follower.frameCount(at: Self.stamp(boundary)) == result.current + frames)
            }
        }
    }

    @Test func freewheelEndsLostExactlyAfterTheFreewheelDurationPastTheDropout() throws {
        var result = try Self.locked()
        let threshold = 2 * Self.ticksPerFrame(.fps25)
        try Self.poll(&result.follower, result.last + threshold + 1)
        #expect(try Self.poll(&result.follower, result.last + threshold + Self.freewheelTicks).isEmpty)
        #expect(result.follower.state == .freewheeling)
        #expect(try Self.poll(&result.follower, result.last + threshold + Self.freewheelTicks + 1) == [.lost])
        #expect(result.follower.state == .lost)
        #expect(result.follower.counters.losses == 1)
        #expect(try Self.poll(&result.follower, result.last + threshold + Self.freewheelTicks + 2).isEmpty)
        #expect(Self.thrown { try result.follower.frameCount(at: Self.stamp(result.last)) } == .noPosition)
        #expect(Self.thrown { try result.follower.host(forFrameCount: result.current + 1) } == .noPosition)
    }

    @Test func bothThresholdsPassedInOneCallReportFreewheelStartedThenLost() throws {
        var result = try Self.locked()
        let lostAt = result.last + 2 * Self.ticksPerFrame(.fps25) + Self.freewheelTicks
        #expect(try Self.poll(&result.follower, lostAt + 1) == [.freewheelStarted, .lost])
        #expect(result.follower.counters.dropouts == 1)
        #expect(result.follower.counters.losses == 1)
    }

    @Test func dropoutFramesScaleTheThresholdAtBothEnds() throws {
        for dropout in [1, 30] {
            var result = try Self.locked(policy: Self.policy(dropout: dropout))
            let threshold = UInt64(dropout) * Self.ticksPerFrame(.fps25)
            #expect(try Self.poll(&result.follower, result.last + threshold).isEmpty)
            #expect(try Self.poll(&result.follower, result.last + threshold + 1) == [.freewheelStarted])
        }
    }

    @Test func freewheelNanosecondsScaleTheLostThresholdAtBothEnds() throws {
        let threshold = 2 * Self.ticksPerFrame(.fps25)
        for (nanoseconds, ticks) in [(Int64(1_000_000), UInt64(3_000_000)), (60_000_000_000, 180_000_000_000)] {
            var result = try Self.locked(policy: Self.policy(freewheel: nanoseconds))
            #expect(try Self.poll(&result.follower, result.last + threshold + ticks) == [.freewheelStarted])
            #expect(result.follower.state == .freewheeling)
            #expect(try Self.poll(&result.follower, result.last + threshold + ticks + 1) == [.lost])
        }
    }

    @Test func thresholdsRoundUpToTheFirstTickAtOrAfterTheRealDuration() throws {
        // 25 fps at 7 ns per tick: two frames are 11,428,571.43 ticks, so the threshold is 11,428,572.
        var result = try Self.locked(timebase: HostTimebase(numer: 7, denom: 1), ticksPerFrame: 5_714_286)
        #expect(result.follower.state == .locked)
        #expect(try Self.poll(&result.follower, result.last + 11_428_571).isEmpty)
        #expect(try Self.poll(&result.follower, result.last + 11_428_572).isEmpty)
        #expect(try Self.poll(&result.follower, result.last + 11_428_573) == [.freewheelStarted])
    }

    @Test func freewheelRunsBackwardsForAReverseStream() throws {
        for rate in SMPTEFrameRate.allCases {
            var result = try Self.locked(rate: rate, direction: .reverse, firstEncoded: 5000)
            let frameTicks = Self.ticksPerFrame(rate)
            try Self.poll(&result.follower, result.last + 2 * frameTicks + 1)
            #expect(result.follower.state == .freewheeling)
            for frames in [1, 2, 31] {
                let boundary = Self.stamp(result.last + UInt64(frames) * frameTicks)
                #expect(try result.follower.frameCount(at: boundary) == result.current - frames)
            }
        }
    }

    @Test func aFollowerDemotedByARelocationGoesStraightToLostWhenItFallsSilent() throws {
        var result = try Self.locked()
        let frameTicks = Self.ticksPerFrame(.fps25)
        let jump = try Self.sequence(encoded: 9000, rate: .fps25, start: result.last + frameTicks)
        try Self.feed(&result.follower, jump)
        #expect(result.follower.state == .acquiring)
        let silent = jump[7].ticks + 2 * frameTicks
        #expect(try Self.poll(&result.follower, silent).isEmpty)
        #expect(try Self.poll(&result.follower, silent + 1) == [.lost])
        #expect(result.follower.counters.dropouts == 0)
    }

    @Test func theFreewheelDurationRoundsUpToTheFirstTickToo() throws {
        // 1 s at 7 ns per tick is 142,857,142.86 ticks: lost needs the 142,857,143rd tick of freewheel to pass.
        var result = try Self.locked(timebase: HostTimebase(numer: 7, denom: 1), ticksPerFrame: 5_714_286)
        let dropoutAt = result.last + 11_428_572
        #expect(try Self.poll(&result.follower, dropoutAt + 1) == [.freewheelStarted])
        #expect(try Self.poll(&result.follower, dropoutAt + 142_857_143).isEmpty)
        #expect(try Self.poll(&result.follower, dropoutAt + 142_857_144) == [.lost])
    }

    @Test func aFollowerThatNeverLockedGoesStraightToLostAfterTheDropoutDuration() throws {
        var subject = try Self.follower()
        let first = try Self.sequence(encoded: 1000, rate: .fps25)
        try Self.feed(&subject, first)
        let last = first[7].ticks
        let threshold = 2 * Self.ticksPerFrame(.fps25)
        #expect(subject.state == .acquiring)
        #expect(try Self.poll(&subject, last + threshold).isEmpty)
        #expect(try Self.poll(&subject, last + threshold + 1) == [.lost])
        #expect(subject.state == .lost)
        #expect(subject.counters.dropouts == 0)
        #expect(subject.counters.losses == 1)
    }

    @Test func withoutAKnownRateTheSlowestFrameDurationSetsTheThreshold() throws {
        var subject = try Self.follower()
        let lone = try MTCQuarterFrame(piece: 3, nibble: 0)
        try subject.consume(lone, at: Self.stamp(1_000))
        #expect(subject.rate == nil)
        let threshold = 2 * Self.ticksPerFrame(.fps24)
        #expect(try Self.poll(&subject, 1_000 + threshold).isEmpty)
        #expect(try Self.poll(&subject, 1_000 + threshold + 1) == [.lost])
    }

    @Test func aQuarterFrameAfterLostReacquiresThenLocksInOrder() throws {
        for lock in [1, 2] {
            var result = try Self.locked(positions: lock, policy: Self.policy(lock: lock))
            let lostAt = result.last + 2 * Self.ticksPerFrame(.fps25) + Self.freewheelTicks
            #expect(try Self.poll(&result.follower, lostAt + 1) == [.freewheelStarted, .lost])
            let start = lostAt + 1_000_000
            let sequences = try Self.stream(rate: .fps25, firstEncoded: 7000, count: lock, start: start)
            #expect(try result.follower.consume(sequences[0][0].frame, at: Self.stamp(sequences[0][0].ticks))
                    == [.reacquired])
            #expect(result.follower.state == .acquiring)
            #expect(Self.thrown { try result.follower.frameCount(at: Self.stamp(start)) } == .noPosition)
            var rest = Array(sequences[0].dropFirst())
            for later in sequences.dropFirst() { rest += later }
            #expect(try Self.feed(&result.follower, rest) == [.locked(frameCount: 7002 + 2 * (lock - 1))])
            #expect(result.follower.state == .locked)
        }
    }

    @Test func aQuarterFrameAfterFreewheelReportsReacquiredWithoutLost() throws {
        var result = try Self.locked()
        let dropoutAt = result.last + 2 * Self.ticksPerFrame(.fps25)
        try Self.poll(&result.follower, dropoutAt + 1)
        let sequence = try Self.sequence(encoded: 1500, rate: .fps25, start: dropoutAt + 2)
        let events = try result.follower.consume(sequence[0].frame, at: Self.stamp(sequence[0].ticks))
        #expect(events == [.reacquired])
        #expect(result.follower.state == .acquiring)
        #expect(result.follower.consecutivePositions == 0)
        #expect(Self.thrown { try result.follower.frameCount(at: Self.stamp(dropoutAt + 2)) } == .noPosition)
    }

    @Test func silenceEventsPrecedeReacquiredWithinOneCall() throws {
        var result = try Self.locked()
        let lostAt = result.last + 2 * Self.ticksPerFrame(.fps25) + Self.freewheelTicks
        let sequence = try Self.sequence(encoded: 1500, rate: .fps25, start: lostAt + 1)
        let events = try result.follower.consume(sequence[0].frame, at: Self.stamp(sequence[0].ticks))
        #expect(events == [.freewheelStarted, .lost, .reacquired])
    }

    @Test func aPartialSequenceDoesNotSurviveADropout() throws {
        var result = try Self.locked()
        let frameTicks = Self.ticksPerFrame(.fps25)
        let sequence = try Self.sequence(encoded: 1004, rate: .fps25, start: result.last + frameTicks / 2)
        try Self.feed(&result.follower, Array(sequence.prefix(4)))
        let stale = sequence[3].ticks
        #expect(try Self.poll(&result.follower, stale + 2 * frameTicks + 1) == [.freewheelStarted])
        let events = try result.follower.consume(sequence[4].frame, at: Self.stamp(stale + 2 * frameTicks + 2))
        #expect(events == [.reacquired, .pieceDiscarded(.unsynchronized(piece: 4))])
    }

    @Test func aLocateAfterSilenceReportsTheSilenceEventsFirst() throws {
        var result = try Self.locked()
        let lostAt = result.last + 2 * Self.ticksPerFrame(.fps25) + Self.freewheelTicks
        let event = try Self.fullFrame(Self.label(900, .fps25))
        let events = try result.follower.consume(fullFrame: event, receiver: Self.receiver,
                                                 at: Self.stamp(lostAt + 1))
        #expect(events == [.freewheelStarted, .lost, .located(frameCount: 900)])
        #expect(result.follower.state == .located)
    }

    @Test func freewheelIsMeasuredFromTheLastQuarterFrameNotTheLastPoll() throws {
        var result = try Self.locked()
        let threshold = 2 * Self.ticksPerFrame(.fps25)
        #expect(try Self.poll(&result.follower, result.last + threshold - 100).isEmpty)
        #expect(try Self.poll(&result.follower, result.last + threshold).isEmpty)
        #expect(try Self.poll(&result.follower, result.last + threshold + 1) == [.freewheelStarted])
    }

    @Test func batchedPiecesWithEqualStampsAreAccepted() throws {
        var subject = try Self.follower(Self.policy(lock: 1))
        let batch = try Self.sequence(encoded: 1000, rate: .fps25).map { (frame: $0.frame, ticks: UInt64(5_000)) }
        #expect(try Self.feed(&subject, batch) == [.locked(frameCount: 1002)])
        #expect(try Self.poll(&subject, 5_000).isEmpty)
    }

    @Test func aRegressedStampIsRefusedByEveryEntryPointAndChangesNothing() throws {
        var result = try Self.locked()
        let before = result.follower.snapshot
        let earlier = Self.stamp(result.last - 1)
        let regressed = MTCFollowerError.hostTimeRegressed(last: result.last, received: result.last - 1)
        let piece = try MTCQuarterFrame(piece: 0, nibble: 0)
        #expect(Self.thrown { try result.follower.consume(piece, at: earlier) } == regressed)
        #expect(Self.thrown { try result.follower.poll(at: earlier) } == regressed)
        let valid = try Self.fullFrame(Self.label(10, .fps25))
        let other = try Self.fullFrame(Self.label(10, .fps25), device: 0x11)
        let malformed = MIDI1Event.sysEx(payload: [1])
        for event in [valid, other, malformed] {
            #expect(Self.thrown { try result.follower.consume(fullFrame: event, receiver: Self.receiver,
                                                              at: earlier) } == regressed)
        }
        #expect(result.follower.snapshot == before)
    }

    @Test func aPollAdvancesTheAcceptedStampSoAnEarlierMessageIsRefused() throws {
        var result = try Self.locked()
        try Self.poll(&result.follower, result.last + 500)
        let piece = try MTCQuarterFrame(piece: 0, nibble: 0)
        let refusal = Self.thrown { try result.follower.consume(piece, at: Self.stamp(result.last + 499)) }
        #expect(refusal == .hostTimeRegressed(last: result.last + 500, received: result.last + 499))
        #expect(try result.follower.consume(piece, at: Self.stamp(result.last + 500)).isEmpty)
    }

    @Test func aRefusalLeavesTheAssemblerProgressUnchanged() throws {
        let sequence = try Self.sequence(encoded: 1000, rate: .fps25)
        var refused = try Self.follower(Self.policy(lock: 1))
        var control = try Self.follower(Self.policy(lock: 1))
        try Self.feed(&refused, Array(sequence.prefix(4)))
        try Self.feed(&control, Array(sequence.prefix(4)))
        #expect(Self.thrown { try refused.consume(sequence[4].frame, at: Self.stamp(sequence[3].ticks - 1)) } != nil)
        #expect(refused.snapshot == control.snapshot)
        let rest = Array(sequence.dropFirst(4))
        #expect(try Self.feed(&refused, rest) == [.locked(frameCount: 1002)])
        #expect(try Self.feed(&control, rest) == [.locked(frameCount: 1002)])
        #expect(refused.snapshot == control.snapshot)
    }

    @Test func anAbsentFollowerPolledForeverStaysAbsentWithoutError() throws {
        var subject = try Self.follower()
        let before = subject.snapshot
        for step in 0..<2_000 {
            #expect(try Self.poll(&subject, UInt64(step) * 1_000_000_000_000).isEmpty)
        }
        #expect(try Self.poll(&subject, UInt64.max).isEmpty)
        #expect(subject.state == .absent)
        var expected = before
        expected.lastStamp = UInt64.max
        #expect(subject.snapshot == expected)
    }
}
