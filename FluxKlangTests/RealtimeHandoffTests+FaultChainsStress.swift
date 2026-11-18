import Foundation
import Synchronization
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared counters for the chain-token stress tests.
private final class ChainStressState: Sendable {
    let arrived = Atomic<Int>(0)
    let started = Atomic<Bool>(false)
    let cancelled = Atomic<Bool>(false)
    let exited = Atomic<Int>(0)
    let timedOut = Atomic<Int>(0)
    /// Raises made while holding a token.
    let counted = Atomic<Int>(0)
    /// Attempts that found the slot empty and took the contended fallback.
    let contended = Atomic<Int>(0)
    /// `raise` or `put` results other than `.ok`.
    let wrongStatus = Atomic<Int>(0)
    /// Contexts holding the raced chain's token right now; a take that sees another holder is an overlap.
    let holders = Atomic<Int>(0)
    let overlaps = Atomic<Int>(0)
    let guarded = TokenGuardedCount()
    /// Per thread, the chain ids each authority granted to it in the batch-mint stress test.
    let mintedIds = Mutex<[[[UInt64]]]>([])
}

private extension UInt16 {
    init(ascii scalar: Unicode.Scalar) { self.init(scalar.value) }
}

/// A plain (non-atomic) counter that only a token holder touches: the slot's release/acquire pair is its only
/// synchronization, so a lost update (or a TSan report) means the chain's happens-before edge is missing.
private final class TokenGuardedCount: @unchecked Sendable {
    var value = 0
}

extension RealtimeHandoffTests {
    /// `Thread` stress (TSan: `--filter Stress`) for chain tokens: contexts race one chain's slot, and every
    /// attempt is either one counted raise or one contended fallback.
    struct FaultChainingStress {
        static let threads = 4
        static let attemptsPerThread = 20_000
        /// Cap on each bounded wait; a failing run waits at most twice, inside the 1-minute limit.
        static let deadline: Duration = .seconds(15)

        static func kind(for frame: Int64) -> FaultKind {
            FaultKind(rawValue: UInt8(truncatingIfNeeded: frame % 8)) ?? .noPlan
        }

        /// One attempt: take, raise and put back, or fall back without raising when the slot is empty.
        fileprivate static func attempt(_ authority: FaultChainAuthority, _ chain: FaultChain, _ scope: FaultScope,
                                        frame: Int64, _ state: ChainStressState) {
            guard var token = chain.take() else {
                authority.raiseContended()
                state.contended.add(1, ordering: .relaxed)
                return
            }
            if state.holders.wrappingAdd(1, ordering: .relaxed).oldValue != 0 {
                state.overlaps.add(1, ordering: .relaxed)
            }
            if authority.raise(&token, scope, kind(for: frame), frame: frame) != .ok {
                state.wrongStatus.add(1, ordering: .relaxed)
            }
            state.guarded.value += 1
            state.counted.add(1, ordering: .relaxed)
            state.holders.wrappingSubtract(1, ordering: .relaxed)
            if chain.put(token) != .ok { state.wrongStatus.add(1, ordering: .relaxed) }
        }

        /// Starts `threads` workers behind a bounded start barrier and waits (bounded) for all to exit; on overrun
        /// it cancels them and records an issue. `true` only when every worker ran to completion in time.
        fileprivate static func run(_ state: ChainStressState, _ body: @escaping @Sendable (Int) -> Void) -> Bool {
            for index in 0..<threads {
                Thread {
                    state.arrived.add(1, ordering: .releasing)
                    let end = ContinuousClock.now + deadline
                    var ready = state.started.load(ordering: .acquiring)
                    while !ready && !state.cancelled.load(ordering: .relaxed) && ContinuousClock.now < end {
                        ready = state.started.load(ordering: .acquiring)
                    }
                    if ready { body(index) } else { state.timedOut.add(1, ordering: .relaxed) }
                    state.exited.add(1, ordering: .releasing)
                }.start()
            }
            let arrived = poll { state.arrived.load(ordering: .acquiring) == threads }
            state.started.store(arrived, ordering: .releasing)
            if !arrived { state.cancelled.store(true, ordering: .relaxed) }
            var exited = poll { state.exited.load(ordering: .acquiring) == threads }
            if !exited {
                state.cancelled.store(true, ordering: .relaxed)
                Issue.record("chain stress workers overran \(deadline); cancelled")
                exited = poll { state.exited.load(ordering: .acquiring) == threads }
            }
            let timedOut = state.timedOut.load(ordering: .relaxed)
            if timedOut > 0 { Issue.record("\(timedOut) chain stress worker(s) never started") }
            return arrived && exited && timedOut == 0
        }

