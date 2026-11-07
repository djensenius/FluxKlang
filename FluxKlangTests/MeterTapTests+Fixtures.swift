import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MeterTapTests {
    /// `20 * log10(0.5)`.
    static let halfDBFS = -6.020599913279624
    /// `20 * log10(0.25)`.
    static let quarterDBFS = -12.041199826559248

    static func accumulator(_ count: Int) throws -> MeterTapAccumulator {
        try MeterTapAccumulator(channelCount: count)
    }

    @discardableResult
    static func feed(_ accumulator: MeterTapAccumulator, _ channel: Int, _ samples: [Float]) -> KernelStatus {
        samples.withUnsafeBufferPointer { accumulator.accumulate(channel: channel, samples: $0) }
    }

    /// Slots built the way `MeterDisplayTests.telemetrySlots(_:)` builds them (restated: that helper is not shared).
    static func slots(_ count: Int) throws -> TelemetrySlots<MeterTapValue> {
        let policy = HandoffPolicy(purpose: .telemetry, producer: .render,
                                   producers: ProducerCardinality(maximum: 1, evidence: .appOwned), consumer: .ui,
                                   consumers: 1, capacity: count, ordering: .latestOnly, deadline: .none,
                                   overflow: .overwriteLatest, lifetime: .session)
        return try TelemetrySlots<MeterTapValue>(policy: policy, slotCount: count)
    }

    @discardableResult
    static func publish(_ accumulator: MeterTapAccumulator, _ slots: TelemetrySlots<MeterTapValue>,
                        firstSlot: Int = 0) -> KernelStatus {
        MeterTapPublisher.publish(accumulator, to: slots, firstSlot: firstSlot, stamp: stamp)
    }

    static func sample(_ slots: TelemetrySlots<MeterTapValue>, _ slot: Int) -> TelemetrySample<MeterTapValue>? {
        if case .measured(let sample) = slots.latest(slot: slot) { return sample }
        return nil
    }

    static func level(_ slots: TelemetrySlots<MeterTapValue>, _ slot: Int) -> Double? {
        sample(slots, slot)?.value.peakDBFS
    }

    static func isUnpublished(_ slots: TelemetrySlots<MeterTapValue>, _ slot: Int) -> Bool {
        if case .unavailable(.neverPublished) = slots.latest(slot: slot) { return true }
        return false
    }

    static func allUnpublished(_ slots: TelemetrySlots<MeterTapValue>) -> Bool {
        (0..<slots.slotCount).allSatisfy { isUnpublished(slots, $0) }
    }

    static func readings(_ accumulator: MeterTapAccumulator) -> [MeterTapReading?] {
        (0..<accumulator.channelCount).map { accumulator.reading(channel: $0) }
    }

    static func close(_ actual: Double?, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) <= tolerance
    }

    /// Equal slot contents, comparing NaN values by `isNaN` (NaN is never equal to itself).
    static func same(_ lhs: TelemetrySample<MeterTapValue>?, _ rhs: TelemetrySample<MeterTapValue>?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        let values = lhs.value.peakDBFS.isNaN ? rhs.value.peakDBFS.isNaN : lhs.value == rhs.value
        return values && lhs.stamp == rhs.stamp && lhs.sequence == rhs.sequence
    }

    /// A fixed integer-formula ramp: `index / 255` for 0...255.
    static var ramp: [Float] { (0...255).map { Float($0) / 255 } }
}
