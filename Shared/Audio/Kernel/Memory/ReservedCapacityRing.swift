// #64 M4 reserved-capacity ring: a single-producer single-consumer FIFO whose last `reserved` slots only
// critical (note-release) events may use. Exhausting the reserve refuses visibly and latches a scoped fault.
// Reference model; not RT-certified.
import Synchronization

/// A bounded SPSC FIFO with a critical reservation. Reference model; not RT-certified.
///
/// General events are refused with `.refused(.full)` once occupancy reaches `generalLimit`
/// (`capacity − reserved`). Critical events may fill the ring to `capacity`; beyond that they are refused with
/// `.refused(.criticalExhausted)` and `FaultLatch.raise(scope, .criticalExhausted, frame:)` is called, so an
/// exhausted reserve is never a silent discard. Nothing is merged, replaced or reordered: an event is admitted
/// whole or refused whole, and admitted events leave in FIFO order regardless of class. The type is meant to be
/// reused as one M5 fan-in lane.
///
/// Composition. Storage, slot cursors and the head/tail publication protocol are an inner `SPSCRing` with the
/// same policy except `overflow: .refuseProducer`; this type adds admission. The producer keeps a local
/// `pushed` count, and the consumer bumps `popped` after each successful inner pop. Both start at
/// `startingIndex` and are monotonic `UInt64`s that wrap with `&+`, so no comparison depends on a counter
/// small enough to wrap while a stale snapshot is in flight.
///
/// Conservative occupancy. Only the consumer advances `popped`, and a load never returns a value older than
/// one this thread already saw, so the producer's view `pushed &- popped` can only overestimate the true
/// occupancy (in `0...capacity`, never ambiguous modulo 2^64): a stale view refuses earlier and never
/// over-admits. Since `popped` is bumped after the inner ring's head store, it never runs ahead of that head.
///
/// Ordering: `popped` is stored releasing (after the inner head store, in program order) and loaded acquiring.
/// So when the producer reads `popped = P`, the inner ring's head store of `P` happens before the inner
/// `tryPush`'s own acquiring head load, which by coherence sees at least `P`. Hence "this check admits" implies
/// "the inner full check admits", and the boundaries never disagree. With relaxed ordering the inner load could
/// still see an older head than `P`; the inner ring would refuse where this check admitted, turning a free
/// reserve slot into a spurious `.criticalExhausted` fault. Slot reuse is ordered by the inner ring's head
/// protocol and, redundantly, by this pair (`popped` trails the inner head, so an admitted slot's last read
/// happens before its rewrite). Only the inner tail's release/acquire publishes elements to the consumer.
/// Sequential consistency is not needed.
///
/// Progress. `tryPush`, `tryPop` and `producerOccupancy` are wait-free: no retry loops, one acquiring load of
/// `popped`, one inner operation (itself wait-free), relaxed counter updates and, on critical exhaustion, one
/// wait-free `FaultLatch.raise`. `popAll` is bounded by `limit` and `capacity`. Nothing allocates after `init`.
///
/// `@unchecked Sendable`: `pushed` is touched only by the producer and the inner ring is safe only under SPSC
/// use, which R2 validation in `init` declares.
final class ReservedCapacityRing<Element: BitwiseCopyable>: @unchecked Sendable {
    /// Why `init` refused to prepare a ring.
    enum PreparationError: Error, Equatable, Sendable {
        /// The policy fails `HandoffPolicy.validate()` (R7 included), or declares more than one producer (R2).
        case policy(HandoffPolicyError)
        /// The policy is valid but its overflow is not `.reservedCritical`.
        case unsupportedPolicy(Unsupported)
        /// The reserve is below `KernelLimits.minimumCriticalReserve`, the note-carrying minimum that R7 defers
        /// to M4.
        case reserveBelowMinimum(Int)
        /// Defensive: the inner ring refused the derived `.refuseProducer` policy. Unreachable, because that
        /// policy differs from a validated reserved-critical policy only in an overflow that R4 and R8 accept.
        case innerRing(SPSCRing<Element>.PreparationError)
    }

    /// Valid overflow policies that this ring does not serve.
    enum Unsupported: Sendable, Equatable {
        case refuseProducer, overwriteLatest
    }

    let policy: HandoffPolicy
    let capacity: Int
    /// Slots only critical events may use.
    let reserved: Int
    /// `capacity − reserved`: the occupancy at which general events are refused.
    let generalLimit: Int

    private let ring: SPSCRing<Element>
    private let faults: FaultLatch
    private let scope: FaultScope
    private let generalAdmission: UInt64
    private let criticalAdmission: UInt64
    /// Successful pops; written by the consumer only.
    private let popped: Atomic<UInt64>
    private let refusedGeneral: Atomic<UInt64>
    private let refusedCritical: Atomic<UInt64>
    /// Successful pushes; owned by the producer only.
    private var pushed: UInt64

    /// Validates `policy` and allocates `policy.capacity` slots. Control-side only. `scope` should be prepared
    /// in `faults`; an unprepared scope is still counted in `FaultLatch.unknownScopeFaults`.
    convenience init(policy: HandoffPolicy, faults: FaultLatch, scope: FaultScope) throws(PreparationError) {
        try self.init(policy: policy, faults: faults, scope: scope, startingIndex: 0)
    }

