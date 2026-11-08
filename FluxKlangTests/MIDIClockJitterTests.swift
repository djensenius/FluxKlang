import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Statistics of host-stamp windows: goldens, the mean, the extremes and equal stamps. Nearest-rank tables, nominal
/// intervals, refusals and the verdict are in the extensions of this suite.
struct MIDIClockJitterTests {
    static func stamps(_ ticks: [UInt64]) -> [HostStamp] {
        ticks.map { HostStamp(ticks: $0) }
    }

    /// Stamps that start at 0 and advance by each interval in turn.
    static func stamps(accumulating intervals: [UInt64]) -> [HostStamp] {
        var current: UInt64 = 0
        var result = [HostStamp(ticks: 0)]
        for interval in intervals {
            current += interval
            result.append(HostStamp(ticks: current))
        }
        return result
    }

    static func nominal(_ span: Int128, _ pulses: Int128) throws(MIDIClockJitterRefusal) -> MIDIClockJitterNominal {
        try MIDIClockJitterNominal.make(spanTicks: span, pulses: pulses)
    }

    static func summary(_ stamps: [HostStamp], span: Int128 = 1_000, pulses: Int128 = 1,
                        percentile: Int = 100) throws(MIDIClockJitterRefusal) -> MIDIClockJitterSummary {
        try MIDIClockJitterSummary.make(
            stamps: stamps, nominal: nominal(span, pulses), percentile: percentile
        )
    }

    static func refusal(_ stamps: [HostStamp], span: Int128 = 1_000, pulses: Int128 = 1,
                        percentile: Int = 100) -> MIDIClockJitterRefusal? {
        do {
            _ = try summary(stamps, span: span, pulses: pulses, percentile: percentile)
            return nil
        } catch {
            return error
        }
    }

    static let windowA = stamps([0, 1_000, 2_000, 3_100, 4_000])
    static let windowB = stamps([0, 334, 667, 1_001])
}

// MARK: - Goldens

extension MIDIClockJitterTests {
    @Test func windowAReportsTheHandComputedIntervalStatistics() throws {
        let summary = try Self.summary(Self.windowA, percentile: 50)
        let nominal = try Self.nominal(1_000, 1)
        #expect(summary.intervalCount == 4)
        #expect(summary.minimumInterval == 900)
        #expect(summary.maximumInterval == 1_100)
        #expect(summary.totalTicks == 4_000)
        #expect(summary.meanFloorTicks == 1_000)
        #expect(summary.maximumDeviationScaled == 100)
        #expect(summary.percentile == 50)
        #expect(summary.percentileDeviationScaled == 0)
        #expect(summary.nominal == nominal)
    }

    @Test func windowAPercentilesSeventyFiveAndHundredReachTheLargeDeviations() throws {
        let seventyFive = try Self.summary(Self.windowA, percentile: 75)
        let hundred = try Self.summary(Self.windowA, percentile: 100)
        #expect(seventyFive.percentileDeviationScaled == 100)
        #expect(hundred.percentileDeviationScaled == 100)
        #expect(seventyFive.maximumDeviationScaled == 100)
    }

    @Test func windowBKeepsDeviationsScaledByThePulseCount() throws {
        let summary = try Self.summary(Self.windowB, span: 1_000, pulses: 3, percentile: 50)
        #expect(summary.intervalCount == 3)
        #expect(summary.minimumInterval == 333)
        #expect(summary.maximumInterval == 334)
        #expect(summary.totalTicks == 1_001)
        #expect(summary.meanFloorTicks == 333)
        #expect(summary.maximumDeviationScaled == 2)
        #expect(summary.percentileDeviationScaled == 2)
    }

    @Test func theMeanIsTheExactPairAndFloorsAHalf() throws {
        let summary = try Self.summary(Self.stamps([0, 3, 7]))
        #expect(summary.totalTicks == 7)
        #expect(summary.intervalCount == 2)
        #expect(summary.meanFloorTicks == 3)
        let exact = try Self.summary(Self.stamps([0, 1_000, 2_000]))
        #expect(exact.meanFloorTicks == 1_000)
    }

    @Test func theTotalIsTheLastStampMinusTheFirstNotMeasuredFromZero() throws {
        let summary = try Self.summary(Self.stamps([100, 160, 200, 290]))
        #expect(summary.totalTicks == 190)
        #expect(summary.meanFloorTicks == 63)
    }

    @Test func minimumAndMaximumAreFoundAtDifferentPositionsInTwoWindows() throws {
        let summary = try Self.summary(Self.stamps(accumulating: [30, 10, 50, 20]))
        #expect(summary.minimumInterval == 10)
        #expect(summary.maximumInterval == 50)
        let reversed = try Self.summary(Self.stamps(accumulating: [20, 50, 10, 30]))
        #expect(reversed.minimumInterval == 10)
        #expect(reversed.maximumInterval == 50)
    }

    @Test func equalConsecutiveStampsAreIntervalsOfZero() throws {
        let summary = try Self.summary(Self.stamps([0, 0, 10]), percentile: 50)
        #expect(summary.intervalCount == 2)
        #expect(summary.minimumInterval == 0)
        #expect(summary.maximumInterval == 10)
        #expect(summary.totalTicks == 10)
        #expect(summary.maximumDeviationScaled == 1_000)
        #expect(summary.percentileDeviationScaled == 990)
    }

    @Test func aWindowOfEqualStampsDeviatesByTheWholeNominalSpan() throws {
        let summary = try Self.summary(Self.stamps([5, 5, 5, 5]), span: 2_000, pulses: 4)
        #expect(summary.intervalCount == 3)
        #expect(summary.maximumInterval == 0)
        #expect(summary.totalTicks == 0)
        #expect(summary.meanFloorTicks == 0)
        #expect(summary.maximumDeviationScaled == 2_000)
    }

    @Test func aStampSpanOfUInt64MaxKeepsExactDeviationsAtTheLargestPulseCountAndAtTheLargestNominalSpan() throws {
        let wide = Self.stamps([0, UInt64.max])
        let manyPulses = try Self.summary(wide, span: 1, pulses: Int128(1) << 48)
        let expected = (Int128(1) << 112) - (Int128(1) << 48) - 1
        #expect(manyPulses.maximumDeviationScaled == expected)
        #expect(manyPulses.totalTicks == UInt64.max)
        let longSpan = try Self.summary(wide, span: Int128(1) << 80, pulses: 1)
        let longExpected = (Int128(1) << 80) - (Int128(1) << 64) + 1
        #expect(longSpan.maximumDeviationScaled == longExpected)
    }

    @Test func buildingTheSameWindowTwiceGivesEqualSummaries() throws {
        let first = try Self.summary(Self.windowA, percentile: 75)
        let second = try Self.summary(Self.windowA, percentile: 75)
        let other = try Self.summary(Self.windowA, percentile: 50)
        #expect(first == second)
        #expect(first != other)
    }
}
