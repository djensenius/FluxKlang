// #64 M2 single-producer single-consumer ring: fixed capacity, refusing, FIFO. Storage is allocated once in
// `init` and released only in `deinit`. Reference model; not RT-certified.
import Synchronization

/// A bounded, lock-free single-producer single-consumer FIFO. Reference model; not RT-certified.
///
/// Exactly one producer context may call `tryPush` and exactly one consumer context may call `tryPop` and
/// `popAll`; `init` refuses any policy that declares otherwise. These methods stay internal because composed
/// handoffs (`FanOutHandoff`, M5 lanes, E4) call them directly. `makeProducer()` and `makeConsumer()` optionally
/// hand out one non-copyable endpoint per side, which protects only callers that use them; the M5
/// `ProducerToken` is the follow-up for the rest.
///
/// Publication protocol. `head` and `tail` are monotonically increasing `UInt64` indices that wrap with `&+`;
/// `tail &- head` is the number of readable elements, at most `capacity`.
/// - Producer: loads `tail` relaxed (it owns it) and `head` acquiring, writes the slot, then stores `tail`
///   releasing, so the consumer that acquires the new `tail` also sees the element.
/// - Consumer: loads `head` relaxed (it owns it) and `tail` acquiring, reads the slot, then stores `head`
///   releasing, so the producer that acquires the new `head` sees the read finish before it reuses the slot.
///
/// Slots come from a per-side cursor that wraps at `capacity` rather than from `index % capacity`: when
/// `capacity` is not a power of two, `index % capacity` is discontinuous where the index wraps past
/// `UInt64.max`, so two live elements could share a slot.
///
/// `@unchecked Sendable`: `writeSlot`, `readSlot` and the slots are safe only under single-producer,
/// single-consumer use, which R2 validation in `init` declares; the optional endpoints enforce single use only
/// for callers that use them.
final class SPSCRing<Element: BitwiseCopyable>: @unchecked Sendable {
    /// Why `init` refused to prepare a ring.
    enum PreparationError: Error, Equatable, Sendable {
        /// The policy fails `HandoffPolicy.validate()`, or declares more than one producer (R2).
        case policy(HandoffPolicyError)
        /// The policy is valid but needs a different container.
        case unsupportedPolicy(Unsupported)
    }

    /// Valid policies that this ring does not serve.
    enum Unsupported: Sendable, Equatable {
        /// The M4 reserved-critical ring.
        case reservedCritical
        /// M8 telemetry slots. `latestOnly` is defensive: after `validate()`, R4 ties it to `overwriteLatest`,
        /// which `init` refuses first, so it is unreachable.
        case overwriteLatest, latestOnly
    }

    let policy: HandoffPolicy
    let capacity: Int

    private let storage: UnsafeMutablePointer<Element>
    private let slotCount: UInt64
    private let head: Atomic<UInt64>
    private let tail: Atomic<UInt64>
    private let refused: Atomic<UInt64>
    private let producerClaimed = Atomic<Bool>(false)
    private let consumerClaimed = Atomic<Bool>(false)
    /// Owned by the producer only.
    private var writeSlot = 0
    /// Owned by the consumer only.
    private var readSlot = 0

    /// Validates `policy` and allocates `policy.capacity` slots. Control-side only.
    ///
    /// Beyond `HandoffPolicy.validate()`, refuses more than one producer with `.policy(.violates(.r2Cardinality))`
    /// and reserved-critical, overwrite-latest or latest-only policies with `.unsupportedPolicy`.
    convenience init(policy: HandoffPolicy) throws(PreparationError) {
        try self.init(policy: policy, startingIndex: 0)
    }

    /// Test seam: starts `head` and `tail` at `startingIndex` so tests can cross the `UInt64` wrap, and the
    /// refusal counter at `startingRefusals` so tests can reach saturation.
    init(policy: HandoffPolicy, startingIndex: UInt64, startingRefusals: UInt64 = 0) throws(PreparationError) {
        do {
            try policy.validate()
        } catch {
            throw .policy(error)
        }
        guard policy.producers.maximum == 1 else { throw .policy(.violates(.r2Cardinality)) }
        switch policy.overflow {
        case .refuseProducer: break
        case .overwriteLatest: throw .unsupportedPolicy(.overwriteLatest)
        case .reservedCritical: throw .unsupportedPolicy(.reservedCritical)
        }
        switch policy.ordering {
        case .fifo, .fifoPerProducer, .completeMessagesFIFO: break
        case .latestOnly: throw .unsupportedPolicy(.latestOnly)  // Defensive: unreachable after R4 + overflow.
        }
        self.policy = policy
        capacity = policy.capacity
        slotCount = UInt64(truncatingIfNeeded: policy.capacity)
        storage = UnsafeMutablePointer<Element>.allocate(capacity: policy.capacity)
        head = Atomic(startingIndex)
        tail = Atomic(startingIndex)
        refused = Atomic(startingRefusals)
    }

