import Foundation
import Synchronization
import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests

/// Shared counters for the `Thread`-based stress tests.
private final class StressState: Sendable {
    let started = Atomic<Bool>(false)
    let readyAcknowledgers = Atomic<Int>(0)
    /// Raisers that finished their first batch (handshake); see `raiseWhileAcknowledging`.
    let signalled = Atomic<Int>(0)
    /// Bounded waits that gave up; any is a test failure.
    let timedOut = Atomic<Int>(0)
    let finishedRaisers = Atomic<Int>(0)
    let exited = Atomic<Int>(0)
    let overlapping = Atomic<Int>(0)
    let reported = Atomic<UInt64>(0)
    let mispaired = Atomic<Int>(0)
    let empty = Atomic<Int>(0)
    let refused = Atomic<Int>(0)
    /// First frames of every acknowledged or pending record; frames are unique per raise, so a repeat means one
    /// generation's first raise was reported twice.
    let frames = Mutex<[Int64]>([])
}

extension RealtimeHandoffTests {
    struct FaultLatching {
        /// Neighbouring and extreme scopes, so a packing or lookup slip lands on a prepared neighbour.
        static let scopes: [FaultScope] = [
            .init(handoff: 0, target: 0), .init(handoff: 0, target: 1), .init(handoff: 1, target: 0),
            .init(handoff: 1, target: 1), .init(handoff: 7, target: 3), .init(handoff: .max, target: .max)
        ]
        static let scope = FaultScope(handoff: 1, target: 0)
        static let lastGeneration = FaultLatch.generationMask

        static func preparationError(_ scopes: [FaultScope]) -> FaultLatch.PreparationError? {
            do {
                _ = try FaultLatch(scopes: scopes)
                return nil
            } catch {
                return error
            }
        }

        static func pendingRecords(_ latch: FaultLatch) -> [FaultRecord] {
            var records: [FaultRecord] = []
            let visited = latch.pending { records.append($0) }
            #expect(visited == records.count)
            return records
        }

        /// `first` is never more than one generation behind `tally` (modulo 2^24).
        static func expectInvariant(_ latch: FaultLatch, _ scopes: [FaultScope] = scopes) {
            for scope in scopes {
                guard let state = latch.stateForTesting(scope) else {
                    Issue.record("unprepared scope \(scope)")
                    continue
                }
                let behind = (state.generation &+ FaultLatch.generationMask) & FaultLatch.generationMask
                #expect(state.claimGeneration == state.generation || state.claimGeneration == behind)
            }
        }

        static func seed(_ latch: FaultLatch, generation: UInt64, count: UInt64, claim: UInt64,
                         kind: FaultKind = .noPlan, frame: Int64 = 0) {
            let state = FaultLatch.TestState(generation: generation, count: count, claimGeneration: claim)
            #expect(latch.seedForTesting(scope, state, kind: kind, frame: frame))
        }

        @Test func raiseIsVisibleUntilAcknowledged() throws {
            for kind in FaultKind.allCases {
                for frame in Root.adversarialFrames {
                    let latch = try FaultLatch(scopes: Self.scopes)
                    #expect(!latch.isLatched(Self.scope))
                    #expect(Self.pendingRecords(latch).isEmpty)
                    #expect(latch.raise(Self.scope, kind, frame: frame) == .ok)
                    let expected = FaultRecord(scope: Self.scope, kind: kind, count: 1, firstFrame: frame)
                    // Reading never clears: repeated render and control reads keep seeing the same record.
                    for _ in 0..<3 {
                        #expect(latch.isLatched(Self.scope))
                        #expect(Self.pendingRecords(latch) == [expected])
                    }
                    Self.expectInvariant(latch)
                    #expect(latch.acknowledge(Self.scope) == expected)
                    #expect(!latch.isLatched(Self.scope))
                    #expect(Self.pendingRecords(latch).isEmpty)
                    Self.expectInvariant(latch)
                }
            }
        }

