import Foundation
import Synchronization
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Only the contention harness parks; the publication-ordering test must not acquire these extra edges.
final class OwnershipContention: @unchecked Sendable {
    let flags: SafetyFlags
    let rounds: Int
    let scopes = 8
    let requesters = 4
    /// Taker advances the permitted round after its final sweep.
    let round = Atomic<Int>(0)
    /// Cumulative requester completions and mid-round signals.
    let completed = Atomic<Int>(0)
    let signalled = Atomic<Int>(0)
    /// Signal snapshot taken BEFORE the most recently completed sweep, including empty sweeps.
    let acknowledged = Atomic<Int>(0)
    let timeouts = Atomic<Int>(0)
    /// Taker-owned; read only after joining all workers.
    var lost = 0
    var overlapped = 0

    private let lock = NSLock()
    private let wakes = (0..<5).map { _ in DispatchSemaphore(value: 0) }
    /// Lock-protected binary tokens, not an ever-growing semaphore count. One consumer per worker.
    private var pending = [Bool](repeating: false, count: 5)
    private var lastProgress: ContinuousClock.Instant?
    private var lastChange = "startup"
    private var firstExpiry: String?

    init(flags: SafetyFlags, rounds: Int) {
        self.flags = flags
        self.rounds = rounds
    }

    var diagnostic: String {
        lock.lock()
        defer { lock.unlock() }
        return firstExpiry ?? "no contention wait expired"
    }

    /// Counters are published before notification. Requests and sweeps NEVER hold this lock.
    /// This adds harness happens-before edges, deliberately absent from the separate publication test.
    func notify(_ change: String) {
        lock.lock()
        defer { lock.unlock() }
        lastProgress = .now
        lastChange = change
        for worker in wakes.indices where !pending[worker] {
            pending[worker] = true
            wakes[worker].signal()
        }
    }

    /// A notification preceding the wait remains consumable; repeated notifications coalesce to one token.
    func consumeWake(worker: Int, until deadline: DispatchTime) -> Bool {
        guard wakes[worker].wait(timeout: deadline) == .success else { return false }
        lock.lock()
        // A notifier racing token consumption may coalesce here. The consumer always rechecks its
        // predicate afterward, so that publication is observed without needing another token.
        pending[worker] = false
        lock.unlock()
        return true
    }

    func wait(worker: Int, phase: String, current: Int, deadline: ContinuousClock.Instant,
              _ predicate: () -> Bool) -> Bool {
        while true {
            let parkStart = DispatchTime.now()
            let now = ContinuousClock.now
            if now >= deadline {
                timeouts.add(1, ordering: .relaxed)
                lock.lock()
                if firstExpiry == nil {
                    let recorded = ContinuousClock.now
                    let start = deadline - .seconds(25)
                    // Individually atomic observations, not a transactional snapshot of all counters.
                    firstExpiry = "worker=\(worker) phase=\(phase) round=\(current) "
                        + "controls=(round:\(round.load(ordering: .acquiring)),"
                        + "signal:\(signalled.load(ordering: .acquiring)),"
                        + "ack:\(acknowledged.load(ordering: .acquiring)),"
                        + "completed:\(completed.load(ordering: .acquiring))) "
                        + "elapsed=\(start.duration(to: recorded)) "
                        + "last=\(lastChange) idle=\((lastProgress ?? start).duration(to: recorded))"
                }
                lock.unlock()
                return false
            }
            if predicate() { return true }
            // Both clocks are monotonic. Recheck the original ContinuousClock budget after every wake or
            // bounded slice (also covers sleep); never restart the 25-second budget or use wall-clock Date.
            let remaining = now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            _ = consumeWake(worker: worker, until: parkStart + min(seconds, 0.05))
        }
    }

    @discardableResult
    func signal() -> Int {
        let value = signalled.add(1, ordering: .releasing).newValue
        notify("signal:\(value)")
        return value
    }

    func complete() {
        let value = completed.add(1, ordering: .releasing).newValue
        notify("completed:\(value)")
    }

    func sweep(into union: inout [SafetyFlagSet]) {
        for scope in union.indices { union[scope].formUnion(flags.take(scope: UInt32(scope))) }
    }

    /// The hook deterministically exercises publication between snapshot and sweep, without native scheduling.
    func sweepAcknowledging(into union: inout [SafetyFlagSet], afterSnapshot: () -> Void = {}) {
        let seen = signalled.load(ordering: .acquiring)
        afterSnapshot()
        sweep(into: &union)
        // Even an empty sweep must acknowledge: a prior sweep may already have consumed this signal's bits.
        acknowledged.store(seen, ordering: .releasing)
        notify("ack:\(seen)")
    }

    func hasSweepWork(after completions: Int) -> Bool {
        signalled.load(ordering: .acquiring) > acknowledged.load(ordering: .acquiring)
            || completed.load(ordering: .acquiring) != completions
    }

    /// Each unique (scope, flag) pair is requested once: two scopes before the handshake, two after.
    func requester(_ index: Int, deadline: ContinuousClock.Instant) {
        let flag = SafetyFlag.allCases[index % SafetyFlag.allCases.count]
        let mine = (0..<scopes).filter { $0 % (requesters / 2) == index / 2 }.map { UInt32($0) }
        for current in 0..<rounds {
            guard wait(worker: index, phase: "round", current: current, deadline: deadline, {
                round.load(ordering: .acquiring) >= current
            }) else { return }
            for scope in mine.prefix(2) { _ = flags.request(flag, scope: scope) }
            let value = signal()
            guard wait(worker: index, phase: "ack", current: current, deadline: deadline, {
                acknowledged.load(ordering: .acquiring) >= value
            }) else { return }
            for scope in mine.dropFirst(2) { _ = flags.request(flag, scope: scope) }
            complete()
        }
    }

    func taker(deadline: ContinuousClock.Instant) {
        for current in 0..<rounds {
            var union = [SafetyFlagSet](repeating: [], count: scopes)
            var completions = requesters * current
            while completed.load(ordering: .acquiring) < requesters * (current + 1) {
                guard wait(worker: requesters, phase: "signal/completion", current: current, deadline: deadline, {
                    hasSweepWork(after: completions)
                }) else { return }
                completions = completed.load(ordering: .acquiring)
                sweepAcknowledging(into: &union)
            }
            // Acknowledged first-half requests must have been swept before the round could complete.
            if union.contains(where: { !$0.isEmpty }) { overlapped += 1 }
            sweep(into: &union)
            lost += union.filter { $0 != [.panic, .allNotesOff] }.count
            round.store(current + 1, ordering: .releasing)
            notify("round:\(current + 1)")
        }
    }
}
