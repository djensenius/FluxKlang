// #190 FLP7b: site S4 (a lane's critical refusal) raises through one chain per lane, all minted from the handoff's
// `faults` authority in one all-or-nothing batch. Model: docs/transformation/fault-latch-chain-tokens.md.
// Reference model; not RT-certified.

extension FanInHandoff {
    /// Control-side, pure: the lane policy check `init` makes before it mints anything (the ring's own `validate`), so
    /// a refused lane policy, in practice `.reserveBelowMinimum`, spends no budget unit on either authority.
    static func validateLanes(_ lanePolicy: HandoffPolicy) throws(PreparationError) {
        do {
            try ReservedCapacityRing<Element>.validate(lanePolicy)
        } catch {
            throw .lane(error)
        }
    }

    /// Control-side (lock and allocation): mints `count` chains from `faults` in one batch, or throws
    /// `.laneChainBudgetExhausted` spending nothing, then builds one lane on each chain. Only the unreachable
    /// `.lane(.innerRing)` can follow the mint, and it would waste `count` units. The mint is all or nothing, so a
    /// refusal leaves `faults` as it was; it does not undo the claim chain `init` minted before it (R1).
    static func makeLanes(_ lanePolicy: HandoffPolicy, count: Int, faults: FaultChainAuthority,
                          scope: FaultScope) throws(PreparationError) -> [ReservedCapacityRing<Element>] {
        guard let chains = faults.mintChains(count: count) else { throw .laneChainBudgetExhausted }
        var built: [ReservedCapacityRing<Element>] = []
        built.reserveCapacity(count)
        for chain in chains {
            do {
                built.append(try ReservedCapacityRing<Element>(policy: lanePolicy, faults: faults, chain: chain,
                                                               scope: scope, startingIndex: 0))
            } catch {
                throw .lane(error)
            }
        }
        return built
    }

    /// Control-side: whether every lane raises on `authority` itself (identity, not capacity or scopes); the claim
    /// authority does not count. `owners` is never empty (`HandoffPolicy.validate` requires at least one producer), so
    /// this is never vacuously true.
    func lanesRaiseOn(_ authority: FaultChainAuthority) -> Bool {
        owners.allSatisfy { $0.raisesOn(authority) }
    }

    /// Critical refusals on `lane` that found its chain's token held (each also latched the lane authority's
    /// contended fault); 0 for an out-of-range lane. Each is also counted in that lane's `refusedCriticalCount`.
    func contendedLaneCount(lane: Int) -> UInt64 {
        owners.indices.contains(lane) ? owners[lane].contendedCount : 0
    }

    /// Test seam, never on a producer path: runs `body` while holding `lane`'s chain token, as a concurrent refusal
    /// would, then puts it back. `false` without calling `body` for an out-of-range lane or when the token is not in
    /// its slot. Never call it while that lane's producer may push, unless the test intends contention: every
    /// critical refusal in that window latches the contended fault, and with it every scope.
    func withLaneChainTokenHeld(lane: Int, _ body: () -> Void) -> Bool {
        owners.indices.contains(lane) && owners[lane].withChainTokenHeld(body)
    }
}
