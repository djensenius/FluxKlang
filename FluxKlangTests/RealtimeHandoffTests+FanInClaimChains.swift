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

/// Shared by `+FanInOut`, `+Starvation` and `+FanInStress`.
extension RealtimeHandoffTests {
    /// Lane critical exhaustion (`criticalExhausted`).
    static let fanInCriticalScope = FaultScope(handoff: 5, target: 1)
    /// Claim exhaustion (`producerSlotsExhausted`).
    static let fanInSlotsScope = FaultScope(handoff: 5, target: 3)
    /// Prepared but never raised by a fan-in.
    static let fanInNeighbourScope = FaultScope(handoff: 5, target: 2)

    /// One element delivered by `FanInHandoff.drain`, tagged with its lane.
    struct FanInDelivery: Hashable {
        let lane: UInt8
        let value: UInt64
    }

    /// A valid MIDI-receive fan-in policy for `lanes` producers: the whole handoff holds `lanes × laneCapacity`
    /// slots, `lanes × reserved` of them critical.
    static func fanInPolicy(lanes: Int = 4, laneCapacity: Int = 20, reserved: Int = 16,
                            ordering: HandoffOrdering = .fifoPerProducer) -> HandoffPolicy {
        policy(producer: .midiReceive,
               producers: ProducerCardinality(maximum: lanes, evidence: lanes == 1 ? .verified : .assumedConservative),
               capacity: laneCapacity &* lanes, ordering: ordering,
               overflow: .reservedCritical(reserved: reserved &* lanes))
    }

    static func fanInLatch() throws -> FaultChainAuthority {
        try FaultChainAuthority.testing(scopes: [fanInCriticalScope, fanInSlotsScope, fanInNeighbourScope])
    }

    static func makeFanIn(_ faults: FaultChainAuthority, claims: FaultChainAuthority? = nil, lanes: Int = 4,
                          laneCapacity: Int = 20, reserved: Int = 16) throws -> FanInHandoff<UInt64> {
        try FanInHandoff<UInt64>(policy: fanInPolicy(lanes: lanes, laneCapacity: laneCapacity, reserved: reserved),
                                 laneCapacity: laneCapacity, reserved: reserved, faults: faults,
                                 claimFaults: claims ?? fanInClaims(), criticalScope: fanInCriticalScope,
                                 producerSlotsScope: fanInSlotsScope)
    }

    /// One drain's deliveries, in delivery order.
    static func drained(_ handoff: FanInHandoff<UInt64>, quota: Int, total: Int) -> [FanInDelivery] {
        var deliveries: [FanInDelivery] = []
        let count = handoff.drain(perLaneQuota: quota, total: total) {
            deliveries.append(FanInDelivery(lane: $0, value: $1))
        }
        #expect(count == deliveries.count)
        return deliveries
    }
}

/// Shared state for the concurrent refused-claim stress (#190 FLP6).
private final class ClaimChainStressState: Sendable {
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let exited = Atomic<Int>(0)
    let refused = Atomic<UInt64>(0)
    let claimed = Atomic<UInt64>(0)
}

/// Shared state for the lane hand-over stress (#190 K-190b). `turn` and `drainWanted` are relaxed on purpose: they
/// add no happens-before edge, so holders are ordered only by the handoff's claim, release and drain and by the
/// lane chain's slot, and TSan sees a missing acquire or release on that path.
private final class LaneHandOverState: Sendable {
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let exited = Atomic<Int>(0)
    /// The next hand-over (`round × threads + thread`); relaxed.
    let turn = Atomic<Int>(0)
    /// Set by a holder before it releases, cleared by the next holder once it has claimed; relaxed.
    let drainWanted = Atomic<Bool>(false)
    let refused = Atomic<UInt64>(0)
    let admitted = Atomic<UInt64>(0)
    let delivered = Atomic<UInt64>(0)
    let other = Atomic<UInt64>(0)
    let missed = Atomic<Int>(0)

