import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests
private typealias FanIn = FanInHandoff<UInt64>
private typealias Word = FanInLaneWord

/// One `init` attempt through the handoff's only initializer.
private struct Attempt {
    var policy = Root.fanInPolicy()
    var laneCapacity = 20
    var reserved = 16
    var slots = Root.fanInSlotsScope

    func run(_ faults: FaultLatch) -> Result<FanIn, FanIn.PreparationError> {
        do {
            return .success(try FanIn(policy: policy, laneCapacity: laneCapacity, reserved: reserved, faults: faults,
                                      criticalScope: Root.fanInCriticalScope, producerSlotsScope: slots))
        } catch {
            return .failure(error)
        }
    }
}

/// The documented lane word `phase << 62 | generation`: phase 0 free, 1 claimed, 2 retiring.
private func laneWord(_ phase: UInt64, _ generation: UInt64) -> UInt64 { phase << 62 | generation }

/// A small deterministic generator so the lane-word walk is reproducible.
private struct WalkMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

extension RealtimeHandoffTests {
    /// Lane critical exhaustion and claim exhaustion latch on distinct scopes: `FaultLatch` keeps the first kind
    /// per scope, so a shared scope would let one source hide the other's kind from E5.
    struct FanInFaultScopes {
        @Test func initRejectsSharedScopeAndRoutesEachSource() throws {
            let faults = try Root.fanInLatch()
            for scope in [Root.fanInCriticalScope, Root.fanInSlotsScope, Root.fanInNeighbourScope] {
                do {
                    _ = try FanInHandoff<UInt64>(policy: Root.fanInPolicy(), laneCapacity: 20, reserved: 16,
                                                 faults: faults, criticalScope: scope, producerSlotsScope: scope)
                    Issue.record("a shared scope was accepted")
                } catch {
                    #expect(error == .sharedFaultScope(scope))
                }
            }
            let handoff = try Root.makeFanIn(faults)
            #expect(handoff.criticalScope == Root.fanInCriticalScope)
            #expect(handoff.producerSlotsScope == Root.fanInSlotsScope)
            #expect(!faults.isLatched(Root.fanInCriticalScope) && !faults.isLatched(Root.fanInSlotsScope))
        }

        /// Fills the single lane's general room and reserve, then refuses one critical event at `frame`.
        private static func exhaustCritical(_ handoff: FanInHandoff<UInt64>, _ token: ProducerToken,
                                            frame: Int64) {
            for value in 0..<UInt64(handoff.laneCapacity) {
                #expect(handoff.tryPush(value, class: .critical, frame: 0, token: token) == .ok)
            }
            #expect(handoff.tryPush(99, class: .critical, frame: frame, token: token) == .refused(.criticalExhausted))
        }

