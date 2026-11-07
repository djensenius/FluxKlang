import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MeterTapTests {
    @Test func meterTapNaNAtFirstMiddleAndLastPositionMakesTheChannelInvalid() throws {
        for samples: [Float] in [[.nan, 0.5, 0.5], [0.5, .nan, 0.5], [0.5, 0.5, .nan]] {
            let tap = try Self.accumulator(1)
            let slots = try Self.slots(1)
            Self.feed(tap, 0, samples)
            #expect(tap.reading(channel: 0) == .invalid)
            #expect(Self.publish(tap, slots) == .ok)
            #expect(try #require(Self.level(slots, 0)).isNaN)
        }
    }

    @Test func meterTapPositiveInfinityMakesTheChannelInvalid() throws {
        let tap = try Self.accumulator(1)
        Self.feed(tap, 0, [0.5, .infinity])
        #expect(tap.reading(channel: 0) == .invalid)
    }

    @Test func meterTapNegativeInfinityMakesTheChannelInvalid() throws {
        let tap = try Self.accumulator(1)
        Self.feed(tap, 0, [-.infinity, 0.5])
        #expect(tap.reading(channel: 0) == .invalid)
    }

    @Test func meterTapInvalidDiscardsAnEarlierLoudFinitePeak() throws {
        let tap = try Self.accumulator(1)
        let slots = try Self.slots(1)
        Self.feed(tap, 0, [0.9])
        #expect(tap.reading(channel: 0) == .peak(0.9))
        Self.feed(tap, 0, [.nan])
        #expect(tap.reading(channel: 0) == .invalid)
        Self.publish(tap, slots)
        #expect(try #require(Self.level(slots, 0)).isNaN)
    }

    @Test func meterTapInvalidIsStickyAgainstLaterFiniteSamplesAndBuffers() throws {
        let tap = try Self.accumulator(1)
        Self.feed(tap, 0, [.nan, 0.5])
        #expect(tap.reading(channel: 0) == .invalid)
        Self.feed(tap, 0, [0.25])
        #expect(tap.reading(channel: 0) == .invalid)
        Self.feed(tap, 0, [1, -1])
        #expect(tap.reading(channel: 0) == .invalid)
    }

    @Test func meterTapNaNInASecondCallAndAnEmptyBufferAfterwardsKeepTheChannelInvalid() throws {
        let tap = try Self.accumulator(1)
        Self.feed(tap, 0, [0.5, 0.75])
        Self.feed(tap, 0, [0.25, .nan])
        #expect(tap.reading(channel: 0) == .invalid)
        Self.feed(tap, 0, [])
        #expect(tap.reading(channel: 0) == .invalid)
    }

    @Test func meterTapAnInvalidChannelIsNeverPublishedAsInfinity() throws {
        let slots = try Self.slots(3)
        let tap = try Self.accumulator(3)
        Self.feed(tap, 0, [.nan])
        Self.feed(tap, 1, [.infinity])
        Self.feed(tap, 2, [-.infinity])
        #expect(Self.publish(tap, slots) == .ok)
        for slot in 0..<3 {
            let value = try #require(Self.level(slots, slot))
            #expect(value.isNaN)
            #expect(!value.isInfinite)
        }
    }

    @Test func meterTapResetClearsInvalidFedAndPeak() throws {
        let tap = try Self.accumulator(3)
        Self.feed(tap, 0, [.nan])
        Self.feed(tap, 1, [0.5])
        Self.feed(tap, 2, [0.25])
        #expect(tap.reset(channel: 0) == .ok)
        #expect(tap.reset(channel: 1) == .ok)
        #expect(Self.readings(tap) == [.unfed, .unfed, .peak(0.25)])
        Self.feed(tap, 0, [0.125])
        Self.feed(tap, 1, [0.0625])
        #expect(Self.readings(tap) == [.peak(0.125), .peak(0.0625), .peak(0.25)])
    }

    @Test func meterTapResetAllClearsEveryChannel() throws {
        let tap = try Self.accumulator(4)
        Self.feed(tap, 0, [.nan])
        Self.feed(tap, 1, [0.5])
        Self.feed(tap, 2, [0])
        Self.feed(tap, 3, [0.25])
        tap.resetAll()
        #expect(Self.readings(tap) == [.unfed, .unfed, .unfed, .unfed])
        Self.feed(tap, 3, [0.0625])
        #expect(tap.reading(channel: 3) == .peak(0.0625))
    }

    @Test func meterTapAnInvalidChannelDoesNotDisturbItsNeighbours() throws {
        let tap = try Self.accumulator(3)
        Self.feed(tap, 0, [0.5])
        Self.feed(tap, 1, [.nan])
        Self.feed(tap, 2, [0.25])
        #expect(Self.readings(tap) == [.peak(0.5), .invalid, .peak(0.25)])
    }
}
