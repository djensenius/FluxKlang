import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MeterTapTests {
    @Test func meterTapPublishWritesOnlyTheChannelSlotsFromFirstSlot() throws {
        let tap = try Self.accumulator(3)
        let slots = try Self.slots(8)
        for channel in 0..<3 { Self.feed(tap, channel, [0.5]) }
        #expect(Self.publish(tap, slots, firstSlot: 2) == .ok)
        for slot in [0, 1, 5, 6, 7] { #expect(Self.isUnpublished(slots, slot), "slot \(slot)") }
        for slot in 2...4 { #expect(Self.close(Self.level(slots, slot), Self.halfDBFS), "slot \(slot)") }
    }

    @Test func meterTapPublishCopiesTheStampUnchangedToEverySlot() throws {
        let tap = try Self.accumulator(2)
        let slots = try Self.slots(2)
        Self.feed(tap, 0, [0.5])
        Self.feed(tap, 1, [0.25])
        let stamp = TelemetryStamp(clockGeneration: 9, frame: -123)
        #expect(MeterTapPublisher.publish(tap, to: slots, firstSlot: 0, stamp: stamp) == .ok)
        for slot in 0..<2 {
            let sample = try #require(Self.sample(slots, slot))
            #expect(sample.stamp == stamp)
            #expect(sample.stamp.clockGeneration == 9)
            #expect(sample.stamp.frame == -123)
        }
    }

    @Test func meterTapPublishSequencesAdvanceByOnePerPublish() throws {
        let tap = try Self.accumulator(1)
        let slots = try Self.slots(1)
        Self.feed(tap, 0, [0.5])
        Self.publish(tap, slots)
        #expect(try #require(Self.sample(slots, 0)).sequence == 1)
        Self.feed(tap, 0, [0.25])
        Self.publish(tap, slots)
        let second = try #require(Self.sample(slots, 0))
        #expect(second.sequence == 2)
        #expect(Self.close(second.value.peakDBFS, Self.quarterDBFS))
    }

    @Test func meterTapMixedChannelsPublishTheirOwnValuesAndSkipTheUnfedOne() throws {
        let tap = try Self.accumulator(5)
        let slots = try Self.slots(8)
        Self.feed(tap, 0, [0.5])
        Self.feed(tap, 1, [0.9, .nan])
        Self.feed(tap, 2, [0, 0])
        Self.feed(tap, 4, [.leastNonzeroMagnitude])
        #expect(Self.publish(tap, slots) == .ok)
        #expect(Self.close(Self.level(slots, 0), Self.halfDBFS))
        #expect(try #require(Self.level(slots, 1)).isNaN)
        #expect(Self.level(slots, 2) == -.infinity)
        #expect(Self.isUnpublished(slots, 3))
        #expect(Self.level(slots, 4) == -200)
        for slot in 5...7 { #expect(Self.isUnpublished(slots, slot)) }
    }

    @Test func meterTapAnUnfedChannelKeepsItsSlotValueAndSequence() throws {
        let tap = try Self.accumulator(2)
        let slots = try Self.slots(2)
        Self.feed(tap, 0, [0.5])
        Self.feed(tap, 1, [0.25])
        Self.publish(tap, slots)
        Self.feed(tap, 0, [1])
        #expect(Self.publish(tap, slots) == .ok)
        #expect(Self.level(slots, 0) == 0)
        #expect(try #require(Self.sample(slots, 0)).sequence == 2)
        let kept = try #require(Self.sample(slots, 1))
        #expect(kept.sequence == 1)
        #expect(Self.close(kept.value.peakDBFS, Self.quarterDBFS))
    }

    @Test func meterTapAllUnfedReturnsEmptyAndWritesNothing() throws {
        let tap = try Self.accumulator(4)
        let slots = try Self.slots(4)
        #expect(Self.publish(tap, slots) == .empty)
        #expect(Self.allUnpublished(slots))
        #expect(Self.readings(tap) == [.unfed, .unfed, .unfed, .unfed])
    }

    @Test func meterTapPublishResetsThePublishedChannelSoThePeakIsSinceTheLastPublish() throws {
        let tap = try Self.accumulator(2)
        let slots = try Self.slots(2)
        Self.feed(tap, 0, [1])
        Self.feed(tap, 1, [.nan])
        #expect(Self.publish(tap, slots) == .ok)
        #expect(Self.readings(tap) == [.unfed, .unfed])
        Self.feed(tap, 0, [0.25])
        Self.feed(tap, 1, [0.5])
        #expect(Self.publish(tap, slots) == .ok)
        #expect(Self.close(Self.level(slots, 0), Self.quarterDBFS))
        #expect(Self.close(Self.level(slots, 1), Self.halfDBFS))
    }

    @Test func meterTapPublishingTwiceWithoutFeedingReturnsEmptyAndKeepsSequenceOne() throws {
        let tap = try Self.accumulator(1)
        let slots = try Self.slots(1)
        Self.feed(tap, 0, [0.5])
        #expect(Self.publish(tap, slots) == .ok)
        #expect(Self.publish(tap, slots) == .empty)
        let sample = try #require(Self.sample(slots, 0))
        #expect(sample.sequence == 1)
        #expect(Self.close(sample.value.peakDBFS, Self.halfDBFS))
    }

    @Test func meterTapPublishWritesEveryChannelOfAFullWidthAccumulator() throws {
        let tap = try Self.accumulator(64)
        let slots = try Self.slots(64)
        for channel in 0..<64 { Self.feed(tap, channel, [Float(channel + 1) / 64]) }
        #expect(Self.publish(tap, slots) == .ok)
        for channel in 0..<64 {
            let expected = 20 * log10(Double(Float(channel + 1) / 64))
            #expect(Self.close(Self.level(slots, channel), expected), "channel \(channel)")
        }
    }
}
