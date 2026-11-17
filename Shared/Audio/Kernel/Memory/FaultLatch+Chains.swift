// #190 chain tokens (FLP3): makes `FaultLatch`'s Raise-context contract hold by construction for raises routed
// through a `FaultChainAuthority`, without relying on any platform callback guarantee. Model and argument:
// docs/transformation/fault-latch-chain-tokens.md. Migrated so far: S1 `SysExAssembler` (FLP4), S3
// `DeferredReleaseQueue.retire` (FLP5), S2 `FanInHandoff.claimProducer` (FLP6) and S4 `ReservedCapacityRing`'s
// critical refusal (FLP7b, one chain per lane); no site raises on `FaultLatch` directly.
// Reference model; not RT-certified.
import Synchronization

/// The only source of production authority identities; read only by `FaultChainAuthority.init` (control). Reuses
/// `FanInIdentityAllocator`: identities 1 through `UInt64.max`, then preparation is refused for good. It never
/// wraps, so no identity is reissued and a token of an old authority cannot match a later one.
private let faultChainAuthorityIdentities = FanInIdentityAllocator()

/// Owns one `FaultLatch` and its only chain budget. Reference model; not RT-certified.
///
/// One budget per latch. The authority builds its latch itself and never hands it out, so no second minting
/// authority can exist for that latch, and every raise on it goes through a minted chain's token
/// (`raise(_:_:_:frame:)`) or the contended fallback (`raiseContended()`), never through `FaultLatch.raise` directly.
///
/// Bounded minting. `mintChain()` and `mintChains(count:)` are control-side (lock, allocation). Each minted chain
/// permanently consumes one unit of `chainBudget`, fixed at creation and at most `maximumChainBudget` (2^16). Nothing
/// returns a unit: dropping a chain or its token does not, and a dropped token leaves its chain empty for good. So
/// over the latch's lifetime at most `chainBudget` chains can ever raise on it, including raises on unprepared scopes
/// (`unknownScopeFaults`).
///
/// Contended fallback. A context whose `take()` finds its chain's slot empty must not raise on the counted path. It
/// calls `raiseContended()`, one idempotent releasing store of a sticky flag that has no scope: observers treat it as
/// a fault on every scope. `isLatched(_:)` reports it for every scope, prepared or not; `pending`, `observe` and
/// `acknowledge` cover counted records only and never clear it. Only replacing the authority (and its latch) while
/// quiescent clears it, as for a saturated scope.
final class FaultChainAuthority: Sendable {
    enum PreparationError: Error, Equatable, Sendable {
        case latch(FaultLatch.PreparationError)
        /// The budget was below 1 or above `maximumChainBudget`.
        case chainBudgetOutOfRange(Int)
        /// The identity allocator has issued `UInt64.max`; no authority can ever be prepared from it again.
        case identitiesExhausted
    }

    /// Hard ceiling for `chainBudget` (inclusive): 2^16 chains, far below the 2^39 the latch's overshoot headroom
    /// allows (see the chain-token document, K_max).
    static var maximumChainBudget: Int { 0x1_0000 }

    /// Chains this authority may ever mint.
    let chainBudget: Int
    /// Distinct for every authority whose identity came from the same allocator (in production, the process one);
    /// carried by its chains and tokens.
    fileprivate let identity: UInt64
    private let latch: FaultLatch
    /// Chains minted so far; never decreases. Control-side.
    private let minted = Mutex<Int>(0)
    private let contended = Atomic<Bool>(false)

    /// Control-side preparation: builds the latch (see `FaultLatch.init`) with a fixed chain budget, and takes the
    /// next process-wide identity.
    convenience init(scopes: [FaultScope], epochLimit: UInt64 = .max, chainBudget: Int) throws(PreparationError) {
        try self.init(scopes: scopes, epochLimit: epochLimit, chainBudget: chainBudget,
                      identities: faultChainAuthorityIdentities)
    }

    /// Test seam: as above with identities from `identities`. Production uses only the process allocator.
    /// Identities are unique per allocator only, so tests use separate seeded allocators to reach the bound. The
    /// identity is taken last, so a refused preparation consumes none.
    init(scopes: [FaultScope], epochLimit: UInt64 = .max, chainBudget: Int,
         identities: FanInIdentityAllocator) throws(PreparationError) {
        guard chainBudget >= 1, chainBudget <= Self.maximumChainBudget else {
            throw .chainBudgetOutOfRange(chainBudget)
        }
        do {
            latch = try FaultLatch(scopes: scopes, epochLimit: epochLimit)
        } catch {
            throw .latch(error)
        }
        guard let identity = identities.reserve() else { throw .identitiesExhausted }
        self.chainBudget = chainBudget
        self.identity = identity
    }

    /// Control-side only: takes a lock and allocates. A new chain whose slot holds its token, or `nil` once
    /// `chainBudget` chains have been minted. A refusal is final: units are never recycled.
    func mintChain() -> FaultChain? {
        mintChains(count: 1)?.first
    }

    /// Control-side only: takes a lock and allocates. All or nothing: `count` new chains with consecutive ids, each
    /// slot holding its token, or `nil` (spending nothing) when `count < 1` or fewer than `count` units remain.
    func mintChains(count: Int) -> [FaultChain]? {
        let first: Int? = minted.withLock { minted in
            // `minted <= chainBudget <= maximumChainBudget`, so the subtraction cannot overflow.
            guard count >= 1, count <= chainBudget - minted else { return nil }
            defer { minted += count }
            return minted + 1
        }
        guard let first else { return nil }
        return (first..<first + count).map { FaultChain(authority: identity, id: UInt64($0)) }
    }