        static func poll(until condition: () -> Bool) -> Bool {
            let end = ContinuousClock.now + deadline
            while !condition() {
                if ContinuousClock.now >= end { return condition() }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return true
        }

        /// Even threads race one chain; odd threads use a chain whose token the test holds throughout, so each of
        /// their attempts must fall back. Counted raises plus fallbacks equal attempts, the counted records hold
        /// exactly the counted raises, and the raced slot ends holding its one token.
        @Test(.timeLimit(.minutes(1))) func racingContextsConserveEveryAttempt() throws {
            let scopes = [FaultScope(handoff: 9, target: 0), FaultScope(handoff: 9, target: 1)]
            let authority = try FaultChainAuthority(scopes: scopes, chainBudget: 2)
            let raced = try #require(authority.mintChain())
            let held = try #require(authority.mintChain())
            let holder = try FaultChaining.take(held)
            let state = ChainStressState()
            let ran = Self.run(state) { thread in
                for index in 0..<Self.attemptsPerThread {
                    if state.cancelled.load(ordering: .relaxed) { return }
                    let frame = Int64(thread * Self.attemptsPerThread + index)
                    let chain = thread.isMultiple(of: 2) ? raced : held
                    Self.attempt(authority, chain, scopes[index % scopes.count], frame: frame, state)
                }
            }
            guard ran else { return }
            let counted = state.counted.load(ordering: .relaxed)
            let contended = state.contended.load(ordering: .relaxed)
            #expect(counted + contended == Self.threads * Self.attemptsPerThread)
            #expect(contended >= Self.threads / 2 * Self.attemptsPerThread)
            #expect(state.wrongStatus.load(ordering: .relaxed) == 0)
            #expect(state.overlaps.load(ordering: .relaxed) == 0)
            #expect(state.guarded.value == counted)
            #expect(authority.hasContendedFault)
            #expect(authority.unknownScopeFaults == 0)
            var total = 0
            var mispaired = 0
            _ = authority.pending { record in
                total += Int(record.count)
                if record.firstFrame < 0 || record.kind != Self.kind(for: record.firstFrame) { mispaired += 1 }
            }
            #expect(total == counted)
            #expect(mispaired == 0)
            // Neither slot is torn: the raced one holds exactly one token, the held one none until it is returned.
            #expect(raced.put(try FaultChaining.take(raced)) == .ok)
            #expect(FaultChaining.isEmpty(held))
            #expect(held.put(holder) == .ok)
            #expect(held.put(try FaultChaining.take(held)) == .ok)
        }

        /// Threads race batch mints of 0 to 8 chains on many small budgets in turn, so each budget's end is contended.
        /// Every grant is whole and `issued`, no budget is overshot, and each authority's grants are exactly ids
        /// `1...mintedChains`, once each.
        @Test(.timeLimit(.minutes(1))) func concurrentBatchMintsNeverOvershootBudget() throws {
            let budget = 16
            let attempts = 8
            let scopes = [FaultScope(handoff: 9, target: 0)]
            let authorities = try (0..<256).map { _ in try FaultChainAuthority(scopes: scopes, chainBudget: budget) }
            let state = ChainStressState()
            let ran = Self.run(state) { thread in
                var granted = [[UInt64]](repeating: [], count: authorities.count)
                for (index, authority) in authorities.enumerated() {
                    if state.cancelled.load(ordering: .relaxed) { break }
                    for attempt in 0..<attempts {
                        let count = (thread &* 7 &+ attempt &* 13 &+ index) % 9
                        guard let chains = authority.mintChains(count: count) else { continue }
                        let batch = chains.map(\.id)
                        let whole = batch.count == count && zip(batch, batch.dropFirst()).allSatisfy { $0 + 1 == $1 }
                        if !whole || !chains.allSatisfy(authority.issued) {
                            state.wrongStatus.add(1, ordering: .relaxed)
                        }
                        granted[index] += batch
                    }
                }
                state.mintedIds.withLock { $0.append(granted) }
            }
            guard ran else { return }
            let perThread = state.mintedIds.withLock { $0 }
            #expect(perThread.count == Self.threads)
            #expect(state.wrongStatus.load(ordering: .relaxed) == 0)
            for (index, authority) in authorities.enumerated() {
                let minted = authority.mintedChains
                let ids = perThread.flatMap { granted in granted.dropFirst(index).first ?? [] }.sorted()
                #expect(minted <= budget)
                #expect(ids == (0..<minted).map { UInt64($0 + 1) })
                // Whatever is left is still exactly available, all or nothing.
                #expect(authority.mintChains(count: budget - minted + 1) == nil)
                if minted < budget {
                    #expect(authority.mintChains(count: budget - minted)?.first?.id == UInt64(minted + 1))
                }
                #expect(authority.mintedChains == budget)
            }
        }
    }
}

/// A declaration body in `FaultRaiseInventory`'s scan: UTF-16 offsets from its `{` to its `}`.
private struct RaiseScope {
    let name: String
    let isFunction: Bool
    let body: Range<Int>
}

/// Blanks comments and string literals for `FaultRaiseInventory`'s scan.
private struct LiteralMask {
    var units: [UInt16]
    var index = 0

