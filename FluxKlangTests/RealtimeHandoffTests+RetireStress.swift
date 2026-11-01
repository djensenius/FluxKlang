import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests

/// Holds the exchange so worker threads borrow it and the test thread alone drops it (teardown on control).
private final class ExchangeBox: @unchecked Sendable {
    /// Written before the start flag is released and after every worker has exited; read only in between.
    var value: ProbeExchange?
    init(_ value: ProbeExchange) { self.value = value }
}

/// Barrier, deadline, cancellation and counters for the `Thread`-based retire stress tests.
private final class RetireHarness: Sendable {
    static let budget: Duration = .seconds(25)
    let deadline = ContinuousClock.now + RetireHarness.budget
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let cancelled = Atomic<Bool>(false)
    let timedOut = Atomic<Int>(0)
    let exited = Atomic<Int>(0)
    let controlDone = Atomic<Bool>(false)
    let acknowledged = Atomic<Int>(0)
    let failures = Atomic<Int>(0)
    let adoptions = Atomic<Int>(0)
    let refusedPublishes = Atomic<Int>(0)
    /// `beginCycle` results of `.refused(.full)`: only blocked stall *retries*. A first stall still adopts and
    /// returns `.ok`, so it shows in `retire.refusedCount` and the `.retireBacklog` fault instead.
    let renderRefusals = Atomic<Int>(0)
    /// Supersede rounds: the round number control has fully published. Control stores it `.releasing` (its CAS
    /// precedes it); render loads it `.relaxed` on purpose, so it is no happens-before edge and the pending CAS
    /// alone must order the payload's initialisation.
    let ready = Atomic<Int>(0)
    /// The highest serial render saw; written by render before it exits, read after the acquiring join.
    let lastSeen = Atomic<Int>(0)

    /// `true` once cancelled or past the deadline; the first expiry is counted and cancels every worker.
    func expired() -> Bool {
        if cancelled.load(ordering: .relaxed) { return true }
        guard ContinuousClock.now >= deadline else { return false }
        timedOut.add(1, ordering: .relaxed)
        cancelled.store(true, ordering: .relaxed)
        return true
    }

    /// Spins until `condition` holds or the harness expires; returns whether it held. Yields the CPU every
    /// 1024 polls so a loaded machine can still schedule the other worker; the deadline and cancellation checks
    /// run on every poll.
    func spin(until condition: () -> Bool) -> Bool {
        var polls = 0
        while !condition() {
            if expired() { return false }
            polls &+= 1
            if polls & 0x3FF == 0 { sched_yield() }
        }
        return true
    }

    /// Arrival barrier: count in, then wait for the start flag the test thread releases once all have arrived.
    func arrive() -> Bool {
        arrived.add(1, ordering: .relaxed)
        return spin { started.load(ordering: .acquiring) }
    }

    /// Starts one dedicated `Thread` per worker, releases them together and waits (bounded) for all to exit.
    /// `false` (with an `Issue`) when a loop timed out or a worker did not exit; callers then skip every post-run
    /// check (`try #require`).
    func run(_ workers: [@Sendable () -> Void]) -> Bool {
        for worker in workers {
            Thread {
                worker()
                self.exited.add(1, ordering: .releasing)
            }.start()
        }
        let limit = deadline + .seconds(5)
        while arrived.load(ordering: .relaxed) < workers.count, ContinuousClock.now < limit {
            Thread.sleep(forTimeInterval: 0.001)
        }
        started.store(true, ordering: .releasing)
        while exited.load(ordering: .acquiring) < workers.count, ContinuousClock.now < limit {
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard exited.load(ordering: .acquiring) == workers.count else {
            cancelled.store(true, ordering: .relaxed)
            Issue.record("retire stress workers did not exit; post-run checks skipped")
            return false
        }
        guard timedOut.load(ordering: .relaxed) == 0 else {
            Issue.record("a bounded retire stress loop timed out; post-run checks skipped")
            return false
        }
        return true
    }
}

private enum RetireOperation: CaseIterable { case publish, cycle, reclaim }

private enum RetireOutcome: Equatable {
    case status(KernelStatus)
    case reclaimed(Int)
}

/// The M6 reference model of one exchange: `retired` payloads await reclaim, at most one is `pending`, and
/// `current` says whether render holds a payload.
private struct RetireModel {
    let capacity: Int
    var current: Bool
    var retired = 0
    var pending = false
    var released = 0

