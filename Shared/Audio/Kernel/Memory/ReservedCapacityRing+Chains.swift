// #190 FLP7b: site S4 (`ReservedCapacityRing` critical refusal) raises `.criticalExhausted` through the chain token of
// its own lane chain, never through `FaultLatch.raise`. Model: docs/transformation/fault-latch-chain-tokens.md.
// Reference model; not RT-certified.
import Synchronization

/// One `ReservedCapacityRing`'s fault chain: the authority, the lane's chain and the count of critical refusals that
/// found the token held. Reference model; not RT-certified.
///
/// Only a critical refusal touches the token; a successful push and a general refusal never do. `refuse` takes the
/// token, raises `.criticalExhausted` once through it and puts it back before returning. A refusal that finds the
/// token held means two contexts refused on one lane at once, which the single-producer contract forbids
/// (single-producer policy rule R2): it latches the authority's scope-less contended fault, which `isLatched`
/// reports for every scope,
/// so the cycle that watches the critical scope silences, deliberately and for good (fail-safe, see the chain-token
/// document). It also counts in `contended`. Either way the push is refused with `.refused(.criticalExhausted)`.
///
/// The fields are `fileprivate`: only this file reads them. The strong `let`s keep the authority and the chain
/// alive for the ring's life; hot paths borrow them through the unretained aliases with
/// `_withUnsafeGuaranteedRef`, valid because each call runs inside a method of the owning ring.
struct ReservedRingChain: ~Copyable, Sendable {
    fileprivate let authority: FaultChainAuthority
    fileprivate let chain: FaultChain
    fileprivate let authorityRef: Unmanaged<FaultChainAuthority>
    fileprivate let chainRef: Unmanaged<FaultChain>
    fileprivate let contended = Atomic<UInt64>(0)

    /// Control-side: wraps an already minted `chain`; the caller has checked `authority.issued(chain)`.
    init(authority: FaultChainAuthority, chain: FaultChain) {
        self.authority = authority
        self.chain = chain
        authorityRef = .passUnretained(authority)
        chainRef = .passUnretained(chain)
    }

    /// Hot path, a critical refusal only: raises `.criticalExhausted` on `scope` at `frame` through the token and
    /// puts it back, or, when the token is held, latches the contended fault and counts it. One exchange, at most
    /// one raise and one store, or one store and one add; no lock, allocation or retry.
    func refuse(_ scope: FaultScope, frame: Int64) {
        // `_withUnsafeGuaranteedRef` cannot return a noncopyable value or consume a captured one, so the token
        // crosses the borrow through this optional.
        var held: FaultChainToken?
        chainRef._withUnsafeGuaranteedRef { held = $0.take() }
        guard var token = held.take() else {
            authorityRef._withUnsafeGuaranteedRef { $0.raiseContended() }
            contended.wrappingAdd(1, ordering: .relaxed)
            return
        }
        // A refused raise (unprepared scope) is still visible through `unknownScopeFaults`.
        _ = authorityRef._withUnsafeGuaranteedRef { $0.raise(&token, scope, .criticalExhausted, frame: frame) }
        held = consume token
        chainRef._withUnsafeGuaranteedRef { chain in
            if let token = held.take() { _ = chain.put(token) }
        }
    }
}

extension ReservedCapacityRing {
    /// Control-side: validates, mints one chain from `faults`, then builds the ring on it (the designated
    /// `init(policy:faults:chain:...)`). Throws `.chainBudgetExhausted` once `faults` has minted its whole budget.
    /// Every policy check comes first, so a policy refusal spends no budget unit. Only the unreachable
    /// `.innerRing` can follow the mint, and it would waste one unit.
    convenience init(policy: HandoffPolicy, faults: FaultChainAuthority, scope: FaultScope) throws(PreparationError) {
        try Self.validate(policy)
        guard let chain = faults.mintChain() else { throw .chainBudgetExhausted }
        try self.init(policy: policy, faults: faults, chain: chain, scope: scope, startingIndex: 0)
    }

    /// Critical refusals that found the lane chain's token held (each also latched the authority's contended
    /// fault); wraps only after 2^64. Each is also counted in `refusedCriticalCount`.
    var contendedCount: UInt64 { laneChain.contended.load(ordering: .relaxed) }

    /// Test seam, never on a producer path: runs `body` while holding the lane chain's token, as a concurrent
    /// refusal would, then puts it back. `false` without calling `body` when the token is not in its slot. Never
    /// call it while the producer may push, unless the test intends contention: every critical refusal in that
    /// window latches the contended fault.
    func withChainTokenHeld(_ body: () -> Void) -> Bool {
        guard let token = laneChain.chain.take() else { return false }
        body()
        return laneChain.chain.put(token) == .ok
    }

    /// The id of the lane chain this ring raises through (see `FaultChain.id`).
    var laneChainID: UInt64 { laneChain.chain.id }

    /// Control-side: whether this ring's lane chain was minted from `authority` itself (identity, not capacity or
    /// scopes). `KernelCycle` preparation uses it to check that `KernelCycleParts.faults` is the lanes' authority.
    func raisesOn(_ authority: FaultChainAuthority) -> Bool { laneChain.authority === authority }
}
