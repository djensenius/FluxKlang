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
/// Fault chain (#190 FLP5). `init` mints one chain from `faults`, and `retire` holds its token for the whole call,
/// push included. Every fault is raised through that token, never through `FaultLatch.raise` directly; observers
/// read the authority's `isLatched` (which includes the contended fault) and `hasContendedFault`. A `retire` that
/// finds the token taken (a concurrent `retire`) does not push: it latches the authority's contended fault, counts
/// in `contendedRetireCount`, returns `.refused(.notOwner)` and leaves the +1 with the caller.
///
/// `reservedCount` is a plain control-owned `Int` in `0...capacity`. It never wraps, and `reclaim` and
/// `cancelReservation` clamp it at 0. This matters only when unreserved retires have occurred.
///
/// Progress (source level only). `retire` makes one token take (exchange), one ring push, on refusal one bounded
/// fault-scope lookup/raise, and one token put (store); a contended call makes one store and one counter add
/// instead of the push and put. Atomic lowering/target progress is unqualified; ARC/allocation/lock checks cover
/// only inspected configurations. Control `reclaim` releases up to `capacity` payloads; their `deinit` time is
/// outside render's source-level bound.
///
/// `@unchecked Sendable`: one render thread may call `retire`, and one control thread may call everything else.
/// Every user of a shared queue (for example several `RetiringExchange`s) must use that same render/control
/// thread pair. A concurrent second `retire` is refused as contended (see "Fault chain"), not raced; the
/// control-side methods are not guarded. `init` validates the policy. Teardown (`deinit`) is control-side and
/// requires a detached render side (D10).
final class DeferredReleaseQueue: @unchecked Sendable {
    /// Why `init` refused to prepare a retire queue.
    enum PreparationError: Error, Equatable, Sendable {
        /// The policy fails `HandoffPolicy.validate()`, or declares more than one producer (R2).
        case policy(HandoffPolicyError)
        /// The policy is valid but is not a render-to-control, refusing retire queue.
        case requires(Requirement)
        /// `faults` has minted its whole chain budget. Checked last, after the policy and the ring, so no other
        /// refusal consumes a budget unit.
        case chainBudgetExhausted
    }

    /// What a retire queue's policy must declare.
    enum Requirement: Sendable, Equatable {
        case retirePurpose, renderProducer, controlConsumer, refuseProducer
    }

    let policy: HandoffPolicy
    let capacity: Int

    private let ring: SPSCRing<UInt>
    private let authority: FaultChainAuthority
    /// This queue's only fault chain, minted in `init`; `retire` holds its token for the whole call.
    private let chain: FaultChain
    private let scope: FaultScope
    /// Unretained aliases of `ring`, `authority` and `chain`, for render. The strong `let`s above own them for this
    /// queue's whole life, so these are valid whenever `self` is. Borrowing through them (`_withUnsafeGuaranteedRef`)
    /// avoids the retain/release that reading a stored class reference costs in an unoptimised (`-Onone`) build.
    private let ringRef: Unmanaged<SPSCRing<UInt>>
    private let authorityRef: Unmanaged<FaultChainAuthority>
    private let chainRef: Unmanaged<FaultChain>
    /// Control-owned; reservations not yet returned by `reclaim` or `cancelReservation`.
    private var reserved = 0
    private let contended = Atomic<UInt64>(0)

    /// Control-side preparation. Requires `purpose == .retire`, render to control, and `.refuseProducer`, then
    /// mints one chain from `faults` (last). The fault scope is not checked against `faults`; an unprepared scope
    /// still shows in `FaultChainAuthority.unknownScopeFaults`.
    init(policy: HandoffPolicy, faults: FaultChainAuthority, scope: FaultScope) throws(PreparationError) {
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
        guard let chain = faults.mintChain() else { throw .chainBudgetExhausted }
        self.ring = ring
        ringRef = Unmanaged.passUnretained(ring)
        self.policy = policy
        capacity = policy.capacity
        authority = faults
        self.chain = chain
        authorityRef = Unmanaged.passUnretained(faults)
        chainRef = Unmanaged.passUnretained(chain)
        self.scope = scope
    }

    /// Control-side teardown: releases whatever render retired and control never reclaimed.
    deinit {
        reclaim()
    }

    /// Render. Hands `object` (+1) to control. If the queue is full, it raises `.retireBacklog` through the chain
    /// token, returns `.refused(.full)` and leaves the +1 with the caller. If another context holds the token, it
    /// pushes nothing, latches the contended fault and returns `.refused(.notOwner)`, again leaving the +1 with the
    /// caller. It never releases; allocation checks are probe-scoped. Control must have `reserve()`d a slot (see
    /// backpressure). Calls borrow the ring, authority and chain through unretained aliases; no retain/release was
    /// observed in the inspected configurations, including `-Onone` (FLP5 has not re-inspected them).
    func retire(_ object: Unmanaged<AnyObject>, frame: Int64) -> KernelStatus {
        // `_withUnsafeGuaranteedRef` cannot return a noncopyable value or consume a captured one, so the token
        // crosses the borrow through this optional.
        var held: FaultChainToken?
        chainRef._withUnsafeGuaranteedRef { held = $0.take() }
        guard var token = held.take() else {
            authorityRef._withUnsafeGuaranteedRef { $0.raiseContended() }
            contended.wrappingAdd(1, ordering: .relaxed)
            return .refused(.notOwner)
        }
        let bits = UInt(bitPattern: object.toOpaque())
        let status = ringRef._withUnsafeGuaranteedRef { $0.tryPush(bits) }
        if status != .ok {
            let scope = scope
            _ = authorityRef._withUnsafeGuaranteedRef { $0.raise(&token, scope, .retireBacklog, frame: frame) }
        }
        held = consume token
        chainRef._withUnsafeGuaranteedRef { chain in
            if let token = held.take() { _ = chain.put(token) }
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

    /// Render retires refused because another context held the chain token (each also latched the contended
    /// fault); wraps only after 2^64.
    var contendedRetireCount: UInt64 { contended.load(ordering: .relaxed) }

    /// Test seam, never on a render path: runs `body` while holding this queue's chain token, as a concurrent
    /// `retire` would, then puts it back. `false` without calling `body` when the token is not in its slot (held
    /// by a `retire` in progress, or lost). Never call it while a producer (render) may run: every retire in that
    /// window is refused as contended and latches the contended fault.
    func withChainTokenHeld(_ body: () -> Void) -> Bool {
        guard let token = chain.take() else { return false }
        body()
        return chain.put(token) == .ok
    }
}
