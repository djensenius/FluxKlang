// #64 M5 fan-in: one reserved-capacity SPSC lane per producer, claimed with an exclusive token and drained
// round-robin with a per-lane quota from a rotating start lane. Reference model; not RT-certified.
import Synchronization

/// An exclusive claim on one `FanInHandoff` lane. Reference model; not RT-certified.
///
/// `handoff` is the issuing handoff's identity and `generation` the lane's claim generation. Neither is ever
/// reused, so a released token, a token for another lane or a token from another handoff never matches a live
/// claim (see `FanInHandoff`, Tokens).
struct ProducerToken: Sendable, BitwiseCopyable, Equatable {
    let handoff: UInt64
    let generation: UInt64
    let lane: UInt8
}

/// Lane state words: `phase | generation`, the phase in the top two bits (see `FanInLaneWord`).
private let claimedPhase: UInt64 = 1 << 62
private let retiringPhase: UInt64 = 2 << 62
private let phaseMask: UInt64 = 3 << 62
/// The largest generation, and the low-bits mask. A lane freed at this generation is never claimed again.
private let generationMask: UInt64 = (1 << 62) - 1
/// Saturation point of the multi-writer refusal counters; reads clamp to it.
private let refusalCap: UInt64 = .max / 2

/// Issues handoff identities 1, 2, … up to `UInt64.max`, then `nil` for good: never wraps, never reissues.
/// Control-side; lock-free. Reference model; not RT-certified.
///
/// Every `FanInHandoff` takes its identity from one private allocator, and its only `init` accepts no other, so
/// no two handoffs share an identity. Any other allocator (tests build them to reach the bounds) has its own
/// sequence and never names a handoff.
final class FanInIdentityAllocator: Sendable {
    private let last: Atomic<UInt64>

    /// An allocator whose next identity is `lastIssued + 1`.
    init(lastIssued: UInt64 = 0) {
        last = Atomic(lastIssued)
    }

    /// The last identity issued, or 0 before the first.
    var lastIssued: UInt64 { last.load(ordering: .relaxed) }

    /// The next identity, or `nil` once `UInt64.max` has been issued.
    func reserve() -> UInt64? {
        var current = last.load(ordering: .relaxed)
        while current < .max {
            let (exchanged, original) = last.compareExchange(expected: current, desired: current &+ 1,
                                                             ordering: .relaxed)
            if exchanged { return current &+ 1 }
            current = original
        }
        return nil
    }
}

/// The only source of `FanInHandoff` identities; `init` only.
private let handoffIdentities = FanInIdentityAllocator()

/// `FanInHandoff` lane state words and their transitions. Pure, so any context; the hot paths use only these.
///
/// A word is `phase | generation`, the phase in the top two bits: `free(g)` is `g`, `claimed(g)` is
/// `1 << 62 | g` and `retiring(g)` is `2 << 62 | g`. A lane cycles `free(g) → claimed(g + 1) → retiring(g + 1)
/// → free(g + 1)`, so its generation only grows and free keeps the last one. Nothing wraps: a lane freed at
/// `finalGeneration` is never claimed again.
enum FanInLaneWord {
    /// A new lane: `free(0)`.
    static var unclaimed: UInt64 { 0 }

    /// The last generation a lane can be claimed with, 2^62 − 1.
    static var finalGeneration: UInt64 { generationMask }

    /// `free(g) → claimed(g + 1)` for `g` below `finalGeneration`; `nil` for any other word.
    static func claim(_ word: UInt64) -> UInt64? {
        // Free words have no phase bits, so `free(g < final)` is `word < generationMask`; `g + 1` is exact.
        word < generationMask ? claimedPhase | (word &+ 1) : nil
    }

    /// `claimed(generation)`, the word a token with `generation` owns; `nil` for a generation no claim issues:
    /// 0, or above `finalGeneration`, which would carry phase bits into the word.
    static func held(by generation: UInt64) -> UInt64? {
        generation &- 1 < generationMask ? claimedPhase | generation : nil
    }

    /// `claimed(g) → retiring(g)`, for a word from `held(by:)`.
    static func retire(_ held: UInt64) -> UInt64 { retiringPhase | (held & generationMask) }

    /// `retiring(g) → free(g)`; `nil` for any other word.
    static func free(_ word: UInt64) -> UInt64? {
        word & phaseMask == retiringPhase ? word & generationMask : nil
    }

    /// The generation in `word`.
    static func generation(_ word: UInt64) -> UInt64 { word & generationMask }
}

