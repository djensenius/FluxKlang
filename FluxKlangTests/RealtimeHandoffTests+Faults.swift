import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

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
                         kind: FaultKind = .noPlan, frame: Int64 = 0, scope: FaultScope = scope) {
            let state = FaultLatch.TestState(generation: generation, count: count, claimGeneration: claim)
            #expect(latch.seedForTesting(scope, state, kind: kind, frame: frame))
        }

        /// Observe, (recover), acknowledge: the caller protocol with nothing raised in between.
        static func acknowledge(_ latch: FaultLatch, _ scope: FaultScope) -> FaultRecord? {
            latch.observe(scope).flatMap(latch.acknowledge)
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
                    #expect(Self.acknowledge(latch, Self.scope) == expected)
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
                    #expect(Self.acknowledge(latch, Self.scope) == expected)
                }
            }
            let cap = FaultLatch.countCap
            #expect(cap == 1 << 39)
            #expect(FaultLatch.countBits == 40 && FaultLatch.countMask == (1 << 40) - 1)
            #expect(FaultLatch.generationMask == (1 << 24) - 1 && FaultLatch.unknownCap == .max / 2)
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
            // A saturated scope fails closed (see `saturatedOrExhaustedObservationsFailClosed`).
            #expect(latch.observe(Self.scope)?.record == saturated)
            #expect(Self.acknowledge(latch, Self.scope) == nil)
            #expect(latch.isLatched(Self.scope))
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
                #expect(Self.acknowledge(latch, scope) == nil)
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
            #expect(Self.acknowledge(latch, Self.scope) == nil)
            var generation = 0
            for kind in FaultKind.allCases {
                for frame in Root.adversarialFrames {
                    generation += 1
                    for _ in 0..<generation {
                        #expect(latch.raise(Self.scope, kind, frame: frame) == .ok)
                    }
                    let record = FaultRecord(scope: Self.scope, kind: kind, count: UInt64(generation),
                                             firstFrame: frame)
                    #expect(Self.acknowledge(latch, Self.scope) == record)
                    #expect(Self.acknowledge(latch, Self.scope) == nil)
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
                #expect(Self.acknowledge(latch, Self.scope) == record)
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
                #expect(Self.acknowledge(latch, Self.scope) == nil)
                #expect(latch.stateForTesting(Self.scope)
                        == .init(generation: generation, count: 3, claimGeneration: previous))
                Self.seed(latch, generation: generation, count: 3, claim: generation, kind: .noPlan, frame: 99)
                let record = FaultRecord(scope: Self.scope, kind: .noPlan, count: 3, firstFrame: 99)
                #expect(Self.pendingRecords(latch) == [record])
                #expect(Self.acknowledge(latch, Self.scope) == record)
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
                    #expect(Self.acknowledge(latch, scope) == nil)
                }
                #expect(latch.isLatched(raised))
                #expect(Self.acknowledge(latch, raised) == record)
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

        /// A raise after the observation (that is, during recovery) refuses the acknowledge and stays latched, so
        /// the caller must re-observe and recover again; the stale observation never succeeds later.
        @Test func raiseAfterObservationRefusesTheAcknowledge() throws {
            for kind in FaultKind.allCases {
                for frame in Root.adversarialFrames {
                    let latch = try FaultLatch(scopes: Self.scopes)
                    #expect(latch.raise(Self.scope, kind, frame: frame) == .ok)
                    let stale = try #require(latch.observe(Self.scope))
                    #expect(stale.isAcknowledgeable)
                    #expect(stale.record == FaultRecord(scope: Self.scope, kind: kind, count: 1, firstFrame: frame))
                    #expect(latch.raise(Self.scope, .noPlan, frame: 1) == .ok)
                    #expect(latch.acknowledge(stale) == nil)
                    #expect(latch.isLatched(Self.scope))
                    #expect(latch.stateForTesting(Self.scope) == .init(generation: 0, count: 2, claimGeneration: 0))
                    let fresh = try #require(latch.observe(Self.scope))
                    let record = FaultRecord(scope: Self.scope, kind: kind, count: 2, firstFrame: frame)
                    #expect(fresh.record == record)
                    #expect(latch.acknowledge(fresh) == record)
                    #expect(latch.acknowledge(fresh) == nil)
                    #expect(latch.acknowledge(stale) == nil)
                    #expect(!latch.isLatched(Self.scope))
                    Self.expectInvariant(latch)
                }
            }
        }

        /// Two observations of one generation: the second is stale once the first is acknowledged, including when
        /// the packed generation later wraps back to exactly the tally and claim it saw (seeded: 2^24 real
        /// acknowledges are too slow for a unit test); the per-scope epoch refuses it.
        @Test func staleObservationCannotClearALaterGenerationAcrossWrap() throws {
            let latch = try FaultLatch(scopes: Self.scopes)
            for generation in [UInt64(0), 5, Self.lastGeneration] {
                let next = (generation &+ 1) & Self.lastGeneration
                Self.seed(latch, generation: generation, count: 2, claim: generation, kind: .noPlan, frame: 7)
                let first = try #require(latch.observe(Self.scope))
                let second = try #require(latch.observe(Self.scope))
                let record = FaultRecord(scope: Self.scope, kind: .noPlan, count: 2, firstFrame: 7)
                #expect(second.record == record)
                #expect(latch.acknowledge(first) == record)
                #expect(latch.acknowledge(second) == nil)
                #expect(latch.stateForTesting(Self.scope)
                        == .init(generation: next, count: 0, claimGeneration: generation))
                #expect(latch.raise(Self.scope, .staleClock, frame: 8) == .ok)
                #expect(latch.acknowledge(second) == nil)
                #expect(latch.stateForTesting(Self.scope) == .init(generation: next, count: 1, claimGeneration: next))
                // The generation wraps back to the stale observation's exact tally and claim.
                Self.seed(latch, generation: generation, count: 2, claim: generation, kind: .noPlan, frame: 7)
                #expect(latch.acknowledge(second) == nil)
                #expect(latch.acknowledge(first) == nil)
                #expect(latch.stateForTesting(Self.scope)
                        == .init(generation: generation, count: 2, claimGeneration: generation))
                #expect(Self.acknowledge(latch, Self.scope) == record)
            }
        }

        /// A refused acknowledge makes one compare-exchange attempt, leaves its scope latched and does not block
        /// other scopes.
        @Test func failedAcknowledgeTriesOnceAndOtherScopesProgress() throws {
            let latch = try FaultLatch(scopes: Self.scopes)
            let other = FaultScope(handoff: 7, target: 3)
            #expect(latch.raise(Self.scope, .noPlan, frame: 1) == .ok)
            #expect(latch.raise(other, .sysexAborted, frame: 2) == .ok)
            let refused = try #require(latch.observe(Self.scope))
            let accepted = try #require(latch.observe(other))
            #expect(latch.raise(Self.scope, .staleClock, frame: 3) == .ok)
            #expect(latch.acknowledge(refused) == nil)
            #expect(latch.stateForTesting(Self.scope) == .init(generation: 0, count: 2, claimGeneration: 0))
            #expect(latch.acknowledge(accepted) == FaultRecord(scope: other, kind: .sysexAborted, count: 1,
                                                               firstFrame: 2))
            #expect(!latch.isLatched(other))
            #expect(latch.isLatched(Self.scope))
            #expect(Self.acknowledge(latch, Self.scope)
                    == FaultRecord(scope: Self.scope, kind: .noPlan, count: 2, firstFrame: 1))
        }

        /// An observation is bound to the latch that made it, even when another latch holds an identical scope
        /// state or fewer scopes than the observation's index.
        @Test func foreignObservationIsRefused() throws {
            let owner = try FaultLatch(scopes: Self.scopes)
            let twin = try FaultLatch(scopes: Self.scopes)
            let small = try FaultLatch(scopes: [Self.scope])
            let last = FaultScope(handoff: .max, target: .max)
            for latch in [owner, twin, small] {
                #expect(latch.raise(Self.scope, .noPlan, frame: 5) == .ok)
            }
            #expect(owner.raise(last, .noPlan, frame: 5) == .ok)
            let observation = try #require(owner.observe(Self.scope))
            let lastObservation = try #require(owner.observe(last))
            for foreign in [twin, small] {
                #expect(foreign.acknowledge(observation) == nil)
                #expect(foreign.acknowledge(lastObservation) == nil)
                #expect(foreign.stateForTesting(Self.scope) == .init(generation: 0, count: 1, claimGeneration: 0))
            }
            let record = FaultRecord(scope: Self.scope, kind: .noPlan, count: 1, firstFrame: 5)
            #expect(owner.acknowledge(observation) == record)
            #expect(owner.acknowledge(lastObservation) == FaultRecord(scope: last, kind: .noPlan, count: 1,
                                                                      firstFrame: 5))
            #expect(Self.acknowledge(twin, Self.scope) == record)
        }

        /// A saturated count cannot prove that no raise was dropped since the observation, and an exhausted epoch
        /// cannot step without wrapping: both fail closed, latched until the latch is replaced while quiescent.
        @Test func saturatedOrExhaustedObservationsFailClosed() throws {
            let latch = try FaultLatch(scopes: Self.scopes)
            for count in [FaultLatch.countCap, FaultLatch.countCap + 5] {
                Self.seed(latch, generation: 3, count: count, claim: 3, kind: .staleClock, frame: .min)
                let observation = try #require(latch.observe(Self.scope))
                #expect(!observation.isAcknowledgeable)
                #expect(observation.record.count == FaultLatch.countCap)
                #expect(latch.acknowledge(observation) == nil)
                #expect(latch.raise(Self.scope, .noPlan, frame: 0) == .ok)
                #expect(latch.stateForTesting(Self.scope) == .init(generation: 3, count: count, claimGeneration: 3))
            }
            Self.seed(latch, generation: 3, count: FaultLatch.countCap - 1, claim: 3)
            let belowCap = try #require(latch.observe(Self.scope))
            #expect(belowCap.isAcknowledgeable)
            for limit in [UInt64(0), 1, 2] {
                let limited = try FaultLatch(scopes: Self.scopes, epochLimit: limit)
                for cycle in 0...limit {
                    #expect(limited.raise(Self.scope, .noPlan, frame: Int64(cycle)) == .ok)
                    let observation = try #require(limited.observe(Self.scope))
                    #expect(observation.isAcknowledgeable == (cycle < limit))
                    let record = FaultRecord(scope: Self.scope, kind: .noPlan, count: 1, firstFrame: Int64(cycle))
                    #expect(limited.acknowledge(observation) == (cycle < limit ? record : nil))
                }
                for _ in 0..<3 {
                    #expect(Self.acknowledge(limited, Self.scope) == nil)
                    #expect(limited.isLatched(Self.scope))
                }
                #expect(limited.stateForTesting(Self.scope)?.generation == limit)
                #expect(Self.acknowledge(limited, FaultScope(handoff: 0, target: 0)) == nil)
                #expect(limited.raise(FaultScope(handoff: 0, target: 0), .noPlan, frame: 1) == .ok)
                let otherRecord = Self.acknowledge(limited, FaultScope(handoff: 0, target: 0))
                #expect((otherRecord != nil) == (limit > 0))
            }
        }

        /// `kind` is only the first kind raised: an observation's count covers every kind raised before it, so
        /// recovery must cover the whole scope, not just `kind`.
        @Test func observationCoversEveryKindRaised() throws {
            let latch = try FaultLatch(scopes: Self.scopes)
            for (frame, kind) in FaultKind.allCases.reversed().enumerated() {
                #expect(latch.raise(Self.scope, kind, frame: Int64(frame)) == .ok)
            }
            let observation = try #require(latch.observe(Self.scope))
            #expect(observation.record == FaultRecord(scope: Self.scope, kind: .staleClock, count: 8, firstFrame: 0))
            #expect(latch.acknowledge(observation) == observation.record)
        }

        /// `seedForTesting` is a quiescent test utility that steps the scope's epoch under the control lock: an
        /// observation made before a seed is refused even when the seed restores the exact tally and claim it saw
        /// (same-epoch replay), and at the epoch limit a seed is refused without changing any state.
        @Test func seedInvalidatesObservationsAndFailsClosedAtTheLimit() throws {
            let latch = try FaultLatch(scopes: Self.scopes)
            #expect(latch.raise(Self.scope, .noPlan, frame: 4) == .ok)
            let replayed = try #require(latch.observe(Self.scope))
            #expect(latch.raise(Self.scope, .staleClock, frame: 5) == .ok)
            Self.seed(latch, generation: 0, count: 1, claim: 0, kind: .noPlan, frame: 4)
            #expect(latch.observe(Self.scope)?.record == replayed.record)
            #expect(latch.acknowledge(replayed) == nil)
            #expect(latch.stateForTesting(Self.scope) == .init(generation: 0, count: 1, claimGeneration: 0))
            #expect(Self.acknowledge(latch, Self.scope) == replayed.record)
            for limit in [UInt64(0), 1] {
                let limited = try FaultLatch(scopes: Self.scopes, epochLimit: limit)
                #expect(limited.raise(Self.scope, .noPlan, frame: 4) == .ok)
                let observation = try #require(limited.observe(Self.scope))
                let seeded = FaultLatch.TestState(generation: 7, count: 2, claimGeneration: 7)
                #expect(limited.seedForTesting(Self.scope, seeded, kind: .staleClock, frame: 9) == (limit > 0))
                #expect(limited.acknowledge(observation) == nil)
                let expected: FaultLatch.TestState = limit > 0 ? seeded : .init(generation: 0, count: 1,
                                                                                 claimGeneration: 0)
                let refused = FaultLatch.TestState(generation: 3, count: 5, claimGeneration: 3)
                #expect(!limited.seedForTesting(Self.scope, refused, kind: .sysexAborted, frame: 1))
                #expect(limited.stateForTesting(Self.scope) == expected)
                let exhausted = try #require(limited.observe(Self.scope))
                #expect(!exhausted.isAcknowledgeable)
                #expect(exhausted.record.kind == (limit > 0 ? .staleClock : .noPlan))
                #expect(limited.acknowledge(exhausted) == nil)
                #expect(limited.isLatched(Self.scope))
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