    func peek(_ text: String, at offset: Int = 0) -> Bool {
        index + offset <= units.count && units[(index + offset)...].starts(with: text.utf16)
    }

    mutating func blank(_ range: Range<Int>) {
        for position in range where units[position] != UInt16(ascii: "\n") {
            units[position] = UInt16(ascii: " ")
        }
    }

    /// Code to the end of input, or, for an interpolation, past the `)` that closes it.
    mutating func code(interpolation: Bool) {
        var depth = 0
        while index < units.count {
            let start = index
            if peek("//") {
                while index < units.count, units[index] != UInt16(ascii: "\n") { index += 1 }
                blank(start..<index)
            } else if peek("/*") {
                blockComment()
            } else if let hashes = rawHashes() {
                string(hashes: hashes)
            } else {
                index += 1
                if interpolation, units[start] == UInt16(ascii: "(") { depth += 1 }
                if interpolation, units[start] == UInt16(ascii: ")") {
                    if depth == 0 { return }
                    depth -= 1
                }
            }
        }
    }

    mutating func blockComment() {
        let start = index
        var depth = 0
        repeat {
            if peek("/*") {
                depth += 1
                index += 2
            } else if peek("*/") {
                depth -= 1
                index += 2
            } else {
                index += 1
            }
        } while depth > 0 && index < units.count
        blank(start..<min(index, units.count))
    }

    /// The `#` count when a string literal starts here, else `nil`.
    func rawHashes() -> Int? {
        var hashes = 0
        while peek("#", at: hashes) { hashes += 1 }
        return peek("\"", at: hashes) ? hashes : nil
    }

    mutating func string(hashes: Int) {
        let start = index
        let pounds = String(repeating: "#", count: hashes)
        index += hashes
        let close = (peek("\"\"\"") ? "\"\"\"" : "\"") + pounds
        index += close.count - hashes
        while index < units.count, !peek(close) {
            if peek("\\" + pounds) {
                index += 1 + hashes
                if peek("(") {
                    index += 1
                    code(interpolation: true)
                    continue
                }
            }
            index += 1
        }
        index = min(index + close.utf16.count, units.count)
        blank(start..<index)
    }
}

extension RealtimeHandoffTests {
    /// K-190a (#190 acceptance item 1 only): every raise site under `Shared/Audio/Kernel`, keyed by file, enclosing
    /// type and function, and kind, is exactly the inventory in fault-latch-raise-sites.md section 9. A regex scan
    /// of source with comments and string literals blanked, not a parser: a raise inside an interpolation is masked.
    struct FaultRaiseInventory {
        /// `relpath Type.func kind`, each once: `raise` and `contended` (`raiseContended`) calls, and `chainRefuse`
        /// (`laneChain`/`claimChain` `.refuse`), the calls that reach a chain's raise from its owner.
        static let expected: [String: Int] = Dictionary(uniqueKeysWithValues: [
            "Memory/FaultLatch+Chains.swift FaultChainAuthority.raise raise", // R0
            "Events/SysExAssembler.swift SysExAssembler.accept contended", // S1
            "Events/SysExAssembler.swift SysExAssembler.extend raise",
            "Events/SysExAssembler.swift SysExAssembler.discard raise",
            "Events/SysExAssembler.swift SysExAssembler.raise raise",
            "Memory/FanInHandoff+Chains.swift FanInClaimChain.refuse raise", // S2
            "Memory/FanInHandoff+Chains.swift FanInClaimChain.refuse contended",
            "Memory/FanInHandoff.swift FanInHandoff.claimProducer chainRefuse",
            "Memory/DeferredRelease.swift DeferredReleaseQueue.retire raise", // S3
            "Memory/DeferredRelease.swift DeferredReleaseQueue.retire contended",
            "Memory/ReservedCapacityRing+Chains.swift ReservedRingChain.refuse raise", // S4
            "Memory/ReservedCapacityRing+Chains.swift ReservedRingChain.refuse contended",
            "Memory/ReservedCapacityRing.swift ReservedCapacityRing.refuse chainRefuse"
        ].map { ($0, 1) })

