import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The order of a `due` result, and a scan of the new sources for the names they must not carry. Every list follows
/// the wrapped scheduler's order (window, then arrival, then bundle index), whatever order the batches were admitted
/// in and whatever order the context table keeps its entries in.
extension OSCReceiveContextTests {
    // MARK: Order

    @Test func dueOrdersDispatchByInnerWindowRegardlessOfAdmitOrder() throws {
        let contexts = try Fixture.peers(3)
        let policy = try Fixture.policy(late: 10 * 1_000_000_000)
        for order in [Array(1...6), Array((1...6).reversed()), [3, 6, 1, 5, 2, 4]] {
            var wrapper = try Fixture.wrapper(policy: policy)
            for step in order {
                let packet = try Fixture.timed(Fixture.tag(after: Int64(step)), Int32(step))
                try Fixture.admit(&wrapper, packet, contexts[step % 3])
            }
            let released = try wrapper.due(now: Fixture.host(6 * Fixture.second), live: Set(contexts))
            #expect(Fixture.payloads(released.dispatch) == [1, 2, 3, 4, 5, 6], "\(order)")
            #expect(released.dispatch.map(\.context) == (1...6).map { contexts[$0 % 3] }, "\(order)")
            #expect(released.revoked.isEmpty && released.refusedWithContext.isEmpty, "\(order)")
            #expect(wrapper.taggedBatchCount == 0 && wrapper.contextCount == 0, "\(order)")
        }
    }

    @Test func dueKeepsArrivalOrderForEqualWindows() throws {
        let contexts = try Fixture.peers(40)
        let arrival = (0..<40).map { Int32($0) }
        var kept = try Fixture.wrapper(limit: 40)
        var dropped = try Fixture.wrapper(limit: 40)
        var refused = try Fixture.wrapper(limit: 40)
        for (index, context) in contexts.enumerated() {
            let packet = try Fixture.message(Int32(index))
            try Fixture.admit(&kept, packet, context)
            try Fixture.admit(&dropped, packet, context)
            try Fixture.admit(&refused, packet, context)
        }
        let dispatched = try kept.due(now: Fixture.host(0), live: Set(contexts))
        #expect(Fixture.payloads(dispatched.dispatch) == arrival && dispatched.dispatch.map(\.context) == contexts)
        let revoked = try dropped.due(now: Fixture.host(0), live: [])
        #expect(Fixture.payloads(revoked.revoked) == arrival && revoked.revoked.map(\.context) == contexts)
        let late = try refused.due(now: Fixture.host(Fixture.second + 1), live: Set(contexts))
        #expect(Fixture.values(late.refusedWithContext.flatMap(\.refused.batch.messages)) == arrival)
        #expect(late.refusedWithContext.map(\.context) == contexts)
    }

    @Test func dueKeepsInnerOrderInRevokedList() throws {
        var wrapper = try Fixture.wrapper(policy: Fixture.policy(late: 10 * 1_000_000_000))
        let context = try Fixture.context()
        for step in [4, 2, 5, 1, 3] {
            try Fixture.admit(&wrapper, Fixture.timed(Fixture.tag(after: Int64(step)), Int32(step)), context)
        }
        let released = try wrapper.due(now: Fixture.host(5 * Fixture.second), live: [])
        #expect(Fixture.payloads(released.revoked) == [1, 2, 3, 4, 5])
        #expect(released.dispatch.isEmpty && released.refusedWithContext.isEmpty)
    }

    @Test func dueKeepsInnerOrderInRefusedList() throws {
        var wrapper = try Fixture.wrapper()
        let context = try Fixture.context()
        for step in [4, 2, 5, 1, 3] {
            try Fixture.admit(&wrapper, Fixture.timed(Fixture.tag(after: Int64(step)), Int32(step)), context)
        }
        let released = try wrapper.due(now: Fixture.host(30 * Fixture.second), live: [context])
        #expect(Fixture.values(released.refusedWithContext.flatMap(\.refused.batch.messages)) == [1, 2, 3, 4, 5])
        #expect(released.dispatch.isEmpty && released.revoked.isEmpty)
    }

    @Test func dueGivesTheSameResultForTheSameBatchesAdmittedInEitherOrder() throws {
        let contexts = try Fixture.peers(3)
        let policy = try Fixture.policy(late: 6_500_000_000)
        let steps = Array(1...12)
        for order in [steps, steps.reversed()] {
            var wrapper = try Fixture.wrapper(policy: policy)
            for step in order {
                let packet = try Fixture.timed(Fixture.tag(after: Int64(step)), Int32(step))
                try Fixture.admit(&wrapper, packet, contexts[step % 3])
            }
            // At 12 s a bundle is released when it opened at most 6.5 s ago: batches 6 through 12. Context 0 is live.
            let released = try wrapper.due(now: Fixture.host(12 * Fixture.second), live: [contexts[0]])
            let refusedPayloads = Fixture.values(released.refusedWithContext.flatMap(\.refused.batch.messages))
            #expect(Fixture.payloads(released.dispatch) == [6, 9, 12], "\(order)")
            #expect(Fixture.payloads(released.revoked) == [7, 8, 10, 11], "\(order)")
            #expect(refusedPayloads == [1, 2, 3, 4, 5], "\(order)")
            #expect(released.dispatch.map(\.context) == Array(repeating: contexts[0], count: 3), "\(order)")
            #expect(released.revoked.map(\.context) == [1, 2, 1, 2].map { contexts[$0] }, "\(order)")
            #expect(released.refusedWithContext.map(\.context) == [1, 2, 0, 1, 2].map { contexts[$0] }, "\(order)")
            #expect(wrapper.taggedBatchCount == 0 && wrapper.contextCount == 0, "\(order)")
        }
    }

