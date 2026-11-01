import Darwin
import Foundation
import Synchronization
import Testing
@testable import FluxKlang

/// Shared counters for the `Thread`-based stress tests.
private final class StressState: Sendable {
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    /// Set by the controller when workers overrun; every worker loop checks it.
    let cancelled = Atomic<Bool>(false)
    /// Workers that passed the start barrier before every worker had arrived; any is a test failure.
    let earlyStarts = Atomic<Int>(0)
    /// Bounded worker waits or loops that gave up; any is a test failure.
    let timedOut = Atomic<Int>(0)
    let finishedRaisers = Atomic<Int>(0)
    /// Acknowledge handshake: the gate an acknowledge opens once it returns a record; raisers wait for it after
    /// their first batch.
    let released = Atomic<Bool>(false)
    /// `finishedRaisers` seen by the acknowledge that opened the gate (-1 until then).
    let finishedAtRelease = Atomic<Int>(-1)
    let exited = Atomic<Int>(0)
    let reported = Atomic<UInt64>(0)
    let mispaired = Atomic<Int>(0)
    let empty = Atomic<Int>(0)
    let refused = Atomic<Int>(0)
    /// `acknowledge` calls that returned `nil` (control-lock test).
    let nilAcknowledges = Atomic<Int>(0)
    /// First frames of all reported records; frames are unique per raise, so a repeat is a double report.
    let frames = Mutex<[Int64]>([])
    /// Mach thread ports of the control-lock test's waiting threads.
    let waiters = Mutex<[mach_port_t]>([])
}

extension RealtimeHandoffTests {
    /// `Thread` stress (TSan: `--filter Stress`) for conservation, pairing and the control lock under contention;
    /// the interleavings themselves are forced deterministically through the seam in `FaultLatching`.
    struct FaultLatchingStress {
        static let raisers = 8
        static let raisesPerThread = 10_000
        static var total: UInt64 { UInt64(raisers * raisesPerThread) }
        /// Cap on each bounded wait and worker loop. A failing run waits at most three times (arrival, exit,
        /// post-cancel exit), 45 s in total, inside the 1-minute time limit.
        static let deadline: Duration = .seconds(15)

        /// Every raise uses `kind = frame % 8`, so a record pairing one raise's kind with another's frame shows.
        static func kind(for frame: Int64) -> FaultKind {
            FaultKind(rawValue: UInt8(truncatingIfNeeded: frame % 8)) ?? .noPlan
        }

        static func isPaired(_ record: FaultRecord) -> Bool {
            record.firstFrame >= 0 && record.kind == kind(for: record.firstFrame)
        }

        /// Raises frames `batch` of one thread's `raisesPerThread`, stopping early (`false`) if cancelled. The
        /// batch ending at `raisesPerThread` counts the thread in `finishedRaisers`.
        @discardableResult
        fileprivate static func raise(_ latch: FaultLatch, _ scopes: [FaultScope], thread: Int, _ state: StressState,
                                      batch: Range<Int> = 0..<raisesPerThread) -> Bool {
            for raise in batch {
                if state.cancelled.load(ordering: .relaxed) { return false }
                let frame = Int64(thread * raisesPerThread + raise)
                if latch.raise(scopes[(thread + raise) % scopes.count], kind(for: frame), frame: frame) != .ok {
                    state.refused.add(1, ordering: .relaxed)
                }
            }
            if batch.upperBound == raisesPerThread { state.finishedRaisers.add(1, ordering: .releasing) }
            return true
        }

        /// Worker side: spins until `condition` holds; `false` (counted in `timedOut`) once cancelled or after
        /// `deadline`.
        fileprivate static func spin(_ state: StressState, until condition: () -> Bool) -> Bool {
            let end = ContinuousClock.now + deadline
            while !condition() {
                if state.cancelled.load(ordering: .relaxed) || ContinuousClock.now >= end {
                    state.timedOut.add(1, ordering: .relaxed)
                    return false
                }
            }
            return true
        }

