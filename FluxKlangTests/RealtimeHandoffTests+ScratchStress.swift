import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests

/// Counts, at each linked probe plan's `deinit`, whether its arena was still alive.
final class ScratchArenaWatch: Sendable {
    let aliveAtPlanDeinit = Atomic<Int>(0)
    let goneAtPlanDeinit = Atomic<Int>(0)
}

/// A plan for slot tests (shared with `+Scratch`). Its `deinit` records where it ran (M6's `RetireLedger`)
/// and, once `link` has named the arena render saw it with, whether that arena was still alive. `link` runs once,
/// on render, before the plan can retire; the retire ring orders it before the control-side `deinit`.
final class ScratchPlanProbe: @unchecked Sendable {
    let serial: Int
    let scratchBytes: Int
    let ledger: RetireLedger
    let watch: ScratchArenaWatch
    private weak var arena: ScratchArena?
    private var linked = false

    init(_ serial: Int, scratchBytes: Int, _ ledger: RetireLedger, _ watch: ScratchArenaWatch) {
        self.serial = serial
        self.scratchBytes = scratchBytes
        self.ledger = ledger
        self.watch = watch
        ledger.created.add(1, ordering: .relaxed)
    }

    func link(_ arena: ScratchArena) {
        self.arena = arena
        linked = true
    }

    deinit {
        if linked {
            if arena == nil {
                watch.goneAtPlanDeinit.add(1, ordering: .relaxed)
            } else {
                watch.aliveAtPlanDeinit.add(1, ordering: .relaxed)
            }
        }
        ledger.noteDeinit()
    }
}

/// Arrival barrier, a per-wait deadline, a cancel flag and counters for the dedicated stress `Thread`s.
private final class ScratchHarness: Sendable {
    /// Bound on the cleanup join after a failed run: long enough for cancelled workers to notice and exit.
    static let cleanupLimit: Duration = .seconds(15)
    /// The comment of the arrival assertion's failure.
    static let arrivalFailure: Comment = "stress workers did not all arrive before release"
    /// Bound on each wait (arrival, every worker loop, the join); 15 s except in the harness's own test.
    let waitLimit: Duration
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let cancelled = Atomic<Bool>(false)
    let timedOut = Atomic<Int>(0)
    let exited = Atomic<Int>(0)
    let controlDone = Atomic<Bool>(false)
    let failures = Atomic<Int>(0)
    let adoptions = Atomic<Int>(0)
    let linked = Atomic<Int>(0)
    let renderRefusals = Atomic<Int>(0)

    init(waitLimit: Duration = .seconds(15)) {
        self.waitLimit = waitLimit
    }

    /// Worker: spins until `condition` holds; `false` once cancelled or after `waitLimit` (which cancels all).
    func spin(until condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + waitLimit
        while !condition() {
            if cancelled.load(ordering: .relaxed) { return false }
            if ContinuousClock.now >= deadline {
                timedOut.add(1, ordering: .relaxed)
                cancelled.store(true, ordering: .relaxed)
                return false
            }
        }
        return true
    }

    /// The comment of the issue a failed `run` records.
    static func runFailure(arrived: Int, released: Bool, joined: Bool, timedOut: Int, cleaned: Bool) -> Comment {
        """
        scratch stress run failed (arrived \(arrived), released \(released), joined \(joined), timed out \
        \(timedOut)); cleanup join \(cleaned ? "done" : "gave up"); results skipped
        """
    }

    /// Test thread: sleeps until `condition` holds; `false` after `limit`.
    static func waitFor(_ limit: Duration, _ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }

