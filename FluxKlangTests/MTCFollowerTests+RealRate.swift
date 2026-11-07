import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MTCFollowerTests {
    private static let timebases = [nanosecondTimebase, appleTimebase, exactTimebase]

    @Test func realRatesAreTheExactReducedRationals() {
        let expected: [SMPTEFrameRate: [Int64]] = [
            .fps24: [24, 1], .fps25: [25, 1], .fps2997DropFrame: [30_000, 1_001], .fps30: [30, 1]
        ]
        for (rate, fraction) in expected {
            let real = MTCRealRate(rate)
            #expect(real.rate == rate)
            #expect(real.numerator == fraction[0])
            #expect(real.denominator == fraction[1])
        }
    }

    @Test func oneSecondHoldsTheWholeFramesOfEachRate() throws {
        let second: UInt64 = 1_000_000_000
        let expected: [(SMPTEFrameRate, Int64)] = [(.fps24, 24), (.fps25, 25), (.fps2997DropFrame, 29), (.fps30, 30)]
        for (rate, frames) in expected {
            let real = MTCRealRate(rate)
            #expect(try real.wholeFrames(inTicks: second, timebase: Self.nanosecondTimebase) == frames)
            // 1 s holds 29.97 drop-frame frames, so one tick fewer still holds 29 whole frames.
            let before = rate.isDropFrame ? frames : frames - 1
            #expect(try real.wholeFrames(inTicks: second - 1, timebase: Self.nanosecondTimebase) == before)
        }
    }

    @Test func thirtyThousandDropFramesLastExactly1001Seconds() throws {
        let real = MTCRealRate(.fps2997DropFrame)
        let ticks = try real.hostTicks(forFrames: 30_000, timebase: Self.nanosecondTimebase)
        #expect(ticks == 1_001_000_000_000)
        #expect(try real.wholeFrames(inTicks: ticks, timebase: Self.nanosecondTimebase) == 30_000)
        #expect(try real.wholeFrames(inTicks: ticks - 1, timebase: Self.nanosecondTimebase) == 29_999)
    }

    @Test func aDayOfDropFrameLabelsLastsExactly86399Point9136Seconds() throws {
        let real = MTCRealRate(.fps2997DropFrame)
        let frames = Int64(SMPTEFrameRate.fps2997DropFrame.framesPerDay)
        #expect(frames == 2_589_408)
        // 2,589,408 * 1001 / 30000 s = 86,399.9136 s = 86,399,913,600,000 ns.
        let ticks = try real.hostTicks(forFrames: frames, timebase: Self.nanosecondTimebase)
        #expect(ticks == 86_399_913_600_000)
        #expect(UInt64(frames) * 1_001 * 1_000_000_000 == ticks * 30_000)
        #expect(try real.wholeFrames(inTicks: ticks, timebase: Self.nanosecondTimebase) == frames)
        #expect(try real.hostTicks(forFrames: frames, timebase: Self.exactTimebase) == 259_199_740_800_000)
    }

    @Test func nonDropDaysLastExactlyOneDay() throws {
        for rate in [SMPTEFrameRate.fps24, .fps25, .fps30] {
            let ticks = try MTCRealRate(rate).hostTicks(forFrames: Int64(rate.framesPerDay),
                                                        timebase: Self.nanosecondTimebase)
            #expect(ticks == 86_400_000_000_000)
        }
    }

    @Test func frameToTicksToFrameRoundTripsExactlyWhenAFrameLastsAtLeastOneTick() throws {
        for timebase in Self.timebases {
            for rate in SMPTEFrameRate.allCases {
                let real = MTCRealRate(rate)
                for frame in Self.boundaryFrames {
                    let ticks = try real.hostTicks(forFrames: Int64(frame), timebase: timebase)
                    #expect(try real.wholeFrames(inTicks: ticks, timebase: timebase) == Int64(frame))
                    if frame > 0 {
                        #expect(try real.wholeFrames(inTicks: ticks - 1, timebase: timebase) == Int64(frame) - 1)
                    }
                }
            }
        }
    }

    @Test func hostTicksRoundUpToTheFirstTickAtOrAfterTheBoundary() throws {
        // 25 fps at 7 ns per tick: one frame is 5,714,285.71 ticks.
        let real = MTCRealRate(.fps25)
        let timebase = HostTimebase(numer: 7, denom: 1)
        #expect(try real.hostTicks(forFrames: 1, timebase: timebase) == 5_714_286)
        #expect(try real.hostTicks(forFrames: 7, timebase: timebase) == 40_000_000)
        #expect(try real.wholeFrames(inTicks: 5_714_285, timebase: timebase) == 0)
        #expect(try real.wholeFrames(inTicks: 5_714_286, timebase: timebase) == 1)
    }

    @Test func ticksLongerThanAFrameKeepTheCeilFloorBracket() throws {
        let secondPerTick = HostTimebase(numer: 1_000_000_000, denom: 1)
        for rate in SMPTEFrameRate.allCases {
            let real = MTCRealRate(rate)
            for frame in Self.boundaryFrames {
                let ticks = try real.hostTicks(forFrames: Int64(frame), timebase: secondPerTick)
                #expect(try real.wholeFrames(inTicks: ticks, timebase: secondPerTick) >= Int64(frame))
                if frame > 0 {
                    #expect(try real.wholeFrames(inTicks: ticks - 1, timebase: secondPerTick) < Int64(frame))
                }
            }
        }
    }

    @Test func hostTicksOverflowExactlyPastTheUInt64Ceiling() throws {
        let real = MTCRealRate(.fps25)
        let last = Int64(UInt64.max / 40_000_000)
        #expect(try real.hostTicks(forFrames: last, timebase: Self.nanosecondTimebase) == UInt64(last) * 40_000_000)
        #expect(Self.thrown { try real.hostTicks(forFrames: last + 1, timebase: Self.nanosecondTimebase) } == .overflow)
    }

    @Test func wholeFramesOverflowExactlyPastTheInt64Ceiling() throws {
        let real = MTCRealRate(.fps30)
        let secondPerTick = HostTimebase(numer: 1_000_000_000, denom: 1)
        let last = UInt64(Int64.max / 30)
        #expect(try real.wholeFrames(inTicks: last, timebase: secondPerTick) == Int64(last) * 30)
        #expect(Self.thrown { try real.wholeFrames(inTicks: last + 1, timebase: secondPerTick) } == .overflow)
    }

    @Test func int128IntermediatesReportOverflowInsteadOfTrapping() {
        let widest = HostTimebase(numer: 1, denom: UInt32.max)
        let real = MTCRealRate(.fps2997DropFrame)
        #expect(Self.thrown { try real.hostTicks(forFrames: Int64.max, timebase: widest) } == .overflow)
        #expect(Self.thrown { try real.wholeFrames(inTicks: UInt64.max, timebase: HostTimebase(numer: .max, denom: 1)) }
                == .overflow)
    }

    @Test func aProductThatWrapsInto128BitsIsStillReportedAsOverflow() {
        // frames * 1001 * 10^9 * denom is just past 2^128, so a wrapped product would be a small valid-looking number.
        let widest = HostTimebase(numer: 1, denom: UInt32.max)
        let unit = UInt128(1_001) * 1_000_000_000 * UInt128(UInt32.max)
        let frames = Int64(UInt128.max / unit + 1)
        let real = MTCRealRate(.fps2997DropFrame)
        #expect(Self.thrown { try real.hostTicks(forFrames: frames, timebase: widest) } == .overflow)
    }

    @Test func conversionsRefuseAnInvalidTimebase() {
        let real = MTCRealRate(.fps24)
        for timebase in [HostTimebase(numer: 0, denom: 1), HostTimebase(numer: 1, denom: 0)] {
            #expect(Self.thrown { try real.hostTicks(forFrames: 1, timebase: timebase) } == .invalidTimebase)
            #expect(Self.thrown { try real.wholeFrames(inTicks: 1, timebase: timebase) } == .invalidTimebase)
        }
    }

    @Test func aNegativeFrameCountHasNoTickDuration() throws {
        let real = MTCRealRate(.fps24)
        #expect(Self.thrown { try real.hostTicks(forFrames: -1, timebase: Self.nanosecondTimebase) } == .overflow)
        #expect(try real.hostTicks(forFrames: 0, timebase: Self.nanosecondTimebase) == 0)
    }
}
