// #64 telemetry slots: render publishes latest-only measurements that the UI or control side reads without
// locks, allocation or waiting. Each slot is a single-producer, single-consumer triple buffer.
// Reference model; not RT-certified.

import Synchronization

/// When a telemetry value was measured. Reference model; not RT-certified.
struct TelemetryStamp: Sendable, BitwiseCopyable, Equatable {
    let clockGeneration: UInt64
    let frame: Int64
}

/// One published measurement. `sequence` starts at 1 for each slot and wraps.
/// Reference model; not RT-certified.
struct TelemetrySample<Value: BitwiseCopyable>: BitwiseCopyable {
    let value: Value
    let stamp: TelemetryStamp
    let sequence: UInt64
}

extension TelemetrySample: Sendable where Value: Sendable {}
extension TelemetrySample: Equatable where Value: Equatable {}

/// Why a read has no measurement to show. Reference model; not RT-certified.
enum TelemetryUnavailable: Sendable, Equatable {
    case neverPublished, invalidSlot, staleGeneration, tooOld
}

/// A measurement, or the reason there is none. Reference model; not RT-certified.
enum TelemetryRead<Value: BitwiseCopyable>: BitwiseCopyable {
    case measured(TelemetrySample<Value>)
    case unavailable(TelemetryUnavailable)
}

extension TelemetryRead: Sendable where Value: Sendable {}
extension TelemetryRead: Equatable where Value: Equatable {}

extension KernelLimits {
    /// Largest `TelemetrySlots` slot count (inclusive): one slot per meter, scope and voice probe with
    /// headroom, while the preallocated cells (3 per slot) stay small for any realistic `Value`.
    static let maximumTelemetrySlots = 4_096
}

/// Latest-only telemetry from render (the single producer) to UI or control (the single consumer).
///
/// Exactly one producer and one consumer per instance. This is enforced at preparation by policy validation
/// (`producer == .render`, `producers.maximum == 1`, R1 `consumers == 1`), not at runtime. Misuse, such as a
/// second concurrent publisher or reader, permanently breaks the back/middle/front index permutation and
/// reads tear.
///
/// Each slot owns three cells. The producer owns one (back), the consumer owns one (front), and the third
/// (middle) is handed between them through the slot's atomic state word, which holds the middle index in
/// bits 0–1 and the dirty bit (`dirtyBit`). The back and front indices never change hands except through
/// that word, so each lives in role-local storage. Calls are wait-free: `publish` does one exchange, and
/// `latest` does one relaxed load plus at most one exchange. There are no loops.
///
/// Reference model; not RT-certified.
///
/// `@unchecked Sendable`: cells change owner only through the per-slot atomic exchange, and the back and front
/// index storage is touched by one role each (producer and consumer respectively), given the single-producer,
/// single-consumer contract above.
final class TelemetrySlots<Value: BitwiseCopyable>: @unchecked Sendable {
    /// Alias for `KernelLimits.maximumTelemetrySlots`; a generic type cannot hold a static stored property.
    static var maximumSlots: Int { KernelLimits.maximumTelemetrySlots }

    enum PreparationError: Error, Equatable, Sendable {
        /// The policy fails `validate()`, or is not a single-producer render → UI/control telemetry policy.
        case policy(HandoffPolicyError)
        /// `slotCount` is outside `1...maximumSlots`.
        case slotCountOutOfRange
        /// `slotCount` differs from `policy.capacity`, so the declared capacity would not match the storage.
        case capacityMismatch(declared: Int, slots: Int)
    }

    let slotCount: Int

    private static var dirtyBit: UInt8 { 0b100 }
    private static var indexMask: UInt8 { 0b011 }
    /// Consumer-local flag: the front cell holds a published sample.
    private static var hasFrontBit: UInt8 { 0b100 }

    /// `slotCount * 3` cells; cell `slot * 3 + index`.
    private let cells: UnsafeMutablePointer<TelemetrySample<Value>>
    /// Shared per-slot word: middle index and dirty bit.
    private let states: UnsafeMutablePointer<Atomic<UInt8>>
    /// Producer-only per-slot back index.
    private let producerBack: UnsafeMutablePointer<UInt8>
    /// Producer-only per-slot sequence of the last publish.
    private let producerSequence: UnsafeMutablePointer<UInt64>
    /// Consumer-only per-slot front index plus `hasFrontBit`.
    private let consumerFront: UnsafeMutablePointer<UInt8>

