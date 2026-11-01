import Testing
@testable import FluxKlang

private typealias Root = RealtimeHandoffTests

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
            do { _ = try FaultLatch(scopes: scopes) } catch { return error }
            return nil
        }

        static func pendingRecords(_ latch: FaultLatch) -> [FaultRecord] {
            var records: [FaultRecord] = []
            let visited = latch.pending { records.append($0) }
            #expect(visited == records.count)
            return records
        }

        /// `first` is never more than one generation behind `tally` (modulo 2^24).
        static func expectInvariant(_ latch: FaultLatch, _ scopes: [FaultScope] = scopes) {
            let states = scopes.compactMap(latch.stateForTesting)
            #expect(states.count == scopes.count)
            for state in states {
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
            #expect(Self.scopes.allSatisfy { !latch.isLatched($0) })
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

        @Test func commitAfterARaiseKeepsTheRaise() throws {
            for kind in FaultKind.allCases {
                for frame in Root.adversarialFrames {
                    let latch = try FaultLatch(scopes: Self.scopes)
                    #expect(latch.raise(Self.scope, kind, frame: frame) == .ok)
                    let snapshot = try #require(latch.snapshotForTesting(Self.scope))
                    // A raise lands between the snapshot and the compare-exchange: the commit retries and keeps it.
                    #expect(latch.raise(Self.scope, .noPlan, frame: 1) == .ok)
                    let record = FaultRecord(scope: Self.scope, kind: kind, count: 2, firstFrame: frame)
                    #expect(latch.commitForTesting(snapshot) == record)
                    #expect(!latch.isLatched(Self.scope))
                    #expect(latch.acknowledge(Self.scope) == nil)
                    Self.expectInvariant(latch)
                }
            }
        }

        /// Two snapshots of one generation (only possible through the seam; `acknowledge` holds the control lock):
        /// the second commit returns `nil` and leaves the next generation, including across the wrap, untouched.
        @Test func staleCommitLeavesTheNextGenerationAlone() throws {
            let latch = try FaultLatch(scopes: Self.scopes)
            for generation in [UInt64(0), 5, Self.lastGeneration] {
                let next = (generation &+ 1) & Self.lastGeneration
                Self.seed(latch, generation: generation, count: 2, claim: generation, kind: .noPlan, frame: 7)
                let snapshots = (0..<3).compactMap { _ in latch.snapshotForTesting(Self.scope) }
                try #require(snapshots.count == 3)
                let record = FaultRecord(scope: Self.scope, kind: .noPlan, count: 2, firstFrame: 7)
                #expect(latch.commitForTesting(snapshots[0]) == record)
                #expect(latch.commitForTesting(snapshots[1]) == nil)
                #expect(latch.stateForTesting(Self.scope)
                        == .init(generation: next, count: 0, claimGeneration: generation))
                #expect(latch.raise(Self.scope, .staleClock, frame: 8) == .ok)
                #expect(latch.commitForTesting(snapshots[2]) == nil)
                #expect(latch.stateForTesting(Self.scope) == .init(generation: next, count: 1, claimGeneration: next))
                #expect(latch.acknowledge(Self.scope)
                        == FaultRecord(scope: Self.scope, kind: .staleClock, count: 1, firstFrame: 8))
            }
        }

        @Test func valuesAreBitwiseCopyable() {
            Root.requireBitwise(FaultKind.self)
            Root.requireBitwise(FaultScope.self)
            Root.requireBitwise(FaultRecord.self)
            #expect(FaultKind.allCases.count == 8)
        }
    }
}
