import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Narrow = NarrowCounter

/// `FanInRefusalCounter.bump` (a relaxed load, then one relaxed add only below the cap) on a 4-bit counter, in the
/// single-location model of relaxed atomics: the adds form one modification order (value `i` of it is
/// `initial + i`, stored as `value & mask`), an add reads the latest value, and a load reads any value from its
/// chain's coherence floor (the newest value that chain read or wrote; its later steps happen after them) to the
/// latest. Every coherent choice is allowed; happens-before between chains would only remove choices.
private struct NarrowCounter: Hashable {
    static let mask = 15
    /// `mask / 2`, as `FanInRefusalCounter.cap` is `UInt64.max / 2`.
    static let cap = 7
    let initial: Int
    /// Adds so far; the latest true value is `initial + writes` (it has wrapped once that exceeds `mask`).
    var writes = 0
    var floors: [Int]
    /// Chains whose load saw a value below `cap`: their add is next.
    var admitted: [Bool]
    var bumpsLeft: [Int]

    init(initial: Int, chains: Int, bumps: Int) {
        self.initial = initial
        floors = Array(repeating: 0, count: chains)
        admitted = Array(repeating: false, count: chains)
        bumpsLeft = Array(repeating: bumps, count: chains)
    }

    var latest: Int { initial + writes }
    /// What `count` reads: the 4-bit raw value, clamped.
    var count: Int { min(latest & Self.mask, Self.cap) }

    /// `chain` loads modification-order value `index`. Incoherent loads ignore the floor: a chain whose bumps are
    /// not happens-before ordered.
    mutating func load(_ chain: Int, at index: Int, coherent: Bool = true) {
        if coherent { floors[chain] = index }
        if (initial + index) & Self.mask < Self.cap { admitted[chain] = true } else { bumpsLeft[chain] -= 1 }
    }

    /// `chain`'s admitted add: `wrappingAdd` on the latest value.
    mutating func add(_ chain: Int) {
        writes += 1
        floors[chain] = writes
        admitted[chain] = false
        bumpsLeft[chain] -= 1
    }

    /// Every state one step of one chain reaches.
    func successors(coherent: Bool) -> [Self] {
        var next: [Self] = []
        for chain in floors.indices where bumpsLeft[chain] > 0 {
            var step = self
            guard !admitted[chain] else {
                step.add(chain)
                next.append(step)
                continue
            }
            for index in (coherent ? floors[chain] : 0)...writes {
                step = self
                step.load(chain, at: index, coherent: coherent)
                next.append(step)
            }
        }
        return next
    }

    /// Every state reachable from `self`: the highest true value written and the lowest a finished run ends on.
    func explore(coherent: Bool) -> (peak: Int, lowestFinal: Int) {
        var seen: Set<Self> = [self]
        var pending = [self]
        var (peak, lowestFinal) = (latest, Int.max)
        while let state = pending.popLast() {
            peak = max(peak, state.latest)
            if state.bumpsLeft.allSatisfy({ $0 == 0 }) { lowestFinal = min(lowestFinal, state.latest) }
            for next in state.successors(coherent: coherent) where seen.insert(next).inserted { pending.append(next) }
        }
        return (peak, lowestFinal)
    }
}

private struct RefusalCallerEmptySlot: Error {}

