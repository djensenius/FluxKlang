import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests

extension RealtimeHandoffTests {
    /// #190 FLP4: `SysExAssembler` raises only through the one fault chain it mints, holding the token per `accept`.
    struct SysExChaining {
        static let base = SysExFixture.base
        static let probe: SysExChunkBytes = (9, 9, 9, 9, 9, 9)

        static func authority(budget: Int = 1) throws -> FaultChainAuthority {
            try FaultChainAuthority(scopes: [.init(handoff: base, target: 0)], chainBudget: budget)
        }

        /// The preparation error, or `nil` when an assembler was built (and then dropped).
        static func preparation(_ faults: FaultChainAuthority, sources: Int = 1, maximum: Int = 4, pool: Int = 8,
                                output: SPSCRing<SysExMessageRef>? = nil) throws -> SysExAssembler.PreparationError? {
            let output = try output ?? SPSCRing(policy: Root.sysexRingPolicy())
            do {
                _ = try SysExAssembler(sources: sources, maximumMessageBytes: maximum, poolBytes: pool, output: output,
                                       faults: faults, scopeBase: base)
                return nil
            } catch {
                return error
            }
        }

        /// The token is back in its slot, nothing contended, and a following `accept` on another source is normal.
        static func expectTokenReturned(_ fixture: SysExFixture, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(fixture.assembler.withChainTokenHeld {}, sourceLocation: sourceLocation)
            #expect(fixture.chunk(.start, [1], source: 1) == .ok, sourceLocation: sourceLocation)
            #expect(fixture.assembler.contendedChunkCount == 0 && !fixture.faults.hasContendedFault,
                    sourceLocation: sourceLocation)
        }

        /// T1. Kills: minting no chain, or more than one.
        @Test func initMintsExactlyOneChain() throws {
            let faults = try Self.authority(budget: 3)
            #expect(faults.mintedChains == 0)
            #expect(try Self.preparation(faults) == nil)
            #expect(faults.mintedChains == 1)
            #expect(try Self.preparation(faults) == nil)
            #expect(faults.mintedChains == 2)
        }

        /// T2. Kills: minting before the pure checks or the producer claim; no budget check.
        @Test func chainBudgetIsCheckedLast() throws {
            let faults = try Self.authority(budget: 1)
            let events = try SPSCRing<SysExMessageRef>(policy: Root.policy(consumer: .control))
            #expect(try Self.preparation(faults, output: events) == .policy(.violates(.r8SysExSeparate)))
            #expect(try Self.preparation(faults, sources: 0) == .sourcesOutOfRange(0))
            #expect(try Self.preparation(faults, pool: 96) == .poolBytesOutOfRange(96))
            #expect(try Self.preparation(faults, maximum: 5) == .maximumMessageBytesOutOfRange(5))
            let claimed = try SPSCRing<SysExMessageRef>(policy: Root.sysexRingPolicy())
            _ = claimed.makeProducer()
            #expect(try Self.preparation(faults, output: claimed) == .outputAlreadyClaimed)
            #expect(faults.mintedChains == 0)
            #expect(try Self.preparation(faults) == nil && faults.mintedChains == 1)
            let fresh = try SPSCRing<SysExMessageRef>(policy: Root.sysexRingPolicy())
            #expect(try Self.preparation(faults, output: fresh) == .chainBudgetExhausted)
            #expect(faults.mintedChains == 1)
            // Documented: the budget refusal comes after the claim, so `fresh` stays claimed.
            let freshClaimable = switch fresh.makeProducer() {
            case .some: true
            case .none: false
            }
            #expect(!freshClaimable)
            // With the budget gone, every earlier refusal still wins.
            #expect(try Self.preparation(faults, output: claimed) == .outputAlreadyClaimed)
            #expect(try Self.preparation(faults, sources: 0) == .sourcesOutOfRange(0))
        }