/// A multi-writer event counter that saturates instead of wrapping. Any context; wait-free.
///
/// `bump` adds 1 only below `cap`; writers that pass that check together can overshoot it by at most their
/// number, far below `UInt64.max`, and `count` clamps, so the count never wraps.
struct FanInRefusalCounter: ~Copyable, Sendable {
    /// Where the count stops: `UInt64.max / 2`.
    static var cap: UInt64 { refusalCap }

    private let raw: Atomic<UInt64>

    /// A counter at `initial`.
    init(_ initial: UInt64 = 0) {
        raw = Atomic(initial)
    }

    /// The count, at most `cap`.
    var count: UInt64 { min(raw.load(ordering: .relaxed), refusalCap) }

    /// Counts one event unless the count has reached `cap`.
    func bump() {
        if raw.load(ordering: .relaxed) < refusalCap { raw.wrappingAdd(1, ordering: .relaxed) }
    }
}

/// Fan-in from up to `KernelLimits.maximumProducers` producers to one consumer. Reference model; not RT-certified.
///
/// Lanes. Each producer claims a lane with `claimProducer()` and pushes only through its `ProducerToken`. A lane
/// is an M4 `ReservedCapacityRing`, so each producer has its own general room and its own critical reserve: a
/// flooding producer is refused on its own lane and cannot take another lane's capacity. Nothing is merged or
/// reordered; each lane is FIFO and `drain` tags every element with its lane, so per-producer order is kept.
/// Order across lanes is the drain's round-robin order, not arrival order.
///
/// Policy. `policy` describes the whole handoff: `producers.maximum` lanes, `capacity == lanes × laneCapacity`,
/// `ordering == .fifoPerProducer` and `.reservedCritical(lanes × reserved)`. Each lane gets the same policy with
/// one producer (`.verified`: the token claim enforces it), `laneCapacity` slots and `reserved` critical slots;
/// M4 requires `reserved >= KernelLimits.minimumCriticalReserve`, so a lane holds at least 17 slots.
///
/// Faults. The handoff raises on two distinct scopes, both of which the caller prepares in `faults`:
/// `criticalScope` gets every lane's `.criticalExhausted` (from M4) and `producerSlotsScope` gets
/// `.producerSlotsExhausted` when a claim is refused. `FaultLatch` keeps one kind per scope, so `init` refuses
/// equal scopes: one kind would otherwise hide the other. E5 keys critical loss on `criticalScope`; a
/// `producerSlotsScope` fault means a producer was refused before it pushed anything.
///
/// Claims. A lane's state word (`FanInLaneWord`) is `free(g)`, `claimed(g)` or `retiring(g)`, where `g` is the
/// lane's generation.
/// `claimProducer` takes the lowest claimable lane, `free(g) → claimed(g + 1)`, with one load and at most one
/// compare-exchange per lane; a lane another thread is cycling concurrently may be skipped as if it were busy.
/// `releaseProducer` moves `claimed(g)` to `retiring(g)`; the consumer's `drain` moves a retiring lane to
/// `free(g)` only when it finds the lane empty, so a lane is never handed to a new producer while it still holds
/// the previous producer's events. With no lane claimable, `claimProducer` returns `nil`, counts the refusal and
/// raises `.producerSlotsExhausted` on `producerSlotsScope`.
///
/// Tokens. A token matches only while its lane is `claimed` with its exact generation and its `handoff` is this
/// handoff's `identity`; stale, forged and foreign tokens are refused with `.refused(.notOwner)` and counted and
/// never act as the owner. Nothing wraps, so nothing is reused. Every `init` takes a fresh identity from one
/// private `FanInIdentityAllocator`, which issues 1 up to `UInt64.max` and then makes `init` throw
/// `.identitiesExhausted`; no initializer takes another source, so no two handoffs share an identity. A lane's
/// generation only grows, from 1 up to `FanInLaneWord.finalGeneration` (2^62 − 1), after which that lane is
/// never claimed again. Nothing outside these transitions sets an identity, a generation or a counter.
///
/// Fair drain. `drain` visits lanes from a rotating start lane and takes at most `perLaneQuota` from each until
/// every lane is visited or `total` is spent. The next drain starts after the last lane visited, or at that lane
/// when the budget cut its quota short, and always at least one lane later than this one. So successive drains
/// sweep the lanes contiguously: every non-empty lane gives at least one element within `laneCount` drains, and
/// with `total >= laneCount × perLaneQuota` every non-empty lane is served in each drain.
///
/// Ordering. Each lane's state word carries the producer handover:
/// - Producer A's pushes, including the M4 and M2 producer-side fields it writes, happen before its releasing
///   compare-exchange `claimed → retiring`.
/// - The consumer loads the state acquiring *before* popping, so a `retiring` it sees covers all of A's pushes,
///   and a drain that then finds fewer elements than its limit has emptied the lane.
/// - The consumer stores `free` releasing; producer B's acquiring claim compare-exchange reads it, so A's
///   producer-side writes and the consumer's slot reads happen before B's first push.
/// With relaxed orderings, B could reuse M4's `pushed` count or M2's write cursor while A's writes are still
/// unordered with it (a data race), or the consumer could free a lane whose last events it has not yet seen.
/// The claim's first load is relaxed: only the compare-exchange synchronizes. The token check in `tryPush` loads
/// relaxed: only the owner leaves `claimed(g)`, and by coherence the owner's own load sees its claim and, after
/// it releases, its release. Sequential consistency is not needed.
///
/// Progress. `claimProducer` is wait-free (at most `laneCount` loads and compare-exchanges, one wait-free fault
/// raise); `releaseProducer` and `tryPush` are wait-free (one compare-exchange or load, then one M4 operation);
/// `drain` is bounded by `total` and `laneCount`. Nothing allocates after `init`. Hot paths call lanes and the
/// latch through unretained references, so they retain and release nothing (see Reference counting).
///
/// Reference counting. `owners` and `faults` are strong `let`s that keep every lane and the latch alive for this
/// object's lifetime; hot paths use the unretained `lanes` buffer and `faultsRef` with
/// `_withUnsafeGuaranteedRef`, valid because each call runs inside a method of `self`, which the caller keeps
/// alive.
///
/// Contracts. One producer thread uses a token at a time and stops pushing before it (or a thread ordered after
/// it) releases the token; a copied token used concurrently breaks the lane's single-producer rule. Only one
/// consumer calls `drain`, and its `body` must not call `drain` (doing so is memory-safe but makes the fairness
/// order unspecified).
///
/// `@unchecked Sendable`: lane producer state is guarded by the claim protocol above, `cursor` is consumer-only,
/// and the state words and counters are atomics.
final class FanInHandoff<Element: BitwiseCopyable>: @unchecked Sendable {
    /// Why `init` refused to prepare a handoff.
    enum PreparationError: Error, Equatable, Sendable {
        /// The handoff policy fails `HandoffPolicy.validate()`.
        case policy(HandoffPolicyError)
        /// `criticalScope` and `producerSlotsScope` are the same scope.
        case sharedFaultScope(FaultScope)
        /// The policy is valid but is not a per-producer FIFO with a critical reservation.
        case unsupportedPolicy(Unsupported)
        /// `laneCapacity` and `reserved` times the producer count do not give the policy's capacity and reserve.
        case laneShapeMismatch(laneCapacity: Int, reserved: Int)
        /// A lane refused its derived policy; in practice only `.reserveBelowMinimum`.
        case lane(ReservedCapacityRing<Element>.PreparationError)
        /// Every handoff identity has been issued; identities are never reused.
        case identitiesExhausted
    }