    /// Chains minted so far (control-side).
    var mintedChains: Int { minted.withLock { $0 } }

    /// Any context: `true` only for a chain this authority minted (identities are unique per allocator).
    func issued(_ chain: FaultChain) -> Bool { chain.authority == identity }

    /// Any context: `true` only for an observation of this authority's latch (`FaultObservation.isObservation(of:)`).
    /// The latch itself stays private.
    func isObservation(_ observation: FaultObservation) -> Bool { observation.isObservation(of: latch) }

    /// Hot path: `FaultLatch.raise` on behalf of `token`'s chain, with the same status and effects. Exclusive
    /// (`inout`) access to the only token of a chain makes the chain's raises non-reentrant. A token from another
    /// authority is refused with `.refused(.notOwner)` and changes nothing.
    func raise(_ token: inout FaultChainToken, _ scope: FaultScope, _ kind: FaultKind, frame: Int64) -> KernelStatus {
        guard token.authority == identity else { return .refused(.notOwner) }
        // swiftlint:disable:next fault_latch_raw_raise - the one plain call: the authority raising on its own latch
        return latch.raise(scope, kind, frame: frame)
    }

    /// Hot path, any context without a token: latches the scope-less contended fault. One releasing store; it
    /// cannot overflow and repeating it changes nothing. Never touches counted records or `unknownScopeFaults`.
    func raiseContended() {
        contended.store(true, ordering: .releasing)
    }

    /// Any context: `true` once any context took the contended fallback. Never reset.
    var hasContendedFault: Bool { contended.load(ordering: .acquiring) }

    /// Render: `true` while `scope` holds a counted fault or the contended fault is latched (for every scope).
    ///
    /// Order matters: the counted latch first, the never-cleared flag last. A counted read that sees an
    /// acknowledge's re-arm (acquiring load, acquire-release compare-exchange) also sees a flag set before that
    /// acknowledge, and the acquiring flag load cannot move above it; flag-first could miss both and report a
    /// scope that was faulted throughout as clear.
    func isLatched(_ scope: FaultScope) -> Bool {
        latch.isLatched(scope) || hasContendedFault
    }

    /// Control: `FaultLatch.pending`. Counted records only; check `hasContendedFault` as well.
    func pending(_ body: (FaultRecord) -> Void) -> Int { latch.pending(body) }

    /// Control: `FaultLatch.observe`. Counted records only.
    func observe(_ scope: FaultScope) -> FaultObservation? { latch.observe(scope) }

    /// Control: `FaultLatch.acknowledge`. Re-arms a counted record only; never clears the contended fault.
    func acknowledge(_ observation: FaultObservation) -> FaultRecord? { latch.acknowledge(observation) }

    /// `FaultLatch.unknownScopeFaults`.
    var unknownScopeFaults: UInt64 { latch.unknownScopeFaults }
}

/// One logical raise chain of a `FaultChainAuthority`: a slot holding the chain's only token while no context holds
/// it. Allocated only by `mintChains(count:)`. Reference model; not RT-certified.
///
/// Invariant: the slot holds `id` only when no token of this chain exists, and at most one token exists, because
/// only `take()` makes one, only from a full slot, and tokens cannot be copied. The converse does not hold: a dropped
/// token, or one consumed by a refused `put`, leaves the slot empty with no token. `take()` is one acquiring exchange
/// with empty (0) and `put(_:)` one releasing store of `id`, so a chain's raises before a `put` happen before the
/// raises after the `take` that reads it, on whatever thread that runs.
final class FaultChain: Sendable {
    fileprivate let authority: UInt64
    /// 1 through `chainBudget`, in minting order.
    let id: UInt64
    /// `id` or 0 (taken).
    private let slot: Atomic<UInt64>

    fileprivate init(authority: UInt64, id: UInt64) {
        self.authority = authority
        self.id = id
        slot = Atomic(id)
    }

    /// Hot path: the chain's token, or `nil` while another context holds it (or after a token was dropped). A
    /// context that gets `nil` must not raise on the counted path; it uses `raiseContended()`.
    func take() -> FaultChainToken? {
        guard slot.exchange(0, ordering: .acquiring) == id else { return nil }
        return FaultChainToken(authority: authority, chain: id)
    }

    /// Hot path: returns the token to its slot (one releasing store). A token of another chain is refused with
    /// `.refused(.notOwner)` and consumed; its own chain then stays empty for good (fail closed).
    func put(_ token: consuming FaultChainToken) -> KernelStatus {
        guard token.authority == authority, token.chain == id else { return .refused(.notOwner) }
        slot.store(id, ordering: .releasing)
        return .ok
    }
}

/// The right to raise on one chain, held by one context at a time. Only `FaultChain.take()` makes one; it cannot be
/// copied or sent, so it moves between threads only through its slot. Reference model; not RT-certified.
struct FaultChainToken: ~Copyable {
    fileprivate let authority: UInt64
    fileprivate let chain: UInt64
}

@available(*, unavailable)
extension FaultChainToken: Sendable {}