        @Test func countSaturatesAndFirstFrameIsSticky() throws {
            for first in Root.adversarialFrames {
                for kind in FaultKind.allCases {
                    let latch = try FaultLatch(scopes: Self.scopes)
                    #expect(latch.raise(Self.scope, kind, frame: first) == .ok)
                    var count: UInt64 = 1
                    for later in Root.adversarialFrames where later != first {
                        for other in FaultKind.allCases where other != kind {
                            #expect(latch.raise(Self.scope, other, frame: later) == .ok)
                            count += 1
                        }
                    }
                    let expected = FaultRecord(scope: Self.scope, kind: kind, count: count, firstFrame: first)
                    #expect(Self.pendingRecords(latch) == [expected])
                    #expect(latch.acknowledge(Self.scope) == expected)
                }
            }
            let cap = FaultLatch.countCap
            #expect(cap == 1 << 39)
            let latch = try FaultLatch(scopes: Self.scopes)
            Self.seed(latch, generation: 9, count: cap - 1, claim: 9, kind: .staleClock, frame: .min)
            let saturated = FaultRecord(scope: Self.scope, kind: .staleClock, count: cap, firstFrame: .min)
            for frame in Root.adversarialFrames {
                #expect(latch.raise(Self.scope, .noPlan, frame: frame) == .ok)
                #expect(latch.stateForTesting(Self.scope) == .init(generation: 9, count: cap, claimGeneration: 9))
                #expect(Self.pendingRecords(latch) == [saturated])
                #expect(latch.isLatched(Self.scope))
            }
            // Concurrent overshoot past the cap is clamped on read and never reaches the generation bits.
            Self.seed(latch, generation: 9, count: cap + 5, claim: 9, kind: .staleClock, frame: .min)
            #expect(latch.raise(Self.scope, .noPlan, frame: 0) == .ok)
            #expect(latch.stateForTesting(Self.scope) == .init(generation: 9, count: cap + 5, claimGeneration: 9))
            #expect(Self.pendingRecords(latch) == [saturated])
            #expect(latch.acknowledge(Self.scope) == saturated)
            #expect(latch.raise(Self.scope, .noPlan, frame: .max) == .ok)
            #expect(latch.acknowledge(Self.scope)
                    == FaultRecord(scope: Self.scope, kind: .noPlan, count: 1, firstFrame: .max))
        }

        @Test func unknownScopeIsCountedNotDropped() throws {
            let latch = try FaultLatch(scopes: Self.scopes)
            let unknown: [FaultScope] = [.init(handoff: 0, target: 2), .init(handoff: 2, target: 0),
                                         .init(handoff: .max, target: 0), .init(handoff: 0, target: .max),
                                         .init(handoff: 7, target: 4), .init(handoff: 6, target: 3)]
            var expected: UInt64 = 0
            for scope in unknown {
                for kind in FaultKind.allCases {
                    #expect(latch.raise(scope, kind, frame: 0) == .refused(.slotOutOfRange))
                    expected += 1
                    #expect(latch.unknownScopeFaults == expected)
                }
                #expect(!latch.isLatched(scope))
                #expect(latch.acknowledge(scope) == nil)
            }
            for scope in Self.scopes {
                #expect(!latch.isLatched(scope))
            }
            #expect(Self.pendingRecords(latch).isEmpty)
            let cap = FaultLatch.unknownCap
            for seeded in [cap - 1, cap, cap + 7, .max - 1, .max] {
                latch.seedUnknownScopeFaultsForTesting(seeded)
                for _ in 0..<3 {
                    #expect(latch.raise(unknown[0], .noPlan, frame: 0) == .refused(.slotOutOfRange))
                    #expect(latch.unknownScopeFaults == cap)
                }
            }
        }

        @Test func acknowledgeReturnsRecordAndRearmsOnce() throws {
            let latch = try FaultLatch(scopes: Self.scopes)
            #expect(latch.acknowledge(Self.scope) == nil)
            var generation = 0
            for kind in FaultKind.allCases {
                for frame in Root.adversarialFrames {
                    generation += 1
                    for _ in 0..<generation {
                        #expect(latch.raise(Self.scope, kind, frame: frame) == .ok)
                    }
                    let record = FaultRecord(scope: Self.scope, kind: kind, count: UInt64(generation),
                                             firstFrame: frame)
                    #expect(latch.acknowledge(Self.scope) == record)
                    #expect(latch.acknowledge(Self.scope) == nil)
                    #expect(!latch.isLatched(Self.scope))
                    #expect(Self.pendingRecords(latch).isEmpty)
                    Self.expectInvariant(latch)
                }
            }
        }

