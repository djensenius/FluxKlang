//
//  WiringImpactTests.swift
//  FluxKlangTests
//
//  The wiring edit impact preview (#101 WPV1): each gesture's rows, the problems it introduces and resolves, the
//  fixed summary, and every refusal in its documented order with the composer's own refusal passed through
//  unchanged. This root file holds the shared fixtures and the gesture, refusal and problem checks; the goldens,
//  limits and source scan are in the Golden extension.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture

@Suite("Wiring edit impact preview", .productionAccessAudit)
struct WiringImpactTests {
    static let draftID = DraftID(validated: "dft.impact")
    static let verb = NodeID(validated: "nod.verb")
    static let keys = NodeID(validated: "nod.keys")

    static func draft(_ edits: [GraphEdit] = [], on graph: GraphDocument = Fixture.graph) -> DraftEdits {
        DraftEdits(id: draftID, graph: graph.id, baseRevision: graph.revision, edits: edits)
    }

    static func nodeID(_ raw: String) -> NodeID { Fixture.id(raw) }

    static func edgeID(_ raw: String) -> EdgeID { Fixture.id(raw) }

    static func node(_ raw: String, ports: [GraphPort]? = nil) -> GraphNode {
        Fixture.node(raw, ports: ports ?? [Fixture.audio("out", .output, 2)], at: 9)
    }

    static func gainNode(_ raw: String) -> GraphNode {
        Fixture.node(raw, .audioGain, ports: [Fixture.audio("in", .input, 2), Fixture.audio("out", .output, 2)], at: 9)
    }

    static func ports(_ count: Int) -> [GraphPort] {
        (0..<count).map { Fixture.audio("p" + padded($0), .output, 1) }
    }

