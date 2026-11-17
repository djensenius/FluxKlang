import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests
private typealias FanIn = FanInHandoff<UInt64>

/// Shared state for the concurrent refused-claim stress (#190 FLP6).
private final class ClaimChainStressState: Sendable {
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let exited = Atomic<Int>(0)
    let refused = Atomic<UInt64>(0)
    let claimed = Atomic<UInt64>(0)
}

/// Shared by the fan-in suites (#190 FLP6).
extension RealtimeHandoffTests {
    /// A claim authority that prepares only the fan-in's producer-slots scope.
    static func fanInClaims(budget: Int = 1) throws -> FaultChainAuthority {
        try FaultChainAuthority(scopes: [fanInSlotsScope], chainBudget: budget)
    }

    /// The counted record for `scope` on a claim authority, if any.
    static func fanInRecord(_ claims: FaultChainAuthority, _ scope: FaultScope) -> FaultRecord? {
        var found: FaultRecord?
        _ = claims.pending { if $0.scope == scope { found = $0 } }
        return found
    }
}

extension RealtimeHandoffTests {
    /// #190 FLP6: `FanInHandoff.claimProducer` raises `.producerSlotsExhausted` only through the one claim chain
    /// `init` mints from its own claim authority, and only on a refused claim.
    struct FanInClaimChaining {
        static let slots = Root.fanInSlotsScope

        /// The handoff, or why `init` refused it.
        fileprivate static func preparation(
            _ faults: FaultChainAuthority, _ claims: FaultChainAuthority, lanes: Int = 4,
            slots: FaultScope = Root.fanInSlotsScope
        ) -> Result<FanIn, FanIn.PreparationError> {
            do {
                return .success(try FanIn(policy: Root.fanInPolicy(lanes: lanes), laneCapacity: 20, reserved: 16,
                                          faults: faults, claimFaults: claims, criticalScope: Root.fanInCriticalScope,
                                          producerSlotsScope: slots))
            } catch {
                return .failure(error)
            }
        }

        /// A one-lane handoff whose only lane the returned token already holds, so every further claim is refused.
        fileprivate static func full(_ faults: FaultChainAuthority, _ claims: FaultChainAuthority,
                                     slots: FaultScope = Root.fanInSlotsScope) throws -> (FanIn, ProducerToken) {
            let handoff = try preparation(faults, claims, lanes: 1, slots: slots).get()
            return (handoff, try #require(handoff.claimProducer()))
        }

        /// Nothing counted on the lanes' latch: the claim path never raises there.
        static func expectLanesLatchUntouched(_ faults: FaultChainAuthority,
                                              sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(faults.pending { _ in } == 0 && faults.unknownScopeFaults == 0, sourceLocation: sourceLocation)
        }

        /// T1. Kills: minting no claim chain, more than one, or one shared across handoffs.
        @Test func initMintsExactlyOneClaimChain() throws {
            let faults = try Root.fanInLatch()
            let claims = try Root.fanInClaims(budget: 3)
            #expect(claims.mintedChains == 0)
            let first = try Root.makeFanIn(faults, claims: claims, lanes: 1)
            #expect(claims.mintedChains == 1)
            let second = try Root.makeFanIn(faults, claims: claims, lanes: 1)
            #expect(claims.mintedChains == 2)
            _ = try #require(first.claimProducer())
            _ = try #require(second.claimProducer())
            // Holding the first handoff's token never contends a refusal on the second: each has its own chain.
            var refusals: [ProducerToken?] = []
            #expect(first.withChainTokenHeld { refusals.append(second.claimProducer(frame: 4)) })
            #expect(refusals == [nil] && second.contendedClaimCount == 0 && !claims.hasContendedFault)
            #expect(Root.fanInRecord(claims, Self.slots)?.count == 1)
            #expect(first.withChainTokenHeld {} && second.withChainTokenHeld {})
            Self.expectLanesLatchUntouched(faults)
        }

        /// T2. A spent claim budget refuses `init` with `.chainBudgetExhausted` and takes no identity. Other suites
        /// prepare handoffs concurrently, so this retries until a window sees no other `init`. Kills: minting after
        /// the identity is reserved.
        @Test func exhaustedClaimBudgetRefusesInitAndReservesNoIdentity() throws {
            let faults = try Root.fanInLatch()
            let spent = try Root.fanInClaims()
            _ = try #require(spent.mintChain())
            let deadline = ContinuousClock.now + .seconds(10)
            var attempts = 0
            var quiet = false
            while !quiet, ContinuousClock.now < deadline {
                attempts += 1
                let before = FanIn.lastIssuedIdentity
                guard case .failure(.chainBudgetExhausted) = Self.preparation(faults, spent) else {
                    Issue.record("a spent claim budget did not refuse init")
                    return
                }
                // A fresh lane authority per attempt: each accepted handoff spends one lane chain per lane of it.
                let accepted = try Self.preparation(Root.fanInLatch(), Root.fanInClaims()).get()
                let after = FanIn.lastIssuedIdentity
                quiet = after == before &+ 1 && accepted.identity == after
            }
            #expect(quiet, "no window without another init in \(attempts) attempts")
            #expect(spent.mintedChains == 1 && !spent.isLatched(Self.slots))
            Self.expectLanesLatchUntouched(faults)
        }

        /// T3. A refusal that finds the token held returns `nil`, counts as refused and as contended, and latches
        /// only the contended fault; a later refusal with the token free is counted normally. Kills: no
        /// `raiseContended`, no contended count, no refused count, or a token returned on the contended path.
        @Test func contendedRefusalReturnsNilAndRaisesContended() throws {
            let faults = try Root.fanInLatch()
            let claims = try Root.fanInClaims()
            let (handoff, owner) = try Self.full(faults, claims)
            var refusals: [ProducerToken?] = []
            #expect(handoff.withChainTokenHeld { refusals.append(handoff.claimProducer(frame: 9)) })
            #expect(refusals == [nil] && handoff.refusedClaimCount == 1 && handoff.contendedClaimCount == 1)
            #expect(claims.hasContendedFault && claims.isLatched(Self.slots))
            #expect(Root.FaultChaining.records(claims).isEmpty && claims.unknownScopeFaults == 0)
            Self.expectLanesLatchUntouched(faults)
            #expect(handoff.claimProducer(frame: 10) == nil)
            #expect(handoff.refusedClaimCount == 2 && handoff.contendedClaimCount == 1)
            #expect(Root.fanInRecord(claims, Self.slots)
                    == FaultRecord(scope: Self.slots, kind: .producerSlotsExhausted, count: 1, firstFrame: 10))
            #expect(handoff.releaseProducer(owner) == .ok && handoff.refusedNotOwnerCount == 0)
        }

