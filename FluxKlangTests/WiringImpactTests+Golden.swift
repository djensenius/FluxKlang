//
//  WiringImpactTests+Golden.swift
//  FluxKlangTests
//
//  The wiring edit impact preview (#101 WPV1): fixed summary goldens, N and N+1 at every bound the composers
//  enforce, the shape of a large graph, and a scan of the shipped source for the quadratic patterns the review
//  forbids inside loops. The shared fixtures are in the root file.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture

extension WiringImpactTests {
    // MARK: Goldens

    @Test func impactGoldenMovedThenRemovedNodeNamesTheCancelledMove() throws {
        let moved = try Self.impact(.moveNode(Self.verb, x: 9, y: 9))
        let result = try WiringImpact.make(.removeNode(Self.verb), draft: moved.after, active: Fixture.graph)
        let expected = "This edit removes 1 node and removes 6 wires. Cancels 1 earlier change. No new problems."
        #expect(result.summary == expected)
        #expect(Self.effects(result).filter { $0 == .cancelled }.count == 1)
    }

    @Test func impactGoldenCancelledRestoreWithAnIntroducedProblemReadsInOneFixedSentence() throws {
        let active = Self.mismatchGraph()
        let removed = [GraphEdit.disconnect(Self.edgeID("edg.bad"))]
        let moved = try Self.impact(.moveNode(Self.nodeID("nod.sink"), x: 4, y: 4), removed, on: active)
        let result = try WiringImpact.make(.restoreEdge(Self.edgeID("edg.bad")), draft: moved.after, active: active)
        #expect(result.summary == "Cancels 1 earlier change. 1 new problem.")
        #expect(result.introduced.map(\.sentence) == ["Wire edg.bad: channel mismatch 1 to 2."])
    }

    @Test func impactSummaryCountsUseTheSingularOnlyForOne() {
        let one = WiringImpactSummary.make(rows: [], introduced: 1, resolved: 1)
        #expect(one == "1 new problem. Resolves 1 problem.")
        let two = WiringImpactSummary.make(rows: [], introduced: 2, resolved: 2)
        #expect(two == "2 new problems. Resolves 2 problems.")
        #expect(WiringImpactSummary.make(rows: [], introduced: 0, resolved: 0) == "No change. No new problems.")
        let resolvedOnly = WiringImpactSummary.make(rows: [], introduced: 0, resolved: 1)
        #expect(resolvedOnly == "No new problems. Resolves 1 problem.")
        #expect(WiringImpactSummary.make(rows: [], introduced: 1, resolved: 0) == "1 new problem.")
    }

    @Test func impactSummaryJoinsThreeKindsWithCommasAndAnAnd() throws {
        let node = Self.node("nod.new")
        var current = try Self.impact(.addNode(node))
        current = try WiringImpact.make(.moveNode(Self.keys, x: 1, y: 5), draft: current.after, active: Fixture.graph)
        current = try WiringImpact.make(
            .removeEdge(Self.edgeID("edg.keys-verb")), draft: current.after, active: Fixture.graph
        )
        let changes = try WiringReviewDiff.make(active: Fixture.graph, draft: current.after).changes
        let rows = WiringImpactRowDelta.rows(before: [], after: changes)
        #expect(rows.count == 3)
        let summary = WiringImpactSummary.make(rows: rows, introduced: 0, resolved: 0)
        #expect(summary == "This edit adds 1 node, moves 1 node and removes 1 wire. No new problems.")
    }

    // MARK: Limits

    @Test func impactAddNodeAcceptsTheNodeThatMakesFourThousandNinetySixAndRefusesTheNext() throws {
        let limit = ProjectGraphLimits.nodes
        let node = Self.node("nod.last", ports: [])
        let below = Self.large(nodes: limit - 1, edges: 0)
        let result = try WiringImpact.make(.addNode(node), draft: Self.draft(on: below), active: below)
        #expect(Self.kinds(result) == [.addedNode])
        let full = Self.large(nodes: limit, edges: 0)
        #expect(Self.refusal(.addNode(node), draft: Self.draft(on: full), active: full) == .node(.tooManyNodes))
    }

    @Test func impactAddNodeAcceptsTheEditThatMakesFourThousandNinetySixAndRefusesTheNext() throws {
        let limit = ProjectGraphLimits.edits
        let active = Self.large(nodes: 3, edges: limit)
        let node = Self.node("nod.last", ports: [])
        let below = Self.disconnecting(limit - 1, in: active)
        let result = try WiringImpact.make(.addNode(node), draft: below, active: active)
        #expect(result.after.edits.count == limit)
        #expect(Self.kinds(result) == [.addedNode])
        let full = Self.disconnecting(limit, in: active)
        #expect(Self.refusal(.addNode(node), draft: full, active: active) == .node(.tooManyEdits))
    }