    /// Test seam: starts every index at `startingIndex` so tests can cross the `UInt64` wrap, and both refusal
    /// counters at `startingRefusals` so tests can reach saturation.
    init(policy: HandoffPolicy, faults: FaultLatch, scope: FaultScope, startingIndex: UInt64,
         startingRefusals: UInt64 = 0) throws(PreparationError) {
        do {
            try policy.validate()
        } catch {
            throw .policy(error)
        }
        guard policy.producers.maximum == 1 else { throw .policy(.violates(.r2Cardinality)) }
        let reserved: Int
        switch policy.overflow {
        case .reservedCritical(let value): reserved = value
        case .refuseProducer: throw .unsupportedPolicy(.refuseProducer)
        case .overwriteLatest: throw .unsupportedPolicy(.overwriteLatest)
        }
        guard reserved >= KernelLimits.minimumCriticalReserve else { throw .reserveBelowMinimum(reserved) }
        let inner = HandoffPolicy(
            purpose: policy.purpose, producer: policy.producer, producers: policy.producers,
            consumer: policy.consumer, consumers: policy.consumers, capacity: policy.capacity,
            ordering: policy.ordering, deadline: policy.deadline, overflow: .refuseProducer, lifetime: policy.lifetime)
        do {
            ring = try SPSCRing<Element>(policy: inner, startingIndex: startingIndex)
        } catch {
            throw .innerRing(error)
        }
        self.policy = policy
        self.faults = faults
        self.scope = scope
        self.reserved = reserved
        capacity = policy.capacity
        generalLimit = policy.capacity &- reserved
        generalAdmission = UInt64(truncatingIfNeeded: policy.capacity &- reserved)
        criticalAdmission = UInt64(truncatingIfNeeded: policy.capacity)
        popped = Atomic(startingIndex)
        pushed = startingIndex
        refusedGeneral = Atomic(startingRefusals)
        refusedCritical = Atomic(startingRefusals)
    }

    /// Producer only; wait-free. Appends `value`, or refuses it whole: a general event with `.refused(.full)`
    /// at `generalLimit`, a critical event with `.refused(.criticalExhausted)` at `capacity`, which also raises
    /// `.criticalExhausted` on `scope` at `frame`. Refusals are counted per class.
    func tryPush(_ value: Element, class eventClass: EventClass, frame: Int64) -> KernelStatus {
        let occupancy = pushed &- popped.load(ordering: .acquiring)
        switch eventClass {
        case .general:
            guard occupancy < generalAdmission else { return refuse(eventClass, frame: frame) }
        case .critical:
            guard occupancy < criticalAdmission else { return refuse(eventClass, frame: frame) }
        }
        // Defensive: unreachable, because the inner ring's occupancy never exceeds `occupancy` (see Ordering).
        guard ring.tryPush(value) == .ok else { return refuse(eventClass, frame: frame) }
        pushed &+= 1
        return .ok
    }

    /// Consumer only; wait-free. Removes and returns the oldest element, or `nil` without side effects.
    func tryPop() -> Element? {
        guard let value = ring.tryPop() else { return nil }
        notePopped()
        return value
    }

    /// Consumer only. Pops up to `min(max(limit, 0), available, capacity)` elements in FIFO order and returns
    /// the count. Each element is released to the producer before `body` sees it; `body` may pop re-entrantly
    /// (see `SPSCRing.popAll`).
    @discardableResult
    func popAll(limit: Int, _ body: (Element) -> Void) -> Int {
        ring.popAll(limit: limit) { value in
            notePopped()
            body(value)
        }
    }

    /// Producer only; wait-free. The producer's conservative occupancy, `0...capacity`: at least the true
    /// occupancy, because the consumer's count may be stale.
    var producerOccupancy: Int { Int(truncatingIfNeeded: pushed &- popped.load(ordering: .acquiring)) }

    /// General refusals since `init`; saturates at `UInt64.max`.
    var refusedGeneralCount: UInt64 { refusedGeneral.load(ordering: .relaxed) }

    /// Critical refusals (each also raised as a fault) since `init`; saturates at `UInt64.max`.
    var refusedCriticalCount: UInt64 { refusedCritical.load(ordering: .relaxed) }

    /// All refusals since `init`; saturates at `UInt64.max`.
    var refusedCount: UInt64 {
        let (sum, overflow) = refusedGeneralCount.addingReportingOverflow(refusedCriticalCount)
        return overflow ? .max : sum
    }

    /// Producer only: counts the refusal and, for a critical event, latches the scoped fault.
    private func refuse(_ eventClass: EventClass, frame: Int64) -> KernelStatus {
        switch eventClass {
        case .general:
            Self.bump(refusedGeneral)
            return .refused(.full)
        case .critical:
            Self.bump(refusedCritical)
            // A refused raise (unprepared scope) is still visible through `unknownScopeFaults`.
            _ = faults.raise(scope, .criticalExhausted, frame: frame)
            return .refused(.criticalExhausted)
        }
    }

    /// Consumer only; the single writer of `popped`. Releasing: see Ordering.
    private func notePopped() {
        popped.store(popped.load(ordering: .relaxed) &+ 1, ordering: .releasing)
    }

    /// Single-writer saturating increment.
    private static func bump(_ counter: borrowing Atomic<UInt64>) {
        let count = counter.load(ordering: .relaxed)
        if count != .max { counter.store(count &+ 1, ordering: .relaxed) }
    }
}