    /// Bounded spin, yielding the core; `false` at `deadline`.
    func spin(until deadline: ContinuousClock.Instant, _ condition: () -> Bool) -> Bool {
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            sched_yield()
        }
        return true
    }
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
                                     slots: FaultScope = Root.fanInSlotsScope,
                                     caller: inout RefusalCallerToken) throws -> (FanIn, ProducerToken) {
            let handoff = try preparation(faults, claims, lanes: 1, slots: slots).get()
            return (handoff, try RefusalCalling.claim(handoff, &caller))
        }

        /// Nothing counted on the lanes' latch: the claim path never raises there.
        static func expectLanesLatchUntouched(_ faults: FaultChainAuthority,
                                              sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(faults.pending { _ in } == 0 && faults.unknownScopeFaults == 0, sourceLocation: sourceLocation)
        }

        /// T1. Kills: minting no claim chain, more than one, or one shared across handoffs.
        @Test func initMintsExactlyOneClaimChain() throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let faults = try Root.fanInLatch()
            let claims = try Root.fanInClaims(budget: 3)
            #expect(claims.mintedChains == 0)
            let first = try Root.makeFanIn(faults, claims: claims, lanes: 1)
            #expect(claims.mintedChains == 1)
            let second = try Root.makeFanIn(faults, claims: claims, lanes: 1)
            #expect(claims.mintedChains == 2)
            _ = try RefusalCalling.claim(first, &caller!)
            _ = try RefusalCalling.claim(second, &caller!)
            // Holding the first handoff's token never contends a refusal on the second: each has its own chain.
            var refusals: [ProducerToken?] = []
            #expect(first.withChainTokenHeld { refusals.append(second.claimProducer(frame: 4, caller: &caller!)) })
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
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let faults = try Root.fanInLatch()
            let claims = try Root.fanInClaims()
            let (handoff, owner) = try Self.full(faults, claims, caller: &caller!)
            var refusals: [ProducerToken?] = []
            #expect(handoff.withChainTokenHeld { refusals.append(handoff.claimProducer(frame: 9, caller: &caller!)) })
            #expect(refusals == [nil] && handoff.refusedClaimCount == 1 && handoff.contendedClaimCount == 1)
            #expect(claims.hasContendedFault && claims.isLatched(Self.slots))
            #expect(Root.FaultChaining.records(claims).isEmpty && claims.unknownScopeFaults == 0)
            Self.expectLanesLatchUntouched(faults)
            #expect(handoff.claimProducer(frame: 10, caller: &caller!) == nil)
            #expect(handoff.refusedClaimCount == 2 && handoff.contendedClaimCount == 1)
            #expect(Root.fanInRecord(claims, Self.slots)
                    == FaultRecord(scope: Self.slots, kind: .producerSlotsExhausted, count: 1, firstFrame: 10))
            #expect(handoff.releaseProducer(owner, caller: &caller!) == .ok && handoff.refusedNotOwnerCount == 0)
        }

        /// T4. Claims that succeed while the token is held never touch it: no contention, no fault, no refusal.
        /// Kills: taking the token at entry (or on the success path).
        @Test func successfulClaimNeverTakesTheChainToken() throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let faults = try Root.fanInLatch()
            let claims = try Root.fanInClaims()
            let handoff = try Root.makeFanIn(faults, claims: claims)
            var tokens: [ProducerToken] = []
            #expect(handoff.withChainTokenHeld {
                tokens = (0..<4).compactMap { _ in handoff.claimProducer(caller: &caller!) }
            })
            #expect(tokens.map(\.lane) == [0, 1, 2, 3])
            #expect(handoff.refusedClaimCount == 0 && handoff.contendedClaimCount == 0)
            #expect(!claims.hasContendedFault && !claims.isLatched(Self.slots))
            #expect(Root.FaultChaining.records(claims).isEmpty)
            Self.expectLanesLatchUntouched(faults)
            #expect(handoff.claimProducer(frame: 2, caller: &caller!) == nil && handoff.contendedClaimCount == 0)
            #expect(Root.fanInRecord(claims, Self.slots)?.count == 1)
        }

        /// T5. After every refusal, counted or contended, the token is back in its slot and the next refusal is
        /// counted. Kills: a missing `put`.
        @Test func everyRefusalPutsTheTokenBack() throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let faults = try Root.fanInLatch()
            let claims = try Root.fanInClaims()
            let (handoff, _) = try Self.full(faults, claims, caller: &caller!)
            for frame in Int64(1)...3 {
                #expect(handoff.claimProducer(frame: frame, caller: &caller!) == nil)
                #expect(handoff.withChainTokenHeld {})
            }
            var contended: [ProducerToken?] = []
            #expect(handoff.withChainTokenHeld { contended.append(handoff.claimProducer(frame: 4, caller: &caller!)) })
            #expect(contended == [nil] && handoff.withChainTokenHeld {})
            #expect(handoff.claimProducer(frame: 5, caller: &caller!) == nil && handoff.withChainTokenHeld {})
            #expect(handoff.refusedClaimCount == 5 && handoff.contendedClaimCount == 1)
            #expect(Root.fanInRecord(claims, Self.slots)
                    == FaultRecord(scope: Self.slots, kind: .producerSlotsExhausted, count: 4, firstFrame: 1))
            Self.expectLanesLatchUntouched(faults)
        }

        /// T6. Records, unknown-scope counts and acknowledge results match a plain `FaultLatch` raised by hand as
        /// `claimProducer` raised before FLP6, for a prepared and an unprepared slots scope. Kills: a wrong scope,
        /// kind or frame on the token path, or a raise on the lanes' latch.
        @Test func claimRaiseMatchesPlainLatch() throws {
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let faults = try Root.fanInLatch()
            let claims = try Root.fanInClaims(budget: 2)
            let twin = try FaultLatch(scopes: [Self.slots])
            let stray = FaultScope(handoff: 5, target: 9)
            let (prepared, _) = try Self.full(faults, claims, caller: &caller!)
            let (unprepared, _) = try Self.full(faults, claims, slots: stray, caller: &caller!)
            let refusals = [prepared.claimProducer(frame: 17, caller: &caller!),
                            prepared.claimProducer(frame: 18, caller: &caller!),
                            unprepared.claimProducer(frame: 5, caller: &caller!)]
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
            #expect(prepared.claimProducer(frame: 40, caller: &caller!) == nil)
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
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let faults = try Root.fanInLatch()
            let claims = try Root.fanInClaims()
            let (handoff, _) = try FanInClaimChaining.full(faults, claims, caller: &caller!)
            let state = ClaimChainStressState()
            let roles = try (0..<Self.threads).map { _ in try #require(RefusalCaller.prepare()) }
            for thread in 0..<Self.threads {
                Thread {
                    defer { state.exited.add(1, ordering: .releasing) }
                    var caller: RefusalCallerToken? = try? RefusalCalling.take(roles[thread])
                    defer { RefusalCalling.giveBack(roles[thread], &caller) }
                    state.arrived.add(1, ordering: .releasing)
                    let deadline = ContinuousClock.now + .seconds(20)
                    while !state.started.load(ordering: .acquiring), ContinuousClock.now < deadline {}
                    guard caller != nil else { return }
                    for call in 0..<Self.claimsPerThread {
                        let frame = Int64(thread * Self.claimsPerThread + call)
                        if handoff.claimProducer(frame: frame, caller: &caller!) == nil {
                            state.refused.add(1, ordering: .relaxed)
                        } else {
                            state.claimed.add(1, ordering: .relaxed)
                        }
                    }
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
            #expect(roles.allSatisfy { !RefusalCalling.isEmpty($0) })
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

        static let handOverThreads = 4
        static let handOverRounds = 200

        /// T15 (#190 K-190b; lane-chain T14's stress, here for `file_length`). `Thread`s take turns holding one lane
        /// while a drain thread empties it: each turn claims (retrying until the drain frees the lane), pushes
        /// critical events until the first refusal and releases. The turn counter is relaxed, so successive holders
        /// on different threads are ordered only by the handoff and the lane chain's slot. Every turn's refusal is
        /// counted through the one lane chain and none contends (TSan, `--filter Stress`). Kills: a missing
        /// acquire or release on the claim or release CAS (TSan); a chain minted per claim or replaced on
        /// release; a skipped `put`. A relaxed free store in the drain survives here (no holder reads what the
        /// drain wrote); `stressClaimChurnKeepsLanesExclusive` catches it.
        @Test(.timeLimit(.minutes(1)))
        func laneHandOverAcrossThreadsNeverContends() throws {
            let (threads, rounds) = (Self.handOverThreads, Self.handOverRounds)
            let role = try #require(RefusalCaller.prepare())
            var caller: RefusalCallerToken? = try RefusalCalling.take(role)
            defer { RefusalCalling.giveBack(role, &caller) }
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 1, laneCapacity: 20)
            let chainID = try #require(handoff.owners.first).laneChainID
            let state = LaneHandOverState()
            let roles = try (0..<threads).map { _ in try #require(RefusalCaller.prepare()) }
            for thread in 0..<threads {
                Thread {
                    defer { state.exited.add(1, ordering: .releasing) }
                    var caller: RefusalCallerToken? = try? RefusalCalling.take(roles[thread])
                    defer { RefusalCalling.giveBack(roles[thread], &caller) }
                    state.arrived.add(1, ordering: .releasing)
                    let deadline = ContinuousClock.now + .seconds(25)
                    guard state.spin(until: deadline, { state.started.load(ordering: .acquiring) }),
                          caller != nil else { return }
                    for round in 0..<rounds {
                        let turn = round * threads + thread
                        guard Self.holdLane(handoff, state, turn: turn, until: deadline, caller: &caller!) else {
                            state.missed.add(1, ordering: .relaxed)
                            return
                        }
                    }
                }.start()
            }
            Thread {
                defer { state.exited.add(1, ordering: .releasing) }
                state.arrived.add(1, ordering: .releasing)
                let deadline = ContinuousClock.now + .seconds(25)
                guard state.spin(until: deadline, { state.started.load(ordering: .acquiring) }) else { return }
                while state.turn.load(ordering: .relaxed) < threads * rounds, ContinuousClock.now < deadline {
                    guard state.drainWanted.load(ordering: .relaxed) else {
                        sched_yield()
                        continue
                    }
                    let count = handoff.drain(perLaneQuota: 32, total: 32) { _, _ in }
                    state.delivered.add(UInt64(count), ordering: .relaxed)
                }
            }.start()
            let arrivalDeadline = ContinuousClock.now + .seconds(20)
            while state.arrived.load(ordering: .acquiring) < threads + 1, ContinuousClock.now < arrivalDeadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            state.started.store(true, ordering: .releasing)
            let exitDeadline = ContinuousClock.now + .seconds(35)
            while state.exited.load(ordering: .acquiring) < threads + 1, ContinuousClock.now < exitDeadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard state.exited.load(ordering: .acquiring) == threads + 1 else {
                Issue.record("hand-over workers did not exit; post-run checks skipped")
                return
            }
            let turns = UInt64(threads * rounds)
            let scope = Root.fanInCriticalScope
            print("FanInClaimChainingStress hand-over refused claims: \(handoff.refusedClaimCount)")
            #expect(roles.allSatisfy { !RefusalCalling.isEmpty($0) })
            #expect(state.missed.load(ordering: .relaxed) == 0 && state.other.load(ordering: .relaxed) == 0)
            #expect(state.refused.load(ordering: .relaxed) == turns)
            #expect(handoff.contendedLaneCount(lane: 0) == 0 && !faults.hasContendedFault)
            #expect(Root.fanInRecord(faults, scope)
                    == FaultRecord(scope: scope, kind: .criticalExhausted, count: turns, firstFrame: 0))
            #expect(handoff.refusedCount(lane: 0, class: .critical) == turns && handoff.refusedNotOwnerCount == 0)
            #expect(faults.mintedChains == 1 && handoff.owners.first?.laneChainID == chainID)
            // The joins order every worker before this thread, now the only consumer: draining frees the lane.
            let rest = handoff.drain(perLaneQuota: 32, total: 32) { _, _ in }
            let delivered = state.delivered.load(ordering: .relaxed) + UInt64(rest)
            #expect(delivered == state.admitted.load(ordering: .relaxed))
            #expect(try RefusalCalling.claim(handoff, &caller!).generation == turns + 1)
            #expect(handoff.withLaneChainTokenHeld(lane: 0) {})
        }

        /// One hand-over turn of `laneHandOverAcrossThreadsNeverContends`: waits for `turn`, claims (retrying until
        /// the drain frees the lane), pushes critical events until the first refusal, releases and passes the turn
        /// on. `false` at `deadline`.
        private static func holdLane(_ handoff: FanIn, _ state: LaneHandOverState, turn: Int,
                                     until deadline: ContinuousClock.Instant,
                                     caller: inout RefusalCallerToken) -> Bool {
            guard state.spin(until: deadline, { state.turn.load(ordering: .relaxed) == turn }) else { return false }
            var claimed: ProducerToken?
            while claimed == nil, ContinuousClock.now < deadline {
                claimed = handoff.claimProducer(frame: Int64(turn), caller: &caller)
                if claimed == nil { sched_yield() }
            }
            guard let token = claimed else { return false }
            state.drainWanted.store(false, ordering: .relaxed)
            var status = KernelStatus.ok
            while status == .ok, ContinuousClock.now < deadline {
                status = handoff.tryPush(UInt64(turn), class: .critical, frame: Int64(turn), token: token,
                                         caller: &caller)
                if status == .ok { state.admitted.add(1, ordering: .relaxed) }
            }
            if status == .refused(.criticalExhausted) {
                state.refused.add(1, ordering: .relaxed)
            } else {
                state.other.add(1, ordering: .relaxed)
            }
            // Before the release, so the next holder's clear, after its acquiring claim, is later.
            state.drainWanted.store(true, ordering: .relaxed)
            if handoff.releaseProducer(token, caller: &caller) != .ok { state.other.add(1, ordering: .relaxed) }
            state.turn.store(turn &+ 1, ordering: .relaxed)
            return true
        }
    }
}
