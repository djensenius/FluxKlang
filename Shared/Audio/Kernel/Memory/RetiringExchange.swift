// #64 M6 retiring exchange: control publishes a replacement payload; render adopts it at a cycle boundary and
// retires the previous one to a `DeferredReleaseQueue`; control releases it later. Reference model; not
// RT-certified.
import Synchronization

/// A control-to-render, latest-wins handoff of one shared payload with deferred release.
/// Reference model; not RT-certified.
///
/// State:
/// - `pending: Atomic<UInt>` holds the bit pattern of a +1 reference that control published and render has not
///   adopted, or 0. Control is the only writer of non-zero values. Render is the only writer of 0, by
///   `exchange(0)`.
/// - `current` and `stalled` are render-owned. `current` is render's +1 reference, or 0. `stalled` is a
///   previous `current` whose retire was refused (the defensive path only).
/// - `adoptionRetires` and `pendingReserved` are control-owned. The first says whether the next payload
///   control publishes into an empty slot will displace a non-nil `current`. The second says whether the
///   payload in `pending` holds a retire reservation.
///
/// Ownership. Each payload is retained once, by `publish`, and released exactly once, on control:
/// - in `publish`, if it was superseded before render adopted it (render never saw it, so control releases it
///   directly; it is not routed through the retire queue);
/// - in `reclaim`, after render retired it;
/// - or in `deinit` (teardown with render detached, D10) if it is still pending, current or stalled.
///
/// Render never releases. `withCurrent` lends `current` without retaining it (`_withUnsafeGuaranteedRef`).
/// That is safe because `current` keeps its +1 until render itself retires it in a later `beginCycle`, and
/// control releases it only after taking it from the retire queue.
///
/// Protocol and ordering:
/// - `publish` (control) retains the payload. If `pending` is non-zero, it tries one
///   `compareExchange(observed → new)`. On success it releases `observed` (superseded) and keeps that payload's
///   reservation. On failure render has taken `observed`, so `pending` is 0 and stays 0 until control writes
///   it. Control then reserves a retire slot if `adoptionRetires` and stores the payload. If the reservation
///   is refused, it releases its own retain (the caller still owns the payload, so no `deinit` runs) and
///   returns `.refused(.full)`.
/// - `beginCycle` (render) first retries a stalled retire, then `exchange(0)`s `pending`. It makes the taken
///   payload `current` and retires the old `current`. If the retire is refused, it keeps the old one in
///   `stalled`.
/// - The publishing write (CAS success and store) is releasing, and render's `exchange` is acquiring. This
///   makes the payload's initialisation on control happen before render reads it in `withCurrent`. Relaxed is
///   unsound: render could see the pointer before the payload's fields, a data race and a possible read of
///   uninitialised memory. Render-to-control release of retired payloads is ordered by the retire ring (see
///   `DeferredReleaseQueue`).
/// - Control's initial load and CAS failure are relaxed. They only decide which path to take, and both paths
///   are correct for either value read: only control writes non-zero values, so a non-zero read is control's
///   own last write.
///
/// ABA. A freed address can be reused by a new payload, but no comparison can confuse the two. Render only
/// tests `!= 0`. Control's single CAS compares against a value it read in the same `publish`. Between that
/// read and the CAS, only render can change `pending`, and only to 0. Only control frees, and never inside
/// that window. A payload control frees has either been removed from `pending` by control itself (superseded)
/// or been handed back by render through the retire queue after render dropped it. Neither can still be in
/// `pending` or in `current`.
///
/// No counter here wraps: reservations are a bounded `Int` (see `DeferredReleaseQueue`), and there are no
/// generations.
///
/// Backpressure invariant, per exchange when the queue is not shared:
/// `retired + (pending ? 1 : 0) <= retire.capacity`. A pending payload adopted over a nil `current` retires
/// nothing and holds no reservation. That can happen only before this exchange's first retire.
///
/// Progress: every operation is wait-free. `publish` makes at most one CAS and `beginCycle` at most two
/// retires and one exchange; neither loops.
///
/// `@unchecked Sendable`: one control thread calls `publish`, `reclaim` and teardown; one render thread calls
/// `beginCycle` and `withCurrent`. Exchanges sharing a queue must share those two threads.
final class RetiringExchange<Payload: AnyObject & Sendable>: @unchecked Sendable {
    let retire: DeferredReleaseQueue

