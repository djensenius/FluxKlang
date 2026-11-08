import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Hand-computed byte and tick goldens. No expected value comes from the production formula; the 125/3 test
/// multiplies a hand-typed step.
extension MTCEmitTests {
    @Test func twentyFourFpsBytesAtOneHourMatchTheHandComputedSequencesForFramesZeroAndTwo() throws {
        let plan = try Self.plan(Self.request(try Self.time(1, 0, 0, 0, .fps24), frames: 4))
        let expected: [UInt8] = [0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x61, 0x70,
                                 0x02, 0x10, 0x20, 0x30, 0x40, 0x50, 0x61, 0x70]
        #expect(Self.dataBytes(plan) == expected)
    }

    @Test func twentyFiveFpsBytesAtTenTwentyThirtyTwelveMatchTheHandComputedSequence() throws {
        let plan = try Self.plan(Self.request(try Self.time(10, 20, 30, 12, .fps25), frames: 2))
        let expected: [UInt8] = [0x0C, 0x10, 0x2E, 0x31, 0x44, 0x51, 0x6A, 0x72]
        #expect(Self.dataBytes(plan) == expected)
    }

    @Test func dropFrameBytesAtMidnightEndWithTheRateCodeTwoInPieceSeven() throws {
        let plan = try Self.plan(Self.request(try Self.time(0, 0, 0, 0, .fps2997DropFrame), frames: 2))
        let expected: [UInt8] = [0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x74]
        #expect(Self.dataBytes(plan) == expected)
    }

    @Test func thirtyFpsBytesAtMidnightEndWithTheRateCodeThreeInPieceSeven() throws {
        let plan = try Self.plan(Self.request(try Self.time(0, 0, 0, 0, .fps30), frames: 2))
        let expected: [UInt8] = [0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x76]
        #expect(Self.dataBytes(plan) == expected)
    }

    @Test func reverseTwentyFourFpsBytesAtOneHourMatchTheHandComputedSequencesForTheStartAndTwoFramesBefore() throws {
        let plan = try Self.plan(Self.request(try Self.time(1, 0, 0, 0, .fps24), frames: 4, direction: .reverse))
        let expected: [UInt8] = [0x70, 0x61, 0x50, 0x40, 0x30, 0x20, 0x10, 0x00,
                                 0x70, 0x60, 0x53, 0x4B, 0x33, 0x2B, 0x11, 0x06]
        #expect(Self.dataBytes(plan) == expected)
    }

    @Test func twentyFourFpsTicksOnTheUnitTimebaseMatchTheHandComputedFlooredValues() throws {
        let plan = try Self.plan(Self.request(try Self.time(0, 0, 0, 0, .fps24), frames: 2))
        let expected: [UInt64] = [0, 10_416_666, 20_833_333, 31_250_000, 41_666_666, 52_083_333, 62_500_000,
                                  72_916_666]
        #expect(Self.ticks(plan) == expected)
    }

    @Test func twentyFiveFpsTicksOnTheUnitTimebaseAreTenMillionApart() throws {
        let plan = try Self.plan(Self.request(try Self.time(0, 0, 0, 0, .fps25), frames: 2))
        let expected: [UInt64] = [0, 10_000_000, 20_000_000, 30_000_000, 40_000_000, 50_000_000, 60_000_000,
                                  70_000_000]
        #expect(Self.ticks(plan) == expected)
    }

    @Test func thirtyFpsTicksOnTheUnitTimebaseMatchTheHandComputedFlooredValues() throws {
        let plan = try Self.plan(Self.request(try Self.time(0, 0, 0, 0, .fps30), frames: 2))
        let expected: [UInt64] = [0, 8_333_333, 16_666_666, 25_000_000, 33_333_333, 41_666_666, 50_000_000,
                                  58_333_333]
        #expect(Self.ticks(plan) == expected)
    }

    @Test func dropFrameTicksOnTheUnitTimebaseMatchTheHandComputedFlooredValues() throws {
        let plan = try Self.plan(Self.request(try Self.time(0, 0, 0, 0, .fps2997DropFrame), frames: 2))
        let expected: [UInt64] = [0, 8_341_666, 16_683_333, 25_025_000, 33_366_666, 41_708_333, 50_050_000,
                                  58_391_666]
        #expect(Self.ticks(plan) == expected)
    }

    @Test func ticksAreComputedFromTheOriginSoTheNinthAndLastEntriesOfAFourFramePlanDoNotAccumulateRounding() throws {
        let plan = try Self.plan(Self.request(try Self.time(0, 0, 0, 0, .fps24), frames: 4))
        let ninth = try #require(plan.entries.dropFirst(8).first)
        let last = try #require(plan.entries.last)
        #expect(ninth.tick == 83_333_333)
        #expect(last.tick == 156_250_000)
    }

    @Test func theLastTickOfATwoHundredFiftySixFramePlanMatchesTheHandComputedValueAtEachRate() throws {
        let rates: [SMPTEFrameRate] = [.fps24, .fps25, .fps2997DropFrame, .fps30]
        let expected: [UInt64] = [10_656_250_000, 10_230_000_000, 8_533_525_000, 8_525_000_000]
        for (rate, tick) in zip(rates, expected) {
            let plan = try Self.plan(Self.request(try Self.time(0, 0, 0, 0, rate), frames: 256))
            let last = try #require(plan.entries.last)
            #expect(last.tick == tick, "\(rate)")
        }
    }

    @Test func theOneTwentyFiveOverThreeTimebaseGivesExactPeriodsAtEachRate() throws {
        let timebase = HostTimebase(numer: 125, denom: 3)
        let rates: [SMPTEFrameRate] = [.fps24, .fps25, .fps2997DropFrame, .fps30]
        let steps: [UInt64] = [250_000, 240_000, 200_200, 200_000]
        for (rate, step) in zip(rates, steps) {
            let plan = try Self.plan(Self.request(try Self.time(0, 0, 0, 0, rate), frames: 2, timebase: timebase))
            let expected = (0..<8).map { UInt64($0) * step }
            #expect(Self.ticks(plan) == expected, "\(rate)")
        }
    }

    @Test func aTickAtTheOriginEndOfTheRangeIsAcceptedAndOneMoreTickOverflows() throws {
        let start = try Self.time(0, 0, 0, 0, .fps24)
        let fits = MTCEmitRequest(start: start, direction: .forward, originTicks: UInt64.max - 72_916_666,
                                  frameCount: 2, timebase: Self.unitTimebase, fullFrameDevice: nil)
        let overflows = MTCEmitRequest(start: start, direction: .forward, originTicks: UInt64.max - 72_916_665,
                                       frameCount: 2, timebase: Self.unitTimebase, fullFrameDevice: nil)
        let plan = try Self.plan(fits)
        let last = try #require(plan.entries.last)
        let refused = Self.refusal(overflows)
        #expect(last.tick == UInt64.max)
        #expect(refused == .tickOverflow)
    }
}