    /// Starts one `Thread` per worker. Each counts in and waits for the start flag, which the test thread releases
    /// only after asserting that all arrived. Returns `true` when every worker started and exited in time and no
    /// loop timed out. Otherwise it cancels, joins again for up to `cleanupLimit` so no worker outlives the run
    /// unnoticed, records an `Issue` and returns `false`; the caller must not read results (`try #require`).
    /// Workers capture what they share, so it stays alive even if the cleanup join gives up.
    func run(_ workers: [@Sendable () -> Void]) -> Bool {
        for worker in workers {
            Thread {
                self.arrived.add(1, ordering: .relaxed)
                if self.spin(until: { self.started.load(ordering: .acquiring) }) { worker() }
                self.exited.add(1, ordering: .releasing)
            }.start()
        }
        let allArrived = Self.waitFor(waitLimit) { arrived.load(ordering: .relaxed) == workers.count }
        #expect(allArrived, Self.arrivalFailure)
        if allArrived { started.store(true, ordering: .releasing) }
        let joined = allArrived && Self.waitFor(waitLimit) { exited.load(ordering: .acquiring) == workers.count }
        if joined, timedOut.load(ordering: .relaxed) == 0 { return true }
        cancelled.store(true, ordering: .relaxed)
        let cleaned = Self.waitFor(Self.cleanupLimit) { exited.load(ordering: .acquiring) == workers.count }
        Issue.record(Self.runFailure(arrived: arrived.load(ordering: .relaxed), released: allArrived, joined: joined,
                                     timedOut: timedOut.load(ordering: .relaxed), cleaned: cleaned))
        return false
    }
}

/// What the harness self-tests saw: issues the intentional-timeout filter matched or let escape, and how far each
/// worker body got.
private final class HarnessSelfTestLog: Sendable {
    let matched = Atomic<Int>(0)
    let escaped = Atomic<Int>(0)
    let spinnerRan = Atomic<Bool>(false)
    let slowSawCancel = Atomic<Bool>(false)
    let slowCleanupDone = Atomic<Bool>(false)
}

/// Holds the slot so workers borrow it and the test thread alone drops it (teardown on control).
private final class SlotBox: @unchecked Sendable {
    /// Written before the start flag is released and after every worker exited; read only in between.
    var slot: ScratchProbeSlot?
    init(_ slot: ScratchProbeSlot) { self.slot = slot }
}

extension RealtimeHandoffTests {
    /// Concurrency stress on dedicated `Thread`s; run under TSan and ASan with `--filter ScratchSlotStress`. It
    /// asserts results only, never that publishing and cycling overlapped.
    struct ScratchSlotStress {
        /// Control publishes plans of varying scratch sizes and reclaims while render cycles, fills and checks the
        /// current arena. Every adopted plan has its own arena of its own size, serials never go back, every
        /// arena outlives its plan and every release runs on control.
        @Test(.timeLimit(.minutes(1)))
        func stressPublishWhileCyclingKeepsPlanAndArena() throws {
            let plans = 4_000
            let ledger = RetireLedger()
            let watch = ScratchArenaWatch()
            let harness = ScratchHarness()
            let (queue, faults) = try Root.scratchRetireQueue(capacity: 2)
            let box = SlotBox(ScratchProbeSlot(retire: queue))
            let joined = harness.run([
                {
                    ledger.controlThread.store(RetireLedger.currentThread(), ordering: .releasing)
                    defer { harness.controlDone.store(true, ordering: .releasing) }
                    guard let slot = box.slot else { return }
                    var serial = 1
                    var pending: ScratchPlanProbe?  // the only strong reference, as `publish` requires
                    _ = harness.spin {
                        if serial % 8 == 0 { slot.reclaim() }
                        if pending == nil {
                            pending = ScratchPlanProbe(serial, scratchBytes: 16 * (1 + serial % 9), ledger, watch)
                        }
                        let bytes = pending?.scratchBytes ?? 0
                        switch try? slot.publish(&pending, scratchBytes: bytes, alignment: 16) {
                        case .ok?:
                            serial += 1
                        case .refused(.full)?:
                            slot.reclaim()  // `pending` was handed back; retry it
                        default:  // threw, `.notOwner` or anything else
                            harness.failures.add(1, ordering: .relaxed)
                            return true
                        }
                        return serial > plans
                    }
                },
                {
                    ledger.renderThread.store(RetireLedger.currentThread(), ordering: .releasing)
                    guard let slot = box.slot else { return }
                    Self.render(slot, harness)
                }
            ])
            try #require(joined)
            ledger.controlThread.store(RetireLedger.currentThread(), ordering: .releasing)
            box.slot?.reclaim()
            box.slot = nil
            #expect(harness.failures.load(ordering: .relaxed) == 0)
            #expect(harness.renderRefusals.load(ordering: .relaxed) == 0)
            #expect(harness.adoptions.load(ordering: .relaxed) > 0)
            #expect(watch.aliveAtPlanDeinit.load(ordering: .relaxed) == harness.linked.load(ordering: .relaxed))
            #expect(watch.goneAtPlanDeinit.load(ordering: .relaxed) == 0)
            #expect(!faults.isLatched(Root.scratchRetireScope))
            #expect(ledger.created.load(ordering: .acquiring) == plans)
            #expect(ledger.live == 0)
            #expect(ledger.allOnControl)
        }

