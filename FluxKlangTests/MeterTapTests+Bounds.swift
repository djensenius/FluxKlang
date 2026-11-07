import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MeterTapTests {
    @Test func meterTapChannelCountAccepts1And64AndRefusesEverythingElse() throws {
        #expect(try Self.accumulator(1).channelCount == 1)
        #expect(try Self.accumulator(64).channelCount == 64)
        for count in [0, -1, 65, Int.min, Int.max] {
            #expect(throws: MeterTapRefusal.channelCountOutOfRange(count)) {
                try MeterTapAccumulator(channelCount: count)
            }
        }
    }

    @Test func meterTapLimitsMatchMeterSourceAndTheDisplayFloor() {
        #expect(MeterTapLimits.maximumChannels == 64)
        #expect(MeterTapLimits.maximumChannels == MeterSource.maximumChannels)
        #expect(MeterTapLimits.maximumChannels <= KernelLimits.maximumTelemetrySlots)
        #expect(MeterTapLimits.floorDBFS == -200)
        #expect(MeterTapLimits.floorDBFS == MeterBallistics.allowedFloorDBFS.lowerBound)
    }

    @Test func meterTapChannelIndexAccepts63AndRefuses64AndMinusOne() throws {
        let tap = try Self.accumulator(64)
        #expect(Self.feed(tap, 0, [0.5]) == .ok)
        #expect(Self.feed(tap, 63, [0.25]) == .ok)
        #expect(tap.reading(channel: 63) == .peak(0.25))
        #expect(tap.reading(channel: 0) == .peak(0.5))
        #expect(tap.reading(channel: 64) == nil)
        #expect(tap.reading(channel: -1) == nil)
        #expect(tap.reading(channel: Int.max) == nil)
        let before = Self.readings(tap)
        #expect(Self.feed(tap, 64, [1]) == .refused(.slotOutOfRange))
        #expect(Self.feed(tap, -1, [1]) == .refused(.slotOutOfRange))
        #expect(Self.feed(tap, Int.max, [1]) == .refused(.slotOutOfRange))
        #expect(tap.reset(channel: 64) == .refused(.slotOutOfRange))
        #expect(tap.reset(channel: -1) == .refused(.slotOutOfRange))
        #expect(Self.readings(tap) == before)
    }

    @Test func meterTapAResetOfAValidChannelReturnsOkAndAClearedChannelIsUnfed() throws {
        let tap = try Self.accumulator(2)
        Self.feed(tap, 1, [0.5])
        #expect(tap.reset(channel: 1) == .ok)
        #expect(tap.reading(channel: 1) == .unfed)
        #expect(tap.reset(channel: 0) == .ok)
    }

    @Test func meterTapPublishRangeAcceptsAnExactFitAndRefusesOneMore() throws {
        let slots = try Self.slots(8)
        let tap = try Self.accumulator(4)
        for channel in 0..<4 { Self.feed(tap, channel, [0.5]) }
        #expect(Self.publish(tap, slots, firstSlot: 5) == .refused(.slotOutOfRange))
        #expect(Self.allUnpublished(slots))
        #expect(Self.readings(tap) == [.peak(0.5), .peak(0.5), .peak(0.5), .peak(0.5)])
        #expect(Self.publish(tap, slots, firstSlot: 4) == .ok)
        for slot in 0..<4 { #expect(Self.isUnpublished(slots, slot)) }
        for slot in 4..<8 { #expect(Self.close(Self.level(slots, slot), Self.halfDBFS)) }
    }

    @Test func meterTapSixtyFourChannelsFitSixtyFourSlotsAndNotSixtyThree() throws {
        let tap = try Self.accumulator(64)
        for channel in 0..<64 { Self.feed(tap, channel, [0.5]) }
        let tight = try Self.slots(63)
        #expect(Self.publish(tap, tight) == .refused(.slotOutOfRange))
        #expect(Self.allUnpublished(tight))
        #expect(Self.readings(tap).allSatisfy { $0 == .peak(0.5) })
        let exact = try Self.slots(64)
        #expect(Self.publish(tap, exact) == .ok)
        #expect(Self.sample(exact, 63) != nil)
    }

    @Test func meterTapPublishRefusesNegativeAndOverflowingFirstSlotsWithoutTrapping() throws {
        let slots = try Self.slots(4)
        let tap = try Self.accumulator(2)
        Self.feed(tap, 0, [0.5])
        Self.feed(tap, 1, [.nan])
        let before = Self.readings(tap)
        for firstSlot in [-1, Int.min, Int.max, Int.max - 1, 3] {
            #expect(Self.publish(tap, slots, firstSlot: firstSlot) == .refused(.slotOutOfRange), "\(firstSlot)")
            #expect(Self.allUnpublished(slots), "\(firstSlot)")
            #expect(Self.readings(tap) == before, "\(firstSlot)")
        }
        #expect(Self.publish(tap, slots, firstSlot: 2) == .ok)
        #expect(Self.sample(slots, 2) != nil)
    }

    @Test func meterTapARefusedPublishWritesNothingEvenWhenTheLeadingChannelIsUnfed() throws {
        let slots = try Self.slots(4)
        let tap = try Self.accumulator(3)
        Self.feed(tap, 1, [0.5])
        Self.feed(tap, 2, [0.25])
        let before = Self.readings(tap)
        #expect(before == [.unfed, .peak(0.5), .peak(0.25)])
        for firstSlot in [-1, 3] {
            #expect(Self.publish(tap, slots, firstSlot: firstSlot) == .refused(.slotOutOfRange), "\(firstSlot)")
            #expect(Self.allUnpublished(slots), "\(firstSlot)")
            #expect(Self.readings(tap) == before, "\(firstSlot)")
        }
    }

    @Test func meterTapARefusedPublishWritesNoSlotAndResetsNoChannel() throws {
        let slots = try Self.slots(8)
        let tap = try Self.accumulator(4)
        Self.feed(tap, 0, [0.5])
        Self.feed(tap, 1, [.nan])
        Self.feed(tap, 2, [0])
        let before = Self.readings(tap)
        #expect(before == [.peak(0.5), .invalid, .peak(0), .unfed])
        for firstSlot in [5, 6, 7, 8, -1, Int.max] {
            #expect(Self.publish(tap, slots, firstSlot: firstSlot) == .refused(.slotOutOfRange), "\(firstSlot)")
            #expect(Self.allUnpublished(slots), "\(firstSlot)")
            #expect(Self.readings(tap) == before, "\(firstSlot)")
        }
    }
}
