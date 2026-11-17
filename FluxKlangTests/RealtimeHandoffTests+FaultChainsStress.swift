import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared counters for the chain-token stress tests.
private final class ChainStressState: Sendable {
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let cancelled = Atomic<Bool>(false)
    let exited = Atomic<Int>(0)
    let timedOut = Atomic<Int>(0)
    /// Raises made while holding a token.
    let counted = Atomic<Int>(0)
    /// Attempts that found the slot empty and took the contended fallback.
    let contended = Atomic<Int>(0)
    /// `raise` or `put` results other than `.ok`.
    let wrongStatus = Atomic<Int>(0)
    /// Contexts holding the raced chain's token right now; a take that sees another holder is an overlap.
    let holders = Atomic<Int>(0)
    let overlaps = Atomic<Int>(0)
    let guarded = TokenGuardedCount()
    /// Per thread, the chain ids each authority granted to it in the batch-mint stress test.
    let mintedIds = Mutex<[[[UInt64]]]>([])
}

/// A plain (non-atomic) counter that only a token holder touches: the slot's release/acquire pair is its only
/// synchronization, so a lost update (or a TSan report) means the chain's happens-before edge is missing.
private final class TokenGuardedCount: @unchecked Sendable {
    var value = 0
}

extension RealtimeHandoffTests {
    /// `Thread` stress (TSan: `--filter Stress`) for chain tokens: contexts race one chain's slot, and every
    /// attempt is either one counted raise or one contended fallback.
    struct FaultChainingStress {
        static let threads = 4
        static let attemptsPerThread = 20_000
        /// Cap on each bounded wait; a failing run waits at most twice, inside the 1-minute limit.
        static let deadline: Duration = .seconds(15)

        static func kind(for frame: Int64) -> FaultKind {
            FaultKind(rawValue: UInt8(truncatingIfNeeded: frame % 8)) ?? .noPlan
        }

        /// One attempt: take, raise and put back, or fall back without raising when the slot is empty.
        fileprivate static func attempt(_ authority: FaultChainAuthority, _ chain: FaultChain, _ scope: FaultScope,
                                        frame: Int64, _ state: ChainStressState) {
            guard var token = chain.take() else {
                authority.raiseContended()
                state.contended.add(1, ordering: .relaxed)
                return
            }
            if state.holders.wrappingAdd(1, ordering: .relaxed).oldValue != 0 {
                state.overlaps.add(1, ordering: .relaxed)
            }
            if authority.raise(&token, scope, kind(for: frame), frame: frame) != .ok {
                state.wrongStatus.add(1, ordering: .relaxed)
            }
            state.guarded.value += 1
            state.counted.add(1, ordering: .relaxed)
            state.holders.wrappingSubtract(1, ordering: .relaxed)
            if chain.put(token) != .ok { state.wrongStatus.add(1, ordering: .relaxed) }
        }

        /// Starts `threads` workers behind a bounded start barrier and waits (bounded) for all to exit; on overrun
        /// it cancels them and records an issue. `true` only when every worker ran to completion in time.
        fileprivate static func run(_ state: ChainStressState, _ body: @escaping @Sendable (Int) -> Void) -> Bool {
            for index in 0..<threads {
                Thread {
                    state.arrived.add(1, ordering: .releasing)
                    let end = ContinuousClock.now + deadline
                    var ready = state.started.load(ordering: .acquiring)
                    while !ready && !state.cancelled.load(ordering: .relaxed) && ContinuousClock.now < end {
                        ready = state.started.load(ordering: .acquiring)
                    }
                    if ready { body(index) } else { state.timedOut.add(1, ordering: .relaxed) }
                    state.exited.add(1, ordering: .releasing)
                }.start()
            }
            let arrived = poll { state.arrived.load(ordering: .acquiring) == threads }
            state.started.store(arrived, ordering: .releasing)
            if !arrived { state.cancelled.store(true, ordering: .relaxed) }
            var exited = poll { state.exited.load(ordering: .acquiring) == threads }
            if !exited {
                state.cancelled.store(true, ordering: .relaxed)
                Issue.record("chain stress workers overran \(deadline); cancelled")
                exited = poll { state.exited.load(ordering: .acquiring) == threads }
            }
            let timedOut = state.timedOut.load(ordering: .relaxed)
            if timedOut > 0 { Issue.record("\(timedOut) chain stress worker(s) never started") }
            return arrived && exited && timedOut == 0
        }