        static let calls = [
            ("raise", #"\braise\s*\("#), ("contended", #"\braiseContended\s*\("#),
            ("chainRefuse", #"\b(?:laneChain|claimChain)\s*\.\s*refuse\s*\("#)
        ]

        /// `func`, `init` or `deinit` (groups 1, 2), or a type or extension name, generics stripped (group 3).
        static let declaration = #"(?<![\w.])(?:func\s+([A-Za-z_]\w*)|(init|deinit)(?!\w)|"#
            + #"(?:class|struct|enum|actor|extension)\s+(?!(?:func|var|let|init|subscript)\b)([A-Za-z_][\w.]*))"#

        static func kernelRoot(from path: String = #filePath) -> URL? {
            let here = URL(fileURLWithPath: path).deletingLastPathComponent()
            let candidates = ["../Shared/Audio/Kernel", "../../Sources/FluxKlang/Shared/Audio/Kernel"]
            return candidates
                .map { here.appendingPathComponent($0).standardizedFileURL }
                .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(sentinel).path) }
        }

        static let sentinel = "Memory/FaultLatch+Chains.swift"
        static let kernelIsReachable = kernelRoot() != nil

        /// Every call in every `.swift` file under `root`, counted by key.
        static func inventory(under root: URL) throws -> [String: Int] {
            let all = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
            var found: [String: Int] = [:]
            for path in all.filter({ $0.hasSuffix(".swift") }).sorted() {
                let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                found.merge(try inventory(of: text, path: path), uniquingKeysWith: +)
            }
            return found
        }