    static func padded(_ value: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, 5 - digits.count)) + digits
    }

    static func wire(_ id: String, _ from: String, _ to: String) -> GraphEdge {
        Fixture.edge(id, Fixture.address(from, "out"), Fixture.address(to, "in"))
    }

    static func largeName(_ index: Int) -> String {
        if index == 0 { return "nod.a" }
        if index == 1 { return "nod.b" }
        return "nod.n" + padded(index)
    }

    /// `nodes` nodes (the first two are nod.a and nod.b) and `edges` edges from nod.a to nod.b.
    static func large(nodes: Int, edges: Int) -> GraphDocument {
        let list = (0..<nodes).map { node(largeName($0), ports: []) }
        let wires = (0..<edges).map { wire("edg." + padded($0), "nod.a", "nod.b") }
        return GraphDocument(id: Fixture.graphID, nodes: list, edges: wires)
    }

    static func disconnecting(_ count: Int, in graph: GraphDocument) -> DraftEdits {
        draft(graph.edges.prefix(count).map { GraphEdit.disconnect($0.id) }, on: graph)
    }

    /// A draft based on revision 7 against an active graph at revision 3, so the preview refuses it.
    static func stale(_ base: GraphDocument = Fixture.graph) throws -> (draft: DraftEdits, active: GraphDocument) {
        var active = base
        active.revision = try ContractRevision(3)
        var stale = draft(on: active)
        stale.baseRevision = try ContractRevision(7)
        return (stale, active)
    }

    static func mismatch() throws -> WiringPreviewRefusal {
        .draftBaseMismatch(draft: try ContractRevision(7), active: try ContractRevision(3))
    }

    /// The graph whose required features list is wrong, so validation stops before it checks any wire.
    static var uncheckableGraph: GraphDocument {
        var graph = Fixture.graph
        graph.requiredFeatures = ["audioGain.constant.v1"]
        return graph
    }

    static let uncheckableError = GraphValidationError.invalidRequiredFeatures(["audioGain.constant.v1"])

    static func impact(
        _ gesture: WiringImpactGesture, _ edits: [GraphEdit] = [], on graph: GraphDocument = Fixture.graph
    ) throws -> WiringImpact {
        try WiringImpact.make(gesture, draft: draft(edits, on: graph), active: graph)
    }

    static func refusal(
        _ gesture: WiringImpactGesture, draft: DraftEdits, active: GraphDocument = Fixture.graph
    ) -> WiringImpactRefusal? {
        do {
            _ = try WiringImpact.make(gesture, draft: draft, active: active)
            return nil
        } catch {
            return error
        }
    }

    static func request(_ edge: String, _ from: (String, String), _ to: (String, String)) -> WiringConnectRequest {
        WiringConnectRequest(
            edge: edgeID(edge), from: Fixture.address(from.0, from.1), to: Fixture.address(to.0, to.1)
        )
    }

    static func kinds(_ impact: WiringImpact) -> [WiringReviewChangeKind] { impact.rows.map(\.change.kind) }

    static func effects(_ impact: WiringImpact) -> [WiringImpactEffect] { impact.rows.map(\.effect) }

    /// A graph of stereo nodes a, b and c wired a<->b and b<->c, with no feedback: one cycle of all three.
    static func cycleGraph() -> GraphDocument {
        let nodes = [Fixture.stereo("nod.a", at: 1), Fixture.stereo("nod.b", at: 2), Fixture.stereo("nod.c", at: 3)]
        let edges = [
            wire("edg.ab", "nod.a", "nod.b"), wire("edg.ba", "nod.b", "nod.a"),
            wire("edg.bc", "nod.b", "nod.c"), wire("edg.cb", "nod.c", "nod.b")
        ]
        return GraphDocument(id: Fixture.graphID, nodes: nodes, edges: edges)
    }

    /// A graph with one wire between a mono output and a stereo input: one channel mismatch.
    static func mismatchGraph() -> GraphDocument {
        let source = Fixture.node("nod.mono", ports: [Fixture.audio("out", .output, 1)], at: 1)
        let sink = Fixture.stereo("nod.sink", at: 2)
        let edges = [wire("edg.bad", "nod.mono", "nod.sink")]
        return GraphDocument(id: Fixture.graphID, nodes: [source, sink], edges: edges)
    }

    // MARK: Gestures

    @Test func impactNoneIsAnEmptyImpactWithTheDraftUnchanged() throws {
        let start = Self.draft([.disconnect(Self.edgeID("edg.keys-verb"))])
        let result = try WiringImpact.make(.none, draft: start, active: Fixture.graph)
        #expect(result.after == start)
        #expect(result.rows.isEmpty)
        #expect(result.introduced.isEmpty)
        #expect(result.resolved.isEmpty)
        #expect(result.isEmpty)
        #expect(result.summary == "No change. No new problems.")
    }

    @Test func impactConnectAddsOneWireRow() throws {
        let request = Self.request("edg.keys-echo", ("nod.keys", "out"), ("nod.echo", "in"))
        let result = try Self.impact(.connect(request))
        #expect(Self.kinds(result) == [.addedEdge])
        #expect(Self.effects(result) == [.added])
        #expect(result.rows.first?.change.sortID == "edg.keys-echo")
        #expect(result.rows.first?.previous == nil)
        #expect(result.summary == "This edit adds 1 wire. No new problems.")
        #expect(result.after == (try WiringDraftComposer.compose(request, into: Self.draft(), active: Fixture.graph)))
    }

    @Test func impactRemoveEdgeAddsOneRemovedWireRow() throws {
        let result = try Self.impact(.removeEdge(Self.edgeID("edg.keys-verb")))
        #expect(Self.kinds(result) == [.removedEdge])
        #expect(Self.effects(result) == [.added])
        #expect(result.summary == "This edit removes 1 wire. No new problems.")
        #expect(!result.isEmpty)
    }

    @Test func impactRestoreEdgeCancelsTheEarlierRemoval() throws {
        let removed = [GraphEdit.disconnect(Self.edgeID("edg.keys-verb"))]
        let result = try Self.impact(.restoreEdge(Self.edgeID("edg.keys-verb")), removed)
        #expect(Self.kinds(result) == [.removedEdge])
        #expect(Self.effects(result) == [.cancelled])
        #expect(result.after.edits.isEmpty)
        #expect(result.summary == "Cancels 1 earlier change. No new problems.")
    }

    @Test func impactMoveNodeAddsOneMovedRowAndMovingBackCancelsIt() throws {
        let moved = try Self.impact(.moveNode(Self.keys, x: 1, y: 5))
        #expect(Self.kinds(moved) == [.movedNode])
        #expect(Self.effects(moved) == [.added])
        #expect(moved.summary == "This edit moves 1 node. No new problems.")
        let back = try WiringImpact.make(
            .moveNode(Self.keys, x: 1, y: 0), draft: moved.after, active: Fixture.graph
        )
        #expect(Self.kinds(back) == [.movedNode])
        #expect(Self.effects(back) == [.cancelled])
        #expect(back.after.edits.isEmpty)
    }

    @Test func impactMoveNodeAgainRevisesTheEarlierRowWithItsPreviousContent() throws {
        let first = try Self.impact(.moveNode(Self.keys, x: 1, y: 5))
        let second = try WiringImpact.make(
            .moveNode(Self.keys, x: 1, y: 9), draft: first.after, active: Fixture.graph
        )
        #expect(Self.effects(second) == [.revised])
        #expect(second.rows.first?.previous == first.rows.first?.change)
        #expect(second.rows.first?.change != first.rows.first?.change)
        #expect(second.summary == "Revises 1 earlier change. No new problems.")
    }

    @Test func impactAddNodeAddsOneNodeRow() throws {
        let node = Self.node("nod.new")
        let result = try Self.impact(.addNode(node))
        #expect(Self.kinds(result) == [.addedNode])
        #expect(Self.effects(result) == [.added])
        #expect(result.summary == "This edit adds 1 node. No new problems.")
        #expect(result.after.edits == [.addNode(node)])
    }

    @Test func impactRemoveNodeRemovesTheNodeAndEveryAttachedWire() throws {
        let result = try Self.impact(.removeNode(Self.verb))
        #expect(Self.kinds(result) == [.removedNode] + Array(repeating: .removedEdge, count: 6))
        #expect(Set(Self.effects(result)) == [.added])
        #expect(result.summary == "This edit removes 1 node and removes 6 wires. No new problems.")
    }

    @Test func impactRemoveNodeThatTheDraftAddedCancelsTheAddition() throws {
        let node = Self.node("nod.new")
        let added = try Self.impact(.addNode(node))
        let result = try WiringImpact.make(.removeNode(node.id), draft: added.after, active: Fixture.graph)
        #expect(Self.kinds(result) == [.addedNode])
        #expect(Self.effects(result) == [.cancelled])
        #expect(result.after.edits.isEmpty)
        #expect(result.summary == "Cancels 1 earlier change. No new problems.")
    }

    @Test func impactRowsAreSortedByKindThenIDBytes() throws {
        let start = Self.draft([.addNode(Self.node("nod.zeta"))])
        let result = try WiringImpact.make(.removeNode(Self.verb), draft: start, active: Fixture.graph)
        let order = result.rows.map(\.change.kind.rawValue)
        #expect(order == [2, 4, 4, 4, 4, 4, 4])
        let wires = result.rows.dropFirst().map(\.change.sortID)
        let expected = [
            "edg.delay-verb-fb", "edg.echo-verb", "edg.keys-verb", "edg.mic-verb", "edg.verb-delay", "edg.verb-mains"
        ]
        #expect(wires == expected)
    }

    @Test func impactAGestureThatChangesNothingIsAnEmptyImpact() throws {
        let result = try Self.impact(.moveNode(Self.keys, x: 1, y: 0))
        #expect(result.rows.isEmpty)
        #expect(result.isEmpty)
        #expect(result.summary == "No change. No new problems.")
    }

    // MARK: Refusals

    @Test func impactRefusesAStaleDraftBeforeAnythingElse() throws {
        let (stale, active) = try Self.stale()
        let expected = WiringImpactRefusal.preview(try Self.mismatch())
        #expect(Self.refusal(.removeNode(Self.nodeID("nod.never")), draft: stale, active: active) == expected)
        #expect(Self.refusal(.none, draft: stale, active: active) == expected)
        let (staleBad, activeBad) = try Self.stale(Self.uncheckableGraph)
        #expect(Self.refusal(.none, draft: staleBad, active: activeBad) == expected)
        #expect(Self.refusal(.removeEdge(Self.edgeID("edg.never")), draft: staleBad, active: activeBad) == expected)
    }

    @Test func impactRefusesAnUncheckableBaselineBeforeTheComposerRefuses() {
        let active = Self.uncheckableGraph
        let expected = WiringImpactRefusal.baselineUncheckable(Self.uncheckableError)
        #expect(Self.refusal(.none, draft: Self.draft(on: active), active: active) == expected)
        let unknown = Self.refusal(.removeEdge(Self.edgeID("edg.never")), draft: Self.draft(on: active), active: active)
        #expect(unknown == expected)
        let plain = Self.refusal(.addNode(Self.node("nod.plain")), draft: Self.draft(on: active), active: active)
        #expect(plain == expected)
    }

    @Test func impactRefusesAResultTheValidationCannotCheckAfterTheComposerAccepted() throws {
        let gain = Self.gainNode("nod.gain")
        let refused = Self.refusal(.addNode(gain), draft: Self.draft())
        let expected = GraphValidationError.invalidRequiredFeatures([])
        #expect(refused == .resultUncheckable(expected))
    }

    @Test func impactPassesTheComposersOwnRefusalThroughUnchanged() throws {
        let missing = Self.edgeID("edg.never")
        #expect(Self.refusal(.removeEdge(missing), draft: Self.draft()) == .edit(.unknownEdge(missing)))
        #expect(Self.refusal(.restoreEdge(missing), draft: Self.draft()) == .edit(.unknownEdge(missing)))
        let never = Self.nodeID("nod.never")
        #expect(Self.refusal(.moveNode(never, x: 1, y: 1), draft: Self.draft()) == .edit(.unknownNode(never)))
        #expect(Self.refusal(.removeNode(never), draft: Self.draft()) == .node(.unknownNode(never)))
        let echo = Self.nodeID("nod.echo")
        #expect(Self.refusal(.addNode(Self.node("nod.echo")), draft: Self.draft()) == .node(.nodeAlreadyPresent(echo)))
        let present = Self.edgeID("edg.keys-verb")
        #expect(Self.refusal(.restoreEdge(present), draft: Self.draft()) == .edit(.notInDraftOrActive(present)))
        let request = Self.request("edg.dup", ("nod.keys", "out"), ("nod.verb", "in"))
        #expect(Self.refusal(.connect(request), draft: Self.draft()) == .compose(.existing(present)))
    }

    // MARK: Problems

    @Test func impactResolvesTheProblemOfAnEdgeTheGestureRemoves() throws {
        let active = Self.mismatchGraph()
        let result = try Self.impact(.removeEdge(Self.edgeID("edg.bad")), on: active)
        #expect(result.introduced.isEmpty)
        #expect(result.resolved.map(\.code) == ["channelMismatch"])
        #expect(result.resolved.first?.stableKey == "channelMismatch\u{0}edge:edg.bad\u{0}1 to 2")
        #expect(result.resolved.first?.sentence == "Wire edg.bad: channel mismatch 1 to 2.")
        #expect(result.summary == "This edit removes 1 wire. No new problems. Resolves 1 problem.")
    }

    @Test func impactIntroducesTheProblemOfAnEdgeTheGestureRestores() throws {
        let active = Self.mismatchGraph()
        let removed = [GraphEdit.disconnect(Self.edgeID("edg.bad"))]
        let result = try Self.impact(.restoreEdge(Self.edgeID("edg.bad")), removed, on: active)
        #expect(result.resolved.isEmpty)
        #expect(result.introduced.map(\.code) == ["channelMismatch"])
        #expect(result.summary == "Cancels 1 earlier change. 1 new problem.")
    }

    @Test func impactDoesNotCountAProblemTheDraftAlreadyHadAsIntroduced() throws {
        let active = Self.mismatchGraph()
        let result = try Self.impact(.moveNode(Self.nodeID("nod.sink"), x: 4, y: 4), on: active)
        #expect(result.introduced.isEmpty)
        #expect(result.resolved.isEmpty)
        #expect(result.summary == "This edit moves 1 node. No new problems.")
    }

    @Test func impactCycleMembershipChangeResolvesOneProblemAndIntroducesAnother() throws {
        let active = Self.cycleGraph()
        let result = try Self.impact(.removeNode(Self.nodeID("nod.c")), on: active)
        #expect(result.resolved.map(\.stableKey) == ["cycleWithoutFeedback\u{0}nodes:nod.a,nod.b,nod.c\u{0}"])
        #expect(result.introduced.map(\.stableKey) == ["cycleWithoutFeedback\u{0}nodes:nod.a,nod.b\u{0}"])
        #expect(result.introduced.first?.sentence == "Cycle nod.a nod.b: cycle without feedback.")
        #expect(result.resolved.first?.sentence == "Cycle nod.a nod.b nod.c: cycle without feedback.")
        #expect(result.summary == "This edit removes 1 node and removes 2 wires. 1 new problem. Resolves 1 problem.")
    }

    @Test func impactProblemOfAUncheckableErrorHasTheGraphPrefixAndScope() {
        let classification = WiringInspectorProblem.classify(Self.uncheckableError)
        let problem = WiringImpactProblems.problem(classification)
        #expect(problem.stableKey.hasPrefix("invalidRequiredFeatures\u{0}uncheckable\u{0}"))
        #expect(problem.sentence.hasPrefix("Graph: "))
    }

    @Test func impactIntroducesTheProblemOfANodeTheGestureAdds() throws {
        var node = Self.node("nod.new")
        node.requiredCapabilities = [CapabilityID(validated: "cap.unknown")]
        let result = try Self.impact(.addNode(node))
        #expect(result.resolved.isEmpty)
        #expect(result.introduced.map(\.stableKey) == ["undefinedCapability\u{0}node:nod.new\u{0}cap.unknown"])
        #expect(result.introduced.first?.sentence == "Node nod.new: undefined capability cap.unknown.")
        #expect(result.summary == "This edit adds 1 node. 1 new problem.")
    }

    @Test func impactSortsProblemsByKeyBytesAndNotByTheOrderOfTheGraph() throws {
        let count = 12
        let sink = Fixture.stereo("nod.sink", at: 100)
        var sources: [GraphNode] = []
        var edges: [GraphEdge] = []
        for slot in 0..<count {
            let scrambled = Self.padded(slot * 5 % count)
            sources.append(Fixture.node("nod.m" + scrambled, ports: [Fixture.audio("out", .output, 1)], at: 1))
            edges.append(Self.wire("edg." + scrambled, "nod.m" + scrambled, "nod.sink"))
        }
        let active = GraphDocument(id: Fixture.graphID, nodes: sources + [sink], edges: edges)
        let result = try Self.impact(.removeNode(Self.nodeID("nod.sink")), on: active)
        let expected = (0..<count).map { "channelMismatch\u{0}edge:edg." + Self.padded($0) + "\u{0}1 to 2" }
        #expect(edges.map(\.id.rawValue) != edges.map(\.id.rawValue).sorted())
        #expect(result.resolved.map(\.stableKey) == expected)
        #expect(result.introduced.isEmpty)
    }

    @Test func impactSortsIntroducedProblemsByKeyBytesAndNotByTheOrderOfTheNode() throws {
        let count = 12
        var node = Self.node("nod.new")
        let names = (0..<count).map { "cap.u" + Self.padded($0 * 5 % count) }
        node.requiredCapabilities = names.compactMap { CapabilityID(rawValue: $0) }
        let result = try Self.impact(.addNode(node))
        let expected = (0..<count).map { "undefinedCapability\u{0}node:nod.new\u{0}cap.u" + Self.padded($0) }
        #expect(node.requiredCapabilities.map(\.rawValue) != node.requiredCapabilities.map(\.rawValue).sorted())
        #expect(result.introduced.map(\.stableKey) == expected)
        #expect(result.resolved.isEmpty)
    }

    @Test func impactLeavesOutTheRowsTheGestureDidNotTouch() throws {
        let removed = [GraphEdit.disconnect(Self.edgeID("edg.keys-verb"))]
        let result = try Self.impact(.moveNode(Self.keys, x: 1, y: 5), removed)
        #expect(Self.kinds(result) == [.movedNode])
        #expect(result.after.edits.count == 2)
    }

    @Test func impactNoneOnADraftThatAlreadyHasAProblemReportsNothingNew() throws {
        let active = Self.mismatchGraph()
        let result = try Self.impact(.none, on: active)
        #expect(result.after == Self.draft(on: active))
        #expect(result.introduced.isEmpty)
        #expect(result.resolved.isEmpty)
        #expect(result.isEmpty)
        #expect(result.summary == "No change. No new problems.")
    }

    @Test func impactProblemOfAGraphLevelErrorHasTheGraphScopeAndPrefix() {
        let duplicate = GraphValidationError.duplicateCapability(CapabilityID(validated: "cap.dup"))
        let problem = WiringImpactProblems.problem(WiringInspectorProblem.classify(duplicate))
        #expect(problem.stableKey == "duplicateCapability\u{0}graph\u{0}cap.dup")
        #expect(problem.sentence.hasPrefix("Graph: "))
    }
}
