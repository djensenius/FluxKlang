//
//  WiringInspectorTests.swift
//  FluxKlangTests
//
//  The wiring inspector model (#101 WIN1): one node or edge of the draft graph described by facts, the contract
//  diagnostics that concern it and one label. This root file holds the shared fixtures, the refusals and their
//  order, the markers, the four golden tables and the source scan; node facts, edge facts and the diagnostics are
//  extensions. The suite is named WiringInspectorTests, not the issue's WiringEditorTests: that name is left to the
//  later editor slices.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture

@Suite("Wiring inspector", .productionAccessAudit)
struct WiringInspectorTests {
    static let draftID = DraftID(validated: "dft.inspector")

    static func nodeID(_ raw: String) -> NodeID { Fixture.id(raw) }

    static func edgeID(_ raw: String) -> EdgeID { Fixture.id(raw) }

    static func portID(_ raw: String) -> PortID { Fixture.id(raw) }

    static func node(_ raw: String) -> WiringInspectorSubject { .node(nodeID(raw)) }

    static func edge(_ raw: String) -> WiringInspectorSubject { .edge(edgeID(raw)) }

    static func draft(_ edits: [GraphEdit] = [], on graph: GraphDocument = Fixture.graph) -> DraftEdits {
        DraftEdits(id: draftID, graph: graph.id, baseRevision: graph.revision, edits: edits)
    }

    static func inspect(
        _ subject: WiringInspectorSubject, _ edits: [GraphEdit] = [], on graph: GraphDocument = Fixture.graph
    ) throws(WiringInspectorRefusal) -> WiringInspector {
        try WiringInspector.make(subject, draft: draft(edits, on: graph), active: graph)
    }

    /// The fixture graph plus a gain node: its declared required features are then invalid, so the contract's
    /// validation stops before it checks any wire.
    static var uncheckableGraph: GraphDocument {
        var graph = Fixture.graph
        graph.nodes.append(GraphNode(id: nodeID("nod.gain"), kind: .audioGain, label: "Gain", linearGain: 1))
        return graph
    }

    static func wire(_ id: String, from source: (String, String), to destination: (String, String)) -> GraphEdge {
        Fixture.edge(id, Fixture.address(source.0, source.1), Fixture.address(destination.0, destination.1))
    }

    static func wideNode(ports count: Int) -> GraphNode {
        let ports = (0..<count).map { Fixture.audio("p\($0)", .input, 1) }
        return Fixture.node("nod.wide", ports: ports, at: 9)
    }

    // MARK: - Refusals

