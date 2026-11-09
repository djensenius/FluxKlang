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

    // MARK: NaN-stable rows

    private static func point(_ horizontal: Double, _ vertical: Double, bag: [String: JSONValue]? = nil) -> GraphPoint {
        var value = GraphPoint(x: horizontal, y: vertical)
        value.extensions = bag
        return value
    }

    private static func moved(from: GraphPoint?, to: GraphPoint?) -> WiringReviewChange {
        .movedNode(keys, from: from, to: to)
    }

    private static func delta(_ before: WiringReviewChange, _ after: WiringReviewChange) -> [WiringImpactRow] {
        WiringImpactRowDelta.rows(before: [before], after: [after])
    }

    private static func placing(_ node: NodeID, at position: GraphPoint, in graph: GraphDocument) -> GraphDocument {
        var placed = graph
        placed.nodes = graph.nodes.map { entry in
            var copy = entry
            if entry.id == node { copy.position = position }
            return copy
        }
        return placed
    }

    private static func nanFeedbackGraph() -> GraphDocument {
        var graph = Fixture.graph
        graph.edges = graph.edges.map { edge in
            var copy = edge
            if edge.id == edgeID("edg.delay-verb-fb") {
                copy.feedback = EdgeFeedback(delayBlocks: 1, gainCeilingDb: .nan)
            }
            return copy
        }
        return graph
    }

    private static let noOpMove = WiringImpactGesture.moveNode(verb, x: 4, y: 0)

    // The first three no-op tests below put the NaN in the ACTIVE graph, the case a caller can reach, because
    // WiringImpact.make takes the active graph as given. The later tests that put a NaN into the DRAFT (the added
    // node and moved row, the added node moved off NaN, the moved row moved off NaN, and the added edge) build the
    // draft value directly: a draft from the history fold (DraftEditFold) refuses a NaN position or edge gain.

    @Test func impactNoOpMoveAfterDisconnectingAnEdgeWithANaNGainIsAnEmptyImpact() throws {
        let active = Self.nanFeedbackGraph()
        let start = Self.draft([.disconnect(Self.edgeID("edg.delay-verb-fb"))], on: active)
        let result = try WiringImpact.make(Self.noOpMove, draft: start, active: active)
        #expect(result.rows.isEmpty)
        #expect(result.isEmpty)
        #expect(result.summary == "No change. No new problems.")
    }

    @Test func impactNoOpMoveWithARemovedNodeOfANaNGainIsAnEmptyImpact() throws {
        var gain = Self.gainNode("nod.gain")
        gain.linearGain = .nan
        let active = Fixture.with([], nodes: [gain])
        let start = Self.draft([.removeNode(gain.id)], on: active)
        let result = try WiringImpact.make(Self.noOpMove, draft: start, active: active)
        #expect(result.rows.isEmpty)
        #expect(result.isEmpty)
    }

    @Test func impactNoOpMoveWithAMovedRowFromANaNPositionIsAnEmptyImpact() throws {
        let active = Self.placing(Self.keys, at: Self.point(.nan, 0), in: Fixture.graph)
        let start = Self.draft([.moveNode(Self.keys, to: Self.point(5, 0))], on: active)
        let result = try WiringImpact.make(Self.noOpMove, draft: start, active: active)
        #expect(result.rows.isEmpty)
        #expect(result.isEmpty)
    }

    @Test func impactNoOpMoveWithAnAddedNodeAndAMovedRowAtANaNPositionIsAnEmptyImpact() throws {
        var added = Self.node("nod.new")
        added.position = Self.point(.nan, .nan)
        let edits: [GraphEdit] = [.addNode(added), .moveNode(Self.keys, to: Self.point(.nan, 0))]
        let start = Self.draft(edits)
        let result = try WiringImpact.make(Self.noOpMove, draft: start, active: Fixture.graph)
        #expect(result.rows.isEmpty)
        #expect(result.isEmpty)
    }

    @Test func impactMovingAnAddedNodeOffANaNPositionRevisesItsRow() throws {
        var added = Self.node("nod.new")
        added.position = Self.point(.nan, 0)
        let start = Self.draft([.addNode(added)])
        let result = try WiringImpact.make(.moveNode(added.id, x: 3, y: 0), draft: start, active: Fixture.graph)
        #expect(Self.kinds(result) == [.addedNode])
        #expect(Self.effects(result) == [.revised])
    }

    @Test func impactMovingARowOffANaNPositionRevisesIt() throws {
        let start = Self.draft([.moveNode(Self.keys, to: Self.point(.nan, 0))])
        let result = try WiringImpact.make(.moveNode(Self.keys, x: 3, y: 0), draft: start, active: Fixture.graph)
        #expect(Self.effects(result) == [.revised])
        #expect(result.summary == "Revises 1 earlier change. No new problems. Resolves 1 problem.")
    }

    @Test func impactRowDeltaRevisesAMoveFromFiniteToNaNAndFromNaNToFinite() {
        let finite = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0))
        let broken = Self.moved(from: Self.point(1, 0), to: Self.point(.nan, 0))
        let towards = Self.delta(finite, broken)
        let back = Self.delta(broken, finite)
        #expect(towards.map(\.effect) == [.revised])
        #expect(back.map(\.effect) == [.revised])
    }

    @Test func impactRowDeltaRevisesAMoveWhenOnlyTheFromPositionDiffers() {
        let first = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0))
        let second = Self.moved(from: Self.point(2, 0), to: Self.point(5, 0))
        #expect(Self.delta(first, second).map(\.effect) == [.revised])
    }

    @Test func impactRowDeltaRevisesAMoveWhenOnlyTheYCoordinateDiffers() {
        let first = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0))
        let second = Self.moved(from: Self.point(1, 0), to: Self.point(5, 1))
        #expect(Self.delta(first, second).map(\.effect) == [.revised])
    }

    @Test func impactRowDeltaReadsPlusZeroAndMinusZeroAsTheSamePosition() {
        let plus = Self.moved(from: Self.point(0.0, 0.0), to: Self.point(5, 0.0))
        let minus = Self.moved(from: Self.point(-0.0, -0.0), to: Self.point(5, -0.0))
        #expect(Self.delta(plus, minus).isEmpty)
    }

    @Test func impactRowDeltaRevisesAMoveFromAPositionToNoPositionAndReadsTwoNoneAsTheSame() {
        let placed = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0))
        let unplaced = Self.moved(from: Self.point(1, 0), to: nil)
        #expect(Self.delta(placed, unplaced).map(\.effect) == [.revised])
        #expect(Self.delta(unplaced, unplaced).isEmpty)
    }

    @Test func impactRowDeltaReadsANaNInAPositionBagAsTheSameValue() {
        let bag: [String: JSONValue] = ["a": .double(.nan), "b": .array([.double(.nan), .int(1)])]
        let nested: [String: JSONValue] = ["c": .object(["d": .double(.nan)])]
        let row = Self.moved(from: Self.point(1, 0, bag: bag), to: Self.point(5, 0, bag: nested))
        #expect(Self.delta(row, row).isEmpty)
    }

    private static func nestedBag(_ value: Double) -> [String: JSONValue] {
        ["c": .object(["d": .double(value)])]
    }

    @Test func impactRowDeltaReadsANaNInANestedObjectAsTheSameValueAndAFiniteOneAsRevised() {
        let first = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0, bag: Self.nestedBag(.nan)))
        let same = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0, bag: Self.nestedBag(.nan)))
        let other = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0, bag: Self.nestedBag(1)))
        #expect(Self.delta(first, same).isEmpty)
        #expect(Self.delta(first, other).map(\.effect) == [.revised])
    }

    @Test func impactRowDeltaRevisesAPositionWhoseBagDiffers() {
        let first = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0, bag: ["a": .int(1)]))
        let second = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0, bag: ["a": .int(2)]))
        #expect(Self.delta(first, second).map(\.effect) == [.revised])
    }

    @Test func impactRowDeltaRevisesAPositionWhoseBagHasAnExtraKey() {
        let first = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0, bag: ["a": .double(.nan)]))
        let second = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0, bag: ["a": .double(.nan), "b": .int(1)]))
        #expect(Self.delta(first, second).map(\.effect) == [.revised])
    }

    @Test func impactNoOpMoveKeepsAnAddedEdgeWithANaNGainOutOfTheRows() throws {
        let feedback = EdgeFeedback(delayBlocks: 1, gainCeilingDb: .nan)
        let edge = Fixture.edge(
            "edg.keys-echo", Fixture.address("nod.keys", "out"), Fixture.address("nod.echo", "in"), feedback: feedback
        )
        let start = Self.draft([.connect(edge)])
        let result = try WiringImpact.make(Self.noOpMove, draft: start, active: Fixture.graph)
        #expect(result.rows.isEmpty)
        #expect(result.isEmpty)
    }

    @Test func impactRowDeltaReadsANaNInThePositionUnknownFieldsAsTheSameValue() {
        var first = Self.point(5, 0)
        first.unknownFields = ["u": .double(.nan)]
        var second = Self.point(5, 0)
        second.unknownFields = ["u": .double(.nan)]
        let before = Self.moved(from: Self.point(1, 0), to: first)
        let after = Self.moved(from: Self.point(1, 0), to: second)
        #expect(Self.delta(before, after).isEmpty)
    }

    @Test func impactRowDeltaRevisesTwoBagsOfOneSizeWithDifferentKeys() {
        let first = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0, bag: ["a": .int(1)]))
        let second = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0, bag: ["b": .int(1)]))
        #expect(Self.delta(first, second).map(\.effect) == [.revised])
    }

    @Test func impactRowDeltaRevisesAPositionWhoseUnknownFieldsDiffer() {
        var other = Self.point(5, 0)
        other.unknownFields = ["u": .int(1)]
        let first = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0))
        let second = Self.moved(from: Self.point(1, 0), to: other)
        #expect(Self.delta(first, second).map(\.effect) == [.revised])
    }

    @Test func impactRowDeltaRevisesAPositionWhoseBagIsAbsentOnOneSideOnly() {
        let first = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0))
        let second = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0, bag: [:]))
        #expect(Self.delta(first, second).map(\.effect) == [.revised])
    }

    @Test func impactRowDeltaRevisesAnArrayWithAnExtraElement() {
        let short: [String: JSONValue] = ["a": .array([.double(.nan)])]
        let long: [String: JSONValue] = ["a": .array([.double(.nan), .int(1)])]
        let first = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0, bag: short))
        let second = Self.moved(from: Self.point(1, 0), to: Self.point(5, 0, bag: long))
        #expect(Self.delta(first, second).map(\.effect) == [.revised])
    }

    private static func row(_ bag: [String: JSONValue]) -> WiringReviewChange {
        moved(from: point(1, 0), to: point(5, 0, bag: bag))
    }

    private static func layered(_ leaf: Double) -> [String: JSONValue] {
        ["k": .array([.object(["m": .array([.double(leaf)])])])]
    }

    @Test func impactRowDeltaRevisesArraysThatDifferOnlyInTheLastElement() {
        let first = Self.row(["a": .array([.int(1), .int(2), .int(3)])])
        let second = Self.row(["a": .array([.int(1), .int(2), .int(4)])])
        #expect(Self.delta(first, second).map(\.effect) == [.revised])
    }

    @Test func impactRowDeltaRevisesAnArrayThatLostItsLastElement() {
        let first = Self.row(["a": .array([.int(1), .int(2), .int(3)])])
        let second = Self.row(["a": .array([.int(1), .int(2)])])
        let effects: [WiringImpactEffect] = Self.delta(first, second).map(\.effect)
        #expect(effects == [.revised])
    }

    @Test func impactRowDeltaRevisesArraysThatDifferOnlyInTheOrderOfTwoUnequalElements() {
        let first = Self.row(["a": .array([.int(1), .int(2)])])
        let second = Self.row(["a": .array([.int(2), .int(1)])])
        #expect(Self.delta(first, second).map(\.effect) == [.revised])
    }

    @Test func impactRowDeltaRevisesObjectsOfOneSizeWhoseValuesDifferAtDepthThree() {
        let first = Self.row(Self.layered(1))
        let second = Self.row(Self.layered(2))
        #expect(Self.delta(first, second).map(\.effect) == [.revised])
    }

    @Test func impactRowDeltaReadsANaNAtDepthThreeOnBothSidesAsUnchanged() {
        let first = Self.row(Self.layered(.nan))
        let second = Self.row(Self.layered(.nan))
        #expect(Self.delta(first, second).isEmpty)
    }

    @Test func impactRowDeltaRevisesANaNAtDepthThreeOnOneSideOnly() {
        let first = Self.row(Self.layered(.nan))
        let second = Self.row(Self.layered(1))
        #expect(Self.delta(first, second).map(\.effect) == [.revised])
    }

    /// A value 100,000 levels deep, built in memory (a decoded one is held to 512 levels). Freeing a value this
    /// deep recurses and would itself overflow the stack, so every deep value lives in a static let and is never
    /// released during the run. The deep tests expect a count and effects, so a failure never prints a deep value.
    private static func deep(_ leaf: Double) -> JSONValue {
        var value = JSONValue.double(leaf)
        for _ in 0..<100_000 { value = .array([value]) }
        return value
    }

    private static let deepNaN = deep(.nan)
    private static let deepNaNTwin = deep(.nan)
    private static let deepOne = deep(1)
    private static let deepTwo = deep(2)

    private static func addedRow(deep value: JSONValue) -> WiringReviewChange {
        var added = node("nod.deep")
        added.position = point(5, 0, bag: ["deep": value])
        return .addedNode(added)
    }

    @Test func impactRowDeltaReadsTwoNaNLeavesAtTheBottomOfDeepValuesAsUnchanged() {
        let first = Self.addedRow(deep: Self.deepNaN)
        let second = Self.addedRow(deep: Self.deepNaNTwin)
        let rowCount: Int = Self.delta(first, second).count
        #expect(rowCount == 0)
    }

    @Test func impactRowDeltaRevisesDeepValuesWhoseBottomLeavesDiffer() {
        let first = Self.addedRow(deep: Self.deepOne)
        let second = Self.addedRow(deep: Self.deepTwo)
        let effects: [WiringImpactEffect] = Self.delta(first, second).map(\.effect)
        #expect(effects == [.revised])
    }
}