    /// Valid policies that this handoff does not serve.
    enum Unsupported: Sendable, Equatable {
        case ordering(HandoffOrdering)
        case overflow(OverflowPolicy)
    }

    /// The last identity issued to any handoff, or 0 before the first. Control-side; read-only diagnostics.
    static var lastIssuedIdentity: UInt64 { handoffIdentities.lastIssued }

    let policy: HandoffPolicy
    /// `policy.producers.maximum`.
    let laneCount: Int
    let laneCapacity: Int
    /// Critical-only slots in each lane.
    let reserved: Int
    /// This handoff's identity, carried by its tokens; never 0 and never shared with another handoff.
    let identity: UInt64
    /// Where every lane raises `.criticalExhausted`.
    let criticalScope: FaultScope
    /// Where a refused claim raises `.producerSlotsExhausted`.
    let producerSlotsScope: FaultScope

    /// Owns the lanes; hot paths use `lanes`.
    private let owners: [ReservedCapacityRing<Element>]
    /// Keeps the latch alive; hot paths use `faultsRef`.
    private let faults: FaultLatch
    private let lanes: UnsafeMutablePointer<Unmanaged<ReservedCapacityRing<Element>>>
    private let faultsRef: Unmanaged<FaultLatch>
    private let states: UnsafeMutablePointer<Atomic<UInt64>>
    private let refusedNotOwner = FanInRefusalCounter()
    private let refusedClaims = FanInRefusalCounter()
    /// The next drain's start lane; consumer only.
    private var cursor = 0