        /// T4. Claims that succeed while the token is held never touch it: no contention, no fault, no refusal.
        /// Kills: taking the token at entry (or on the success path).
        @Test func successfulClaimNeverTakesTheChainToken() throws {
            let faults = try Root.fanInLatch()
            let claims = try Root.fanInClaims()
            let handoff = try Root.makeFanIn(faults, claims: claims)
            var tokens: [ProducerToken] = []
            #expect(handoff.withChainTokenHeld { tokens = (0..<4).compactMap { _ in handoff.claimProducer() } })
            #expect(tokens.map(\.lane) == [0, 1, 2, 3])
            #expect(handoff.refusedClaimCount == 0 && handoff.contendedClaimCount == 0)
            #expect(!claims.hasContendedFault && !claims.isLatched(Self.slots))
            #expect(Root.FaultChaining.records(claims).isEmpty)
            Self.expectLanesLatchUntouched(faults)
            #expect(handoff.claimProducer(frame: 2) == nil && handoff.contendedClaimCount == 0)
            #expect(Root.fanInRecord(claims, Self.slots)?.count == 1)
        }

        /// T5. After every refusal, counted or contended, the token is back in its slot and the next refusal is
        /// counted. Kills: a missing `put`.
        @Test func everyRefusalPutsTheTokenBack() throws {
            let faults = try Root.fanInLatch()
            let claims = try Root.fanInClaims()
            let (handoff, _) = try Self.full(faults, claims)
            for frame in Int64(1)...3 {
                #expect(handoff.claimProducer(frame: frame) == nil)
                #expect(handoff.withChainTokenHeld {})
            }
            var contended: [ProducerToken?] = []
            #expect(handoff.withChainTokenHeld { contended.append(handoff.claimProducer(frame: 4)) })
            #expect(contended == [nil] && handoff.withChainTokenHeld {})
            #expect(handoff.claimProducer(frame: 5) == nil && handoff.withChainTokenHeld {})
            #expect(handoff.refusedClaimCount == 5 && handoff.contendedClaimCount == 1)
            #expect(Root.fanInRecord(claims, Self.slots)
                    == FaultRecord(scope: Self.slots, kind: .producerSlotsExhausted, count: 4, firstFrame: 1))
            Self.expectLanesLatchUntouched(faults)
        }

