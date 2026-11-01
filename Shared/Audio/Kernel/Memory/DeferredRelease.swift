// #64 M6 deferred release: render hands retired object references to control, which releases them, so no
// `deinit` ever runs on the render path. Reference model; not RT-certified.
import Synchronization

/// A render-to-control queue of retained object references awaiting release. Reference model; not RT-certified.
///
/// Render calls `retire(_:frame:)` with a +1 `Unmanaged` reference and never releases it; control calls
/// `reclaim()`, which balances each retain with exactly one `release()`. That release is where a payload's
/// `deinit` may run, so it runs on control only.
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
/// full. An unreserved retire past capacity is the defensive path: it raises `.retireBacklog` on `scope`,
/// returns `.refused(.full)`, and leaves the +1 with the caller (never released on render).
///
/// `reservedCount` is a plain control-owned `Int` in `0...capacity`. It never wraps, and `reclaim` and
/// `cancelReservation` clamp it at 0. This matters only when unreserved retires have occurred.
///
/// `@unchecked Sendable`: one render thread may call `retire`, and one control thread may call everything else.
/// `init` validates that policy. Teardown (`deinit`) is control-side and requires a detached render side (D10).
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
        do {
            ring = try SPSCRing(policy: policy)
        } catch {
            switch error {
            case .policy(let violation): throw .policy(violation)
            case .unsupportedPolicy: throw .requires(.refuseProducer)  // Unreachable after the checks above.
            }
        }
        self.policy = policy
        capacity = policy.capacity
        self.faults = faults
        self.scope = scope
    }

    /// Control-side teardown: releases whatever render retired and control never reclaimed.
    deinit {
        reclaim()
    }

    /// Render. Hands `object` (+1) to control. If the queue is full, it raises `.retireBacklog`, returns
    /// `.refused(.full)` and leaves the +1 with the caller. It never releases and never allocates.
    func retire(_ object: Unmanaged<AnyObject>, frame: Int64) -> KernelStatus {
        let status = ring.tryPush(UInt(bitPattern: object.toOpaque()))
        if status != .ok { _ = faults.raise(scope, .retireBacklog, frame: frame) }
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
    /// This is the only place a retired object's `deinit` can run. Returns how many were released.
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