    mutating func apply(_ operation: RetireOperation) -> RetireOutcome {
        switch operation {
        case .publish:
            if pending {
                released += 1  // superseded
            } else if current, retired == capacity {
                released += 1  // refused; the caller drops it
                return .status(.refused(.full))
            } else {
                pending = true
            }
            return .status(.ok)
        case .cycle:
            guard pending else { return .status(.empty) }
            pending = false
            if current { retired += 1 }
            current = true
            return .status(.ok)
        case .reclaim:
            defer { (released, retired) = (released + retired, 0) }
            return .reclaimed(retired)
        }
    }

    var reservations: Int { retired + (pending && current ? 1 : 0) }
}

extension RealtimeHandoffTests {
    /// Every operation sequence up to length 7 (and long seeded random ones) against a reference model of one
    /// exchange: statuses, releases, reservations and `retired + (pending ? 1 : 0) <= capacity` after each step.
    struct RetireModelChecking {
        /// Runs `operations` on a fresh exchange and model; returns the first divergence, or `nil`.
        fileprivate static func check(_ operations: [RetireOperation], capacity: Int, initial: Bool) throws -> String? {
            let ledger = RetireLedger()
            var model = RetireModel(capacity: capacity, current: initial)
            let divergence: String? = try {
                let fixture = try RetiringExchanging.make(capacity: capacity,
                                                          initial: initial ? RetireProbe(0, ledger) : nil)
                let (exchange, queue, faults) = (fixture.exchange, fixture.queue, fixture.faults)
                for (step, operation) in operations.enumerated() {
                    let actual: RetireOutcome = switch operation {
                    case .publish: .status(exchange.publish(RetireProbe(step + 1, ledger)))
                    case .cycle: .status(ledger.asRender { exchange.beginCycle(frame: Int64(step)) })
                    case .reclaim: .reclaimed(exchange.reclaim())
                    }
                    let expected = model.apply(operation)
                    func context() -> String { "\(operations) cap \(capacity) initial \(initial) step \(step)" }
                    guard actual == expected else { return "\(context()): \(actual) != \(expected)" }
                    guard ledger.deinited.load(ordering: .acquiring) == model.released else {
                        return "\(context()): released \(ledger.deinited.load(ordering: .acquiring)), "
                            + "model \(model.released)"
                    }
                    guard queue.reservedCount == model.reservations,
                          model.retired + (model.pending ? 1 : 0) <= capacity else {
                        return "\(context()): reservations \(queue.reservedCount) != \(model.reservations)"
                    }
                    guard !faults.isLatched(RetireQueueing.scope) else { return "\(context()): backlog fault" }
                }
                return nil
            }()
            if let divergence { return divergence }
            guard ledger.live == 0, ledger.allOnControl else { return "\(operations): leak or render deinit" }
            return nil
        }

        @Test func everyShortSequenceMatchesTheModel() throws {
            var checked = 0
            for capacity in 1...3 {
                for initial in [false, true] {
                    for length in 0...7 {
                        var combinations = 1
                        for _ in 0..<length { combinations *= RetireOperation.allCases.count }
                        for code in 0..<combinations {
                            var rest = code
                            let operations = (0..<length).map { _ in
                                defer { rest /= RetireOperation.allCases.count }
                                return RetireOperation.allCases[rest % RetireOperation.allCases.count]
                            }
                            if let divergence = try Self.check(operations, capacity: capacity, initial: initial) {
                                Issue.record(Comment(rawValue: divergence))
                                return
                            }
                            checked += 1
                        }
                    }
                }
            }
            #expect(checked == 6 * 3_280)
        }

        @Test func longSeededSequencesMatchTheModel() throws {
            var state: UInt64 = 0x6A09_E667_F3BC_C908
            for run in 0..<200 {
                let operations = (0..<200).map { _ in
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    return RetireOperation.allCases[Int(state >> 33) % RetireOperation.allCases.count]
                }
                if let divergence = try Self.check(operations, capacity: 1 + run % 4, initial: run % 2 == 0) {
                    Issue.record(Comment(rawValue: divergence))
                    return
                }
            }
        }
    }

