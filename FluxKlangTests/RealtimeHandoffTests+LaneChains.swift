import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests
private typealias Ring = ReservedCapacityRing<UInt64>
private typealias FanIn = FanInHandoff<UInt64>

/// Test-only helpers (#190 FLP7b): rigs hold the largest budget, and the plain `raise` of the retired
/// `FaultLatch` API mints one chain per call and goes through its token.
extension FaultChainAuthority {
    /// An authority with `maximumChainBudget`, so a suite that mints per call or per handoff never runs dry.
    static func testing(scopes: [FaultScope]) throws -> FaultChainAuthority {
        try FaultChainAuthority(scopes: scopes, chainBudget: maximumChainBudget)
    }

    /// Mints one chain, takes its token, raises and puts it back; `.refused(.notOwner)` if the mint or the take
    /// fails. Control or test side only: it allocates and locks.
    func raise(_ scope: FaultScope, _ kind: FaultKind, frame: Int64) -> KernelStatus {
        guard let chain = mintChain(), var token = chain.take() else { return .refused(.notOwner) }
        let status = raise(&token, scope, kind, frame: frame)
        _ = chain.put(token)
        return status
    }
}

extension ReservedCapacityRing {
    /// Test seam of the old convenience: validates, mints a chain, then starts at `startingIndex` and
    /// `startingRefusals`.
    convenience init(policy: HandoffPolicy, faults: FaultChainAuthority, scope: FaultScope, startingIndex: UInt64,
                     startingRefusals: UInt64) throws(PreparationError) {
        try Self.validate(policy)
        guard let chain = faults.mintChain() else { throw .chainBudgetExhausted }
        try self.init(policy: policy, faults: faults, chain: chain, scope: scope, startingIndex: startingIndex,
                      startingRefusals: startingRefusals)
    }
}

/// A 20-slot lane with 16 reserved.
private let ringPolicy = Root.policy(capacity: 20, overflow: .reservedCritical(reserved: 16))