    @Test func wiringInspectorWrapsADraftForAnotherGraphAsPreviewDraftGraphMismatch() {
        let other = GraphID(validated: "gph.other")
        let draft = DraftEdits(id: Self.draftID, graph: other, baseRevision: Fixture.graph.revision, edits: [])
        let expected = WiringInspectorRefusal.preview(.draftGraphMismatch(draft: other, active: Fixture.graph.id))
        #expect(throws: expected) {
            try WiringInspector.make(Self.node("nod.keys"), draft: draft, active: Fixture.graph)
        }
    }

    @Test func wiringInspectorWrapsADraftOnAnotherRevisionAsPreviewDraftBaseMismatch() throws {
        let later = try ContractRevision(7)
        let draft = DraftEdits(id: Self.draftID, graph: Fixture.graph.id, baseRevision: later, edits: [])
        let expected = WiringInspectorRefusal.preview(.draftBaseMismatch(draft: later, active: .initial))
        #expect(throws: expected) {
            try WiringInspector.make(Self.node("nod.keys"), draft: draft, active: Fixture.graph)
        }
    }

    @Test func wiringInspectorWrapsRepeatedActiveNodeAndEdgeIDsAsPreviewAmbiguousNodeAndEdge() {
        var nodes = Fixture.graph
        nodes.nodes.append(Fixture.graph.nodes[0])
        let ambiguousNode = WiringInspectorRefusal.preview(.ambiguousNode(Self.nodeID("nod.keys")))
        #expect(throws: ambiguousNode) { try Self.inspect(Self.node("nod.verb"), on: nodes) }
        var edges = Fixture.graph
        edges.edges.append(Fixture.graph.edges[0])
        let ambiguousEdge = WiringInspectorRefusal.preview(.ambiguousEdge(Self.edgeID("edg.keys-verb")))
        #expect(throws: ambiguousEdge) { try Self.inspect(Self.edge("edg.verb-mains"), on: edges) }
    }

    @Test func wiringInspectorWrapsADraftThatDoesNotApplyAsPreviewDraftDoesNotApply() {
        let missing = Self.edgeID("edg.none")
        let expected = WiringInspectorRefusal.preview(.draftDoesNotApply(.missingEdge(missing)))
        #expect(throws: expected) { try Self.inspect(Self.node("nod.keys"), [.disconnect(missing)]) }
    }

    @Test func wiringInspectorAcceptsANodeWith256PortsAndRefusesOneWith257AsPreviewBounds() throws {
        let wide = Fixture.with([], nodes: [Self.wideNode(ports: 256)])
        let accepted = try Self.inspect(Self.node("nod.wide"), on: wide)
        #expect(accepted.ports.count == 256)
        let tooWide = Fixture.with([], nodes: [Self.wideNode(ports: 257)])
        let limit = ProjectGraphLimitError.exceeded(path: "$.nodes[nod.wide].ports", maximum: 256)
        #expect(throws: WiringInspectorRefusal.preview(.bounds(limit))) {
            try Self.inspect(Self.node("nod.wide"), on: tooWide)
        }
    }

    @Test func wiringInspectorRefusesTwoUncheckableGraphsWithTheContractErrorForANodeAndAnEdgeSubject() {
        let features = WiringInspectorRefusal.uncheckableGraph(.invalidRequiredFeatures([]))
        #expect(throws: features) { try Self.inspect(Self.node("nod.keys"), on: Self.uncheckableGraph) }
        #expect(throws: features) { try Self.inspect(Self.edge("edg.keys-verb"), on: Self.uncheckableGraph) }
        var collision = Fixture.graph
        collision.unknownFields["requiredFeatures"] = .array([])
        let expected = WiringInspectorRefusal.uncheckableGraph(.requiredFeaturesCollision)
        #expect(throws: expected) { try Self.inspect(Self.node("nod.keys"), on: collision) }
    }

    @Test func wiringInspectorRefusesAnAbsentNodeAndAnAbsentEdgeOfTheActiveGraph() {
        let node = Self.node("nod.nobody")
        #expect(throws: WiringInspectorRefusal.subjectAbsent(node)) { try Self.inspect(node) }
        let edge = Self.edge("edg.nobody")
        #expect(throws: WiringInspectorRefusal.subjectAbsent(edge)) { try Self.inspect(edge) }
    }

    @Test func wiringInspectorRefusesAnItemTheDraftRemovedAsAbsent() {
        let node = Self.node("nod.keys")
        let removed: [GraphEdit] = [.disconnect(Self.edgeID("edg.keys-verb")), .removeNode(Self.nodeID("nod.keys"))]
        #expect(throws: WiringInspectorRefusal.subjectAbsent(node)) { try Self.inspect(node, removed) }
        let edge = Self.edge("edg.keys-verb")
        let disconnected: [GraphEdit] = [.disconnect(Self.edgeID("edg.keys-verb"))]
        #expect(throws: WiringInspectorRefusal.subjectAbsent(edge)) { try Self.inspect(edge, disconnected) }
        let implied: [GraphEdit] = [.removeNode(Self.nodeID("nod.keys"))]
        #expect(throws: WiringInspectorRefusal.subjectAbsent(edge)) { try Self.inspect(edge, implied) }
    }

    @Test func wiringInspectorReportsTheDraftBaseMismatchBeforeAnUncheckableGraphWhenBothHold() throws {
        let graph = Self.uncheckableGraph
        let later = try ContractRevision(3)
        let draft = DraftEdits(id: Self.draftID, graph: graph.id, baseRevision: later, edits: [])
        let expected = WiringInspectorRefusal.preview(.draftBaseMismatch(draft: later, active: .initial))
        #expect(throws: expected) { try WiringInspector.make(Self.node("nod.keys"), draft: draft, active: graph) }
    }

    @Test func wiringInspectorReportsAnUncheckableGraphBeforeAnAbsentSubjectWhenBothHold() {
        let features = WiringInspectorRefusal.uncheckableGraph(.invalidRequiredFeatures([]))
        #expect(throws: features) { try Self.inspect(Self.node("nod.nobody"), on: Self.uncheckableGraph) }
        #expect(throws: features) { try Self.inspect(Self.edge("edg.nobody"), on: Self.uncheckableGraph) }
    }

    // MARK: - Markers

    @Test func wiringInspectorMarksEveryNodeAndEdgeOfTheFixtureActiveUnderAnEmptyDraft() throws {
        for node in Fixture.graph.nodes {
            let inspector = try Self.inspect(.node(node.id))
            #expect(inspector.marker == .active, "\(node.id)")
        }
        for edge in Fixture.graph.edges {
            let inspector = try Self.inspect(.edge(edge.id))
            #expect(inspector.marker == .active, "\(edge.id)")
        }
    }

    @Test func wiringInspectorMarksAnAddedNodeAndAConnectedEdgeDraftAndLeavesTheOthersActive() throws {
        let newNode = Fixture.stereo("nod.added", at: 9)
        let wire = Self.wire("edg.keys-mains", from: ("nod.keys", "out"), to: ("nod.mains", "in"))
        let edits: [GraphEdit] = [.addNode(newNode), .connect(wire)]
        let added = try Self.inspect(Self.node("nod.added"), edits)
        let connected = try Self.inspect(Self.edge("edg.keys-mains"), edits)
        let otherNode = try Self.inspect(Self.node("nod.keys"), edits)
        let otherEdge = try Self.inspect(Self.edge("edg.keys-verb"), edits)
        #expect(added.marker == .draft)
        #expect(connected.marker == .draft)
        #expect(otherNode.marker == .active)
        #expect(otherEdge.marker == .active)
    }

    @Test func wiringInspectorKeepsAMovedNodeAndANeighbourOfADisconnectActive() throws {
        let edits: [GraphEdit] = [
            .moveNode(Self.nodeID("nod.keys"), to: GraphPoint(x: 40, y: 2)),
            .disconnect(Self.edgeID("edg.keys-verb"))
        ]
        let keysNode = try Self.inspect(Self.node("nod.keys"), edits)
        let echoEdge = try Self.inspect(Self.edge("edg.echo-verb"), edits)
        #expect(keysNode.marker == .active)
        #expect(echoEdge.marker == .active)
    }

    @Test func wiringInspectorMarksAnEdgeThatReusesAnActiveIDAfterANodeRemovalDraft() throws {
        let reused = Self.wire("edg.keys-verb", from: ("nod.echo", "out"), to: ("nod.mains", "in"))
        let edits: [GraphEdit] = [.removeNode(Self.nodeID("nod.keys")), .connect(reused)]
        let inspector = try Self.inspect(Self.edge("edg.keys-verb"), edits)
        #expect(inspector.marker == .draft)
        let titles = inspector.ends.map(\.title)
        let expected = ["nod.echo", "nod.mains"]
        #expect(titles == expected)
    }

    // MARK: - Golden tables

    @Test func wiringInspectorDescribesTheReverbNodeOfTheFixtureByTheGoldenTable() throws {
        let inspector = try Self.inspect(Self.node("nod.verb"))
        #expect(inspector.subject == Self.node("nod.verb"))
        #expect(inspector.marker == .active)
        #expect(inspector.title == "nod.verb")
        #expect(inspector.kind == .plugin)
        let ports = [
            WiringInspectorPort(id: Self.portID("in"), direction: .input, signal: .audio, channels: 2),
            WiringInspectorPort(id: Self.portID("out"), direction: .output, signal: .audio, channels: 2),
            WiringInspectorPort(id: Self.portID("mod"), direction: .input, signal: .control, channels: nil)
        ]
        #expect(inspector.ports == ports)
        let attached = [
            "edg.delay-verb-fb", "edg.echo-verb", "edg.keys-verb", "edg.mic-verb", "edg.verb-delay", "edg.verb-mains"
        ].map { Self.edgeID($0) }
        #expect(inspector.attachedEdges == attached)
        #expect(inspector.feedbackCount == 1)
        #expect(inspector.hasConversion == false)
        #expect(inspector.ends.isEmpty)
        #expect(inspector.problems.isEmpty)
        let label = "nod.verb, plugin, active. 2 inputs, 1 output. 6 connections, 1 feedback. No problems."
        #expect(inspector.label == label)
    }

    @Test func wiringInspectorDescribesADanglingDraftWireOnBothEndsByTheGoldenTable() throws {
        let dangling = Self.wire("edg.keys-ghost", from: ("nod.keys", "out"), to: ("nod.ghost", "in"))
        let edits: [GraphEdit] = [.connect(dangling)]
        let sentence = "Wire edg.keys-ghost: missing node nod.ghost."
        let stableID = "missingNode|edg.keys-ghost|nod.ghost"

        let node = try Self.inspect(Self.node("nod.keys"), edits)
        #expect(node.attachedEdges == [Self.edgeID("edg.keys-ghost"), Self.edgeID("edg.keys-verb")])
        #expect(node.problems.count == 1)
        let nodeProblem = try #require(node.problems.first)
        #expect(nodeProblem.code == "missingNode")
        #expect(nodeProblem.stableID == stableID)
        #expect(nodeProblem.sentence == sentence)
        let nodeLabel = "nod.keys, plugin, active. 0 inputs, 1 output. 2 connections, 0 feedback. 1 problem."
        #expect(node.label == nodeLabel)

        let edge = try Self.inspect(Self.edge("edg.keys-ghost"), edits)
        #expect(edge.marker == .draft)
        let ends = [
            WiringInspectorEnd(
                node: Self.nodeID("nod.keys"), port: Self.portID("out"), title: "nod.keys",
                state: .connected(direction: .output, signal: .audio, channels: 2)
            ),
            WiringInspectorEnd(
                node: Self.nodeID("nod.ghost"), port: Self.portID("in"), title: "nod.ghost", state: .missingNode
            )
        ]
        #expect(edge.ends == ends)
        #expect(edge.problems.count == 1)
        let edgeProblem = try #require(edge.problems.first)
        #expect(edgeProblem.stableID == stableID)
        #expect(edgeProblem.sentence == sentence)
        #expect(edge.label == "nod.keys to nod.ghost (missing), draft, not active. 1 problem.")
    }

    @Test func wiringInspectorDescribesTheObservedShortcutNodeByTheGoldenTable() throws {
        let inspector = try Self.inspect(Self.node("nod.ch7"))
        #expect(inspector.kind == .observedShortcut)
        #expect(inspector.ports.isEmpty)
        #expect(inspector.attachedEdges.isEmpty)
        let label = """
            nod.ch7, observedShortcut, active. 0 inputs, 0 outputs. 0 connections, 0 feedback. \
            Observed, not routable. No problems.
            """
        #expect(inspector.label == label)
    }

    @Test func wiringInspectorDescribesTheKeysToReverbEdgeByTheGoldenTable() throws {
        let inspector = try Self.inspect(Self.edge("edg.keys-verb"))
        #expect(inspector.subject == Self.edge("edg.keys-verb"))
        #expect(inspector.title == "edg.keys-verb")
        #expect(inspector.kind == nil)
        #expect(inspector.ends.map(\.title) == ["nod.keys", "nod.verb"])
        #expect(inspector.problems.isEmpty)
        #expect(inspector.label == "nod.keys to nod.verb, active. No problems.")
    }

    // MARK: - Source scan

    private static func sourceDirectory(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let candidates = ["../Shared/Wiring/Inspector", "../../Sources/FluxKlang/Shared/Wiring/Inspector"]
        let marker = "WiringInspector.swift"
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    private static let sourcesAreReachable = sourceDirectory() != nil

    /// Texts the three production files must not contain, even in a comment; each is joined from pieces so that no
    /// literal here spells it.
    private static func forbiddenSourceWords() -> [String] {
        [
            ["Ta", "sk"].joined(), ["Cl", "ock"].joined(), ["Da", "te"].joined(), ["Dispatch", "Queue"].joined(),
            ["Swift", "UI"].joined(), ["Dou", "ble"].joined(), ["Flo", "at"].joined(), ["defa", "ult:"].joined(),
            ["imp", "ort"].joined(), ["mut", "ating"].joined(), ["static", " var"].joined(),
            ["nonisolated", "(unsafe)"].joined()
        ]
    }

    /// Looks for each forbidden text and for a `static func` whose name starts with an operator character. The
    /// search is over the raw text, so a comment is scanned too. It is skipped when the sources are not next to the
    /// tests.
    @Test(.enabled(if: Self.sourcesAreReachable, "the inspector sources are not next to the tests"))
    func wiringInspectorSourceFilesContainNoForbiddenTextAndNoOperatorFunction() throws {
        let directory = try #require(Self.sourceDirectory(), "the inspector sources are not next to the tests")
        let names = ["WiringInspector.swift", "WiringInspectorLabel.swift", "WiringInspectorProblem.swift"]
        let operators = Set("+-*/<>=!&|%^~".unicodeScalars)
        var hits: [String] = []
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.isEmpty)
            for word in Self.forbiddenSourceWords() where text.contains(word) {
                hits.append("\(name): \(word)")
            }
            for part in text.components(separatedBy: "static func ").dropFirst() {
                if let first = part.unicodeScalars.first, operators.contains(first) { hits.append("\(name): operator") }
            }
        }
        #expect(hits.isEmpty)
    }
}