        static func poll(until condition: () -> Bool) -> Bool {
            let end = ContinuousClock.now + deadline
            while !condition() {
                if ContinuousClock.now >= end { return condition() }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return true
        }

        /// Even threads race one chain; odd threads use a chain whose token the test holds throughout, so each of
        /// their attempts must fall back. Counted raises plus fallbacks equal attempts, the counted records hold
        /// exactly the counted raises, and the raced slot ends holding its one token.
        @Test(.timeLimit(.minutes(1))) func racingContextsConserveEveryAttempt() throws {
            let scopes = [FaultScope(handoff: 9, target: 0), FaultScope(handoff: 9, target: 1)]
            let authority = try FaultChainAuthority(scopes: scopes, chainBudget: 2)
            let raced = try #require(authority.mintChain())
            let held = try #require(authority.mintChain())
            let holder = try FaultChaining.take(held)
            let state = ChainStressState()
            let ran = Self.run(state) { thread in
                for index in 0..<Self.attemptsPerThread {
                    if state.cancelled.load(ordering: .relaxed) { return }
                    let frame = Int64(thread * Self.attemptsPerThread + index)
                    let chain = thread.isMultiple(of: 2) ? raced : held
                    Self.attempt(authority, chain, scopes[index % scopes.count], frame: frame, state)
                }
            }
            guard ran else { return }
            let counted = state.counted.load(ordering: .relaxed)
            let contended = state.contended.load(ordering: .relaxed)
            #expect(counted + contended == Self.threads * Self.attemptsPerThread)
            #expect(contended >= Self.threads / 2 * Self.attemptsPerThread)
            #expect(state.wrongStatus.load(ordering: .relaxed) == 0)
            #expect(state.overlaps.load(ordering: .relaxed) == 0)
            #expect(state.guarded.value == counted)
            #expect(authority.hasContendedFault)
            #expect(authority.unknownScopeFaults == 0)
            var total = 0
            var mispaired = 0
            _ = authority.pending { record in
                total += Int(record.count)
                if record.firstFrame < 0 || record.kind != Self.kind(for: record.firstFrame) { mispaired += 1 }
            }
            #expect(total == counted)
            #expect(mispaired == 0)
            // Neither slot is torn: the raced one holds exactly one token, the held one none until it is returned.
            #expect(raced.put(try FaultChaining.take(raced)) == .ok)
            #expect(FaultChaining.isEmpty(held))
            #expect(held.put(holder) == .ok)
            #expect(held.put(try FaultChaining.take(held)) == .ok)
        }

        /// Threads race batch mints of 0 to 8 chains on many small budgets in turn, so each budget's end is contended.
        /// Every grant is whole and `issued`, no budget is overshot, and each authority's grants are exactly ids
        /// `1...mintedChains`, once each.
        @Test(.timeLimit(.minutes(1))) func concurrentBatchMintsNeverOvershootBudget() throws {
            let budget = 16
            let attempts = 8
            let scopes = [FaultScope(handoff: 9, target: 0)]
            let authorities = try (0..<256).map { _ in try FaultChainAuthority(scopes: scopes, chainBudget: budget) }
            let state = ChainStressState()
            let ran = Self.run(state) { thread in
                var granted = [[UInt64]](repeating: [], count: authorities.count)
                for (index, authority) in authorities.enumerated() {
                    if state.cancelled.load(ordering: .relaxed) { break }
                    for attempt in 0..<attempts {
                        let count = (thread &* 7 &+ attempt &* 13 &+ index) % 9
                        guard let chains = authority.mintChains(count: count) else { continue }
                        let batch = chains.map(\.id)
                        let whole = batch.count == count && zip(batch, batch.dropFirst()).allSatisfy { $0 + 1 == $1 }
                        if !whole || !chains.allSatisfy(authority.issued) {
                            state.wrongStatus.add(1, ordering: .relaxed)
                        }
                        granted[index] += batch
                    }
                }
                state.mintedIds.withLock { $0.append(granted) }
            }
            guard ran else { return }
            let perThread = state.mintedIds.withLock { $0 }
            #expect(perThread.count == Self.threads)
            #expect(state.wrongStatus.load(ordering: .relaxed) == 0)
            for (index, authority) in authorities.enumerated() {
                let minted = authority.mintedChains
                let ids = perThread.flatMap { granted in granted.dropFirst(index).first ?? [] }.sorted()
                #expect(minted <= budget)
                #expect(ids == (0..<minted).map { UInt64($0 + 1) })
                // Whatever is left is still exactly available, all or nothing.
                #expect(authority.mintChains(count: budget - minted + 1) == nil)
                if minted < budget {
                    #expect(authority.mintChains(count: budget - minted)?.first?.id == UInt64(minted + 1))
                }
                #expect(authority.mintedChains == budget)
            }
        }
    }
}