/// A ring on `faults` filled to capacity with critical events, so every further critical push is refused.
private func fullRing(_ faults: FaultChainAuthority, scope: FaultScope = Root.fanInCriticalScope) throws -> Ring {
    let ring = try Ring(policy: ringPolicy, faults: faults, scope: scope)
    for value in 0..<20 { #expect(ring.tryPush(UInt64(value), class: .critical, frame: 0) == .ok) }
    return ring
}

/// Why a ring refuses `policy` on `chain`, or `nil` when it accepts.
private func ringError(_ policy: HandoffPolicy, _ faults: FaultChainAuthority, _ chain: FaultChain)
    -> Ring.PreparationError? {
    do {
        _ = try Ring(policy: policy, faults: faults, chain: chain, scope: Root.fanInCriticalScope, startingIndex: 0)
        return nil
    } catch {
        return error
    }
}

/// The fan-in, or why `init` refused it.
private func prepare(_ policy: HandoffPolicy = Root.fanInPolicy(), laneCapacity: Int = 20, reserved: Int = 16,
                     faults: FaultChainAuthority, claims: FaultChainAuthority,
                     slots: FaultScope = Root.fanInSlotsScope) -> Result<FanIn, FanIn.PreparationError> {
    do {
        return .success(try FanIn(policy: policy, laneCapacity: laneCapacity, reserved: reserved, faults: faults,
                                  claimFaults: claims, criticalScope: Root.fanInCriticalScope,
                                  producerSlotsScope: slots))
    } catch {
        return .failure(error)
    }
}

/// One pure refusal of `FanInHandoff.init` and the error it must give.
private struct PureRow {
    let policy: HandoffPolicy
    let laneCapacity: Int
    let reserved: Int
    let scope: FaultScope
    let expected: FanIn.PreparationError

    init(_ policy: HandoffPolicy, _ laneCapacity: Int, _ reserved: Int, _ scope: FaultScope,
         _ expected: FanIn.PreparationError) {
        (self.policy, self.laneCapacity, self.reserved, self.scope, self.expected) =
            (policy, laneCapacity, reserved, scope, expected)
    }
}

/// Fills `token`'s lane with critical events.
private func fillLane(_ handoff: FanIn, _ token: ProducerToken) {
    for value in 0..<20 { #expect(handoff.tryPush(UInt64(value), class: .critical, frame: 0, token: token) == .ok) }
}

/// Shared state for the concurrent refusal stress (#190 FLP7b).
private final class LaneChainStressState: Sendable {
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let exited = Atomic<Int>(0)
    let refusedLane0 = Atomic<UInt64>(0)
    let refusedLane1 = Atomic<UInt64>(0)
    let other = Atomic<UInt64>(0)

    func refused(lane: Int) {
        if lane == 0 { refusedLane0.add(1, ordering: .relaxed) } else { refusedLane1.add(1, ordering: .relaxed) }
    }
}

extension RealtimeHandoffTests {
    /// #190 FLP7b: a lane's critical refusal raises `.criticalExhausted` only through the lane's own chain token,
    /// one chain per lane minted from the handoff's `faults` authority; the cycle watches that authority.
    struct LaneChaining {
        /// T1. Kills: one chain shared across lanes; a partial batch mint.
        @Test func mintsOneChainPerLane() throws {
            for lanes in [1, 4, 64] {
                let faults = try Root.fanInLatch()
                let claims = try Root.fanInClaims()
                let handoff = try Root.makeFanIn(faults, claims: claims, lanes: lanes, laneCapacity: 20)
                #expect(faults.mintedChains == lanes && claims.mintedChains == 1)
                #expect(handoff.owners.map(\.laneChainID) == (1...UInt64(lanes)).map { $0 })
                #expect(faults.mintChains(count: 65_537 - lanes) == nil)
            }
        }

        /// T2. A spent lane budget refuses `init` with `.laneChainBudgetExhausted` after exactly one claim unit, no
        /// lane chain and no identity (R1). Other suites prepare handoffs concurrently, so this retries until a
        /// window sees no other `init`. Kills: the lane mint before the claim mint; the mints after the identity.
        @Test func laneBudgetRefusalSpendsOnlyTheClaimUnit() throws {
            let deadline = ContinuousClock.now + .seconds(10)
            var attempts = 0
            var quiet = false
            while !quiet, ContinuousClock.now < deadline {
                attempts += 1
                let faults = try FaultChainAuthority(scopes: [Root.fanInCriticalScope], chainBudget: 3)
                let claims = try Root.fanInClaims(budget: 2)
                let before = FanIn.lastIssuedIdentity
                guard case .failure(.laneChainBudgetExhausted) = prepare(faults: faults, claims: claims) else {
                    Issue.record("a lane budget below the lane count did not refuse init")
                    return
                }
                #expect(claims.mintedChains == 1 && faults.mintedChains == 0)
                #expect(faults.mintChains(count: 3)?.count == 3)
                let accepted = try prepare(faults: Root.fanInLatch(), claims: Root.fanInClaims()).get()
                let after = FanIn.lastIssuedIdentity
                quiet = after == before &+ 1 && accepted.identity == after
            }
            #expect(quiet, "no window without another init in \(attempts) attempts")
        }

        /// T3. Every pure refusal, and the lane policy refusal, mints nothing on either authority. Kills: a mint
        /// before the lane policy check (`.lane(.reserveBelowMinimum)`) or before any pure check.
        @Test func pureRefusalsMintNothing() throws {
            let slots = Root.fanInSlotsScope
            let rows: [PureRow] = [
                .init(Root.fanInPolicy(ordering: .fifo), 20, 16, slots, .unsupportedPolicy(.ordering(.fifo))),
                .init(Root.fanInPolicy(), 21, 16, slots, .laneShapeMismatch(laneCapacity: 21, reserved: 16)),
                .init(Root.fanInPolicy(), 20, 16, Root.fanInCriticalScope,
                      .sharedFaultScope(Root.fanInCriticalScope)),
                .init(Root.fanInPolicy(reserved: 8), 20, 8, slots, .lane(.reserveBelowMinimum(8)))
            ]
            for row in rows {
                let (policy, laneCapacity, reserved, scope, expected) =
                    (row.policy, row.laneCapacity, row.reserved, row.scope, row.expected)
                let faults = try Root.fanInLatch()
                let claims = try Root.fanInClaims()
                let result = prepare(policy, laneCapacity: laneCapacity, reserved: reserved, faults: faults,
                                     claims: claims, slots: scope)
                guard case .failure(let error) = result, error == expected else {
                    Issue.record("expected \(expected)")
                    continue
                }
                #expect(faults.mintedChains == 0 && claims.mintedChains == 0)
            }
        }

        /// T4. A chain another authority minted is refused after the policy checks. Kills: `issued` skipped.
        @Test func foreignChainRefused() throws {
            let owner = try Root.fanInLatch()
            let foreign = try #require(try Root.fanInLatch().mintChain())
            #expect(ringError(ringPolicy, owner, foreign) == .foreignChain)
            #expect(ringError(Root.policy(), owner, foreign) == .unsupportedPolicy(.refuseProducer))
            let own = try #require(owner.mintChain())
            #expect(ringError(ringPolicy, owner, own) == nil && owner.mintedChains == 1)
        }

        /// T5. The convenience `init` mints its own chain after the policy checks, and refuses a spent budget.
        /// Kills: no mint; a mint before the policy check; the budget error missing.
        @Test func convenienceInitMintsOwnAndRefusesExhaustion() throws {
            let faults = try FaultChainAuthority(scopes: [Root.fanInCriticalScope], chainBudget: 2)
            let scope = Root.fanInCriticalScope
            do { _ = try Ring(policy: Root.policy(), faults: faults, scope: scope) } catch {
                #expect(error == .unsupportedPolicy(.refuseProducer) && faults.mintedChains == 0)
            }
            let first = try Ring(policy: ringPolicy, faults: faults, scope: scope)
            let second = try Ring(policy: ringPolicy, faults: faults, scope: scope)
            #expect(faults.mintedChains == 2 && first.laneChainID == 1 && second.laneChainID == 2)
            do { _ = try Ring(policy: ringPolicy, faults: faults, scope: scope) } catch {
                #expect(error == .chainBudgetExhausted && faults.mintedChains == 2)
            }
        }

        /// T6. Records, unknown-scope counts and acknowledge results match a plain `FaultLatch` raised by hand as
        /// the ring raised before FLP7b, for a prepared and an unprepared scope. Kills: a wrong kind or frame.
        @Test func criticalRefusalMatchesPlainLatch() throws {
            for (scope, prepared) in [(Root.fanInCriticalScope, true), (FaultScope(handoff: 5, target: 9), false)] {
                let faults = try Root.fanInLatch()
                let twin = try FaultLatch(scopes: [Root.fanInCriticalScope, Root.fanInSlotsScope])
                let ring = try fullRing(faults, scope: scope)
                for frame in [17, 18, .min, .max] as [Int64] {
                    #expect(ring.tryPush(1, class: .critical, frame: frame) == .refused(.criticalExhausted))
                    _ = twin.raise(scope, .criticalExhausted, frame: frame)
                }
                #expect(Root.FaultChaining.records(faults) == Root.FaultChaining.records(twin))
                #expect(faults.unknownScopeFaults == twin.unknownScopeFaults && ring.refusedCriticalCount == 4)
                #expect(prepared == (Root.fanInRecord(faults, scope)?.count == 4) && !faults.hasContendedFault)
                if prepared {
                    let observed = try #require(faults.observe(scope))
                    let expected = try #require(twin.observe(scope))
                    #expect(faults.acknowledge(observed) == twin.acknowledge(expected))
                } else {
                    #expect(faults.unknownScopeFaults == 4)
                }
            }
        }

        /// T7. Successful pushes and a general refusal never touch the token: with it held they raise nothing and
        /// contend nothing; only a critical refusal takes it. Kills: the token taken on the success path or on
        /// the general refusal.
        @Test func onlyCriticalRefusalTakesToken() throws {
            let faults = try Root.fanInLatch()
            let ring = try Ring(policy: ringPolicy, faults: faults, scope: Root.fanInCriticalScope)
            var statuses: [KernelStatus] = []
            var general: KernelStatus?
            #expect(ring.withChainTokenHeld {
                for value in 0..<20 { statuses.append(ring.tryPush(UInt64(value), class: .critical, frame: 0)) }
                general = ring.tryPush(99, class: .general, frame: 0)
            })
            #expect(statuses.count == 20 && statuses.allSatisfy { $0 == .ok } && general == .refused(.full))
            #expect(ring.contendedCount == 0 && !faults.hasContendedFault && ring.refusedGeneralCount == 1)
            #expect(Root.FaultChaining.records(faults).isEmpty)
            #expect(ring.tryPush(98, class: .critical, frame: 4) == .refused(.criticalExhausted))
            #expect(Root.fanInRecord(faults, Root.fanInCriticalScope)?.count == 1 && ring.contendedCount == 0)
        }

        /// T8. A critical refusal that finds the token held still returns `.refused(.criticalExhausted)`, counts in
        /// `refusedCriticalCount` and `contendedCount`, and latches only the contended fault, which latches every
        /// scope; a later refusal with the token free is counted normally. Kills: a silent contended branch; the
        /// contended count not bumped; the refusal count skipped.
        @Test func contendedRefusalLatches() throws {
            let faults = try Root.fanInLatch()
            let ring = try fullRing(faults)
            var status: KernelStatus?
            #expect(ring.withChainTokenHeld { status = ring.tryPush(1, class: .critical, frame: 3) })
            #expect(status == .refused(.criticalExhausted) && ring.refusedCriticalCount == 1)
            #expect(ring.contendedCount == 1 && faults.hasContendedFault)
            #expect(faults.isLatched(Root.fanInNeighbourScope) && faults.isLatched(Root.fanInSlotsScope))
            #expect(Root.FaultChaining.records(faults).isEmpty && faults.unknownScopeFaults == 0)
            #expect(ring.withChainTokenHeld {})
            #expect(ring.tryPush(2, class: .critical, frame: 5) == .refused(.criticalExhausted))
            #expect(Root.fanInRecord(faults, Root.fanInCriticalScope)
                    == FaultRecord(scope: Root.fanInCriticalScope, kind: .criticalExhausted, count: 1, firstFrame: 5))
            #expect(ring.contendedCount == 1 && ring.refusedCriticalCount == 2)
        }

        /// T9. After every refusal, counted or contended, the token is back in its slot and the next refusal is
        /// counted. Kills: a missing `put`.
        @Test func everyRefusalPutsTokenBack() throws {
            let faults = try Root.fanInLatch()
            let ring = try fullRing(faults)
            for frame in Int64(1)...3 {
                #expect(ring.tryPush(1, class: .critical, frame: frame) == .refused(.criticalExhausted))
                #expect(ring.withChainTokenHeld {})
            }
            #expect(ring.withChainTokenHeld { _ = ring.tryPush(1, class: .critical, frame: 4) })
            #expect(ring.withChainTokenHeld {} && ring.contendedCount == 1)
            #expect(ring.tryPush(1, class: .critical, frame: 5) == .refused(.criticalExhausted))
            #expect(Root.fanInRecord(faults, Root.fanInCriticalScope)
                    == FaultRecord(scope: Root.fanInCriticalScope, kind: .criticalExhausted, count: 4, firstFrame: 1))
        }

        /// T10. Each lane has its own chain: holding one lane's token never contends another lane's refusal, and
        /// the seams refuse an out-of-range lane. Kills: one chain shared across lanes.
        @Test func lanesHaveIndependentChains() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 2, laneCapacity: 20)
            let tokens = [try #require(handoff.claimProducer()), try #require(handoff.claimProducer())]
            for token in tokens { fillLane(handoff, token) }
            var refusals: [KernelStatus] = []
            #expect(handoff.withLaneChainTokenHeld(lane: 1) {
                refusals.append(handoff.tryPush(1, class: .critical, frame: 7, token: tokens[0]))
            })
            #expect(refusals == [.refused(.criticalExhausted)] && !faults.hasContendedFault)
            #expect(handoff.contendedLaneCount(lane: 0) == 0 && handoff.contendedLaneCount(lane: 1) == 0)
            #expect(Root.fanInRecord(faults, Root.fanInCriticalScope)?.count == 1)
            #expect(handoff.withLaneChainTokenHeld(lane: 0) {
                refusals.append(handoff.tryPush(2, class: .critical, frame: 8, token: tokens[0]))
            })
            #expect(refusals.count == 2 && faults.hasContendedFault)
            #expect(handoff.contendedLaneCount(lane: 0) == 1 && handoff.contendedLaneCount(lane: 1) == 0)
            #expect(!handoff.withLaneChainTokenHeld(lane: 2) {} && !handoff.withLaneChainTokenHeld(lane: -1) {})
            #expect(handoff.contendedLaneCount(lane: 2) == 0 && handoff.refusedNotOwnerCount == 0)
        }

        /// T11. A contended lane refusal latches the cycle's critical scope through the authority's contended
        /// fault, so step 2 silences every run for good, with no counted record to acknowledge. Kills: `isLatched`
        /// ignoring the contended flag.
        @Test func contendedSilencesCycle() throws {
            let rig = try CycleRig()
            let token = try #require(rig.events.claimProducer())
            var statuses: [KernelStatus] = []
            #expect(rig.events.withLaneChainTokenHeld(lane: 0) {
                for index in 0..<21 {
                    let event = cycleEvent(0, .noteOff(channel: 0, note: 60), sequence: UInt64(index))
                    statuses.append(rig.push(event, token))
                }
            })
            #expect(statuses.prefix(20).allSatisfy { $0 == .ok } && statuses.last == .refused(.criticalExhausted))
            #expect(rig.faults.hasContendedFault && rig.events.contendedLaneCount(lane: 0) == 1)
            #expect(rig.faults.pending { _ in } == 0 && rig.faults.observe(CycleRig.criticalScope) == nil)
            for block in 0..<3 {
                #expect(rig.run(Int64(block) * 64, 64).0.status == .silenced(.scopeFaulted))
            }
        }
    }

    /// T12 (#190 FLP7b). `Thread`s push critical events at once onto two full lanes, two threads per lane: every
    /// push is refused and refusals overlap, so each raises once through its lane's chain or, finding the token
    /// held, latches the contended fault (TSan, `--filter Stress`). Only refused pushes run, so the lane's plain
    /// `pushed` is only read; the refusal counter is a relaxed single-writer count and may lose updates, so it is
    /// not asserted exactly. Kills: a refusal that neither raises nor counts, under a race.
    struct LaneChainingStress {
        static let threads = 4
        static let pushesPerThread = 20_000

        @Test(.timeLimit(.minutes(1)))
        func concurrentRefusalsAreCountedOrContended() throws {
            let faults = try Root.fanInLatch()
            let handoff = try Root.makeFanIn(faults, lanes: 2, laneCapacity: 20)
            let tokens = [try #require(handoff.claimProducer()), try #require(handoff.claimProducer())]
            for token in tokens { fillLane(handoff, token) }
            let state = LaneChainStressState()
            for thread in 0..<Self.threads {
                let lane = thread / 2
                let token = tokens[lane]
                Thread {
                    state.arrived.add(1, ordering: .releasing)
                    let deadline = ContinuousClock.now + .seconds(20)
                    while !state.started.load(ordering: .acquiring), ContinuousClock.now < deadline {}
                    for call in 0..<Self.pushesPerThread {
                        let frame = Int64(thread * Self.pushesPerThread + call)
                        let status = handoff.tryPush(1, class: .critical, frame: frame, token: token)
                        if status == .refused(.criticalExhausted) {
                            state.refused(lane: lane)
                        } else {
                            state.other.add(1, ordering: .relaxed)
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
            let refused = (state.refusedLane0.load(ordering: .relaxed), state.refusedLane1.load(ordering: .relaxed))
            let contended = (handoff.contendedLaneCount(lane: 0), handoff.contendedLaneCount(lane: 1))
            print("LaneChainingStress contended refusals: \(contended)")
            let each = UInt64(2 * Self.pushesPerThread)
            #expect(state.other.load(ordering: .relaxed) == 0 && refused == (each, each))
            let counted = Root.fanInRecord(faults, Root.fanInCriticalScope)?.count ?? 0
            #expect(counted + contended.0 + contended.1 == refused.0 + refused.1)
            #expect(contended.0 <= refused.0 && contended.1 <= refused.1)
            #expect(faults.hasContendedFault == (contended.0 + contended.1 > 0))
            #expect(Root.FaultChaining.records(faults).allSatisfy { $0.kind == .criticalExhausted })
            #expect(faults.unknownScopeFaults == 0 && handoff.refusedNotOwnerCount == 0)
            #expect(handoff.withLaneChainTokenHeld(lane: 0) {} && handoff.withLaneChainTokenHeld(lane: 1) {})
        }
    }
}