        /// The calls in `text`, keyed `path Type.func kind`; `<none>` when no type or function encloses one.
        static func inventory(of text: String, path: String) throws -> [String: Int] {
            let code = sanitized(text)
            let scopes = try Self.scopes(in: code)
            let length = (code as NSString).length
            var found: [String: Int] = [:]
            for (kind, pattern) in calls {
                for match in try NSRegularExpression(pattern: pattern).matches(in: code, range: NSRange(0..<length)) {
                    let start = match.range.location
                    let before = (code as NSString).substring(to: start)
                    if before.range(of: #"\bfunc\s+$"#, options: .regularExpression) != nil { continue }
                    let enclosing = scopes.filter { $0.body.contains(start) }
                    let type = enclosing.last { !$0.isFunction }?.name ?? "<none>"
                    let function = enclosing.last { $0.isFunction }?.name ?? "<none>"
                    found["\(path) \(type).\(function) \(kind)", default: 0] += 1
                }
            }
            return found
        }

        /// Each declaration with a body, in source order (so the last enclosing one is the innermost). A body is
        /// the first `{` outside `(…)`/`[…]` before the next declaration, to its matching `}`; a requirement
        /// without one has none.
        fileprivate static func scopes(in code: String) throws -> [RaiseScope] {
            let units = Array(code.utf16)
            let matches = try NSRegularExpression(pattern: declaration)
                .matches(in: code, range: NSRange(0..<units.count))
            var scopes: [RaiseScope] = []
            for (index, match) in matches.enumerated() {
                let limit = index + 1 < matches.count ? matches[index + 1].range.location : units.count
                guard let body = Self.body(units, from: NSMaxRange(match.range), before: limit) else { continue }
                let group = (1...3).first { match.range(at: $0).location != NSNotFound } ?? 3
                let name = (code as NSString).substring(with: match.range(at: group))
                scopes.append(RaiseScope(name: name, isFunction: group < 3, body: body))
            }
            return scopes
        }

        static func body(_ units: [UInt16], from start: Int, before limit: Int) -> Range<Int>? {
            var depth = 0
            for index in start..<max(start, limit) {
                switch units[index] {
                case UInt16(ascii: "("), UInt16(ascii: "["): depth += 1
                case UInt16(ascii: ")"), UInt16(ascii: "]"): depth -= 1
                case UInt16(ascii: "}") where depth == 0: return nil
                case UInt16(ascii: "{") where depth == 0:
                    var braces = 0
                    for end in index..<units.count {
                        if units[end] == UInt16(ascii: "{") { braces += 1 }
                        if units[end] == UInt16(ascii: "}") { braces -= 1 }
                        if braces == 0 { return index..<end }
                    }
                    return nil
                default: break
                }
            }
            return nil
        }

        /// `text` with every comment (`//`, nested `/* */`, doc) and string literal (`"…"`, `"""…"""`, `#"…"#`,
        /// interpolations included) blanked to spaces; newlines stay, so offsets and lines are unchanged.
        static func sanitized(_ text: String) -> String {
            var mask = LiteralMask(units: Array(text.utf16))
            mask.code(interpolation: false)
            return String(decoding: mask.units, as: UTF16.self)
        }

        @Test(.enabled(if: Self.kernelIsReachable, "the kernel sources are not next to the tests"))
        func faultRaiseInventoryMatchesTheDocumentedSites() throws {
            let root = try #require(Self.kernelRoot())
            let found = try Self.inventory(under: root)
            let added = found.filter { $0.value > Self.expected[$0.key, default: 0] }
                .map { "\($0.key) x\($0.value)" }.sorted()
            let missing = Self.expected.filter { $0.value > found[$0.key, default: 0] }
                .map { "\($0.key) x\(found[$0.key, default: 0])" }.sorted()
            #expect(found == Self.expected, "added: \(added); missing: \(missing)")
        }

        @Test func faultRaiseScannerIgnoresCommentsStringsAndDeclarations() throws {
            let source = #"""
                struct Lane {
                    // $0.raise(&token, scope, kind, frame: frame)
                    /* outer /* nested $0.raise(&token) */ raiseContended() */
                    /// laneChain.refuse(scope, frame: frame)
                    func raise(_ token: inout Int) {}
                    func raiseContended () {}
                    func describe() -> String {
                        let plain = "$0.raise(&token, scope, kind, frame: frame) \" raiseContended()"
                        let raw = #"$0.raiseContended() "# + "\(note("raise(&token)")) claimChain.refuse("
                        return plain + raw + """
                            laneChain.refuse(scope, frame: frame) "" raise(
                            """
                    }
                }
                """#
            #expect(try Self.inventory(of: source, path: "L.swift").isEmpty)
            #expect(Self.sanitized(source).filter { $0 == "\n" }.count == source.filter { $0 == "\n" }.count)
        }

        @Test func faultRaiseScannerFindsSplitAndBareCalls() throws {
            let source = #"""
                final class Queue {
                    func retire() {
                        _ = authority
                            .raise(&token, scope, .retireBacklog, frame: frame)
                        raise (index, kind, frame, &token)
                        authorityRef._withUnsafeGuaranteedRef { $0.raiseContended() }
                        laneChain
                            .refuse(scope, frame: frame)
                    }
                }
                """#
            #expect(try Self.inventory(of: source, path: "Q.swift") == [
                "Q.swift Queue.retire raise": 2, "Q.swift Queue.retire contended": 1,
                "Q.swift Queue.retire chainRefuse": 1
            ])
        }

        @Test func faultRaiseScannerKeysByEnclosingTypeAndFunction() throws {
            let source = #"""
                protocol Raising {
                    func raise(_ value: Int)
                }
                struct Ring<Element: BitwiseCopyable>: Raising {
                    init() { raise(1) }
                    func raise(_ value: Int) { $0.raise(&token) }
                }
                extension Ring where Element == Int {
                    func flush(_ body: () -> Void = { }) {
                        items.forEach { _ in authority.raiseContended() }
                    }
                    deinit { laneChain.refuse(scope, frame: 0) }
                }
                enum Loose {
                    static let fault: Void = authority.raiseContended()
                }
                """#
            #expect(try Self.inventory(of: source, path: "R.swift") == [
                "R.swift Ring.init raise": 1, "R.swift Ring.raise raise": 1, "R.swift Ring.flush contended": 1,
                "R.swift Ring.deinit chainRefuse": 1, "R.swift Loose.<none> contended": 1
            ])
            let renamed = source.replacingOccurrences(of: "func flush(", with: "func drain(")
            #expect(try Self.inventory(of: renamed, path: "R.swift")["R.swift Ring.drain contended"] == 1)
            #expect(try Self.inventory(of: renamed, path: "R.swift")["R.swift Ring.flush contended"] == nil)
        }

        @Test func faultRaiseScannerCountsDuplicates() throws {
            let source = "struct Chain {\n    func refuse() {\n        $0.raise(&token)\n        $0.raise(&token)\n"
                + "        $0.raiseContended()\n    }\n}\n"
            #expect(try Self.inventory(of: source, path: "D.swift") == [
                "D.swift Chain.refuse raise": 2, "D.swift Chain.refuse contended": 1
            ])
        }
    }
}