    /// Validates `policy` against the lane shape and allocates every lane. Control-side only. Both scopes should
    /// be prepared in `faults` (an unprepared scope is still counted in `FaultLatch.unknownScopeFaults`) and must
    /// differ (see Faults). The identity is taken last, so a refused `init` takes none.
    init(policy: HandoffPolicy, laneCapacity: Int, reserved: Int, faults: FaultLatch,
         criticalScope: FaultScope, producerSlotsScope: FaultScope) throws(PreparationError) {
        do {
            try policy.validate()
        } catch {
            throw .policy(error)
        }
        guard criticalScope != producerSlotsScope else { throw .sharedFaultScope(criticalScope) }
        guard policy.ordering == .fifoPerProducer else { throw .unsupportedPolicy(.ordering(policy.ordering)) }
        guard case .reservedCritical(let totalReserved) = policy.overflow else {
            throw .unsupportedPolicy(.overflow(policy.overflow))
        }
        let count = policy.producers.maximum
        let (capacity, capacityOverflow) = laneCapacity.multipliedReportingOverflow(by: count)
        let (reserve, reserveOverflow) = reserved.multipliedReportingOverflow(by: count)
        guard !capacityOverflow, !reserveOverflow, capacity == policy.capacity, reserve == totalReserved else {
            throw .laneShapeMismatch(laneCapacity: laneCapacity, reserved: reserved)
        }
        let lanePolicy = Self.lanePolicy(policy, laneCapacity: laneCapacity, reserved: reserved)
        var built: [ReservedCapacityRing<Element>] = []
        built.reserveCapacity(count)
        for _ in 0..<count {
            do {
                built.append(try ReservedCapacityRing<Element>(policy: lanePolicy, faults: faults,
                                                               scope: criticalScope))
            } catch {
                throw .lane(error)
            }
        }
        // Last, so a refused `init` takes no identity.
        guard let identity = handoffIdentities.reserve() else { throw .identitiesExhausted }
        self.identity = identity
        self.policy = policy
        self.laneCapacity = laneCapacity
        self.reserved = reserved
        self.faults = faults
        self.criticalScope = criticalScope
        self.producerSlotsScope = producerSlotsScope
        laneCount = count
        owners = built
        faultsRef = .passUnretained(faults)
        lanes = .allocate(capacity: count)
        states = .allocate(capacity: count)
        for index in 0..<count {
            (lanes + index).initialize(to: .passUnretained(built[index]))
            (states + index).initialize(to: Atomic(FanInLaneWord.unclaimed))
        }
    }

    /// Control-side teardown.
    deinit {
        lanes.deinitialize(count: laneCount)
        lanes.deallocate()
        states.deinitialize(count: laneCount)
        states.deallocate()
    }

    /// Any producer context; wait-free. Claims the lowest claimable lane, or returns `nil` after counting the
    /// refusal and raising `.producerSlotsExhausted` on `producerSlotsScope` at `frame`.
    func claimProducer(frame: Int64 = 0) -> ProducerToken? {
        var lane = 0
        while lane < laneCount {
            let state = (states + lane).pointee.load(ordering: .relaxed)
            // Acquiring: pairs with the releasing `free` store in `drain` (see Ordering).
            if let claimed = FanInLaneWord.claim(state), (states + lane).pointee.compareExchange(
                expected: state, desired: claimed, successOrdering: .acquiring, failureOrdering: .relaxed
            ).exchanged {
                return ProducerToken(handoff: identity, generation: FanInLaneWord.generation(claimed),
                                     lane: UInt8(truncatingIfNeeded: lane))
            }
            lane &+= 1
        }
        refusedClaims.bump()
        let scope = producerSlotsScope  // A local copy, so the closure does not capture (and retain) `self`.
        _ = faultsRef._withUnsafeGuaranteedRef { $0.raise(scope, .producerSlotsExhausted, frame: frame) }
        return nil
    }

    /// The token's producer, after its last push (or any thread ordered after it); wait-free. Retires the lane;
    /// the next `drain` that finds it empty frees it for a new claim. Any token that does not own its lane is
    /// refused with `.refused(.notOwner)` and counted.
    @discardableResult
    func releaseProducer(_ token: ProducerToken) -> KernelStatus {
        let lane = Int(token.lane)
        // `held(by:)` refuses a generation that would carry phase bits into the word.
        // Releasing: publishes this producer's pushes and lane state to the consumer (see Ordering).
        guard token.handoff == identity, lane < laneCount, let held = FanInLaneWord.held(by: token.generation),
              (states + lane).pointee.compareExchange(
                  expected: held, desired: FanInLaneWord.retire(held), successOrdering: .releasing,
                  failureOrdering: .relaxed
              ).exchanged else {
            refusedNotOwner.bump()
            return .refused(.notOwner)
        }
        return .ok
    }

