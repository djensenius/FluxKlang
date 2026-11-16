// #190 FLP6: site S2 (`FanInHandoff.claimProducer`) raises `.producerSlotsExhausted` through a chain token of its
// own claim authority, never through `FaultLatch.raise`. Model: docs/transformation/fault-latch-chain-tokens.md.
// Reference model; not RT-certified.
import Synchronization

/// One `FanInHandoff`'s claim chain: the claim authority, the one chain `init` mints from it, and the count of
/// refused claims that found the token held. Reference model; not RT-certified.
///
/// Only a refused claim touches the token; a successful claim never does. `refuse` takes the token, raises once
/// through it and puts it back before returning. A refusal that finds the token held by another refused claim
/// latches the authority's scope-less contended fault and counts in `contended` instead. Contention here is legal:
/// any thread may call `claimProducer`, so the contended fault means "refused claims overlapped", not a broken
/// contract. Either way `claimProducer` returns `nil`, so the caller fails closed.
///
/// The fields are `fileprivate`: only this file reads them. The strong `let`s keep the authority and the chain
/// alive for the handoff's life; hot paths borrow them through the unretained aliases with
/// `_withUnsafeGuaranteedRef`, valid because each call runs inside a method of the owning handoff.
struct FanInClaimChain: ~Copyable, Sendable {
    fileprivate let authority: FaultChainAuthority
    fileprivate let chain: FaultChain
    fileprivate let authorityRef: Unmanaged<FaultChainAuthority>
    fileprivate let chainRef: Unmanaged<FaultChain>
    fileprivate let contended = Atomic<UInt64>(0)

    /// Control-side (a lock and an allocation): mints one chain from `authority`, or `nil` once its budget is spent.
    init?(minting authority: FaultChainAuthority) {
        guard let chain = authority.mintChain() else { return nil }
        self.authority = authority
        self.chain = chain
        authorityRef = .passUnretained(authority)
        chainRef = .passUnretained(chain)
    }

    /// Hot path, a refused claim only: raises `.producerSlotsExhausted` on `scope` at `frame` through the token and
    /// puts it back, or, when another refused claim holds the token, latches the contended fault and counts it.
    /// One exchange, at most one raise and one store, or one store and one add; no lock, allocation or retry.
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
        _ = authorityRef._withUnsafeGuaranteedRef { $0.raise(&token, scope, .producerSlotsExhausted, frame: frame) }
        held = consume token
        chainRef._withUnsafeGuaranteedRef { chain in
            if let token = held.take() { _ = chain.put(token) }
        }
    }
}

extension FanInHandoff {
    /// Refused claims that found the claim chain's token held by another refused claim (each also latched the
    /// claim authority's contended fault); wraps only after 2^64. Each is also counted in `refusedClaimCount`.
    var contendedClaimCount: UInt64 { claimChain.contended.load(ordering: .relaxed) }

    /// Test seam, never on a producer path: runs `body` while holding the claim chain's token, as a concurrent
    /// refused claim would, then puts it back. `false` without calling `body` when the token is not in its slot
    /// (held by a refused claim in progress, or lost). Never call it while producers may claim, unless the test
    /// intends contention: every refused claim in that window latches the contended fault.
    func withChainTokenHeld(_ body: () -> Void) -> Bool {
        guard let token = claimChain.chain.take() else { return false }
        body()
        return claimChain.chain.put(token) == .ok
    }
}