        /// Render loop: `.ok` is the only status counted as an adoption. Stops after the first empty cycle once
        /// control is done.
        private static func render(_ slot: ScratchProbeSlot, _ harness: ScratchHarness) {
            var last = 0
            var frame: Int64 = 0
            _ = harness.spin {
                let done = harness.controlDone.load(ordering: .acquiring)
                frame &+= 1
                let status = slot.beginCycle(frame: frame)
                if status == .ok { harness.adoptions.add(1, ordering: .relaxed) }
                if status == .refused(.full) { harness.renderRefusals.add(1, ordering: .relaxed) }
                let seen = slot.withCurrent(Self.check) ?? 0
                if seen < last { harness.failures.add(1, ordering: .relaxed) }
                if seen > last {
                    slot.withCurrent { plan, scratch in plan.link(scratch) }
                    harness.linked.add(1, ordering: .relaxed)
                    last = seen
                }
                return done && status == .empty
            }
        }

        /// Render: the arena is this plan's (size and alignment), empty after `beginCycle`, holds exactly its bytes
        /// and keeps what was written. Returns the plan's serial, or -1 on any mismatch.
        private static func check(_ plan: ScratchPlanProbe, _ arena: ScratchArena) -> Int {
            let mark = UInt32(truncatingIfNeeded: plan.serial)
            guard arena.byteCapacity == plan.scratchBytes, arena.alignment == 16,
                  let words = arena.take(UInt32.self, count: plan.scratchBytes / 4) else { return -1 }
            words.initialize(repeating: mark)
            guard words.allSatisfy({ $0 == mark }), arena.take(UInt8.self, count: 1) == nil else { return -1 }
            return plan.serial
        }

        /// The harness itself: once a worker loop or the run's own join times out, `run` cancels and keeps joining,
        /// so it returns only after a worker that is slow to notice the cancel has exited too. Only that run's own
        /// failure report is expected, exactly once; both bodies must have run, the slow one to its end.
        @Test(.timeLimit(.minutes(1)))
        func harnessJoinsCancelledWorkersBeforeReturning() {
            let harness = ScratchHarness(waitLimit: .milliseconds(200))
            let log = HarnessSelfTestLog()
            var joined = true
            Self.expectingIntentionalTimeout(log) {
                joined = harness.run([
                    {
                        log.spinnerRan.store(true, ordering: .relaxed)
                        _ = harness.spin { false }  // never done: ends by its own timeout or the run's cancel
                    },
                    {
                        let deadline = ContinuousClock.now + .seconds(15)
                        while !harness.cancelled.load(ordering: .relaxed), ContinuousClock.now < deadline {
                            Thread.sleep(forTimeInterval: 0.001)
                        }
                        log.slowSawCancel.store(harness.cancelled.load(ordering: .relaxed), ordering: .relaxed)
                        Thread.sleep(forTimeInterval: 0.5)  // exits well after the run's own join gave up
                        log.slowCleanupDone.store(true, ordering: .relaxed)
                    }
                ])
            }
            let exited = harness.exited.load(ordering: .acquiring)  // pairs with each worker's releasing exit
            let cancelled = harness.cancelled.load(ordering: .relaxed)
            let matched = log.matched.load(ordering: .relaxed)
            let spinnerRan = log.spinnerRan.load(ordering: .relaxed)
            let slowSawCancel = log.slowSawCancel.load(ordering: .relaxed)
            let slowCleanupDone = log.slowCleanupDone.load(ordering: .relaxed)
            #expect(matched == 1)
            #expect(exited == 2)
            #expect(spinnerRan)
            #expect(slowSawCancel)
            #expect(slowCleanupDone)
            #expect(!joined)
            #expect(cancelled)
        }

