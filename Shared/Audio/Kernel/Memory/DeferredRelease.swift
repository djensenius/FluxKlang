// #64 M6 deferred release: render hands retired object references to control, which releases them, so render
// never releases a reference this queue owns. Reference model; not RT-certified.
import Synchronization

/// A render-to-control queue of retained object references awaiting release. Reference model; not RT-certified.
///
/// Render calls `retire(_:frame:)` with a +1 `Unmanaged` reference and never releases it; control calls
/// `reclaim()`, which balances each retain with exactly one `release()`, on control.
///
/// Release versus destruction. The guarantee is about the references this queue owns: each is released on
/// control, never on render. Where the object's `deinit` then runs is not the queue's to control:
/// - Destruction happens at the *last* release, which is ours only if no external alias outlives it. An alias
///   held elsewhere (another owner, a capture, a cache) is released by its holder, on that holder's thread. To
///   keep render free of destruction, the payload's owner must ensure render holds no strong alias, and that
///   other aliases are released off render.
/// - Our last release destroys synchronously on control for nonisolated destruction, the default even for
///   global-actor types. An explicitly `isolated deinit` goes through `swift_task_deinitOnExecutor`: it may
///   run inline on control when that executor is available, or be scheduled there later. `reclaim` does not
///   wait for scheduled destruction. Isolation, not ownership alone, determines actual destructor execution.
///
/// Storage is an `SPSCRing<UInt>` of pointer bit patterns. Its tail store releases and its consumer acquires,
/// so every render access to an object happens before control releases it. Relaxed ordering would let
/// `deinit` race with render's last reads. `popAll` publishes `head` before calling its body. That is sound
/// here because the body receives a copy of the bit pattern, not a reference into the slot. Render may
/// overwrite the slot at once without touching the object control is about to release.
///
/// Backpressure. Control-side `reserve()` admits a future render `retire` only while
/// `reservedCount < capacity`, and `reclaim()` returns one reservation per released object. When every retire
/// is reserved first, `ring count <= reservedCount <= capacity`, so a reserved `retire` never finds the ring
/// full. `RetiringExchange` always reserves first. Any other (direct) caller must have control `reserve()`
/// before render calls `retire` for that object. An unreserved retire skews the accounting: a later `reclaim`
/// returns a reservation nobody took, and the clamp absorbs it, so other users may meet spurious defensive
/// refusals. It never causes a leak or a double release. An unreserved retire past capacity is the defensive
/// path: it raises `.retireBacklog` on `scope`, returns `.refused(.full)`, and leaves the +1 with the caller
/// (never released on render).
///
/// `reservedCount` is a plain control-owned `Int` in `0...capacity`. It never wraps, and `reclaim` and
/// `cancelReservation` clamp it at 0. This matters only when unreserved retires have occurred.
///
/// Progress. `retire` is wait-free and bounded on render. `reclaim` makes up to `capacity` releases on control,
/// each of which may run a payload `deinit` (see above). Their duration is the payload's and lies outside
/// render's bounded guarantee.
///
/// `@unchecked Sendable`: one render thread may call `retire`, and one control thread may call everything else.
/// Every user of a shared queue (for example several `RetiringExchange`s) must use that same render/control
/// thread pair. This is documented, not enforced. `init` validates the policy. Teardown (`deinit`) is
/// control-side and requires a detached render side (D10).
final class DeferredReleaseQueue: @unchecked Sendable {
    /// Why `init` refused to prepare a retire queue.
    enum PreparationError: Error, Equatable, Sendable {
        /// The policy fails `HandoffPolicy.validate()`, or declares more than one producer (R2).
        case policy(HandoffPolicyError)
        /// The policy is valid but is not a render-to-control, refusing retire queue.
        case requires(Requirement)
    }

    /// What a retire queue's policy must declare.
    enum Requirement: Sendable, Equatable {
        case retirePurpose, renderProducer, controlConsumer, refuseProducer
    }

    let policy: HandoffPolicy
    let capacity: Int