    /// The token's producer only; wait-free. Appends `value` to the token's lane with M4 admission: a general
    /// event is refused with `.refused(.full)` at the lane's general limit, a critical one with
    /// `.refused(.criticalExhausted)` at lane capacity, which also raises `.criticalExhausted` on `criticalScope`.
    /// A token that does not own its lane is refused with `.refused(.notOwner)` and counted.
    func tryPush(_ value: Element, class eventClass: EventClass, frame: Int64, token: ProducerToken) -> KernelStatus {
        let lane = Int(token.lane)
        guard token.handoff == identity, lane < laneCount, let held = FanInLaneWord.held(by: token.generation),
              (states + lane).pointee.load(ordering: .relaxed) == held else {
            refusedNotOwner.bump()
            return .refused(.notOwner)
        }
        return lanes[lane]._withUnsafeGuaranteedRef { $0.tryPush(value, class: eventClass, frame: frame) }
    }

    /// The consumer only. Visits lanes round-robin from the rotating start lane, passing each element and its
    /// lane to `body` in per-lane FIFO order, at most `perLaneQuota` per lane and `total` in all. Frees each
    /// retiring lane it empties. Returns the number delivered; with a non-positive quota or total it does
    /// nothing. `body` must not call `drain`.
    @discardableResult
    func drain(perLaneQuota: Int, total: Int, _ body: (UInt8, Element) -> Void) -> Int {
        guard perLaneQuota > 0, total > 0 else { return 0 }
        let start = cursor
        var lane = start
        var last = start
        var remaining = total
        var visited = 0
        var lastLimit = 0
        while visited < laneCount, remaining > 0 {
            let limit = min(perLaneQuota, remaining)
            // Acquiring, and before the pop: a `retiring` seen here covers every push of its producer.
            let state = (states + lane).pointee.load(ordering: .acquiring)
            let tag = UInt8(truncatingIfNeeded: lane)
            let delivered = lanes[lane]._withUnsafeGuaranteedRef { ring in
                ring.popAll(limit: limit) { body(tag, $0) }
            }
            // Fewer than `limit` means the lane is now empty; only this consumer leaves `retiring`.
            if delivered < limit, let freed = FanInLaneWord.free(state) {
                (states + lane).pointee.store(freed, ordering: .releasing)
            }
            remaining &-= delivered  // Exact: delivered <= limit <= remaining.
            lastLimit = limit
            last = lane
            visited &+= 1
            lane = lane &+ 1 == laneCount ? 0 : lane &+ 1
        }
        // `lane` is now the one after the last visited. A lane the budget cut short starts the next drain.
        var next = remaining == 0 && lastLimit < perLaneQuota ? last : lane
        if next == start { next = start &+ 1 == laneCount ? 0 : start &+ 1 }
        cursor = next
        return total &- remaining
    }

    /// Pushes and releases refused because the token did not own its lane; saturates at `UInt64.max / 2`.
    var refusedNotOwnerCount: UInt64 { refusedNotOwner.count }

    /// Claims refused because every lane was claimed or retiring; saturates at `UInt64.max / 2`.
    var refusedClaimCount: UInt64 { refusedClaims.count }

    /// One lane's refusals of `eventClass` (M4 counters), or `nil` for an out-of-range lane. Any context.
    func refusedCount(lane: Int, class eventClass: EventClass) -> UInt64? {
        guard lane >= 0, lane < laneCount else { return nil }
        return lanes[lane]._withUnsafeGuaranteedRef { ring in
            switch eventClass {
            case .general: ring.refusedGeneralCount
            case .critical: ring.refusedCriticalCount
            }
        }
    }

    /// The lane policy: the handoff policy with one verified producer and the lane's capacity and reserve.
    private static func lanePolicy(_ policy: HandoffPolicy, laneCapacity: Int, reserved: Int) -> HandoffPolicy {
        HandoffPolicy(
            purpose: policy.purpose, producer: policy.producer,
            producers: ProducerCardinality(maximum: 1, evidence: .verified), consumer: policy.consumer,
            consumers: policy.consumers, capacity: laneCapacity, ordering: policy.ordering,
            deadline: policy.deadline, overflow: .reservedCritical(reserved: reserved), lifetime: policy.lifetime)
    }
}