        /// T6. Records, unknown-scope counts and acknowledge results match a plain `FaultLatch` raised by hand as
        /// `claimProducer` raised before FLP6, for a prepared and an unprepared slots scope. Kills: a wrong scope,
        /// kind or frame on the token path, or a raise on the lanes' latch.
        @Test func claimRaiseMatchesPlainLatch() throws {
            let faults = try Root.fanInLatch()
            let claims = try Root.fanInClaims(budget: 2)
            let twin = try FaultLatch(scopes: [Self.slots])
            let stray = FaultScope(handoff: 5, target: 9)
            let (prepared, _) = try Self.full(faults, claims)
            let (unprepared, _) = try Self.full(faults, claims, slots: stray)
            let refusals = [prepared.claimProducer(frame: 17), prepared.claimProducer(frame: 18),
                            unprepared.claimProducer(frame: 5)]
            #expect(refusals.allSatisfy { $0 == nil })
            for frame in Int64(17)...18 { _ = twin.raise(Self.slots, .producerSlotsExhausted, frame: frame) }
            _ = twin.raise(stray, .producerSlotsExhausted, frame: 5)
            let records = Root.FaultChaining.records(claims)
            #expect(records == Root.FaultChaining.records(twin))
            #expect(records
                    == [FaultRecord(scope: Self.slots, kind: .producerSlotsExhausted, count: 2, firstFrame: 17)])
            #expect(claims.unknownScopeFaults == 1 && claims.unknownScopeFaults == twin.unknownScopeFaults)
            let observed = try #require(claims.observe(Self.slots))
            let expected = try #require(twin.observe(Self.slots))
            #expect(claims.acknowledge(observed) == twin.acknowledge(expected))
            #expect(!claims.isLatched(Self.slots) && !twin.isLatched(Self.slots))
            #expect(prepared.claimProducer(frame: 40) == nil)
            #expect(twin.raise(Self.slots, .producerSlotsExhausted, frame: 40) == .ok)
            #expect(Root.FaultChaining.records(claims) == Root.FaultChaining.records(twin))
            #expect(!claims.hasContendedFault && prepared.contendedClaimCount == 0)
            #expect(unprepared.contendedClaimCount == 0)
            Self.expectLanesLatchUntouched(faults)
        }
    }

    /// T7 (#190 FLP6). `Thread`s claim at once on a handoff whose only lane the test holds, so every claim is
    /// refused and refusals overlap: each raises once through the claim chain or, finding the token held, latches
    /// the contended fault instead (TSan, `--filter Stress`). Kills: a refusal that neither raises nor counts.
    struct FanInClaimChainingStress {
        static let threads = 4
        static let claimsPerThread = 20_000

        @Test(.timeLimit(.minutes(1)))
        func concurrentRefusedClaimsAreCountedOrContended() throws {
            let faults = try Root.fanInLatch()
            let claims = try Root.fanInClaims()
            let (handoff, _) = try FanInClaimChaining.full(faults, claims)
            let state = ClaimChainStressState()
            for thread in 0..<Self.threads {
                Thread {
                    state.arrived.add(1, ordering: .releasing)
                    let deadline = ContinuousClock.now + .seconds(20)
                    while !state.started.load(ordering: .acquiring), ContinuousClock.now < deadline {}
                    for call in 0..<Self.claimsPerThread {
                        if handoff.claimProducer(frame: Int64(thread * Self.claimsPerThread + call)) == nil {
                            state.refused.add(1, ordering: .relaxed)
                        } else {
                            state.claimed.add(1, ordering: .relaxed)
                        }
                    }
                    state.exited.add(1, ordering: .releasing)
                }.start()
            }
            let arrivalDeadline = ContinuousClock.now + .seconds(20)
            while state.arrived.load(ordering: .acquiring) < Self.threads, ContinuousClock.now < arrivalDeadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            state.started.store(true, ordering: .releasing)
            let exitDeadline = ContinuousClock.now + .seconds(30)
            while state.exited.load(ordering: .acquiring) < Self.threads, ContinuousClock.now < exitDeadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard state.exited.load(ordering: .acquiring) == Self.threads else {
                Issue.record("stress workers did not exit; post-run checks skipped")
                return
            }
            let refused = state.refused.load(ordering: .relaxed)
            let contended = handoff.contendedClaimCount
            print("FanInClaimChainingStress contended claims: \(contended)")
            #expect(state.claimed.load(ordering: .relaxed) == 0)
            #expect(refused == UInt64(Self.threads * Self.claimsPerThread) && handoff.refusedClaimCount == refused)
            let counted = Root.fanInRecord(claims, FanInClaimChaining.slots)?.count ?? 0
            #expect(counted + contended == refused && claims.hasContendedFault == (contended > 0))
            #expect(Root.FaultChaining.records(claims).allSatisfy { $0.kind == .producerSlotsExhausted })
            #expect(claims.unknownScopeFaults == 0)
            FanInClaimChaining.expectLanesLatchUntouched(faults)
            #expect(handoff.withChainTokenHeld {})
        }
    }
}