    @Test func impactRemoveNodeAcceptsFortyNinetyFiveAttachedEdgesAndRefusesFortyNinetySix() throws {
        let limit = ProjectGraphLimits.edits
        let hub = Self.nodeID("nod.a")
        let below = Self.large(nodes: 2, edges: limit - 1)
        let result = try WiringImpact.make(.removeNode(hub), draft: Self.draft(on: below), active: below)
        let rowCount: Int = limit
        #expect(result.rows.count == rowCount)
        // Every edge but the first has a duplicate-wire error, and every edge has two missing-port errors.
        let expected: Int = 12_284
        #expect(result.resolved.count == expected)
        #expect(result.introduced.isEmpty)
        let full = Self.large(nodes: 2, edges: limit)
        #expect(Self.refusal(.removeNode(hub), draft: Self.draft(on: full), active: full) == .node(.tooManyEdits))
    }

    @Test func impactRemoveNodeReportsTheFoldsBoundWhenTheDraftIsFull() throws {
        let limit = ProjectGraphLimits.edits
        let active = Self.large(nodes: 3, edges: limit)
        let lone = Self.nodeID("nod.n00002")
        let below = Self.disconnecting(limit - 1, in: active)
        let result = try WiringImpact.make(.removeNode(lone), draft: below, active: active)
        #expect(result.after.edits.count == limit)
        let bound = ProjectGraphLimitError.exceeded(path: "$.edits", maximum: limit)
        let full = Self.disconnecting(limit, in: active)
        #expect(Self.refusal(.removeNode(lone), draft: full, active: active) == .node(.fold(.bounds(bound))))
    }

    @Test func impactOfALargeGraphKeepsTheShapeOfASmallOne() throws {
        let active = Self.large(nodes: ProjectGraphLimits.nodes, edges: ProjectGraphLimits.edges)
        let result = try WiringImpact.make(
            .moveNode(Self.nodeID("nod.n00002"), x: 3, y: 3), draft: Self.draft(on: active), active: active
        )
        #expect(Self.kinds(result) == [.movedNode])
        #expect(result.introduced.isEmpty)
        #expect(result.resolved.isEmpty)
        #expect(result.summary == "This edit moves 1 node. No new problems.")
    }

    // MARK: Source scan

    private static let loopOnlyBans = [".contains", ".firstIndex", ".first(where", ".first {", ".filter", ".sorted"]
    private static let everywhereBans = ["removeFirst"]

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = ["../Shared/Wiring/Impact", "../../Sources/FluxKlang/Shared/Wiring/Impact"]
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("WiringImpact.swift").path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    private static func codeLines(_ name: String) throws -> [String] {
        let directory = try #require(sourceDirectory(), "the impact sources are not next to the tests")
        let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line)
        }
    }

    /// The lines inside the braces of every `for` or `while` statement, nested loops included.
    private static func loopBodies(_ lines: [String]) -> [String] {
        var body: [String] = []
        var depth = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if depth == 0, trimmed.hasPrefix("for ") || trimmed.hasPrefix("while ") {
                depth = 1
                continue
            }
            guard depth > 0 else { continue }
            body.append(line)
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
        }
        return body
    }

    private static let shippedFiles = [
        "WiringImpact.swift", "WiringImpactGesture.swift", "WiringImpactProblems.swift",
        "WiringImpactRefusal.swift", "WiringImpactRows.swift", "WiringImpactSummary.swift"
    ]

    @Test(.enabled(if: sourcesAreReachable, "the impact sources are not reachable from the compiled test path"))
    func impactSourceHasNoQuadraticPatternInsideALoop() throws {
        var loopLines = 0
        for name in Self.shippedFiles {
            let lines = try Self.codeLines(name)
            let body = Self.loopBodies(lines)
            loopLines += body.count
            for ban in Self.loopOnlyBans {
                let usesInLoop: Bool = body.contains { $0.contains(ban) }
                #expect(!usesInLoop, "\(name) uses \(ban) inside a loop")
            }
            for ban in Self.everywhereBans {
                let uses: Bool = lines.contains { $0.contains(ban) }
                #expect(!uses, "\(name) uses \(ban)")
            }
            let insertsAtAnIndex: Bool = lines.contains { $0.contains("insert(") && $0.contains("at:") }
            #expect(!insertsAtAnIndex, "\(name) inserts at an index")
        }
        #expect(loopLines > 0)
    }
}
