import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests

/// Shared state for the `Thread`-based SysEx stress test.
private final class SysExStressState: Sendable {
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let cancelled = Atomic<Bool>(false)
    let timedOut = Atomic<Int>(0)
    let exited = Atomic<Int>(0)
    let produced = Atomic<UInt64>(0)
    let refusals = Atomic<UInt64>(0)
    let received = Atomic<UInt64>(0)
    let corrupt = Atomic<UInt64>(0)
    let misordered = Atomic<UInt64>(0)
}

extension RealtimeHandoffTests {
    /// Producer and consumer on dedicated `Thread`s; run under TSan with `--filter Stress`.
    struct SysExStress {
        static let messages: UInt64 = 100_000
        static let sources: UInt32 = 3
        static let maximum = 40

        static func length(_ sequence: UInt64) -> Int { Int((sequence &* 0x2545_F491_4F6C_DD1D) >> 58) % 41 }

        /// Spins until `condition` holds, the shared cancellation flag is set or 25 s pass; a timeout is counted.
        fileprivate static func spin(_ state: SysExStressState, until condition: () -> Bool) -> Bool {
            let deadline = ContinuousClock.now + .seconds(25)
            var spins = 0
            while !condition() {
                if state.cancelled.load(ordering: .acquiring) { return false }
                spins &+= 1
                if spins & 1_023 == 0, ContinuousClock.now >= deadline {
                    state.timedOut.add(1, ordering: .relaxed)
                    state.cancelled.store(true, ordering: .releasing)
                    return false
                }
            }
            return true
        }

        /// Assembles every message, resending a refused one whole until the consumer frees space.
        fileprivate static func produce(_ fixture: SysExFixture, _ state: SysExStressState) {
            var sequence: UInt64 = 0
            _ = spin(state) {
                guard sequence < messages else { return true }
                let source = UInt32(sequence % UInt64(sources))
                let statuses = fixture.send(Root.sysexMessage(sequence, length: length(sequence)), source: source)
                if statuses.last == .ok {
                    sequence += 1
                    state.produced.store(sequence, ordering: .relaxed)
                } else {
                    state.refusals.add(1, ordering: .relaxed)
                }
                return false
            }
        }

        /// Reads every message in order, verifying every byte twice with indexed loads (bulk compares can hide the
        /// reads from TSan) before releasing. Alternates `receive` with `tryPop` + `withMessage` + `release`.
        fileprivate static func consume(_ fixture: SysExFixture, _ state: SysExStressState) {
            var expected: UInt64 = 0
            func check(_ ref: SysExMessageRef, _ bytes: UnsafeRawBufferPointer) {
                let wanted = Root.sysexMessage(expected, length: length(expected))
                if ref.source != UInt32(expected % UInt64(sources)) || bytes.count != wanted.count {
                    state.misordered.add(1, ordering: .relaxed)
                }
                for _ in 0..<2 {
                    var index = 0
                    while index < min(bytes.count, wanted.count), bytes[index] == wanted[index] { index += 1 }
                    if index != wanted.count { state.corrupt.add(1, ordering: .relaxed) }
                }
                expected += 1
            }
            _ = spin(state) {
                guard expected < messages else { return true }
                if expected % 2 == 0 {
                    _ = fixture.assembler.receive(check)
                } else if let ref = fixture.ring.tryPop() {
                    if fixture.assembler.withMessage(ref, { check(ref, $0) }) == nil
                        || fixture.assembler.release(ref) != .ok {
                        state.misordered.add(1, ordering: .relaxed)
                        expected += 1
                    }
                }
                state.received.store(expected, ordering: .relaxed)
                return false
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func stressConsumerAcknowledgedPoolNeverCorrupts() throws {
            // A 128-byte pool holds at most a few messages, so the producer laps it thousands of times.
            let fixture = try SysExFixture(sources: Int(Self.sources), maximum: Self.maximum, pool: 128,
                                           ringCapacity: 8)
            let state = SysExStressState()
            let workers: [@Sendable () -> Void] = [{ Self.produce(fixture, state) }, { Self.consume(fixture, state) }]
            for work in workers {
                Thread {
                    state.arrived.add(1, ordering: .releasing)
                    if Self.spin(state, until: { state.started.load(ordering: .acquiring) }) { work() }
                    state.exited.add(1, ordering: .releasing)
                }.start()
            }
            // Arrival barrier: release the start flag only once both workers are spinning on it.
            let arrivalDeadline = ContinuousClock.now + .seconds(25)
            while state.arrived.load(ordering: .acquiring) < workers.count, ContinuousClock.now < arrivalDeadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            state.started.store(true, ordering: .releasing)
            let exitDeadline = ContinuousClock.now + .seconds(50)
            while state.exited.load(ordering: .acquiring) < workers.count, ContinuousClock.now < exitDeadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard state.exited.load(ordering: .acquiring) == workers.count else {
                state.cancelled.store(true, ordering: .releasing)
                Issue.record("stress workers did not exit; post-run checks skipped")
                return
            }
            if state.timedOut.load(ordering: .relaxed) > 0 { Issue.record("a bounded stress wait timed out") }
            let refusals = state.refusals.load(ordering: .relaxed)
            print("SysExStress refusals while the pool or ring was full: \(refusals)")
            #expect(state.corrupt.load(ordering: .relaxed) == 0 && state.misordered.load(ordering: .relaxed) == 0)
            #expect(state.produced.load(ordering: .relaxed) == Self.messages
                    && state.received.load(ordering: .relaxed) == Self.messages)
            #expect(fixture.assembler.emittedCount == Self.messages)
            #expect(fixture.assembler.discardedCount == refusals)
            #expect(fixture.assembler.receive { _, _ in } == .empty)
        }
    }
}
