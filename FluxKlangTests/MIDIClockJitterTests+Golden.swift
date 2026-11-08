import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Nearest-rank percentile tables and nominal intervals built from a tempo, typed by hand.
extension MIDIClockJitterTests {
    static func percentileDeviations(of intervals: [UInt64], at percentiles: [Int]) throws -> [Int128] {
        let window = stamps(accumulating: intervals)
        return try percentiles.map { try summary(window, percentile: $0).percentileDeviationScaled }
    }

    /// Absolute deviations from 1000 are 50, 0, 30, 10, 40, 20, 70, 60, 90, 80: sorted 0, 10, ... 90.
    static let tenIntervals: [UInt64] = [1_050, 1_000, 970, 1_010, 960, 1_020, 1_070, 940, 1_090, 920]

    @Test func nearestRankOfTenDeviationsPicksTheHandComputedRanks() throws {
        let percentiles = [1, 10, 11, 50, 51, 90, 91, 95, 100]
        let observed = try Self.percentileDeviations(of: Self.tenIntervals, at: percentiles)
        #expect(observed == [0, 0, 10, 40, 50, 80, 90, 90, 90])
    }

    @Test func nearestRankOfOneDeviationIsThatDeviationAtEveryPercentileTried() throws {
        let observed = try Self.percentileDeviations(of: [1_007], at: [1, 37, 50, 99, 100])
        #expect(observed == [7, 7, 7, 7, 7])
    }

    @Test func nearestRankOfFourDeviationsSwitchesRankAtTwentyFiveSeventyFive() throws {
        let percentiles = [25, 26, 50, 51, 75, 76, 100]
        let observed = try Self.percentileDeviations(of: [1_030, 1_000, 1_020, 1_010], at: percentiles)
        #expect(observed == [0, 10, 10, 20, 20, 30, 30])
    }

    @Test func theMaximumDeviationIsTheSameAtPercentileOneAndOneHundred() throws {
        let window = Self.stamps(accumulating: Self.tenIntervals)
        let low = try Self.summary(window, percentile: 1)
        let high = try Self.summary(window, percentile: 100)
        #expect(low.maximumDeviationScaled == 90)
        #expect(high.maximumDeviationScaled == 90)
    }

    @Test func tempoNominalAtOneHundredTwentyOnAUnitTimebaseMatchesTheHandComputedRatio() throws {
        let timebase = HostTimebase(numer: 1, denom: 1)
        let nominal = try MIDIClockJitterNominal.make(beatsPerMinute: 120, timebase: timebase)
        #expect(nominal.spanTicks == 60_000_000_000)
        #expect(nominal.pulses == 2_880)
    }

    @Test func tempoNominalOnAnAppleSiliconStyleTimebaseMatchesTheHandComputedRatio() throws {
        let timebase = HostTimebase(numer: 125, denom: 3)
        let nominal = try MIDIClockJitterNominal.make(beatsPerMinute: 120, timebase: timebase)
        #expect(nominal.spanTicks == 180_000_000_000)
        #expect(nominal.pulses == 360_000)
    }

    @Test func tempoNominalAtTheExtremesOfTempoAndTimebaseBuilds() throws {
        let widest = HostTimebase(numer: UInt32.max, denom: UInt32.max)
        let fast = try MIDIClockJitterNominal.make(beatsPerMinute: 300, timebase: widest)
        #expect(fast.spanTicks == 257_698_037_700_000_000_000)
        #expect(fast.pulses == 30_923_764_524_000)
        let slow = try MIDIClockJitterNominal.make(beatsPerMinute: 20, timebase: HostTimebase(numer: 1, denom: 1))
        #expect(slow.spanTicks == 60_000_000_000)
        #expect(slow.pulses == 480)
    }
}