        /// Negative control for the masking case. An unfiltered known-issue block around `run` would also absorb
        /// the arrival assertion and the report of a run in which no worker body ran, so the self-test could pass
        /// with neither body run. Recorded inside the self-test's filter, each such issue escapes it (here to an
        /// outer block that expects exactly them), and only the intentional timeout is matched.
        @Test
        func harnessSelfTestFilterLeavesOtherIssuesUnsuppressed() {
            let log = HarnessSelfTestLog()
            let unexpected: [Comment] = [  // the first three: no body ran
                ScratchHarness.runFailure(arrived: 0, released: false, joined: false, timedOut: 0, cleaned: true),
                ScratchHarness.runFailure(arrived: 1, released: false, joined: false, timedOut: 0, cleaned: true),
                ScratchHarness.runFailure(arrived: 2, released: false, joined: false, timedOut: 0, cleaned: true),
                ScratchHarness.runFailure(arrived: 2, released: true, joined: false, timedOut: 1, cleaned: false),
                "an unrelated failure"
            ]
            withKnownIssue("issues the self-test's filter must not absorb") {
                Self.expectingIntentionalTimeout(log) {
                    let allArrived = false
                    #expect(allArrived, ScratchHarness.arrivalFailure)  // as `run` reports a failed arrival
                    for comment in unexpected { Issue.record(comment) }
                    Issue.record(
                        ScratchHarness.runFailure(arrived: 2, released: true, joined: false, timedOut: 1, cleaned: true)
                    )
                }
            } matching: { issue in
                guard !Self.isIntentionalTimeout(issue) else { return false }
                log.escaped.add(1, ordering: .relaxed)
                return true
            }
            let matched = log.matched.load(ordering: .relaxed)
            let escaped = log.escaped.load(ordering: .relaxed)
            #expect(matched == 1)
            #expect(escaped == unexpected.count + 1)
        }

        /// Runs `body` expecting the self-test's intentional timeout: suppresses, and counts in `log.matched`, only
        /// issues `isIntentionalTimeout` accepts. Every other issue is recorded as usual.
        private static func expectingIntentionalTimeout(_ log: HarnessSelfTestLog, _ body: () -> Void) {
            withKnownIssue("the harness run times out on purpose") {
                body()
            } matching: { issue in
                guard Self.isIntentionalTimeout(issue) else { return false }
                log.matched.add(1, ordering: .relaxed)
                return true
            }
        }

        /// The self-test's one expected issue: `run`'s own failure report after both workers arrived and were
        /// released and its cleanup join finished, joined or not and with any timeout count. Not the arrival
        /// assertion, a run whose barrier was never released (no body ran), a cleanup join that gave up, or
        /// anything else.
        private static func isIntentionalTimeout(_ issue: Issue) -> Bool {
            guard case .unconditional = issue.kind, issue.comments.count == 1 else { return false }
            let comment = issue.comments[0]
            return [false, true].contains { joined in
                (0...2).contains { timedOut in
                    comment == ScratchHarness.runFailure(arrived: 2, released: true, joined: joined,
                                                         timedOut: timedOut, cleaned: true)
                }
            }
        }
    }
}