    /// Concurrency stress on dedicated `Thread`s (never a task group); run under TSan with `--filter Stress`.
    struct RetireStress {
        /// Control publishes and reclaims while render cycles and reads every adopted payload. Asserts no
        /// use-after-free (magic and monotonic serial), no render `deinit` and created == deinit'd at the end.
        @Test(.timeLimit(.minutes(1)))
        func stressPublishAndCyclesConserveObjects() throws {
            let target = 20_000
            let ledger = RetireLedger()
            let harness = RetireHarness()
            let (box, faults) = try Self.prepare(capacity: 2, ledger)
            try #require(harness.run([
                {
                    ledger.controlThread.store(RetireLedger.currentThread(), ordering: .releasing)
                    guard harness.arrive(), let exchange = box.value else { return }
                    var serial = 1
                    // Reclaims only every eighth publish or after a refusal, so backpressure is exercised.
                    while serial <= target, !harness.expired() {
                        if serial % 8 == 0 { exchange.reclaim() }
                        if exchange.publish(RetireProbe(serial, ledger)) == .ok {
                            serial += 1
                        } else {
                            harness.refusedPublishes.add(1, ordering: .relaxed)
                            exchange.reclaim()
                        }
                    }
                    harness.controlDone.store(true, ordering: .releasing)
                },
                {
                    ledger.renderThread.store(RetireLedger.currentThread(), ordering: .releasing)
                    guard harness.arrive(), let exchange = box.value else { return }
                    Self.render(exchange, harness)
                }
            ]))
            ledger.controlThread.store(RetireLedger.currentThread(), ordering: .releasing)
            #expect(box.value?.retire.refusedCount == 0)  // no retire was ever refused, not even a first stall
            box.value?.reclaim()
            box.value = nil
            #expect(harness.failures.load(ordering: .relaxed) == 0)
            #expect(harness.renderRefusals.load(ordering: .relaxed) == 0)
            #expect(harness.adoptions.load(ordering: .relaxed) > 0)
            #expect(harness.lastSeen.load(ordering: .relaxed) == target)  // the final publish was adopted
            #expect(!faults.isLatched(RetireQueueing.scope))
            Self.expectConserved(ledger, created: target + 1 + harness.refusedPublishes.load(ordering: .relaxed))
            print("RetireStress adoptions \(harness.adoptions.load(ordering: .relaxed)), refused publishes "
                  + "\(harness.refusedPublishes.load(ordering: .relaxed))")
        }

        /// Render loop: cycle, read the current payload, stop after the first empty cycle once control is done.
        private static func render(_ exchange: ProbeExchange, _ harness: RetireHarness) {
            var last = 0
            while !harness.expired() {
                let done = harness.controlDone.load(ordering: .acquiring)
                let status = exchange.beginCycle(frame: Int64(last))
                if status == .ok { harness.adoptions.add(1, ordering: .relaxed) }
                if status == .refused(.full) { harness.renderRefusals.add(1, ordering: .relaxed) }
                let seen = exchange.withCurrent { probe -> Int in
                    guard let probe, probe.magic == RetireProbe.alive else { return -1 }
                    return probe.serial
                }
                if seen < last { harness.failures.add(1, ordering: .relaxed) }
                last = max(last, seen)
                if done, status == .empty { break }
            }
            harness.lastSeen.store(last, ordering: .relaxed)
        }

        /// Deterministic handshake, alternating two kinds of round. Nothing is reclaimed until the end, so the
        /// retire ring's `head` never changes and the pending slot is the only control-to-render edge. A relaxed
        /// publish or take therefore shows up as a ThreadSanitizer race (or a stale or poisoned payload).
        /// - Odd rounds (store path): control publishes one payload into the empty slot; render spins on
        ///   `beginCycle` until it adopts it.
        /// - Even rounds (CAS path, forced): control publishes a decoy, then the real payload, then stores
        ///   `ready` with `.releasing`. Render does not cycle until its `.relaxed` load sees `ready`, so the decoy
        ///   is still pending and the second publish must supersede it by CAS. Control checks that by its
        ///   reservation count, which a CAS keeps unchanged. Render then expects `.ok` on its first cycle and
        ///   serial `3r/2` (one serial per odd round, two per even round).
        ///
        /// Render's relaxed `ready` load does not synchronise with the release store. The checks detect either
        /// too-early take: before the decoy store, it returns `.empty` and the final reclaim count is short;
        /// between the decoy store and CAS, replacement falls back, failing the reservation and serial checks.
        /// RMW atomicity makes the latter detectable; it does not establish cross-atomic ordering. The relaxed
        /// load is deliberate: `ready` adds no happens-before edge, so only the CAS's release orders the real
        /// payload's initialisation, and weakening that CAS (mutant R3c) is a TSan race on render's read.
        ///
        /// Retire capacity is `rounds + rounds / 2` rather than the exact `rounds` adoptions: a CAS that falls
        /// back to the store path reserves an extra slot. The spare reports that as a counted failure without
        /// also causing a refusal.
        @Test(.timeLimit(.minutes(1)))
        func stressPendingPublicationOrdersPayloadInitialisation() throws {
            let rounds = 2_048
            let ledger = RetireLedger()
            let harness = RetireHarness()
            let (box, _) = try Self.prepare(capacity: rounds + rounds / 2, ledger)
            try #require(harness.run([
                {
                    ledger.controlThread.store(RetireLedger.currentThread(), ordering: .releasing)
                    guard harness.arrive(), let exchange = box.value else { return }
                    Self.publishRounds(rounds, exchange, harness, ledger)
                },
                {
                    ledger.renderThread.store(RetireLedger.currentThread(), ordering: .releasing)
                    guard harness.arrive(), let exchange = box.value else { return }
                    Self.adoptRounds(rounds, exchange, harness)
                }
            ]))
            ledger.controlThread.store(RetireLedger.currentThread(), ordering: .releasing)
            #expect(box.value?.reclaim() == rounds)
            box.value = nil
            #expect(harness.failures.load(ordering: .relaxed) == 0)
            Self.expectConserved(ledger, created: rounds + rounds / 2 + 1)  // + one decoy per even round
        }

        /// Control side of the ordering handshake; see `stressPendingPublicationOrdersPayloadInitialisation`.
        private static func publishRounds(_ rounds: Int, _ exchange: ProbeExchange, _ harness: RetireHarness,
                                          _ ledger: RetireLedger) {
            var serial = 0
            for round in 1...rounds {
                var published = true
                if round.isMultiple(of: 2) {
                    serial += 1
                    published = exchange.publish(RetireProbe(serial, ledger)) == .ok  // decoy: store path
                    let reserved = exchange.retire.reservedCount
                    serial += 1
                    published = published && exchange.publish(RetireProbe(serial, ledger)) == .ok
                    published = published && exchange.retire.reservedCount == reserved  // it took the CAS path
                    harness.ready.store(round, ordering: .releasing)  // render's load stays relaxed: no edge
                } else {
                    serial += 1
                    published = exchange.publish(RetireProbe(serial, ledger)) == .ok
                }
                if !published { harness.failures.add(1, ordering: .relaxed) }
                guard harness.spin(until: { harness.acknowledged.load(ordering: .acquiring) >= round }) else { return }
            }
        }

        /// Render side of the ordering handshake.
        private static func adoptRounds(_ rounds: Int, _ exchange: ProbeExchange, _ harness: RetireHarness) {
            var expected = 0
            for round in 1...rounds {
                let frame = Int64(round)
                if round.isMultiple(of: 2) {
                    expected += 2
                    // Relaxed on purpose: an acquire would mask missing ordering in the pending CAS.
                    guard harness.spin(until: { harness.ready.load(ordering: .relaxed) >= round }) else { return }
                    if exchange.beginCycle(frame: frame) != .ok { harness.failures.add(1, ordering: .relaxed) }
                } else {
                    expected += 1
                    guard harness.spin(until: { exchange.beginCycle(frame: frame) == .ok }) else { return }
                }
                let seen = exchange.withCurrent { probe in
                    probe.map { $0.magic == RetireProbe.alive ? $0.serial : -1 } ?? -2
                }
                if seen != expected { harness.failures.add(1, ordering: .relaxed) }
                harness.acknowledged.store(round, ordering: .releasing)
            }
        }

        /// The box holds the only strong reference, so `box.value = nil` on the test thread is the teardown.
        private static func prepare(capacity: Int, _ ledger: RetireLedger) throws -> (ExchangeBox, FaultLatch) {
            let fixture = try RetiringExchanging.make(capacity: capacity, initial: RetireProbe(0, ledger))
            return (ExchangeBox(fixture.exchange), fixture.faults)
        }

        private static func expectConserved(_ ledger: RetireLedger, created: Int) {
            #expect(ledger.created.load(ordering: .acquiring) == created)
            #expect(ledger.deinited.load(ordering: .acquiring) == created)
            #expect(ledger.renderDeinits.load(ordering: .acquiring) == 0)
            #expect(ledger.allOnControl)
        }
    }
}
