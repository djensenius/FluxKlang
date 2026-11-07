import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MeterTapTests {
    @Test func meterTapImpulseReadsPeakOneAndPublishesZeroDBFS() throws {
        let tap = try Self.accumulator(1)
        let slots = try Self.slots(1)
        #expect(Self.feed(tap, 0, [0, 0, 1, 0, 0]) == .ok)
        #expect(tap.reading(channel: 0) == .peak(1))
        #expect(Self.publish(tap, slots) == .ok)
        #expect(Self.level(slots, 0) == 0)
    }

    @Test func meterTapNegativeImpulseUsesTheMagnitude() throws {
        let tap = try Self.accumulator(1)
        let slots = try Self.slots(1)
        Self.feed(tap, 0, [0, -0.5, 0])
        #expect(tap.reading(channel: 0) == .peak(0.5))
        Self.publish(tap, slots)
        #expect(Self.close(Self.level(slots, 0), Self.halfDBFS))
    }

    @Test func meterTapSilenceIsPeakZeroPublishesMinusInfinityAndIsNotUnfed() throws {
        for samples: [Float] in [[0, 0, 0, 0], [-0.0], [0, -0.0, 0]] {
            let tap = try Self.accumulator(1)
            let slots = try Self.slots(1)
            #expect(tap.reading(channel: 0) == .unfed)
            Self.feed(tap, 0, samples)
            #expect(tap.reading(channel: 0) == .peak(0))
            #expect(tap.reading(channel: 0) != .unfed)
            #expect(Self.publish(tap, slots) == .ok)
            #expect(Self.level(slots, 0) == -.infinity)
        }
    }

    @Test func meterTapEmptyBufferIsUnfedPublishesNothingAndReturnsEmpty() throws {
        let tap = try Self.accumulator(2)
        let slots = try Self.slots(2)
        #expect(Self.feed(tap, 0, []) == .ok)
        #expect(tap.reading(channel: 0) == .unfed)
        #expect(Self.publish(tap, slots) == .empty)
        #expect(Self.allUnpublished(slots))
    }

    @Test func meterTapEmptyBufferAfterSamplesChangesNothing() throws {
        let tap = try Self.accumulator(1)
        Self.feed(tap, 0, [0.5])
        #expect(Self.feed(tap, 0, []) == .ok)
        #expect(tap.reading(channel: 0) == .peak(0.5))
    }

    @Test func meterTapAscendingAndDescendingRampsPeakAtOne() throws {
        let tap = try Self.accumulator(2)
        let slots = try Self.slots(2)
        Self.feed(tap, 0, Self.ramp)
        Self.feed(tap, 1, Self.ramp.reversed())
        #expect(Self.readings(tap) == [.peak(1), .peak(1)])
        Self.publish(tap, slots)
        #expect(Self.level(slots, 0) == 0)
        #expect(Self.level(slots, 1) == 0)
    }

    @Test func meterTapFullScaleReportsZeroAndOverFullScaleHasNoUpperClamp() throws {
        for value: Float in [1, -1] {
            let tap = try Self.accumulator(1)
            let slots = try Self.slots(1)
            Self.feed(tap, 0, [value])
            Self.publish(tap, slots)
            #expect(Self.level(slots, 0) == 0)
        }
        let tap = try Self.accumulator(3)
        let slots = try Self.slots(3)
        Self.feed(tap, 0, [2])
        Self.feed(tap, 1, [Float.greatestFiniteMagnitude])
        Self.feed(tap, 2, [0.1])
        Self.publish(tap, slots)
        #expect(Self.close(Self.level(slots, 0), 6.020599913279624))
        let huge = try #require(Self.level(slots, 1))
        #expect(huge.isFinite)
        #expect(huge > 24)
        #expect(Self.close(Self.level(slots, 2), -20, tolerance: 1e-6))
    }

    @Test func meterTapPeakIsTheMaximumAcrossCallsNotTheLastCall() throws {
        let tap = try Self.accumulator(1)
        Self.feed(tap, 0, [0.5])
        Self.feed(tap, 0, [0.25])
        #expect(tap.reading(channel: 0) == .peak(0.5))
        Self.feed(tap, 0, [0.75, 0.125])
        #expect(tap.reading(channel: 0) == .peak(0.75))
        Self.feed(tap, 0, [0, -0.0])
        #expect(tap.reading(channel: 0) == .peak(0.75))
    }

    @Test func meterTapPeakIsNotTheLastSampleOfABuffer() throws {
        let tap = try Self.accumulator(1)
        Self.feed(tap, 0, [1, 0.5, 0.25])
        #expect(tap.reading(channel: 0) == .peak(1))
    }

    @Test func meterTapChannelsAccumulateIndependently() throws {
        let tap = try Self.accumulator(3)
        Self.feed(tap, 0, [0.5])
        Self.feed(tap, 2, [-0.25])
        #expect(Self.readings(tap) == [.peak(0.5), .unfed, .peak(0.25)])
    }

    @Test func meterTapChunkingAtEveryIndexEqualsOneBuffer() throws {
        let whole = try Self.accumulator(1)
        Self.feed(whole, 0, Self.ramp)
        let expected = whole.reading(channel: 0)
        #expect(expected == .peak(1))
        let samples = Self.ramp
        for split in 0...samples.count {
            let tap = try Self.accumulator(1)
            Self.feed(tap, 0, Array(samples[..<split]))
            Self.feed(tap, 0, Array(samples[split...]))
            #expect(tap.reading(channel: 0) == expected, "split at \(split)")
        }
    }

    @Test func meterTapChunkingAtEveryIndexKeepsAnInvalidChannelInvalid() throws {
        var samples = Self.ramp
        try #require(samples.indices.contains(100))
        samples[100] = .nan
        for split in 0...samples.count {
            let tap = try Self.accumulator(1)
            Self.feed(tap, 0, Array(samples[..<split]))
            Self.feed(tap, 0, Array(samples[split...]))
            #expect(tap.reading(channel: 0) == .invalid, "split at \(split)")
        }
    }

    @Test func meterTapIdenticalHistoriesGiveIdenticalReadingsAndSlots() throws {
        let fixtures: [[Float]] = [[0.5], [.nan], [0], [], [Float.leastNonzeroMagnitude, -0.25]]
        let first = try Self.accumulator(5)
        let second = try Self.accumulator(5)
        let firstSlots = try Self.slots(5)
        let secondSlots = try Self.slots(5)
        for (channel, samples) in fixtures.enumerated() {
            Self.feed(first, channel, samples)
            Self.feed(second, channel, samples)
        }
        #expect(Self.readings(first) == Self.readings(second))
        #expect(Self.publish(first, firstSlots) == Self.publish(second, secondSlots))
        for slot in 0..<5 {
            #expect(Self.same(Self.sample(firstSlots, slot), Self.sample(secondSlots, slot)), "slot \(slot)")
        }
    }
}