    /// Control-side. Requires a valid policy with `purpose == .telemetry` (so latest-only and overwrite-latest
    /// under R4), `producer == .render` and exactly one producer, and `slotCount == policy.capacity`.
    init(policy: HandoffPolicy, slotCount: Int) throws(PreparationError) {
        do {
            try policy.validate()
        } catch {
            throw .policy(error)
        }
        guard policy.purpose == .telemetry else { throw .policy(.violates(.r4LatestOnly)) }
        guard policy.producer == .render else { throw .policy(.violates(.r5TelemetryNotRender)) }
        guard policy.producers.maximum == 1 else { throw .policy(.violates(.r2Cardinality)) }
        guard slotCount >= 1, slotCount <= Self.maximumSlots else { throw .slotCountOutOfRange }
        guard slotCount == policy.capacity else {
            throw .capacityMismatch(declared: policy.capacity, slots: slotCount)
        }
        self.slotCount = slotCount

        let cellCount = slotCount * 3
        let layout = MemoryLayout<TelemetrySample<Value>>.self
        let raw = UnsafeMutableRawPointer.allocate(byteCount: cellCount * layout.stride, alignment: layout.alignment)
        // Zero bytes so no path, even a faulty one, can read uninitialised memory; `hasFrontBit` still decides
        // whether a cell is ever shown as measured. Then rebind to the trivial sample type.
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: cellCount * layout.stride)
        cells = raw.bindMemory(to: TelemetrySample<Value>.self, capacity: cellCount)
        states = .allocate(capacity: slotCount)
        producerBack = .allocate(capacity: slotCount)
        producerSequence = .allocate(capacity: slotCount)
        consumerFront = .allocate(capacity: slotCount)
        for slot in 0..<slotCount {
            (states + slot).initialize(to: Atomic<UInt8>(1))
            (producerBack + slot).initialize(to: 0)
            (producerSequence + slot).initialize(to: 0)
            (consumerFront + slot).initialize(to: 2)
        }
    }

    deinit {
        states.deinitialize(count: slotCount)
        states.deallocate()
        UnsafeMutableRawPointer(cells).deallocate()
        producerBack.deallocate()
        producerSequence.deallocate()
        consumerFront.deallocate()
    }

    /// Render only. Overwrites the slot's latest value; refuses an out-of-range slot.
    func publish(slot: Int, value: Value, stamp: TelemetryStamp) -> KernelStatus {
        guard slot >= 0, slot < slotCount else { return .refused(.slotOutOfRange) }
        let sequence = producerSequence[slot] &+ 1
        producerSequence[slot] = sequence
        let back = producerBack[slot]
        cells[slot &* 3 &+ Int(back)] = TelemetrySample(value: value, stamp: stamp, sequence: sequence)
        // Release publishes the cell write above to the consumer's acquiring exchange. Acquire pairs with the
        // consumer's releasing exchange, so its reads of the cell it handed back finish before we overwrite it.
        let old = states[slot].exchange(back | Self.dirtyBit, ordering: .acquiringAndReleasing)
        producerBack[slot] = old & Self.indexMask
        return .ok
    }

    /// UI or control only. Returns the most recent complete sample for the slot.
    func latest(slot: Int) -> TelemetryRead<Value> {
        guard slot >= 0, slot < slotCount else { return .unavailable(.invalidSlot) }
        var front = consumerFront[slot]
        // Relaxed is enough: a clean word means we keep our own front, and a dirty word is only acted on through
        // the exchange below, which carries the ordering. Only this consumer clears the dirty bit, so a dirty
        // load cannot turn clean before the exchange.
        if states[slot].load(ordering: .relaxed) & Self.dirtyBit != 0 {
            // Acquire sees the producer's cell write; release finishes our reads of the old front before the
            // producer can take it back as its next back cell.
            let old = states[slot].exchange(front & Self.indexMask, ordering: .acquiringAndReleasing)
            front = (old & Self.indexMask) | Self.hasFrontBit
            consumerFront[slot] = front
        }
        guard front & Self.hasFrontBit != 0 else { return .unavailable(.neverPublished) }
        return .measured(cells[slot &* 3 &+ Int(front & Self.indexMask)])
    }

    /// Applies the caller's staleness rule (D5). The generation must match exactly; the age is
    /// `frame - stamp.frame`, and overflow counts as too old. An age equal to `maximumAgeFrames` is still
    /// measured, and a negative `maximumAgeFrames` makes every sample too old. A negative age (a stamp from
    /// the future of `frame`) is measured, but a future stamp whose subtraction overflows is conservatively
    /// `tooOld`. `.unavailable` reads pass through unchanged.
    static func classify(_ read: TelemetryRead<Value>, generation: UInt64, frame: Int64,
                         maximumAgeFrames: Int64) -> TelemetryRead<Value> {
        guard case .measured(let sample) = read else { return read }
        guard sample.stamp.clockGeneration == generation else { return .unavailable(.staleGeneration) }
        let (age, overflow) = frame.subtractingReportingOverflow(sample.stamp.frame)
        guard maximumAgeFrames >= 0, !overflow, age <= maximumAgeFrames else { return .unavailable(.tooOld) }
        return read
    }
}