    // MARK: Source scan

    private static let sourceFiles: [(name: String, declaration: String)] = [
        ("OpenSoundControl+ReceiveContext.swift", "struct ReceiveContext"),
        ("OpenSoundControl+ContextScheduler.swift", "struct ContextScheduler"),
        ("OpenSoundControl+ContextRefusal.swift", "enum ContextRefusal")
    ]

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = ["../Shared/OSC/Connections", "../../Sources/FluxKlang/Shared/OSC/Connections"]
        let marker = "OpenSoundControl+ReceiveContext.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    /// Whether `sourceDirectory()` finds the sources from the path this file was compiled at.
    private static let sourcesAreReachable = sourceDirectory() != nil

    private static func sourceText(_ name: String) throws -> String {
        let directory = try #require(sourceDirectory(), "the OSC connection sources are not next to the tests")
        return try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private static func isLower(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) }

    private static func isUpper(_ scalar: Unicode.Scalar) -> Bool { ("A"..."Z").contains(scalar) }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        isLower(scalar) || isUpper(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
    }

    /// Whether a camelCase part starts at `index`: a capital after a lowercase letter, or the last capital of an
    /// acronym when a lowercase letter follows it (the `A` of `IPAddress`).
    private static func startsPart(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index > 0, isUpper(scalars[index]) else { return false }
        if isLower(scalars[index - 1]) { return true }
        return isUpper(scalars[index - 1]) && index + 1 < scalars.count && isLower(scalars[index + 1])
    }

    /// The lowercased camelCase parts of `word`: `peerIP` gives `peer`, `ip`; `IPAddress` gives `ip`, `address`.
    private static func parts(of word: String) -> [String] {
        let scalars = Array(word.unicodeScalars)
        var parts = [""]
        for (index, scalar) in scalars.enumerated() {
            let isLetter = isLower(scalar) || isUpper(scalar)
            if !isLetter || startsPart(scalars, at: index) { parts.append("") }
            if isLetter { parts[parts.count - 1].unicodeScalars.append(scalar) }
        }
        return parts.filter { !$0.isEmpty }.map { $0.lowercased() }
    }

    private static func isBanned(_ word: String) -> Bool {
        let lowered = word.lowercased()
        return lowered.contains("trusted") || lowered.contains("authenticated") || parts(of: word).contains("ip")
    }

    private static func code(of text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }

    /// The distinct banned words of the code of `text` (comments left out), in first-seen order.
    private static func findings(in text: String) -> [String] {
        let words = code(of: text).unicodeScalars.split(whereSeparator: { !isWordScalar($0) }).map { String($0) }
        var found: [String] = []
        for word in words where isBanned(word) && !found.contains(word) {
            found.append(word)
        }
        return found
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the OSC connection sources are not next to the tests"))
    func contextSourcesNameNothingTrustedAuthenticatedOrIP() throws {
        for source in Self.sourceFiles {
            let text = try Self.sourceText(source.name)
            #expect(text.contains(source.declaration), "\(source.name)")
            #expect(Self.findings(in: text) == [], "\(source.name)")
        }
    }

    @Test(.enabled(if: Self.sourcesAreReachable, "the OSC connection sources are not next to the tests"))
    func contextSourcesStateThatIPAllowlistsAreNotAuthentication() throws {
        let sentence = "IP allowlists are not authentication"
        for name in ["OpenSoundControl+ReceiveContext.swift", "OpenSoundControl+ContextScheduler.swift"] {
            #expect(try Self.sourceText(name).contains(sentence), "\(name)")
        }
    }

    @Test func sourceScannerFlagsTheNamesItBans() {
        let banned = [
            "trusted", "isTrusted", "trustedPeer", "authenticated", "isAuthenticated", "ip", "IP", "peerIP",
            "ipAddress", "IPAddress", "ip_address", "hostIP4"
        ]
        for name in banned {
            #expect(Self.findings(in: "var \(name): Bool") == [name], "\(name)")
        }
        #expect(Self.findings(in: "let ip = 1\nlet ip = 2\nvar trusted = ip") == ["ip", "trusted"])
    }

    @Test func sourceScannerIgnoresCommentsAndOrdinaryWords() {
        let clean = [
            "// var trusted = IP", "/// IP allowlists are not authentication.", "let count = 1 // isAuthenticated",
            "skipped tripod scripts description relationship authentication authenticating pipeline equipment"
        ]
        for text in clean {
            #expect(Self.findings(in: text).isEmpty, "\(text)")
        }
    }
}
