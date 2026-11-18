import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests
private typealias LatchScan = RealtimeHandoffTests.FaultRaiseInventory
/// A `FaultLatchConstruction` scan pattern: the key's kind and its regular expression.
typealias LatchPattern = (kind: String, regex: String)

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

        @Test func batchMintIsAllOrNothing() throws {
            let authority = try Self.authority(budget: 5)
            let first = try #require(authority.mintChains(count: 2))
            #expect(first.map(\.id) == [1, 2] && authority.mintedChains == 2)
            // More than the 3 units left: refused whole, nothing spent, however often it is asked.
            for count in [4, 5, 6, Int.max] {
                #expect(authority.mintChains(count: count) == nil)
                #expect(authority.mintedChains == 2)
            }
            // The exact remainder still fits, and then the budget is spent.
            let rest = try #require(authority.mintChains(count: 3))
            #expect(rest.map(\.id) == [3, 4, 5] && authority.mintedChains == 5)
            #expect(authority.mintChains(count: 1) == nil && authority.mintChain() == nil)
            #expect(authority.mintedChains == authority.chainBudget)
            // A whole budget in one batch, at the ceiling.
            let maximum = FaultChainAuthority.maximumChainBudget
            let full = try Self.authority(budget: maximum)
            #expect(full.mintChains(count: maximum + 1) == nil && full.mintedChains == 0)
            #expect(try #require(full.mintChains(count: maximum)).count == maximum)
            #expect(full.mintedChains == maximum && full.mintChains(count: 1) == nil)
        }

        @Test func batchMintRejectsNonPositiveCount() throws {
            let authority = try Self.authority(budget: 2)
            for count in [0, -1, Int.min] {
                #expect(authority.mintChains(count: count) == nil)
                #expect(authority.mintedChains == 0)
            }
            // Nothing was spent: the whole budget is still there.
            #expect(try #require(authority.mintChains(count: 2)).map(\.id) == [1, 2])
        }

        @Test func batchMintIdsAreConsecutiveAndOwned() throws {
            let authority = try Self.authority(budget: 8)
            let single = try #require(authority.mintChain())
            let batch = try #require(authority.mintChains(count: 4))
            let next = try #require(authority.mintChains(count: 3))
            #expect(([single] + batch + next).map(\.id) == (1...8).map { UInt64($0) })
            #expect(authority.mintedChains == 8)
            // Every chain is this authority's: it is `issued`, and a raise through each one counts.
            for (index, chain) in ([single] + batch + next).enumerated() {
                #expect(authority.issued(chain))
                var token = try Self.take(chain)
                #expect(authority.raise(&token, Self.scope, .noPlan, frame: Int64(index)) == .ok)
                #expect(chain.put(token) == .ok)
            }
            #expect(Self.records(authority) == [FaultRecord(scope: Self.scope, kind: .noPlan, count: 8, firstFrame: 0)])
            #expect(!authority.hasContendedFault)
        }

        @Test func issuedRejectsForeignChain() throws {
            let owner = try Self.authority()
            let twin = try Self.authority()
            let own = try #require(owner.mintChains(count: 2))
            let foreign = try #require(twin.mintChains(count: 2))
            // Same ids, same scope table, different authority.
            #expect(own.map(\.id) == foreign.map(\.id))
            #expect(own.allSatisfy { owner.issued($0) && !twin.issued($0) })
            #expect(foreign.allSatisfy { twin.issued($0) && !owner.issued($0) })
            // Asking changes nothing.
            #expect(owner.mintedChains == 2 && twin.mintedChains == 2)
            Self.expectUntouched(owner)
            Self.expectUntouched(twin)
        }

        @Test func isObservationRejectsTwinAuthority() throws {
            let owner = try Self.authority()
            let twin = try Self.authority()
            let plain = try FaultLatch(scopes: Self.scopes)
            for authority in [owner, twin] {
                let chain = try #require(authority.mintChain())
                var token = try Self.take(chain)
                #expect(authority.raise(&token, Self.scope, .staleClock, frame: 7) == .ok)
                #expect(chain.put(token) == .ok)
            }
            #expect(plain.raise(Self.scope, .staleClock, frame: 7) == .ok)
            let mine = try #require(owner.observe(Self.scope))
            let theirs = try #require(twin.observe(Self.scope))
            let unowned = try #require(plain.observe(Self.scope))
            // Equal records, but each observation belongs only to the latch that made it.
            #expect(mine.record == theirs.record && mine.record == unowned.record)
            #expect(owner.isObservation(mine) && !owner.isObservation(theirs) && !owner.isObservation(unowned))
            #expect(twin.isObservation(theirs) && !twin.isObservation(mine) && !twin.isObservation(unowned))
            // Asking changes nothing: both scopes stay latched until acknowledged by their own authority.
            #expect(owner.isLatched(Self.scope) && twin.isLatched(Self.scope))
            #expect(owner.acknowledge(mine) == mine.record)
            #expect(!owner.isLatched(Self.scope) && twin.isLatched(Self.scope))
        }
    }
}