        @Test func claimExhaustionFirstLeavesCriticalExhaustionObservable() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 1, laneCapacity: 17)
            let token = try #require(handoff.claimProducer(frame: 1))
            #expect(handoff.claimProducer(frame: 3) == nil)
            Self.exhaustCritical(handoff, token, frame: 9)
            #expect(Root.fanInRecord(faults, Root.fanInSlotsScope)
                    == FaultRecord(scope: Root.fanInSlotsScope, kind: .producerSlotsExhausted, count: 1, firstFrame: 3))
            #expect(Root.fanInRecord(faults, Root.fanInCriticalScope)
                    == FaultRecord(scope: Root.fanInCriticalScope, kind: .criticalExhausted, count: 1, firstFrame: 9))
            // E5 acknowledges the critical scope on its own; the claim record stays latched.
            #expect(faults.acknowledge(Root.fanInCriticalScope)?.kind == .criticalExhausted)
            #expect(!faults.isLatched(Root.fanInCriticalScope) && faults.isLatched(Root.fanInSlotsScope))
            #expect(!faults.isLatched(Root.fanInNeighbourScope))
        }

        @Test func criticalExhaustionFirstLeavesClaimExhaustionObservable() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 1, laneCapacity: 17)
            let token = try #require(handoff.claimProducer(frame: 1))
            Self.exhaustCritical(handoff, token, frame: 4)
            #expect(handoff.claimProducer(frame: 6) == nil && handoff.claimProducer(frame: 7) == nil)
            #expect(Root.fanInRecord(faults, Root.fanInCriticalScope)
                    == FaultRecord(scope: Root.fanInCriticalScope, kind: .criticalExhausted, count: 1, firstFrame: 4))
            #expect(Root.fanInRecord(faults, Root.fanInSlotsScope)
                    == FaultRecord(scope: Root.fanInSlotsScope, kind: .producerSlotsExhausted, count: 2, firstFrame: 6))
            #expect(faults.acknowledge(Root.fanInSlotsScope)?.kind == .producerSlotsExhausted)
            #expect(faults.isLatched(Root.fanInCriticalScope) && !faults.isLatched(Root.fanInSlotsScope))
            #expect(!faults.isLatched(Root.fanInNeighbourScope))
        }
    }

    /// A token is never current twice: handoff identities and per-lane claim generations never wrap.
    struct FanInTokenIdentity {
        /// Regression: a 20-bit claim count wrapped after 2^20 claims and revived the first token.
        @Test func staleTokenStaysRefusedPastTwoToTheTwentyClaims() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 1, laneCapacity: 17)
            let first = try #require(handoff.claimProducer())
            var token = first
            for _ in 0..<(1 << 20) {
                guard handoff.releaseProducer(token) == .ok, handoff.drain(perLaneQuota: 1, total: 1, { _, _ in }) == 0,
                      let next = handoff.claimProducer() else {
                    Issue.record("claim/release/drain cycle broke")
                    return
                }
                token = next
            }
            #expect(token != first)
            #expect(handoff.tryPush(1, class: .critical, frame: 0, token: first) == .refused(.notOwner))
            #expect(handoff.releaseProducer(first) == .refused(.notOwner))
            #expect(handoff.tryPush(2, class: .general, frame: 0, token: token) == .ok)
            #expect(Root.drained(handoff, quota: 4, total: 4) == [.init(lane: 0, value: 2)])
        }

        /// Regression: a 12-bit session block wrapped after 4,096 handoffs and let a foreign token match.
        @Test func foreignTokenStaysRefusedAcrossManyHandoffs() throws {
            let faults = try Root.fanInLatch()
            let origin = try Root.makeFanIn(faults, lanes: 1, laneCapacity: 17)
            let token = try #require(origin.claimProducer())
            var matched = 0
            for _ in 0..<8_192 {
                let other = try Root.makeFanIn(faults, lanes: 1, laneCapacity: 17)
                _ = try #require(other.claimProducer())
                if other.tryPush(1, class: .general, frame: 0, token: token) != .refused(.notOwner) { matched += 1 }
                if other.releaseProducer(token) != .refused(.notOwner) { matched += 1 }
            }
            #expect(matched == 0)
            #expect(origin.tryPush(3, class: .general, frame: 0, token: token) == .ok)
        }

        /// Regression (round 2): an injectable identity source gave handoffs a second way to be constructed, and a
        /// fresh source issued 1, the first identity the shared source issues, so one handoff accepted another's
        /// tokens. The handoff now has one initializer, which draws from one shared allocator; `api_absence.sh`
        /// in the scratch package checks at compile time that the injectable form and the seeds are gone.
        @Test func everyConstructionTakesAFreshIdentity() throws {
            let faults = try Root.fanInLatch()
            // What the removed source did: a separately built allocator starts over at 1. It names no handoff.
            let fresh = FanInIdentityAllocator()
            #expect(fresh.reserve() == 1)
            var handoffs: [FanIn] = []
            var tokens: [ProducerToken] = []
            for _ in 0..<16 {
                let handoff = try Root.makeFanIn(faults, lanes: 1, laneCapacity: 17)
                let token = try #require(handoff.claimProducer())
                // Strictly increasing on one thread, even while other suites prepare handoffs.
                #expect(handoff.identity > (handoffs.last?.identity ?? 0))
                #expect(handoff.identity <= FanIn.lastIssuedIdentity)
                #expect(token == ProducerToken(handoff: handoff.identity, generation: 1, lane: 0))
                handoffs.append(handoff)
                tokens.append(token)
            }
            var accepted = 0
            for (index, handoff) in handoffs.enumerated() {
                for (other, token) in tokens.enumerated() where other != index {
                    let pushed = handoff.tryPush(1, class: .general, frame: 0, token: token)
                    if pushed != .refused(.notOwner) { accepted += 1 }
                    if handoff.releaseProducer(token) != .refused(.notOwner) { accepted += 1 }
                }
            }
            #expect(accepted == 0)
            for (handoff, token) in zip(handoffs, tokens) {
                #expect(handoff.tryPush(2, class: .general, frame: 0, token: token) == .ok)
                #expect(Root.drained(handoff, quota: 4, total: 4) == [.init(lane: 0, value: 2)])
            }
        }

        /// The allocator issues 1, 2, … and stops at `UInt64.max` for good instead of wrapping to reissue.
        @Test func identityAllocatorFailsClosedInsteadOfWrapping() {
            let fresh = FanInIdentityAllocator()
            #expect(fresh.lastIssued == 0)
            #expect(fresh.reserve() == 1)
            #expect(fresh.reserve() == 2)
            #expect(fresh.lastIssued == 2)
            let nearTop = FanInIdentityAllocator(lastIssued: UInt64.max - 2)
            #expect(nearTop.reserve() == UInt64.max - 1)
            #expect(nearTop.reserve() == UInt64.max)
            for _ in 0..<3 {
                #expect(nearTop.reserve() == nil)
            }
            #expect(nearTop.lastIssued == UInt64.max)
        }

        /// `init` takes its identity last, so each refusal kind takes none and one accepted `init` takes exactly
        /// one. Other suites prepare handoffs concurrently, so this retries until a window sees no other `init`.
        @Test func refusedInitTakesNoIdentity() throws {
            let faults = try Root.fanInLatch()
            let appOwnedMIDI = Root.policy(producer: .midiReceive, capacity: 20, ordering: .fifoPerProducer,
                                           overflow: .reservedCritical(reserved: 16))
            let refusing = Root.policy(producer: .midiReceive, producers: .conservativeDefault(for: .midiReceive),
                                       ordering: .fifoPerProducer)
            let refusals: [(Attempt, FanIn.PreparationError)] = [
                (Attempt(policy: appOwnedMIDI), .policy(.violates(.r2Cardinality))),
                (Attempt(slots: Root.fanInCriticalScope), .sharedFaultScope(Root.fanInCriticalScope)),
                (Attempt(policy: Root.fanInPolicy(ordering: .fifo)), .unsupportedPolicy(.ordering(.fifo))),
                (Attempt(policy: refusing), .unsupportedPolicy(.overflow(.refuseProducer))),
                (Attempt(laneCapacity: 21), .laneShapeMismatch(laneCapacity: 21, reserved: 16)),
                (Attempt(policy: Root.fanInPolicy(reserved: 8), reserved: 8), .lane(.reserveBelowMinimum(8)))
            ]
            let isolated = FanInIdentityAllocator()
            let deadline = ContinuousClock.now + .seconds(10)
            var attempts = 0
            var quiet = false
            while !quiet, ContinuousClock.now < deadline {
                attempts += 1
                let before = FanIn.lastIssuedIdentity
                for (attempt, expected) in refusals {
                    guard case .failure(let error) = attempt.run(faults), error == expected else {
                        Issue.record("expected \(expected)")
                        return
                    }
                }
                _ = isolated.reserve()  // Its own sequence: handoff identities do not move.
                let accepted = try Attempt().run(faults).get()
                let after = FanIn.lastIssuedIdentity
                quiet = after == before &+ 1 && accepted.identity == after
            }
            #expect(quiet, "no window without another init in \(attempts) attempts")
            #expect(!faults.isLatched(Root.fanInCriticalScope) && !faults.isLatched(Root.fanInSlotsScope))
        }

        /// On a live lane each claim takes the next generation, and no stale, future or forged generation (0,
        /// phase bits, beyond the final one) ever owns it.
        @Test func liveGenerationsGrowAndForgedOnesNeverMatch() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 1, laneCapacity: 17)
            let id = handoff.identity
            var stale: [ProducerToken] = []
            var refusals: UInt64 = 0
            for round in UInt64(1)...3 {
                let token = try #require(handoff.claimProducer())
                #expect(token == ProducerToken(handoff: id, generation: round, lane: 0))
                let generations = [round - 1, round + 1, laneWord(1, round), laneWord(2, round), laneWord(3, round),
                                   Word.finalGeneration + 1, .max]
                let forged = generations.map { ProducerToken(handoff: id, generation: $0, lane: 0) }
                for bad in forged + stale {
                    #expect(handoff.tryPush(9, class: .critical, frame: 0, token: bad) == .refused(.notOwner))
                    #expect(handoff.releaseProducer(bad) == .refused(.notOwner))
                    refusals += 2
                }
                #expect(handoff.tryPush(round, class: .general, frame: 0, token: token) == .ok)
                #expect(handoff.releaseProducer(token) == .ok)
                #expect(Root.drained(handoff, quota: 4, total: 4) == [.init(lane: 0, value: round)])
                stale.append(token)
            }
            #expect(handoff.refusedNotOwnerCount == refusals)
            #expect(Root.drained(handoff, quota: 4, total: 8).isEmpty && !faults.isLatched(Root.fanInCriticalScope))
        }
    }

    /// The lane-word transitions the hot paths use, checked directly: live lanes cannot reach the final
    /// generation in a test, and no production entry point moves a live lane's generation.
    struct FanInLaneTransitions {
        @Test func wordsFollowTheClaimCycle() {
            #expect(Word.unclaimed == laneWord(0, 0))
            #expect(Word.claim(Word.unclaimed) == laneWord(1, 1))
            #expect(Word.held(by: 1) == laneWord(1, 1))
            #expect(Word.generation(laneWord(1, 1)) == 1)
            #expect(Word.retire(laneWord(1, 1)) == laneWord(2, 1))
            #expect(Word.free(laneWord(2, 1)) == laneWord(0, 1))
            #expect(Word.claim(laneWord(0, 1)) == laneWord(1, 2))
            // Only free words claim, only retiring words free, and a generation no claim issues names no word.
            for word in [laneWord(1, 0), laneWord(1, 1), laneWord(2, 1), laneWord(3, 1), UInt64.max] {
                #expect(Word.claim(word) == nil)
            }
            for word in [laneWord(0, 0), laneWord(0, 1), laneWord(1, 1), laneWord(3, 1), UInt64.max] {
                #expect(Word.free(word) == nil)
            }
            for generation in [0, Word.finalGeneration + 1, laneWord(1, 1), laneWord(2, 1), UInt64.max] {
                #expect(Word.held(by: generation) == nil)
            }
        }

        /// A lane's generation only grows, and at the final generation it stops: a lane freed there is never
        /// claimed again, so no old token can become current.
        @Test func generationsExhaustInsteadOfWrapping() {
            let final = Word.finalGeneration
            #expect(final == (1 << 62) - 1)
            var word = laneWord(0, final - 2)
            var claimed: [UInt64] = []
            while claimed.count < 4, let next = Word.claim(word) {
                let generation = Word.generation(next)
                #expect(next == laneWord(1, Word.generation(word) + 1) && Word.held(by: generation) == next)
                let retiring = Word.retire(next)
                #expect(retiring == laneWord(2, generation) && Word.claim(retiring) == nil)
                guard let freed = Word.free(retiring) else {
                    Issue.record("retiring(\(generation)) did not free")
                    return
                }
                #expect(freed == laneWord(0, generation))
                claimed.append(generation)
                word = freed
            }
            #expect(claimed == [final - 1, final])
            #expect(word == laneWord(0, final) && Word.claim(word) == nil)
            #expect(Word.held(by: final) == laneWord(1, final) && Word.held(by: final + 1) == nil)
        }

        /// A seeded walk of claims, token releases (stale, current and future generations) and frees, from both
        /// generation boundaries, agrees with a `(phase, generation)` model step by step.
        @Test func seededWalkMatchesModel() {
            let final = Word.finalGeneration
            var mix = WalkMix(state: 0x64_0005)
            for start in [0, 1, final - 3, final - 1, final] as [UInt64] {
                var word = laneWord(0, start)
                var (phase, generation): (UInt64, UInt64) = (0, start)
                for _ in 0..<256 {
                    switch mix.next() % 3 {
                    case 0:
                        let claimable = phase == 0 && generation < final
                        if claimable { (phase, generation) = (1, generation + 1) }
                        #expect(Word.claim(word) == (claimable ? laneWord(phase, generation) : nil))
                        word = Word.claim(word) ?? word
                    case 1:
                        let probe = generation &+ mix.next() % 3 &- 1
                        let held = Word.held(by: probe)
                        #expect(held == (probe >= 1 && probe <= final ? laneWord(1, probe) : nil))
                        if let held, held == word {  // The release compare-exchange succeeds.
                            phase = 2
                            word = Word.retire(held)
                        }
                    default:
                        let freeable = phase == 2
                        if freeable { phase = 0 }
                        #expect(Word.free(word) == (freeable ? laneWord(0, generation) : nil))
                        word = Word.free(word) ?? word
                    }
                    #expect(word == laneWord(phase, generation))
                }
            }
        }
    }
}