    deinit {
        storage.deallocate()
    }

    /// Producer only. Appends `value`, or returns `.refused(.full)` and counts the refusal.
    func tryPush(_ value: Element) -> KernelStatus {
        let next = tail.load(ordering: .relaxed)
        guard next &- head.load(ordering: .acquiring) < slotCount else {
            let count = refused.load(ordering: .relaxed)
            if count != .max { refused.store(count &+ 1, ordering: .relaxed) }
            return .refused(.full)
        }
        (storage + writeSlot).initialize(to: value)
        writeSlot = writeSlot &+ 1 == capacity ? 0 : writeSlot &+ 1
        tail.store(next &+ 1, ordering: .releasing)
        return .ok
    }

    /// Consumer only. Removes and returns the oldest element, or `nil` without side effects when empty.
    func tryPop() -> Element? {
        let current = head.load(ordering: .relaxed)
        guard current != tail.load(ordering: .acquiring) else { return nil }
        let value = readNext()
        head.store(current &+ 1, ordering: .releasing)
        return value
    }

    /// Consumer only. Pops up to `min(max(limit, 0), available, capacity)` elements in FIFO order and returns
    /// the count. Each element is released to the producer before `body` sees it. `body` may pop re-entrantly;
    /// this call then stops at the `tail` it acquired on entry, or earlier if `body` has already passed it.
    @discardableResult
    func popAll(limit: Int, _ body: (Element) -> Void) -> Int {
        let end = tail.load(ordering: .acquiring)
        let bound = min(UInt64(truncatingIfNeeded: max(limit, 0)), slotCount)
        var popped: UInt64 = 0
        while popped < bound {
            let current = head.load(ordering: .relaxed)
            // `end &- current` is 1...capacity only while `current` is before `end`.
            let remaining = end &- current
            guard remaining != 0, remaining <= slotCount else { break }
            let value = readNext()
            head.store(current &+ 1, ordering: .releasing)
            popped &+= 1
            body(value)
        }
        return Int(truncatingIfNeeded: popped)
    }

    /// Producer refusals since `init`; saturates at `UInt64.max`.
    var refusedCount: UInt64 { refused.load(ordering: .relaxed) }

    /// Test seam: the storage address, which never changes after `init`.
    var storageBaseAddress: UnsafeRawPointer { UnsafeRawPointer(storage) }

    private func readNext() -> Element {
        let value = storage[readSlot]
        readSlot = readSlot &+ 1 == capacity ? 0 : readSlot &+ 1
        return value
    }
}

// D4: optional non-copyable endpoints. Each side can be claimed once. They are deliberately not `Sendable`, so
// an endpoint can only move to another task by `consume` and can never be shared by two concurrent tasks.
extension SPSCRing {
    struct Producer: ~Copyable {
        fileprivate let ring: SPSCRing<Element>
        func tryPush(_ value: Element) -> KernelStatus { ring.tryPush(value) }
    }

    struct Consumer: ~Copyable {
        fileprivate let ring: SPSCRing<Element>
        func tryPop() -> Element? { ring.tryPop() }
        @discardableResult
        func popAll(limit: Int, _ body: (Element) -> Void) -> Int { ring.popAll(limit: limit, body) }
    }

    /// Control-side. The producer endpoint the first time, then `nil`.
    func makeProducer() -> Producer? {
        guard producerClaimed.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else {
            return nil
        }
        return Producer(ring: self)
    }

    /// Control-side. The consumer endpoint the first time, then `nil`.
    func makeConsumer() -> Consumer? {
        guard consumerClaimed.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else {
            return nil
        }
        return Consumer(ring: self)
    }
}

@available(*, unavailable)
extension SPSCRing.Producer: Sendable {}

@available(*, unavailable)
extension SPSCRing.Consumer: Sendable {}