        @Test func generationWrapStillLatches() throws {
            let latch = try FaultLatch(scopes: Self.scopes)
            Self.seed(latch, generation: Self.lastGeneration, count: 0, claim: Self.lastGeneration - 1)
            Self.expectInvariant(latch)
            for (round, kind) in [FaultKind.sysexAborted, .retireBacklog, .staleClock].enumerated() {
                #expect(!latch.isLatched(Self.scope))
                #expect(latch.raise(Self.scope, kind, frame: Int64(round)) == .ok)
                #expect(latch.isLatched(Self.scope))
                let record = FaultRecord(scope: Self.scope, kind: kind, count: 1, firstFrame: Int64(round))
                #expect(Self.pendingRecords(latch) == [record])
                #expect(latch.acknowledge(Self.scope) == record)
                #expect(latch.stateForTesting(Self.scope)?.generation == UInt64(round))
                Self.expectInvariant(latch)
            }
        }

        @Test func unpublishedClaimIsSkippedNotMisread() throws {
            let latch = try FaultLatch(scopes: Self.scopes)
            // A fresh scope's claim is one generation behind, so a mid-publish first raise is never misread.
            for scope in Self.scopes {
                #expect(latch.stateForTesting(scope) == .init(generation: 0, count: 0,
                                                              claimGeneration: Self.lastGeneration))
            }
            // Count > 0 while `first` still holds the previous generation: the first raiser is mid-publish.
            for generation in [UInt64(0), 5, Self.lastGeneration] {
                let previous = (generation &+ Self.lastGeneration) & Self.lastGeneration
                Self.seed(latch, generation: generation, count: 3, claim: previous, kind: .sysexOverflow, frame: 7)
                #expect(latch.isLatched(Self.scope))
                #expect(Self.pendingRecords(latch).isEmpty)
                #expect(latch.acknowledge(Self.scope) == nil)
                #expect(latch.stateForTesting(Self.scope)
                        == .init(generation: generation, count: 3, claimGeneration: previous))
                Self.seed(latch, generation: generation, count: 3, claim: generation, kind: .noPlan, frame: 99)
                let record = FaultRecord(scope: Self.scope, kind: .noPlan, count: 3, firstFrame: 99)
                #expect(Self.pendingRecords(latch) == [record])
                #expect(latch.acknowledge(Self.scope) == record)
                #expect(!latch.isLatched(Self.scope))
            }
        }

        @Test func scopesAreIsolated() throws {
            for raised in Self.scopes {
                let latch = try FaultLatch(scopes: Self.scopes)
                #expect(latch.raise(raised, .sysexOverflow, frame: 42) == .ok)
                for scope in Self.scopes {
                    #expect(latch.isLatched(scope) == (scope == raised))
                }
                let record = FaultRecord(scope: raised, kind: .sysexOverflow, count: 1, firstFrame: 42)
                #expect(Self.pendingRecords(latch) == [record])
                for scope in Self.scopes where scope != raised {
                    #expect(latch.acknowledge(scope) == nil)
                }
                #expect(latch.isLatched(raised))
                #expect(latch.acknowledge(raised) == record)
            }
            // Every scope latched at once still reports each record against its own scope.
            let latch = try FaultLatch(scopes: Self.scopes.reversed())
            for (offset, scope) in Self.scopes.enumerated() {
                for _ in 0...offset {
                    #expect(latch.raise(scope, .retireBacklog, frame: Int64(offset)) == .ok)
                }
            }
            let records = Self.pendingRecords(latch)
            #expect(records.count == Self.scopes.count)
            for (offset, scope) in Self.scopes.enumerated() {
                let record = FaultRecord(scope: scope, kind: .retireBacklog, count: UInt64(offset + 1),
                                         firstFrame: Int64(offset))
                #expect(records.filter { $0.scope == scope } == [record])
            }
        }

        @Test func initRejectsEmptyDuplicateAndOversizedScopeTables() {
            #expect(FaultLatch.maximumScopes == 4_096)
            #expect(Self.preparationError([]) == .emptyScopeTable)
            #expect(Self.preparationError(Self.scopes) == nil)
            for duplicate in Self.scopes {
                #expect(Self.preparationError(Self.scopes + [duplicate]) == .duplicateScope(duplicate))
                #expect(Self.preparationError([duplicate, duplicate]) == .duplicateScope(duplicate))
            }
            let full = (0..<FaultLatch.maximumScopes).map {
                FaultScope(handoff: UInt16($0 / 256), target: UInt32($0 % 256))
            }
            #expect(Self.preparationError(full) == nil)
            #expect(Self.preparationError(full + [.init(handoff: .max, target: .max)]) == .tooManyScopes(4_097))
            #expect(Self.preparationError(full + [full[0]]) == .tooManyScopes(4_097))
        }

        @Test func valuesAreBitwiseCopyable() {
            Root.requireBitwise(FaultKind.self)
            Root.requireBitwise(FaultScope.self)
            Root.requireBitwise(FaultRecord.self)
            #expect(FaultKind.allCases.count == 8)
        }
    }

    /// Concurrency stress on dedicated `Thread`s; run under TSan with `--filter Stress`.
    struct FaultLatchingStress {
        static let raisers = 8
        static let raisesPerThread = 10_000
        static var total: UInt64 { UInt64(raisers * raisesPerThread) }
        /// Raises each raiser makes before the acknowledge handshake.
        static let firstBatch = 1_000

        /// Every raise uses `kind = frame % 8`, so a record pairing one raise's kind with another's frame shows.
        static func kind(for frame: Int64) -> FaultKind {
            FaultKind(rawValue: UInt8(truncatingIfNeeded: frame % 8)) ?? .noPlan
        }

        static func isPaired(_ record: FaultRecord) -> Bool {
            record.firstFrame >= 0 && record.kind == kind(for: record.firstFrame)
        }

        /// Raises `raisesPerThread` times from one thread after the start barrier.
        /// Raises `raisesPerThread` times from one thread after the start barrier. With `handshake`, it signals
        /// after `firstBatch` raises and holds until an acknowledge has overlapped (see `raiseWhileAcknowledging`).
        fileprivate static func raise(_ latch: FaultLatch, _ scopes: [FaultScope], thread: Int,
                                      _ state: StressState, handshake: Bool = false) {
            spin(state) { state.started.load(ordering: .acquiring) }
            for raise in 0..<raisesPerThread {
                if handshake, raise == firstBatch {
                    state.signalled.add(1, ordering: .releasing)
                    spin(state) { state.overlapping.load(ordering: .acquiring) >= 1 }
                }
                let frame = Int64(thread * raisesPerThread + raise)
                if latch.raise(scopes[(thread + raise) % scopes.count], kind(for: frame), frame: frame) != .ok {
                    state.refused.add(1, ordering: .relaxed)
                }
            }
            state.finishedRaisers.add(1, ordering: .releasing)
        }

        /// Spins until `condition` holds, for at most 25 s; a timeout is counted in `timedOut` and fails the test.
        fileprivate static func spin(_ state: StressState, until condition: () -> Bool) {
            let deadline = ContinuousClock.now + .seconds(25)
            while !condition() {
                if ContinuousClock.now >= deadline {
                    state.timedOut.add(1, ordering: .relaxed)
                    return
                }
            }
        }

        /// Starts `threads` threads running `body` and waits (bounded) until all have exited.
        fileprivate static func run(threads: Int, _ state: StressState,
                                    _ body: @escaping @Sendable (Int) -> Void) {
            for index in 0..<threads {
                Thread {
                    body(index)
                    state.exited.add(1, ordering: .releasing)
                }.start()
            }
            let deadline = ContinuousClock.now + .seconds(50)
            while state.exited.load(ordering: .acquiring) < threads, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            #expect(state.exited.load(ordering: .acquiring) == threads)
        }

        @Test(.timeLimit(.minutes(1))) func concurrentRaisesConserveCount() throws {
            let scopes = (0..<4).map { FaultScope(handoff: 2, target: UInt32($0)) }
            let latch = try FaultLatch(scopes: scopes)
            let state = StressState()
            state.started.store(true, ordering: .releasing)
            Self.run(threads: Self.raisers, state) { Self.raise(latch, scopes, thread: $0, state) }
            #expect(state.timedOut.load(ordering: .relaxed) == 0)
            #expect(state.refused.load(ordering: .relaxed) == 0)
            var counts: [FaultScope: UInt64] = [:]
            var mispaired = 0
            let visited = latch.pending { record in
                counts[record.scope, default: 0] += record.count
                if !Self.isPaired(record) { mispaired += 1 }
            }
            #expect(visited == scopes.count)
            #expect(mispaired == 0)
            for scope in scopes {
                #expect(counts[scope] == Self.total / UInt64(scopes.count))
            }
            FaultLatching.expectInvariant(latch, scopes)
        }

        @Test(.timeLimit(.minutes(1))) func raiseConcurrentWithAcknowledgeIsNeverLost() throws {
            let scopes = [FaultScope(handoff: 3, target: 0), FaultScope(handoff: 3, target: 1)]
            try Self.raiseWhileAcknowledging(scopes, acknowledgers: 1)
        }

        /// Two control threads race to acknowledge one scope: the loser must return `nil`, not reset the next
        /// generation's count and report it under the previous generation's first raise.
        @Test(.timeLimit(.minutes(1))) func twoAcknowledgersNeverDuplicateOrLose() throws {
            try Self.raiseWhileAcknowledging([FaultScope(handoff: 4, target: 0)], acknowledgers: 2)
        }

        /// Checks one acknowledged or pending record and adds it to the reported total.
        fileprivate static func note(_ record: FaultRecord, _ state: StressState) {
            state.reported.add(record.count, ordering: .relaxed)
            if !isPaired(record) { state.mispaired.add(1, ordering: .relaxed) }
            if record.count == 0 { state.empty.add(1, ordering: .relaxed) }
            state.frames.withLock { $0.append(record.firstFrame) }
        }

        /// `raisers` raising threads plus `acknowledgers` acknowledging threads; the last acknowledger to start
        /// opens the barrier. Asserts overlap, conservation, pairing and that no first raise is reported twice.
        ///
        /// Handshake, so `overlapping >= 1` holds on every schedule: each raiser does `firstBatch` raises, signals
        /// (release) and holds; acknowledgers start only once all have signalled (acquire), so those raises happen
        /// before their first acknowledge and, with the raisers held, the first acknowledge of a raised scope
        /// returns a record while no raiser has finished. It then bumps `overlapping` (release), which releases the
        /// raisers (acquire). With two acknowledgers either one's record is enough: the other may lose the race
        /// for that generation and see nothing more until the raisers resume.
        static func raiseWhileAcknowledging(_ scopes: [FaultScope], acknowledgers: Int) throws {
            let latch = try FaultLatch(scopes: scopes)
            let state = StressState()
            Self.run(threads: Self.raisers + acknowledgers, state) { thread in
                guard thread >= Self.raisers else {
                    return Self.raise(latch, scopes, thread: thread, state, handshake: true)
                }
                if state.readyAcknowledgers.add(1, ordering: .acquiringAndReleasing).newValue == acknowledgers {
                    state.started.store(true, ordering: .releasing)
                }
                Self.spin(state) { state.signalled.load(ordering: .acquiring) == Self.raisers }
                while state.finishedRaisers.load(ordering: .acquiring) < Self.raisers {
                    for scope in scopes {
                        guard let record = latch.acknowledge(scope) else { continue }
                        Self.note(record, state)
                        if state.finishedRaisers.load(ordering: .acquiring) < Self.raisers {
                            state.overlapping.add(1, ordering: .releasing)
                        }
                    }
                }
            }
            _ = latch.pending { Self.note($0, state) }
            let overlapping = state.overlapping.load(ordering: .relaxed)
            print("FaultLatchingStress \(acknowledgers) acknowledger(s), overlapping acknowledges: \(overlapping)")
            if state.timedOut.load(ordering: .relaxed) > 0 { Issue.record("a bounded stress wait timed out") }
            #expect(overlapping >= 1)
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