extension RealtimeHandoffTests {
    /// K-190c (#190): where the kernel builds a `FaultLatch` (T1), where one is held (T2), where chains are minted
    /// (T3), and that production code builds no `FaultChainAuthority` (T4). Keys are `relpath Type.func kind` over
    /// K-190a's sanitized source (comments and string literals blanked): a regex tripwire, not a parser.
    struct FaultLatchConstruction {
        /// T1: a spelled-out construction, the metatype, an inferred `.init(scopes:` (the latch's label), or a call
        /// of a lower-case static member (a factory such as `FaultLatch.spare(`).
        static let constructions: [LatchPattern] = [
            ("latch", #"\bFaultLatch\s*(?:\.\s*init\s*)?\("#),
            ("metatype", #"\bFaultLatch\s*\.\s*(?:self|Type)\b"#),
            ("inferred", #"(?<![\w.])\.\s*init\s*\(\s*scopes\s*:"#),
            ("factory", #"\bFaultLatch\s*\.\s*(?!init\b|self\b|Type\b)[a-z_]\w*\s*\("#)
        ]
        /// T1, only inside a type or extension named `FaultLatch`: `Self(`, a bare `.init(` and `self.init(`.
        static let selfConstructions: [LatchPattern] = [
            ("self", #"(?<![\w.])Self\s*(?:\.\s*init\s*)?\("#), ("init", #"(?<![\w.])\.\s*init\s*\("#),
            ("selfInit", #"(?<![\w.])self\s*\.\s*init\s*\("#)
        ]
        static let builders = ["Memory/FaultLatch+Chains.swift FaultChainAuthority.init latch": 1]

        /// T2: `FaultLatch` in any type position (stored, local, parameter, return, optional, collection, generic
        /// argument such as `Unmanaged<FaultLatch>`, tuple, closure, cast, alias), keyed with its line.
        static let holders: [LatchPattern] = [("type", #"\bFaultLatch\b(?!\s*[.(])"#)]
        /// The class, the authority's private latch, `FaultObservation`'s owner (it can outlive the authority but
        /// cannot raise) and its borrowed identity check, and the two `fault_latch_test_seams` owners.
        static let owners: [String: Int] = Dictionary(uniqueKeysWithValues: [
            "Memory/FaultLatch+Chains.swift FaultChainAuthority.<none> type: private let latch: FaultLatch",
            "Memory/FaultLatch.swift <none>.<none> type: final class FaultLatch",
            "Memory/FaultLatch.swift FaultObservation.<none> type: fileprivate let owner: FaultLatch",
            "Memory/FaultLatch.swift FaultObservation.<none> type: func isObservation(of latch: FaultLatch",
            "Memory/FaultLatch.swift AdmittedRaiseForTesting.<none> type: fileprivate let owner: FaultLatch",
            "Memory/FaultLatch.swift UnpublishedRaiseForTesting.<none> type: fileprivate let owner: FaultLatch"
        ].map { ($0, 1) })
        /// T2, only inside `FaultChainAuthority`: every `latch` token (bare, `self.`, `.`, key path or backticked), so
        /// an escape that never names the type (`{ latch.raise }`, a capture) adds or raises a count.
        static let latchUses: [LatchPattern] = [("use", #"\blatch\b"#)]
        /// The `PreparationError.latch` case, the declaration and `unknownScopeFaults`, the build and its
        /// `.latch(error)` rethrow, and the one use in each forwarding member.
        static let authorityLatchUses: [String: Int] = [
            "Memory/FaultLatch+Chains.swift PreparationError.<none> use": 1,
            "Memory/FaultLatch+Chains.swift FaultChainAuthority.<none> use": 2,
            "Memory/FaultLatch+Chains.swift FaultChainAuthority.init use": 2,
            "Memory/FaultLatch+Chains.swift FaultChainAuthority.isObservation use": 1,
            "Memory/FaultLatch+Chains.swift FaultChainAuthority.raise use": 1,
            "Memory/FaultLatch+Chains.swift FaultChainAuthority.isLatched use": 1,
            "Memory/FaultLatch+Chains.swift FaultChainAuthority.pending use": 1,
            "Memory/FaultLatch+Chains.swift FaultChainAuthority.observe use": 1,
            "Memory/FaultLatch+Chains.swift FaultChainAuthority.acknowledge use": 1
        ]

        /// T3: each call that mints, once: the five owners' `mintChain`, `mintChains` from `makeLanes` and from the
        /// authority's own `mintChain`, and the builders that reach them, all in control-side inits.
        static let mints: [LatchPattern] = [
            ("mintChain", #"\bmintChain\s*\("#), ("mintChains", #"\bmintChains\s*\("#),
            ("makeLanes", #"\bmakeLanes\s*\("#), ("claimChain", #"\(\s*minting\s*:"#),
            ("ringChain", #"\bReservedRingChain\s*(?:\.\s*init\s*)?\("#)
        ]
        static let mintSites: [String: Int] = Dictionary(uniqueKeysWithValues: [
            "Events/SysExAssembler.swift SysExAssembler.init mintChain",
            "Memory/DeferredRelease.swift DeferredReleaseQueue.init mintChain",
            "Memory/ReservedCapacityRing+Chains.swift ReservedCapacityRing.init mintChain",
            "Memory/FanInHandoff+Chains.swift FanInClaimChain.init mintChain",
            "Memory/FanInHandoff+LaneChains.swift FanInHandoff.makeLanes mintChains",
            "Memory/FaultLatch+Chains.swift FaultChainAuthority.mintChain mintChains",
            "Memory/FanInHandoff.swift FanInHandoff.init makeLanes",
            "Memory/FanInHandoff.swift FanInHandoff.init claimChain",
            "Memory/ReservedCapacityRing.swift ReservedCapacityRing.init ringChain"
        ].map { ($0, 1) })

        /// T4 (#190 item 5): `FaultChainAuthority` constructions, spelled out or inferred, under `Shared` (kernel
        /// included) and the app trees. None yet: each real-caller slice adds its own key here on purpose.
        static let authorities: [LatchPattern] = [
            ("authority", #"\bFaultChainAuthority\s*(?:\.\s*init\s*)?\("#),
            ("inferred", #"(?<![\w.])\.\s*init\s*\(\s*scopes\s*:"#)
        ]
        static let productionAuthorities: [String: Int] = [:]

        @Test(.enabled(if: LatchScan.kernelIsReachable, "the kernel sources are not next to the tests"))
        func faultLatchIsBuiltOnlyByTheAuthorityInit() throws {
            let root = try #require(LatchScan.kernelRoot())
            let found = try Self.sites(of: Self.constructions, under: root)
                .merging(try Self.sites(of: Self.selfConstructions, under: root, within: "FaultLatch")) { $0 + $1 }
            #expect(found == Self.builders, Self.difference(found, Self.builders))
        }

        @Test(.enabled(if: LatchScan.kernelIsReachable, "the kernel sources are not next to the tests"))
        func faultLatchIsHeldOnlyByItsOwners() throws {
            let root = try #require(LatchScan.kernelRoot())
            let found = try Self.sites(of: Self.holders, under: root)
            #expect(found == Self.owners, Self.difference(found, Self.owners))
            let uses = try Self.sites(of: Self.latchUses, under: root, within: "FaultChainAuthority")
            #expect(uses == Self.authorityLatchUses, Self.difference(uses, Self.authorityLatchUses))
        }

        @Test(.enabled(if: LatchScan.kernelIsReachable, "the kernel sources are not next to the tests"))
        func chainsAreMintedOnlyAtTheKeyedSites() throws {
            let found = try Self.sites(of: Self.mints, under: try #require(LatchScan.kernelRoot()))
            #expect(found == Self.mintSites, Self.difference(found, Self.mintSites))
        }

        @Test(.enabled(if: LatchScan.kernelIsReachable, "the kernel sources are not next to the tests"))
        func productionBuildsNoFaultChainAuthority() throws {
            // The repository root (it has `project.yml`) holds `Shared` and both app trees; the mirror's
            // `Sources/FluxKlang` holds only `Shared`.
            let base = try #require(LatchScan.kernelRoot()).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let all = ["Shared", "FluxKlang", "FluxKlangMac"]
            let trees = all.filter { FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) }
            let fromRepository = FileManager.default.fileExists(atPath: base.appendingPathComponent("project.yml").path)
            #expect(trees == (fromRepository ? all : ["Shared"]))
            var found: [String: Int] = [:]
            var outside: [String: Int] = [:]
            for tree in trees {
                let url = base.appendingPathComponent(tree)
                found.merge(try Self.sites(of: Self.authorities, under: url, prefix: tree + "/",
                                           naming: ["FaultChainAuthority", "scopes"])) { $0 + $1 }
                // Outside the kernel, none of T1's constructions or T2's holders at all (aliases included).
                outside.merge(try Self.sites(of: Self.constructions + Self.holders, under: url, prefix: tree + "/",
                                             naming: ["FaultLatch", "scopes"])
                    .filter { !$0.key.hasPrefix("Shared/Audio/Kernel/") }) { $0 + $1 }
            }
            #expect(found == Self.productionAuthorities, Self.difference(found, Self.productionAuthorities))
            #expect(outside.isEmpty, Self.difference(outside, [:]))
        }
    }
}
