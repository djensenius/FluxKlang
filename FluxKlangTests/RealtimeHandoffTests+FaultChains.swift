import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests

/// Thrown by `FaultChaining.take` when a slot it needs is empty.
private struct FaultChainEmptySlot: Error {}

extension RealtimeHandoffTests {
    /// #190 FLP3: chain tokens for `FaultLatch` raises (`FaultChainAuthority`, `FaultChain`, `FaultChainToken`).
    struct FaultChaining {
        static let scopes = FaultLatching.scopes
        static let scope = FaultLatching.scope
        /// Not in `scopes`, so raises on them land in `unknownScopeFaults`.
        static let unprepared: [FaultScope] = [.init(handoff: 0, target: 2), .init(handoff: 2, target: 0)]

        static func authority(budget: Int = 4) throws -> FaultChainAuthority {
            try FaultChainAuthority(scopes: scopes, chainBudget: budget)
        }

        static func preparationError(_ scopes: [FaultScope], budget: Int) -> FaultChainAuthority.PreparationError? {
            do { _ = try FaultChainAuthority(scopes: scopes, chainBudget: budget) } catch { return error }
            return nil
        }

        /// `#require` for a token (the macros cannot capture a noncopyable value): records an issue and throws when
        /// the slot is empty.
        static func take(_ chain: FaultChain, sourceLocation: SourceLocation = #_sourceLocation) throws
            -> FaultChainToken {
            guard let token = chain.take() else {
                Issue.record("chain \(chain.id): slot unexpectedly empty", sourceLocation: sourceLocation)
                throw FaultChainEmptySlot()
            }
            return token
        }

        /// `true` when `take()` gets nothing; a token it does get is put straight back.
        static func isEmpty(_ chain: FaultChain) -> Bool {
            guard let token = chain.take() else { return true }
            _ = chain.put(token)
            return false
        }

        static func records(_ authority: FaultChainAuthority) -> [FaultRecord] {
            var records: [FaultRecord] = []
            #expect(authority.pending { records.append($0) } == records.count)
            return records
        }

        static func records(_ latch: FaultLatch) -> [FaultRecord] {
            var records: [FaultRecord] = []
            #expect(latch.pending { records.append($0) } == records.count)
            return records
        }

        /// Nothing counted, nothing contended, nothing latched.
        static func expectUntouched(_ authority: FaultChainAuthority) {
            #expect(records(authority).isEmpty)
            #expect(authority.unknownScopeFaults == 0)
            #expect(!authority.hasContendedFault)
            #expect((scopes + unprepared).allSatisfy { !authority.isLatched($0) })
        }

        @Test func budgetIsCheckedAtPreparation() {
            let maximum = FaultChainAuthority.maximumChainBudget
            #expect(maximum == 1 << 16)
            for budget in [Int.min, -1, 0, maximum + 1, .max] {
                #expect(Self.preparationError(Self.scopes, budget: budget) == .chainBudgetOutOfRange(budget))
            }
            for budget in [1, 2, maximum] {
                #expect(Self.preparationError(Self.scopes, budget: budget) == nil)
            }
            #expect(Self.preparationError([], budget: 1) == .latch(.emptyScopeTable))
            #expect(Self.preparationError([Self.scope, Self.scope], budget: 1) == .latch(.duplicateScope(Self.scope)))
            // The budget is checked first, so an out-of-range budget never builds a latch.
            #expect(Self.preparationError([], budget: 0) == .chainBudgetOutOfRange(0))
        }

        @Test func identitiesStopAtTheBoundAndNeverWrap() throws {
            // A refused preparation consumes no identity.
            let fresh = FanInIdentityAllocator(lastIssued: .max - 1)
            #expect(throws: FaultChainAuthority.PreparationError.chainBudgetOutOfRange(0)) {
                _ = try FaultChainAuthority(scopes: Self.scopes, chainBudget: 0, identities: fresh)
            }
            #expect(throws: FaultChainAuthority.PreparationError.latch(.emptyScopeTable)) {
                _ = try FaultChainAuthority(scopes: [], chainBudget: 1, identities: fresh)
            }
            #expect(fresh.lastIssued == UInt64.max - 1)
            // The last identity is issued once; then preparation is refused for good, never wrapping to 1.
            let identities = FanInIdentityAllocator(lastIssued: .max - 1)
            let last = try FaultChainAuthority(scopes: Self.scopes, chainBudget: 1, identities: identities)
            #expect(identities.lastIssued == UInt64.max)
            for _ in 0..<2 {
                #expect(throws: FaultChainAuthority.PreparationError.identitiesExhausted) {
                    _ = try FaultChainAuthority(scopes: Self.scopes, chainBudget: 1, identities: identities)
                }
                #expect(identities.lastIssued == UInt64.max)
            }
            // The exhausted authority still works, and its token is refused elsewhere.
            let chain = try #require(last.mintChain())
            var token = try Self.take(chain)
            let other = try Self.authority()
            #expect(other.raise(&token, Self.scope, .noPlan, frame: 0) == .refused(.notOwner))
            #expect(last.raise(&token, Self.scope, .noPlan, frame: 0) == .ok)
            #expect(chain.put(token) == .ok)
            Self.expectUntouched(other)
        }

        @Test func mintingStopsAtTheBudgetAndNeverRecycles() throws {
            for budget in [1, 3] {
                let authority = try Self.authority(budget: budget)
                #expect(authority.chainBudget == budget && authority.mintedChains == 0)
                var ids: [UInt64] = []
                for _ in 0..<budget {
                    let chain = try #require(authority.mintChain())
                    ids.append(chain.id)
                    // Drop a taken token and the chain itself: neither returns a unit.
                    let token = try Self.take(chain)
                    _ = consume token
                }
                #expect(ids == (1...UInt64(budget)).map { $0 })
                for _ in 0..<5 {
                    #expect(authority.mintChain() == nil)
                    #expect(authority.mintedChains == budget)
                }
            }
            // A chain kept alive and returned to its slot does not return a unit either.
            let authority = try Self.authority(budget: 1)
            let chain = try #require(authority.mintChain())
            let token = try Self.take(chain)
            #expect(chain.put(token) == .ok)
            #expect(authority.mintChain() == nil)
            #expect(authority.mintedChains == 1)
        }

        @Test func eachAuthorityHasItsOwnBudget() throws {
            let first = try Self.authority(budget: 2)
            let second = try Self.authority(budget: 2)
            let kept = try #require(first.mintChain())
            #expect(first.mintChain() != nil)
            #expect(first.mintChain() == nil)
            // Exhausting one authority's budget leaves another's, over the same scope table, untouched.
            #expect(second.mintedChains == 0)
            let other = try #require(second.mintChain())
            #expect(try #require(second.mintChain()).id == 2)
            #expect(second.mintChain() == nil)
            #expect(first.mintedChains == 2 && second.mintedChains == 2)
            // Same chain id, different authority: each raises only on its own latch.
            #expect(kept.id == other.id)
            var token = try Self.take(kept)
            #expect(second.raise(&token, Self.scope, .noPlan, frame: 1) == .refused(.notOwner))
            #expect(first.raise(&token, Self.scope, .noPlan, frame: 1) == .ok)
            #expect(first.isLatched(Self.scope) && !second.isLatched(Self.scope))
            #expect(kept.put(token) == .ok)
        }

        @Test func foreignTokenIsRefusedWithoutSideEffects() throws {
            let owner = try Self.authority()
            let foreign = try Self.authority()
            let ownerChain = try #require(owner.mintChain())
            let foreignChain = try #require(foreign.mintChain())
            var token = try Self.take(foreignChain)
            for scope in Self.scopes + Self.unprepared {
                for kind in FaultKind.allCases {
                    #expect(owner.raise(&token, scope, kind, frame: 3) == .refused(.notOwner))
                }
            }
            Self.expectUntouched(owner)
            Self.expectUntouched(foreign)
            // A foreign token is not accepted into another slot: the slot keeps its own token, and the foreign
            // token is consumed, so its own chain stays empty (fail closed).
            #expect(ownerChain.put(token) == .refused(.notOwner))
            let own = try Self.take(ownerChain)
            #expect(Self.isEmpty(ownerChain))
            #expect(ownerChain.put(own) == .ok)
            #expect(Self.isEmpty(foreignChain))
            // Another chain of the same authority is refused the same way.
            let sibling = try #require(owner.mintChain())
            let siblingToken = try Self.take(sibling)
            #expect(ownerChain.put(siblingToken) == .refused(.notOwner))
            #expect(Self.isEmpty(sibling))
            #expect(ownerChain.put(try Self.take(ownerChain)) == .ok)
            Self.expectUntouched(owner)
            Self.expectUntouched(foreign)
        }

        @Test func takeAndPutRoundTrip() throws {
            let authority = try Self.authority()
            let chain = try #require(authority.mintChain())
            for round in 0..<8 {
                var token = try Self.take(chain)
                // The slot is empty while the token is out: every other take gets nothing.
                for _ in 0..<3 { #expect(Self.isEmpty(chain)) }
                #expect(authority.raise(&token, Self.scope, .noPlan, frame: Int64(round)) == .ok)
                #expect(chain.put(token) == .ok)
            }
            #expect(Self.records(authority) == [FaultRecord(scope: Self.scope, kind: .noPlan, count: 8, firstFrame: 0)])
            #expect(!authority.hasContendedFault)
        }

        @Test func chainRaiseMatchesPlainRaise() throws {
            let authority = try Self.authority()
            let plain = try FaultLatch(scopes: Self.scopes)
            let chain = try #require(authority.mintChain())
            var token = try Self.take(chain)
            for kind in FaultKind.allCases {
                for frame in Root.adversarialFrames {
                    for scope in Self.scopes + Self.unprepared {
                        let status = plain.raise(scope, kind, frame: frame)
                        #expect(authority.raise(&token, scope, kind, frame: frame) == status)
                        #expect(authority.isLatched(scope) == plain.isLatched(scope))
                    }
                    #expect(Self.records(authority) == Self.records(plain))
                    #expect(authority.unknownScopeFaults == plain.unknownScopeFaults)
                }
                // Acknowledging re-arms both the same way, record for record.
                for scope in Self.scopes {
                    let expected = try #require(plain.observe(scope).flatMap(plain.acknowledge))
                    let observed = try #require(authority.observe(scope))
                    #expect(observed.record == expected)
                    #expect(authority.acknowledge(observed) == expected)
                    #expect(!authority.isLatched(scope) && !plain.isLatched(scope))
                }
            }
            #expect(authority.unknownScopeFaults == UInt64(FaultKind.allCases.count * Root.adversarialFrames.count
                                                          * Self.unprepared.count))
            #expect(chain.put(token) == .ok)
            #expect(!authority.hasContendedFault)
        }

        @Test func contendedFallbackIsStickyAndUncounted() throws {
            let authority = try Self.authority()
            let chain = try #require(authority.mintChain())
            Self.expectUntouched(authority)
            for _ in 0..<3 {
                authority.raiseContended()
                #expect(authority.hasContendedFault)
                // Scope unknown: every scope, prepared or not, reads as latched; nothing is counted.
                #expect((Self.scopes + Self.unprepared).allSatisfy { authority.isLatched($0) })
                #expect(Self.records(authority).isEmpty)
                #expect(Self.scopes.allSatisfy { authority.observe($0) == nil })
                #expect(authority.unknownScopeFaults == 0)
            }
            // Counted raises and acknowledges work as before, and never clear the contended fault.
            var token = try Self.take(chain)
            #expect(authority.raise(&token, Self.scope, .staleClock, frame: -2) == .ok)
            let record = FaultRecord(scope: Self.scope, kind: .staleClock, count: 1, firstFrame: -2)
            #expect(Self.records(authority) == [record])
            let observed = try #require(authority.observe(Self.scope))
            #expect(authority.acknowledge(observed) == record)
            #expect(Self.records(authority).isEmpty)
            #expect(authority.hasContendedFault && authority.isLatched(Self.scope))
            #expect(chain.put(token) == .ok)
            #expect(authority.hasContendedFault)
        }
    }
}
