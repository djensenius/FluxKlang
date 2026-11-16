import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared counters for the chain-token stress test.
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
    }
}