    private let pending = Atomic<UInt>(0)
    /// Render-owned.
    private var current: UInt
    /// Render-owned; a previous `current` whose retire was refused, or 0.
    private var stalled: UInt = 0
    /// Control-owned.
    private var adoptionRetires: Bool
    /// Control-owned.
    private var pendingReserved = false

    /// Control-side preparation. Retains `initial`, if any, as render's first `current`.
    init(initial: Payload?, retire: DeferredReleaseQueue) {
        self.retire = retire
        current = initial.map { Self.bits(Unmanaged.passRetained($0)) } ?? 0
        adoptionRetires = initial != nil
    }

    /// Control-side teardown; render must be detached (D10). Releases what is still pending, current or stalled,
    /// and returns their reservations to a possibly shared queue.
    deinit {
        let left = pending.exchange(0, ordering: .acquiring)
        if left != 0, pendingReserved { retire.cancelReservation() }
        if stalled != 0 { retire.cancelReservation() }
        Self.release(left)
        Self.release(stalled)
        Self.release(current)
    }

    /// Control. Makes `next` the payload render adopts at its next `beginCycle`, replacing (and releasing) any
    /// payload render has not adopted yet. `.refused(.full)` when the retire queue cannot guarantee room for the
    /// payload this adoption would displace; nothing changes and the caller keeps `next`.
    func publish(_ next: Payload) -> KernelStatus {
        let bits = Self.bits(Unmanaged.passRetained(next))
        let observed = pending.load(ordering: .relaxed)
        if observed != 0, pending.compareExchange(
            expected: observed, desired: bits, successOrdering: .releasing, failureOrdering: .relaxed).exchanged {
            Self.release(observed)
            return .ok
        }
        // `pending` is 0: it was empty, or render adopted `observed` after the load; only this call refills it.
        if adoptionRetires, !retire.reserve() {
            Self.release(bits)
            return .refused(.full)
        }
        pendingReserved = adoptionRetires
        adoptionRetires = true
        pending.store(bits, ordering: .releasing)
        return .ok
    }

    /// Render. Adopts the pending payload, if any, and retires the previous one; never releases or allocates.
    /// Returns `.ok` when it adopted, `.empty` when nothing was pending, and `.refused(.full)` when a retire was
    /// refused (the defensive path, which raised `.retireBacklog`). In that case the displaced payload is kept
    /// in `stalled`. Each later cycle retries it first and adopts nothing until the retry succeeds.
    func beginCycle(frame: Int64 = 0) -> KernelStatus {
        if stalled != 0 {
            guard retireBits(stalled, frame: frame) == .ok else { return .refused(.full) }
            stalled = 0
        }
        let taken = pending.exchange(0, ordering: .acquiring)
        guard taken != 0 else { return .empty }
        let old = current
        current = taken
        if old != 0, retireBits(old, frame: frame) != .ok {
            stalled = old
            return .refused(.full)
        }
        return .ok
    }

    /// Render. Lends the current payload to `body` without retaining it; `body` must not let it escape the call.
    func withCurrent<R>(_ body: (Payload?) -> R) -> R {
        guard let raw = UnsafeRawPointer(bitPattern: current) else { return body(nil) }
        return Unmanaged<Payload>.fromOpaque(raw)._withUnsafeGuaranteedRef { body($0) }
    }

    /// Control. Releases every payload render has retired to the (possibly shared) queue; the only place a
    /// render-seen payload's `deinit` runs before teardown. Returns how many were released.
    @discardableResult
    func reclaim() -> Int {
        retire.reclaim()
    }

    private func retireBits(_ bits: UInt, frame: Int64) -> KernelStatus {
        guard let raw = UnsafeRawPointer(bitPattern: bits) else { return .ok }
        return retire.retire(Unmanaged<AnyObject>.fromOpaque(raw), frame: frame)
    }

    private static func bits(_ reference: Unmanaged<Payload>) -> UInt {
        UInt(bitPattern: reference.toOpaque())
    }

    /// Control only.
    private static func release(_ bits: UInt) {
        guard let raw = UnsafeRawPointer(bitPattern: bits) else { return }
        Unmanaged<Payload>.fromOpaque(raw).release()
    }
}