        /// Controller side: polls `condition` for at most `deadline`.
        static func poll(until condition: () -> Bool) -> Bool {
            let end = ContinuousClock.now + deadline
            while !condition() {
                if ContinuousClock.now >= end { return condition() }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return true
        }

        /// Starts `threads` workers behind a start barrier that opens only once all have arrived, then waits for
        /// them (bounded). On overrun it cancels the workers and records an `Issue`. Returns `true` only when
        /// every worker exited in time without a timeout, so callers skip post-run checks otherwise. Every worker
        /// loop checks `cancelled`, so no worker keeps running after a cancelled run.
        fileprivate static func run(threads: Int, _ state: StressState,
                                    _ body: @escaping @Sendable (Int) -> Void) -> Bool {
            for index in 0..<threads {
                Thread {
                    state.arrived.add(1, ordering: .releasing)
                    if spin(state, until: { state.started.load(ordering: .acquiring) }) {
                        if state.arrived.load(ordering: .acquiring) < threads {
                            state.earlyStarts.add(1, ordering: .relaxed)
                        }
                        body(index)
                    }
                    state.exited.add(1, ordering: .releasing)
                }.start()
            }
            if poll(until: { state.arrived.load(ordering: .acquiring) == threads }) {
                #expect(state.arrived.load(ordering: .acquiring) == threads, "start barrier released early")
                state.started.store(true, ordering: .releasing)
            }
            let exited = poll { state.exited.load(ordering: .acquiring) == threads }
            if !exited {
                state.cancelled.store(true, ordering: .relaxed)
                Issue.record("stress workers overran \(deadline); cancelled")
                _ = poll { state.exited.load(ordering: .acquiring) == threads }
            }
            let timedOut = state.timedOut.load(ordering: .relaxed)
            if timedOut > 0 { Issue.record("\(timedOut) bounded stress wait(s) timed out") }
            #expect(state.earlyStarts.load(ordering: .relaxed) == 0)
            return exited && timedOut == 0
        }

        @Test(.timeLimit(.minutes(1))) func concurrentRaisesConserveCount() throws {
            let scopes = (0..<4).map { FaultScope(handoff: 2, target: UInt32($0)) }
            let latch = try FaultLatch(scopes: scopes)
            let state = StressState()
            guard Self.run(threads: Self.raisers, state, { Self.raise(latch, scopes, thread: $0, state) }) else {
                return
            }
            #expect(state.refused.load(ordering: .relaxed) == 0)
            var counts: [FaultScope: UInt64] = [:]
            var mispaired = 0
            let visited = latch.pending { record in
                counts[record.scope, default: 0] += record.count
                if !Self.isPaired(record) { mispaired += 1 }
            }
            #expect(visited == scopes.count)
            #expect(mispaired == 0)
            #expect(scopes.allSatisfy { counts[$0] == Self.total / UInt64(scopes.count) })
            FaultLatching.expectInvariant(latch, scopes)
        }

        @Test(.timeLimit(.minutes(1))) func raiseConcurrentWithAcknowledgeIsNeverLost() throws {
            let scopes = [FaultScope(handoff: 3, target: 0), FaultScope(handoff: 3, target: 1)]
            try Self.raiseWhileAcknowledging(scopes, acknowledgers: 1)
        }

        /// Two control threads contend for one scope's acknowledges (serialized by the control lock).
        @Test(.timeLimit(.minutes(1))) func twoAcknowledgersNeverDuplicateOrLose() throws {
            try Self.raiseWhileAcknowledging([FaultScope(handoff: 4, target: 0)], acknowledgers: 2)
        }

        /// A delayed reader across the wrap: while a snapshot of generation 2^24 − 1 is held under the control
        /// lock, a concurrent `acknowledge` and `pending` wait, so no generation step can intervene before the
        /// commit. Afterwards the waiting `acknowledge` finds nothing and the scope re-arms at generation 0.
        /// The commit waits until both threads are blocked in the kernel (Mach `TH_STATE_WAITING`, stable over
        /// consecutive samples) after they arrived; the only blocking point left in `acknowledge`/`pending` is the
        /// control lock. With the lock that state is always reached, so the test cannot fail; without it
        /// (`S-*-no-lock`) a thread cannot block there, runs to completion and `exited == 0` fails before the commit.
        @Test(.timeLimit(.minutes(1))) func controlWaitsForTheLockAcrossWrap() throws {
            let scope = FaultScope(handoff: 5, target: 0)
            let latch = try FaultLatch(scopes: [scope])
            let last = FaultLatch.generationMask
            let held = FaultLatch.TestState(generation: last, count: 2, claimGeneration: last)
            #expect(latch.seedForTesting(scope, held, kind: .noPlan, frame: 7))
            let probe = StressState()
            var committed: FaultRecord?
            latch.withControlLockForTesting {
                let snapshot = latch.snapshotForTesting(scope)
                Thread {
                    Self.arrive(probe)
                    if latch.acknowledge(scope) == nil { probe.nilAcknowledges.add(1, ordering: .relaxed) }
                    probe.exited.add(1, ordering: .releasing)
                }.start()
                Thread {
                    Self.arrive(probe)
                    _ = latch.pending { _ in }
                    probe.exited.add(1, ordering: .releasing)
                }.start()
                // Ends as soon as a thread returns (no lock: fails below) or both are blocked on the lock.
                let settled = Self.poll {
                    probe.exited.load(ordering: .acquiring) > 0 || Self.bothBlocked(probe)
                }
                if !settled { Issue.record("control calls neither blocked nor returned within \(Self.deadline)") }
                #expect(probe.exited.load(ordering: .acquiring) == 0)
                #expect(latch.stateForTesting(scope) == held)
                committed = snapshot.flatMap(latch.commitForTesting)
            }
            #expect(committed == FaultRecord(scope: scope, kind: .noPlan, count: 2, firstFrame: 7))
            let returned = Self.poll { probe.exited.load(ordering: .acquiring) == 2 }
            if !returned { Issue.record("control calls did not return within \(Self.deadline)") }
            guard returned else { return }
            #expect(probe.nilAcknowledges.load(ordering: .relaxed) == 1)
            #expect(latch.stateForTesting(scope) == .init(generation: 0, count: 0, claimGeneration: last))
            #expect(latch.raise(scope, .sysexAborted, frame: 9) == .ok)
            #expect(latch.acknowledge(scope) == FaultRecord(scope: scope, kind: .sysexAborted, count: 1, firstFrame: 9))
            probe.waiters.withLock { $0.forEach { _ = mach_port_deallocate(mach_task_self_, $0) } }
        }

        /// Records the calling thread's Mach port, then counts it as arrived.
        fileprivate static func arrive(_ probe: StressState) {
            let port = mach_thread_self()
            probe.waiters.withLock { $0.append(port) }
            probe.arrived.add(1, ordering: .releasing)
        }

        /// Both waiting threads arrived and are blocked in the kernel in 5 samples 1 ms apart, so a brief
        /// non-lock wait (such as a page fault) cannot pass for blocking on the lock.
        fileprivate static func bothBlocked(_ probe: StressState) -> Bool {
            guard probe.arrived.load(ordering: .acquiring) == 2 else { return false }
            let ports = probe.waiters.withLock { $0 }
            return (0..<5).allSatisfy { _ in
                defer { Thread.sleep(forTimeInterval: 0.001) }
                return ports.allSatisfy(isWaiting)
            }
        }

        /// `true` when the thread's Mach run state is `TH_STATE_WAITING` (blocked in the kernel).
        static func isWaiting(_ port: mach_port_t) -> Bool {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS && info.run_state == TH_STATE_WAITING
        }

        /// Checks one acknowledged or pending record and adds it to the reported total.
        fileprivate static func note(_ record: FaultRecord, _ state: StressState) {
            state.reported.add(record.count, ordering: .relaxed)
            if !isPaired(record) { state.mispaired.add(1, ordering: .relaxed) }
            if record.count == 0 { state.empty.add(1, ordering: .relaxed) }
            state.frames.withLock { $0.append(record.firstFrame) }
        }

        /// `raisers` raising threads plus `acknowledgers` acknowledging threads behind one start barrier. Asserts
        /// conservation, pairing, no empty record, no first raise reported twice and the generation invariant.
        ///
        /// Handshake, so the run cannot degrade into a sequential drain: each raiser raises its first half, then
        /// waits (bounded, cancellable) until an acknowledge has returned a record; that acknowledge opens the gate
        /// (with one or two acknowledgers, whichever returns a record first) and the raisers raise their second
        /// half. A record always exists for it (first-half raises, drained only by acknowledges that also open the
        /// gate), and no raiser can finish before the gate opens, so at least one acknowledge returning a record
        /// provably precedes half of every raiser's raises; `finishedAtRelease == 0` checks it.
        static func raiseWhileAcknowledging(_ scopes: [FaultScope], acknowledgers: Int) throws {
            let latch = try FaultLatch(scopes: scopes)
            let state = StressState()
            let half = Self.raisesPerThread / 2
            let ran = Self.run(threads: Self.raisers + acknowledgers, state) { thread in
                if thread < Self.raisers {
                    guard Self.raise(latch, scopes, thread: thread, state, batch: 0..<half) else { return }
                    guard Self.spin(state, until: { state.released.load(ordering: .acquiring) }) else { return }
                    Self.raise(latch, scopes, thread: thread, state, batch: half..<Self.raisesPerThread)
                    return
                }
                // Each poll acknowledges every scope; bounded and cancellable like every worker wait.
                _ = Self.spin(state) {
                    for scope in scopes {
                        guard let record = latch.acknowledge(scope) else { continue }
                        Self.note(record, state)
                        if state.finishedAtRelease.compareExchange(
                            expected: -1, desired: state.finishedRaisers.load(ordering: .acquiring),
                            ordering: .relaxed).exchanged {
                            state.released.store(true, ordering: .releasing)
                        }
                    }
                    return state.finishedRaisers.load(ordering: .acquiring) == Self.raisers
                }
            }
            guard ran else { return }
            let released = state.released.load(ordering: .acquiring)
            #expect(released)
            #expect(state.finishedAtRelease.load(ordering: .relaxed) == 0)
            #expect(state.finishedRaisers.load(ordering: .acquiring) == Self.raisers)
            _ = latch.pending { Self.note($0, state) }
            #expect(state.refused.load(ordering: .relaxed) == 0)
            #expect(state.mispaired.load(ordering: .relaxed) == 0)
            #expect(state.empty.load(ordering: .relaxed) == 0)
            #expect(state.reported.load(ordering: .relaxed) == Self.total)
            let frames = state.frames.withLock { $0 }
            #expect(Set(frames).count == frames.count)
            FaultLatching.expectInvariant(latch, scopes)
        }
    }
}