extension RealtimeHandoffTests {
    /// Reduced-width interleaving evidence for `FanInRefusalCounter`'s caller contract (see its doc and the
    /// handoff's Refusal counting) on `NarrowCounter`: the same load-then-add algorithm on 4 bits, cap 7. The bound
    /// argument needs only `cap + K` below the width, as with 64 bits, `cap = 2^63 − 1` and K < 2^39. This checks
    /// the argument at reduced width for up to 3 chains of 3 bumps, not the 64-bit lowering.
    struct FanInRefusalBound {
        /// Every interleaving and every coherent load: K chains never wrap, peak at most `max(initial, cap + K)`,
        /// reach `cap + K − 1` from `cap − 1` (so the search is not vacuous) and lose no count below the cap.
        @Test func chainBoundHoldsInEveryInterleaving() {
            for chains in 1...3 {
                for bumps in 1...3 {
                    for initial in [Narrow.cap - 2, Narrow.cap - 1, Narrow.cap, Narrow.cap + 3] {
                        let run = Narrow(initial: initial, chains: chains, bumps: bumps).explore(coherent: true)
                        #expect(run.peak <= max(initial, Narrow.cap + chains) && run.peak <= Narrow.mask)
                        #expect(run.lowestFinal >= min(initial + chains * bumps, Narrow.cap))
                        if initial == Narrow.cap - 1 { #expect(run.peak == Narrow.cap + chains - 1) }
                        if initial >= Narrow.cap { #expect(run.peak == initial) }
                    }
                }
            }
        }

        /// With no lifetime bound on chains the same algorithm wraps, so lane count cannot stand in for K. Each of
        /// `mask - cap + 2` threads may push a distinct stale issued token once, adding that many counter chains.
        /// The schedule (every load, then every add) is sequentially consistent: no weak-memory reordering is needed.
        @Test func unboundedChainsWrap() {
            let chains = Narrow.mask - Narrow.cap + 2
            var counter = Narrow(initial: Narrow.cap - 1, chains: chains, bumps: 1)
            for chain in 0..<chains { counter.load(chain, at: 0) }
            for chain in 0..<chains - 1 { counter.add(chain) }
            #expect(counter.count == Narrow.cap)
            counter.add(chains - 1)
            #expect(counter.latest == Narrow.mask + 1 && counter.count == 0)
        }

        /// A chain whose bumps are not happens-before ordered (its loads may ignore what it wrote) overshoots by
        /// more than one, so the in-chain ordering is part of the contract.
        @Test func unorderedChainOvershoots() {
            let start = Narrow(initial: Narrow.cap - 1, chains: 1, bumps: 4)
            let (ordered, unordered) = (start.explore(coherent: true), start.explore(coherent: false))
            #expect(ordered.peak == Narrow.cap && unordered.peak == Narrow.cap + 3)
        }
    }

    struct RefusalCalling {
        static func take(_ role: RefusalCaller, sourceLocation: SourceLocation = #_sourceLocation) throws
            -> RefusalCallerToken {
            guard let token = role.take() else {
                Issue.record("refusal caller slot unexpectedly empty", sourceLocation: sourceLocation)
                throw RefusalCallerEmptySlot()
            }
            return token
        }

        static func isEmpty(_ role: RefusalCaller) -> Bool {
            guard let token = role.take() else { return true }
            _ = role.put(token)
            return false
        }

        @Test func repeatedTakeReturnIsExclusive() throws {
            let role = try #require(RefusalCaller.prepare())
            for _ in 0..<100 {
                let token = try Self.take(role)
                #expect(Self.isEmpty(role))
                let status = role.put(token)
                #expect(status == .ok)
            }
            #expect(!Self.isEmpty(role))
        }

        @Test func foreignReturnLeavesAvailableDestinationAndStrandsSource() throws {
            let source = try #require(RefusalCaller.prepare())
            let destination = try #require(RefusalCaller.prepare())
            let foreign = try Self.take(source)
            let status = destination.put(foreign)
            #expect(status == .refused(.notOwner))
            for _ in 0..<10 {
                #expect(Self.isEmpty(source))
                let own = try Self.take(destination)
                #expect(Self.isEmpty(destination))
                let returned = destination.put(own)
                #expect(returned == .ok)
            }
        }

        @Test func foreignReturnLeavesHeldDestinationAndStrandsSource() throws {
            let source = try #require(RefusalCaller.prepare())
            let destination = try #require(RefusalCaller.prepare())
            let own = try Self.take(destination)
            let foreign = try Self.take(source)
            let status = destination.put(foreign)
            #expect(status == .refused(.notOwner))
            #expect(Self.isEmpty(source))
            #expect(Self.isEmpty(destination))
            let returned = destination.put(own)
            #expect(returned == .ok)
            #expect(!Self.isEmpty(destination))
            #expect(Self.isEmpty(source))
        }

        private static func dropToken(_ role: RefusalCaller) throws {
            _ = try take(role)
        }

        private static func orphanToken() throws -> RefusalCallerToken {
            let role = try #require(RefusalCaller.prepare())
            return try take(role)
        }

        @Test func droppedTokenStrandsRoleAndDroppedRoleCannotReissueIdentity() throws {
            let stranded = try #require(RefusalCaller.prepare())
            try Self.dropToken(stranded)
            for _ in 0..<100 {
                #expect(Self.isEmpty(stranded))
                let orphan = try Self.orphanToken()
                let next = try #require(RefusalCaller.prepare())
                let status = next.put(orphan)
                #expect(status == .refused(.notOwner))
                #expect(!Self.isEmpty(next))
            }
            // Exact budget/no-refund evidence additionally uses the labelled reduced-budget fresh process.
        }
    }
}
