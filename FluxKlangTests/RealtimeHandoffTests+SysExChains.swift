import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests
private typealias LatchScan = RealtimeHandoffTests.FaultRaiseInventory

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

/// A declaration body in `FaultLatchConstruction`'s scan: UTF-16 offsets from its `{` to its `}`.
private struct LatchScope {
    let name: String
    let isFunction: Bool
    let body: Range<Int>
}

/// K-190c's scan (here for `+FaultChains.swift`'s line cap) and its self-tests.
extension RealtimeHandoffTests.FaultLatchConstruction {
    /// `sites(of:in:path:within:)` over each `.swift` file under `root` that names one of `words` (every file when
    /// empty), keyed from `prefix`.
    static func sites(of patterns: [LatchPattern], under root: URL, prefix: String = "", naming words: [String] = [],
                      within: String? = nil) throws -> [String: Int] {
        let all = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
        var found: [String: Int] = [:]
        for path in all.filter({ $0.hasSuffix(".swift") }).sorted() {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            guard words.isEmpty || words.contains(where: { text.contains($0) }) else { continue }
            found.merge(try Self.sites(of: patterns, in: text, path: prefix + path, within: within)) { $0 + $1 }
        }
        return found
    }

    /// Each match in `text`, keyed `path Type.func kind` (`<none>` when nothing encloses it); a `type` key ends with
    /// its line up to the match. With `within`, only matches inside a type or extension of that name count. The
    /// name in a `func name(` declaration is not a call.
    static func sites(of patterns: [LatchPattern], in text: String, path: String, within: String? = nil) throws
        -> [String: Int] {
        let code = LatchScan.sanitized(text)
        let source = code as NSString
        let matches = try patterns.flatMap { pattern in
            try NSRegularExpression(pattern: pattern.regex).matches(in: code, range: NSRange(0..<source.length))
                .map { (pattern.kind, $0.range) }
        }
        guard !matches.isEmpty else { return [:] }
        let scopes = try Self.scopes(in: code)
        var found: [String: Int] = [:]
        for (kind, range) in matches {
            let start = source.lineRange(for: NSRange(location: range.location, length: 0)).location
            let lead = source.substring(with: NSRange(start..<range.location))
            if lead.range(of: #"\bfunc\s+$"#, options: .regularExpression) != nil { continue }
            let enclosing = scopes.filter { $0.body.contains(range.location) }
            if let within, !enclosing.contains(where: { !$0.isFunction && $0.name == within }) { continue }
            let type = enclosing.last { !$0.isFunction }?.name ?? "<none>"
            let function = enclosing.last { $0.isFunction }?.name ?? "<none>"
            let line = source.substring(with: NSRange(start..<NSMaxRange(range)))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let quote = kind == "type" ? ": " + line : ""
            found["\(path) \(type).\(function) \(kind)\(quote)", default: 0] += 1
        }
        return found
    }

    /// K-190a's scopes: each declaration with a body, in source order, so the last enclosing one is innermost.
    fileprivate static func scopes(in code: String) throws -> [LatchScope] {
        let units = Array(code.utf16)
        let matches = try NSRegularExpression(pattern: LatchScan.declaration)
            .matches(in: code, range: NSRange(0..<units.count))
        var scopes: [LatchScope] = []
        for (index, match) in matches.enumerated() {
            let limit = index + 1 < matches.count ? matches[index + 1].range.location : units.count
            guard let body = LatchScan.body(units, from: NSMaxRange(match.range), before: limit) else { continue }
            let group = (1...3).first { match.range(at: $0).location != NSNotFound } ?? 3
            let name = (code as NSString).substring(with: match.range(at: group))
            scopes.append(LatchScope(name: name, isFunction: group < 3, body: body))
        }
        return scopes
    }

    /// What `found` adds to or misses from `expected`, for a failure message.
    static func difference(_ found: [String: Int], _ expected: [String: Int]) -> Comment {
        let added = found.filter { $0.value > expected[$0.key, default: 0] }.map { "\($0.key) x\($0.value)" }
        let missing = expected.filter { $0.value > found[$0.key, default: 0] }
            .map { "\($0.key) x\(found[$0.key, default: 0])" }
        return Comment(rawValue: "added: \(added.sorted()); missing: \(missing.sorted())")
    }

    @Test func latchScanFlagsConstructionsAndAuthorities() throws {
        let source = #"""
            struct Lane {
                init(scopes: [FaultScope]) throws {
                    _ = try FaultLatch(scopes: scopes)
                    _ = try FaultLatch
                        .init(scopes: scopes, epochLimit: 4)
                    let spare: FaultLatch = try .init(scopes: scopes)
                    let kind = FaultLatch.self
                    let made = try FaultLatch.fresh(scopes)
                }
            }
            extension FaultLatch {
                static func spare(_ scopes: [FaultScope]) throws -> FaultLatch { try Self(scopes: scopes) }
                static func copy(_ scopes: [FaultScope]) throws -> FaultLatch { try .init(scopes: scopes) }
                static func twin(_ scopes: [FaultScope]) throws -> Self { try Self.init(scopes: scopes) }
                static func fresh(_ scopes: [FaultScope]) throws -> Self { try self.init(scopes: scopes) }
            }
            """#
        // The split `FaultLatch\n.init(scopes:` counts as both a spelled-out and an inferred construction.
        #expect(try Self.sites(of: Self.constructions, in: source, path: "L.swift") == [
            "L.swift Lane.init latch": 2, "L.swift Lane.init inferred": 2, "L.swift Lane.init metatype": 1,
            "L.swift Lane.init factory": 1, "L.swift FaultLatch.copy inferred": 1
        ])
        #expect(try Self.sites(of: Self.selfConstructions, in: source, path: "L.swift", within: "FaultLatch") == [
            "L.swift FaultLatch.spare self": 1, "L.swift FaultLatch.copy init": 1, "L.swift FaultLatch.twin self": 1,
            "L.swift FaultLatch.fresh selfInit": 1
        ])
        let audit = "let authority = try FaultChainAuthority\n    .init(scopes: scopes, chainBudget: 2)\n"
            + "func make() throws -> FaultChainAuthority { try .init(scopes: scopes) }\n"
        #expect(try Self.sites(of: Self.authorities, in: audit, path: "A.swift") == [
            "A.swift <none>.<none> authority": 1, "A.swift <none>.<none> inferred": 1, "A.swift <none>.make inferred": 1
        ])
    }

    @Test func latchScanFlagsEveryWayToHoldALatch() throws {
        let source = #"""
            final class FaultChainAuthority {
                let latch: FaultLatch
                var exposedLatch: FaultLatch { latch }
                func borrow() -> FaultLatch { latch }
                private let latchRef: Unmanaged<FaultLatch>
                var spares: [FaultLatch?] = []
                func visit(_ body: (FaultLatch) -> Void) { body(latch) }
                func rawRaise() -> (FaultScope, FaultKind, Int64) -> KernelStatus { self.latch.raise }
                func hook() -> () -> Bool { { [latch] in latch.isLatched(scope) } }
                func path() -> AnyKeyPath { \Self.`latch` }
                func describe() -> String { "latch.raise" } // self.latch
            }
            typealias Latch = FaultLatch
            let held = holder as! FaultLatch
            func adopt(_ latch: inout FaultLatch) {}
            """#
        let owner = "H.swift FaultChainAuthority.<none> type: "
        #expect(try Self.sites(of: Self.holders, in: source, path: "H.swift") == [
            owner + "let latch: FaultLatch": 1, owner + "var exposedLatch: FaultLatch": 1,
            owner + "func borrow() -> FaultLatch": 1, owner + "private let latchRef: Unmanaged<FaultLatch": 1,
            owner + "var spares: [FaultLatch": 1, owner + "func visit(_ body: (FaultLatch": 1,
            "H.swift <none>.<none> type: typealias Latch = FaultLatch": 1,
            "H.swift <none>.<none> type: let held = holder as! FaultLatch": 1,
            "H.swift <none>.<none> type: func adopt(_ latch: inout FaultLatch": 1
        ])
        // Escapes that never name the type: a bare, `self.`, captured or key-path `latch` (not `adopt`'s, outside).
        let uses = "H.swift FaultChainAuthority."
        #expect(try Self.sites(of: Self.latchUses, in: source, path: "H.swift", within: "FaultChainAuthority") == [
            uses + "<none> use": 2, uses + "borrow use": 1, uses + "visit use": 1, uses + "rawRaise use": 1,
            uses + "hook use": 2, uses + "path use": 1
        ])
    }

    @Test func latchScanFlagsMintsOutsideTheirSites() throws {
        let source = #"""
            extension FanInHandoff {
                func claimProducer() -> Bool { faults.mintChain() != nil }
                static func buildLanes(_ policy: HandoffPolicy) throws -> [Lane] {
                    try makeLanes(policy, count: 2, faults: faults, scope: scope)
                }
                func releaseProducer() {
                    _ = FanInClaimChain.init(minting: faults)
                    _ = faults
                        .mintChains (count: 2)
                    let ring = ReservedRingChain(authority: faults, chain: chain)
                }
            }
            """#
        #expect(try Self.sites(of: Self.mints, in: source, path: "F.swift") == [
            "F.swift FanInHandoff.claimProducer mintChain": 1, "F.swift FanInHandoff.buildLanes makeLanes": 1,
            "F.swift FanInHandoff.releaseProducer claimChain": 1, "F.swift FanInHandoff.releaseProducer mintChains": 1,
            "F.swift FanInHandoff.releaseProducer ringChain": 1
        ])
    }

    @Test func latchScanIgnoresCommentsStringsAndLookalikes() throws {
        let source = #"""
            // let latch = try FaultLatch(scopes: scopes); faults.mintChain()
            /* outer /* nested FaultLatch.init(scopes:) */ -> FaultLatch? */
            /// var exposed: FaultLatch { latch }; makeLanes(policy); FanInClaimChain(minting: faults)
            final class FaultChainAuthority {
                enum PreparationError: Error { case latch(FaultLatch.PreparationError) }
                convenience init(scopes: [FaultScope]) throws { try self.init(scopes: scopes, chainBudget: 1) }
                func mintChain() -> FaultChain? { nil }
                func mintChains(count: Int) -> [FaultChain]? { nil }
                static func makeLanes(_ count: Int) {}
                func describe() -> String {
                    let plain = "FaultLatch(scopes: s) Self(scopes: s) .init(scopes: s) \" mintChain() [FaultLatch]"
                    let raw = #"Unmanaged<FaultLatch> latch "# + "\(note("FaultChainAuthority(scopes:"))"
                    return plain + raw + """
                        FaultLatch.self ReservedRingChain(authority: a, chain: c) "" makeLanes( { latch }
                        """
                }
                func unlatch() -> Bool { isLatched(latches: latchRef) }
            }
            struct FaultLatchNote { let note = MyFaultLatch(); let other = FaultLatchy() }
            func remakeLanes() { faultLatch(); premintChain(); mintChainCount(); ReservedRingChainNote() }
            extension FaultLatchNote { func make() -> Self { Self() } static func spare() -> Self { .init() } }
            """#
        for patterns in [Self.constructions, Self.holders, Self.mints, Self.authorities] {
            #expect(try Self.sites(of: patterns, in: source, path: "G.swift").isEmpty)
        }
        #expect(try Self.sites(of: Self.selfConstructions, in: source, path: "G.swift", within: "FaultLatch").isEmpty)
        // Only the `PreparationError.latch` case is a `latch` token: not strings, `unlatch`, `latches` or `latchRef`.
        #expect(try Self.sites(of: Self.latchUses, in: source, path: "G.swift", within: "FaultChainAuthority") == [
            "G.swift PreparationError.<none> use": 1
        ])
    }
}
