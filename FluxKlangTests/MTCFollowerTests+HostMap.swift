import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MTCFollowerTests {
    /// Ticks per frame rounded up, from an independent integer oracle.
    private static func ceilTicksPerFrame(_ rate: SMPTEFrameRate, _ timebase: HostTimebase) -> UInt64 {
        let real = MTCRealRate(rate)
        let numerator = UInt64(real.denominator) * 1_000_000_000 * UInt64(timebase.denom)
        let divisor = UInt64(real.numerator) * UInt64(timebase.numer)
        return (numerator + divisor - 1) / divisor
    }

    @Test func forwardHostMapAddsWholeFramesAtTheExactRate() throws {
        for rate in SMPTEFrameRate.allCases {
            let result = try Self.locked(rate: rate)
            let frameTicks = Self.ticksPerFrame(rate)
            for frames in [0, 1, 2, 30, 1_000] {
                let host = try result.follower.host(forFrameCount: result.current + frames)
                #expect(host.ticks == result.last + UInt64(frames) * frameTicks)
                #expect(try result.follower.frameCount(at: host) == result.current + frames)
                if frames > 0 {
                    #expect(try result.follower.frameCount(at: Self.stamp(host.ticks - 1))
                            == result.current + frames - 1)
                }
            }
        }
    }

    @Test func reverseHostMapSubtractsWholeFramesAndRefusesFramesBehind() throws {
        let result = try Self.locked(direction: .reverse)
        let frameTicks = Self.ticksPerFrame(.fps25)
        #expect(result.current == 996)
        for frames in [0, 1, 2, 30] {
            let host = try result.follower.host(forFrameCount: result.current - frames)
            #expect(host.ticks == result.last + UInt64(frames) * frameTicks)
            #expect(try result.follower.frameCount(at: host) == result.current - frames)
        }
        let behind = MTCFollowerError.behindDirectionOfTravel(frameCount: 997, anchor: 996)
        #expect(Self.thrown { try result.follower.host(forFrameCount: 997) } == behind)
    }

    @Test func aFrameOneBehindTheDirectionOfTravelIsRefusedAndTheAnchorFrameIsAccepted() throws {
        let result = try Self.locked()
        #expect(try result.follower.host(forFrameCount: result.current).ticks == result.last)
        let behind = MTCFollowerError.behindDirectionOfTravel(frameCount: result.current - 1, anchor: result.current)
        #expect(Self.thrown { try result.follower.host(forFrameCount: result.current - 1) } == behind)
    }

    @Test func framesOutsideTheDayAreRefusedBeforeTheirDirectionIsChecked() throws {
        let day = SMPTEFrameRate.fps25.framesPerDay
        let forward = try Self.locked(firstEncoded: day - 100)
        #expect(try forward.follower.host(forFrameCount: day - 1).ticks > forward.last)
        let past = MTCFollowerError.frameCountOutOfRange(frameCount: day, framesPerDay: day)
        #expect(Self.thrown { try forward.follower.host(forFrameCount: day) } == past)
        let negative = MTCFollowerError.frameCountOutOfRange(frameCount: -1, framesPerDay: day)
        #expect(Self.thrown { try forward.follower.host(forFrameCount: -1) } == negative)
        let reverse = try Self.locked(direction: .reverse, firstEncoded: 100)
        #expect(try reverse.follower.host(forFrameCount: 0).ticks > reverse.last)
        #expect(Self.thrown { try reverse.follower.host(forFrameCount: -1) } == negative)
        #expect(Self.thrown { try reverse.follower.host(forFrameCount: day) } == past)
    }

    @Test func extrapolationWrapsAroundTheDayInBothDirections() throws {
        for rate in SMPTEFrameRate.allCases {
            let day = rate.framesPerDay
            let frameTicks = Self.ticksPerFrame(rate)
            let forward = try Self.locked(rate: rate, firstEncoded: day - 100)
            let toMidnight = UInt64(day - forward.current)
            #expect(try forward.follower.frameCount(at: Self.stamp(forward.last + toMidnight * frameTicks)) == 0)
            let before = forward.last + toMidnight * frameTicks - 1
            #expect(try forward.follower.frameCount(at: Self.stamp(before)) == day - 1)
            let reverse = try Self.locked(rate: rate, direction: .reverse, firstEncoded: 100)
            let toZero = UInt64(reverse.current)
            #expect(try reverse.follower.frameCount(at: Self.stamp(reverse.last + toZero * frameTicks)) == 0)
            let wrapped = Self.stamp(reverse.last + (toZero + 1) * frameTicks)
            #expect(try reverse.follower.frameCount(at: wrapped) == day - 1)
        }
    }

    @Test func aQueryBeforeTheAnchorIsRefusedAndAtTheAnchorIsExact() throws {
        let result = try Self.locked()
        #expect(try result.follower.frameCount(at: Self.stamp(result.last)) == result.current)
        let early = MTCFollowerError.queryPrecedesAnchor(anchor: result.last, received: result.last - 1)
        #expect(Self.thrown { try result.follower.frameCount(at: Self.stamp(result.last - 1)) } == early)
    }

    @Test func theInverseIsNeverEarlierThanTheBoundaryAndOneTickEarlierIsThePriorFrame() throws {
        for timebase in [Self.nanosecondTimebase, Self.appleTimebase, Self.exactTimebase] {
            for rate in SMPTEFrameRate.allCases {
                let real = MTCRealRate(rate)
                let result = try Self.locked(rate: rate, timebase: timebase,
                                             ticksPerFrame: Self.ceilTicksPerFrame(rate, timebase))
                for frames in [0, 1, 2, 3, 29, 30, 1_799, 1_800, 17_981, 17_982] {
                    let host = try result.follower.host(forFrameCount: result.current + frames).ticks
                    let elapsed = Int128(host - result.last)
                    let boundary = Int128(frames) * Int128(real.denominator) * 1_000_000_000 * Int128(timebase.denom)
                    let scale = Int128(real.numerator) * Int128(timebase.numer)
                    #expect(elapsed * scale >= boundary)
                    #expect(try result.follower.frameCount(at: Self.stamp(host)) == result.current + frames)
                    if frames > 0 {
                        #expect((elapsed - 1) * scale < boundary)
                        #expect(try result.follower.frameCount(at: Self.stamp(host - 1)) == result.current + frames - 1)
                    }
                }
            }
        }
    }

    @Test func theHostMapIsStrictlyMonotonic() throws {
        let result = try Self.locked(rate: .fps2997DropFrame)
        var previous = try result.follower.host(forFrameCount: result.current).ticks
        for frames in 1..<300 {
            let host = try result.follower.host(forFrameCount: result.current + frames).ticks
            #expect(host > previous)
            previous = host
        }
    }

    @Test func theHostMapRefusesOnlyPastTheUInt64Ceiling() throws {
        let frameTicks = Self.ticksPerFrame(.fps25)
        let start = UInt64.max - frameTicks - 7 * frameTicks / 4
        var subject = try Self.follower(Self.policy(lock: 1))
        try Self.feed(&subject, Self.sequence(encoded: 1000, rate: .fps25, start: start))
        #expect(try subject.host(forFrameCount: 1003).ticks == UInt64.max)
        #expect(Self.thrown { try subject.host(forFrameCount: 1004) } == .overflow)
    }

    @Test func extrapolationReportsOverflowForAnAbsurdElapsedTime() throws {
        let huge = HostTimebase(numer: .max, denom: 1)
        let anchor = MTCFollowerAnchor(frameCount: 1002, stamp: 1_001, rate: .fps25, direction: .forward)
        #expect(try anchor.frameCount(atTicks: 1_001, timebase: huge) == 1002)
        #expect(Self.thrown { try anchor.frameCount(atTicks: UInt64.max, timebase: huge) } == .overflow)
    }
}