        /// T3. Kills: state touched before the take; a counted raise without the token; no `raiseContended`.
        @Test func contendedAcceptChangesNothingAndLatchesEveryScope() throws {
            let fixture = try SysExFixture(maximum: 6, pool: 16)
            #expect(fixture.chunk(.start, [1, 2, 3]) == .ok)
            var statuses: [KernelStatus] = []
            #expect(fixture.assembler.withChainTokenHeld { statuses.append(fixture.chunk(.end, [4])) })
            #expect(statuses == [.refused(.notOwner)])
            #expect(fixture.assembler.contendedChunkCount == 1 && fixture.faults.hasContendedFault)
            let unprepared = FaultScope(handoff: 0, target: 0)
            #expect(((0..<4).map(fixture.scope) + [unprepared]).allSatisfy(fixture.faults.isLatched))
            #expect(fixture.takeFaults().isEmpty && fixture.faults.unknownScopeFaults == 0)
            #expect(fixture.assembler.emittedCount == 0 && fixture.assembler.discardedCount == 0)
            #expect(fixture.ring.tryPop() == nil)
            // Every status on the open source 0 and the idle source 1: refused, nothing assembled or raised.
            statuses = []
            #expect(fixture.assembler.withChainTokenHeld {
                for source: UInt32 in [0, 1] {
                    for status in SysExChunkStatus.allCases {
                        statuses.append(fixture.assembler.accept(source: source, status: status, bytes: Self.probe,
                                                                 count: 6))
                    }
                }
            })
            #expect(statuses == Array(repeating: .refused(.notOwner), count: 8))
            #expect(fixture.assembler.contendedChunkCount == 9 && fixture.takeFaults().isEmpty)
            // Once released, the open message continues as if nothing had happened.
            #expect(fixture.chunk(.end, [4]) == .ok)
            #expect(fixture.drain().map(\.bytes) == [[1, 2, 3, 4]])
            #expect(fixture.chunk(.continue, [1], source: 1) == .refused(.notOwner))
            #expect(fixture.takeFaults().map(\.kind) == [.sysexAborted])
            #expect(fixture.assembler.contendedChunkCount == 9 && fixture.assembler.discardedCount == 0)
        }

        /// T4. Every return path puts the token back: the 12 state-table cells, overflow, pool full and ring full.
        /// Kills: a missing `put` on any branch.
        @Test func everyReturnPathPutsTheTokenBack() throws {
            let full: [UInt8] = [1, 2, 3, 4, 5, 6]
            let setups: [(name: String, chunks: [(SysExChunkStatus, [UInt8])])] = [
                ("idle", []), ("open", [(.start, [1])]), ("discarding", [(.start, full), (.continue, [7])])
            ]
            let expected: [String: [KernelStatus]] = [
                "idle": [.ok, .ok, .refused(.notOwner), .refused(.notOwner)],
                "open": [.ok, .ok, .ok, .ok],
                "discarding": [.ok, .ok, .refused(.invalidLength), .refused(.invalidLength)]
            ]
            for (name, chunks) in setups {
                for (status, wanted) in zip(SysExChunkStatus.allCases, expected[name] ?? []) {
                    let fixture = try SysExFixture(maximum: 6, pool: 16)
                    for (setupStatus, bytes) in chunks { _ = fixture.chunk(setupStatus, bytes) }
                    #expect(fixture.chunk(status, [9]) == wanted, "\(name) \(status)")
                    Self.expectTokenReturned(fixture)
                }
            }
            let overflow = try SysExFixture(maximum: 6, pool: 16)
            #expect(overflow.chunk(.start, [1]) == .ok)
            #expect(overflow.chunk(.continue, full) == .refused(.invalidLength))
            Self.expectTokenReturned(overflow)
            let poolFull = try SysExFixture(maximum: 6, pool: 16)
            #expect([full, full, full].map { poolFull.chunk(.complete, $0) } == [.ok, .ok, .refused(.full)])
            Self.expectTokenReturned(poolFull)
            let ringFull = try SysExFixture(maximum: 6, pool: 128, ringCapacity: 2)
            #expect((0..<3).map { _ in ringFull.chunk(.complete, []) } == [.ok, .ok, .refused(.full)])
            Self.expectTokenReturned(ringFull)
        }

        /// T5. An abort and an overflow in one call are two counted raises on the one held token. Kills: taking
        /// the token again inside the call.
        @Test func twoRaisesInOneCallAreCountedWithoutContention() throws {
            let fixture = try SysExFixture(maximum: 4, pool: 8)
            #expect(fixture.chunk(.start, [1]) == .ok)
            #expect(fixture.chunk(.start, [1, 2, 3, 4, 5, 6]) == .refused(.invalidLength))
            let records = fixture.takeFaults()
            #expect(records.map(\.scope) == [fixture.scope(0)])
            #expect(records.map(\.kind) == [.sysexAborted] && records.map(\.count) == [2])
            #expect(fixture.assembler.discardedCount == 2)
            Self.expectTokenReturned(fixture)
        }

        /// T6. Counted parity with a plain `FaultLatch` raised by hand: records, observe, acknowledge, re-arm and
        /// `unknownScopeFaults`. Kills: a wrong scope, kind or frame.
        @Test func countedFaultsMatchAPlainLatch() throws {
            // Source 1 is left unprepared, so its raises land in `unknownScopeFaults`.
            let scopes = [FaultScope(handoff: Self.base, target: 0), FaultScope(handoff: Self.base, target: 2)]
            let faults = try FaultChainAuthority(scopes: scopes, chainBudget: 1)
            let twin = try FaultLatch(scopes: scopes)
            let assembler = try SysExAssembler(sources: 3, maximumMessageBytes: 4, poolBytes: 8,
                                               output: SPSCRing(policy: Root.sysexRingPolicy()), faults: faults,
                                               scopeBase: Self.base)
            func send(_ source: UInt32, _ status: SysExChunkStatus, _ count: UInt8, frame: Int64) -> KernelStatus {
                assembler.accept(source: source, status: status, bytes: Self.probe, count: count, frame: frame)
            }
            func expectRaise(_ source: UInt32, _ kind: FaultKind, frame: Int64) {
                _ = twin.raise(FaultScope(handoff: Self.base, target: source), kind, frame: frame)
            }
            #expect(send(0, .continue, 1, frame: 5) == .refused(.notOwner))
            expectRaise(0, .sysexAborted, frame: 5)
            #expect(send(1, .end, 1, frame: 6) == .refused(.notOwner))
            expectRaise(1, .sysexAborted, frame: 6)
            #expect(send(2, .start, 1, frame: 3) == .ok)
            #expect(send(2, .start, 6, frame: 7) == .refused(.invalidLength))
            expectRaise(2, .sysexAborted, frame: 7)
            expectRaise(2, .sysexOverflow, frame: 7)
            #expect(send(0, .complete, 6, frame: 8) == .refused(.invalidLength))
            expectRaise(0, .sysexOverflow, frame: 8)
            #expect(Root.FaultChaining.records(faults) == Root.FaultChaining.records(twin))
            #expect(Root.FaultChaining.records(faults).count == 2)
            #expect(faults.unknownScopeFaults == twin.unknownScopeFaults && faults.unknownScopeFaults == 1)
            for scope in scopes {
                let observed = try #require(faults.observe(scope))
                let expected = try #require(twin.observe(scope))
                #expect(observed.record == expected.record)
                #expect(faults.acknowledge(observed) == twin.acknowledge(expected))
            }
            #expect(Root.FaultChaining.records(faults).isEmpty && Root.FaultChaining.records(twin).isEmpty)
            #expect(send(0, .end, 1, frame: 9) == .refused(.notOwner))
            expectRaise(0, .sysexAborted, frame: 9)
            #expect(Root.FaultChaining.records(faults) == Root.FaultChaining.records(twin))
            #expect(!faults.hasContendedFault && assembler.contendedChunkCount == 0)
        }

        /// T7. The pure guards run before the take, so they never contend even while the token is held. Kills:
        /// the take moved above the guards.
        @Test func pureGuardsDoNotTouchTheSlot() throws {
            let fixture = try SysExFixture()
            var statuses: [KernelStatus] = []
            #expect(fixture.assembler.withChainTokenHeld {
                for status in SysExChunkStatus.allCases {
                    statuses.append(fixture.assembler.accept(source: 0, status: status, bytes: Self.probe, count: 7))
                    statuses.append(fixture.assembler.accept(source: 4, status: status, bytes: Self.probe, count: 1))
                }
            })
            #expect(statuses == Array(repeating: [.refused(.invalidLength), .refused(.slotOutOfRange)], count: 4)
                .flatMap(\.self))
            #expect(fixture.assembler.contendedChunkCount == 0 && !fixture.faults.hasContendedFault)
            #expect(fixture.takeFaults().isEmpty && fixture.faults.unknownScopeFaults == 0)
            Self.expectTokenReturned(fixture)
        }
    }
}