    private let ring: SPSCRing<UInt>
    private let faults: FaultLatch
    private let scope: FaultScope
    /// Unretained aliases of `ring` and `faults`, for render. The strong `let`s above own both for this queue's
    /// whole life, so these are valid whenever `self` is. Borrowing through them (`_withUnsafeGuaranteedRef`)
    /// avoids the retain/release that reading a stored class reference costs in an unoptimised (`-Onone`) build.
    private let ringRef: Unmanaged<SPSCRing<UInt>>
    private let faultsRef: Unmanaged<FaultLatch>
    /// Control-owned; reservations not yet returned by `reclaim` or `cancelReservation`.
    private var reserved = 0

    /// Control-side preparation. Requires `purpose == .retire`, render to control, and `.refuseProducer`.
    /// The fault scope is not checked against `faults`; an unprepared scope still shows in
    /// `FaultLatch.unknownScopeFaults`.
    init(policy: HandoffPolicy, faults: FaultLatch, scope: FaultScope) throws(PreparationError) {
        do {
            try policy.validate()
        } catch {
            throw .policy(error)
        }
        guard policy.purpose == .retire else { throw .requires(.retirePurpose) }
        guard policy.producer == .render else { throw .requires(.renderProducer) }
        // Defensive: R5 already ties retire to a control consumer.
        guard policy.consumer == .control else { throw .requires(.controlConsumer) }
        guard policy.overflow == .refuseProducer else { throw .requires(.refuseProducer) }
        let ring: SPSCRing<UInt>
        do {
            ring = try SPSCRing(policy: policy)
        } catch {
            switch error {
            case .policy(let violation): throw .policy(violation)
            case .unsupportedPolicy: throw .requires(.refuseProducer)  // Unreachable after the checks above.
            }
        }
        self.ring = ring
        ringRef = Unmanaged.passUnretained(ring)
        self.policy = policy
        capacity = policy.capacity
        self.faults = faults
        faultsRef = Unmanaged.passUnretained(faults)
        self.scope = scope
    }

    /// Control-side teardown: releases whatever render retired and control never reclaimed.
    deinit {
        reclaim()
    }

    /// Render. Hands `object` (+1) to control. If the queue is full, it raises `.retireBacklog`, returns
    /// `.refused(.full)` and leaves the +1 with the caller. It never releases and never allocates. Control must
    /// have `reserve()`d a slot for this retire (see the type's backpressure notes). It borrows the ring and the
    /// fault latch through their unretained aliases, so it makes no retain/release even at `-Onone`.
    func retire(_ object: Unmanaged<AnyObject>, frame: Int64) -> KernelStatus {
        let bits = UInt(bitPattern: object.toOpaque())
        let status = ringRef._withUnsafeGuaranteedRef { $0.tryPush(bits) }
        if status != .ok {
            let scope = scope
            _ = faultsRef._withUnsafeGuaranteedRef { $0.raise(scope, .retireBacklog, frame: frame) }
        }
        return status
    }

    /// Control. Claims room for one future render `retire`; `false` when `capacity` retires are already
    /// reserved or unreclaimed.
    func reserve() -> Bool {
        guard reserved < capacity else { return false }
        reserved &+= 1
        return true
    }

    /// Control. Returns a reservation that will never be retired against, for example at exchange teardown.
    func cancelReservation() {
        if reserved > 0 { reserved &-= 1 }
    }

    /// Control. Releases up to `capacity` retired objects in FIFO order, returning one reservation for each.
    /// These are the queue's only releases of retired objects. A last reference's `deinit` may run here
    /// (see the type's notes). Returns how many were released.
    @discardableResult
    func reclaim() -> Int {
        let released = ring.popAll(limit: capacity) { bits in
            guard let raw = UnsafeRawPointer(bitPattern: bits) else { return }
            Unmanaged<AnyObject>.fromOpaque(raw).release()
        }
        reserved = max(reserved &- released, 0)
        return released
    }

    /// Control. Reservations not yet returned.
    var reservedCount: Int { reserved }

    /// Render retires refused because the queue was full; saturates at `UInt64.max`.
    var refusedCount: UInt64 { ring.refusedCount }
}
