//
//  WiringNodeEditTests.swift
//  FluxKlangTests
//
//  Add and remove node composers (#101 WP4): one `addNode` or one atomic
//  `disconnect`-each-attached-edge-then-`removeNode` gesture folded into a
//  draft, every refusal typed in a fixed order, N and N+1 at every bound, and
//  a refusal changes nothing. Nothing is activated; the active graph is only
//  read. This root file holds the shared fixtures and the plan and fixture
//  checks; the add, remove and order suites are extensions.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture

@Suite("Wiring node add and remove")
struct WiringNodeEditTests {
    static let keys = NodeID(validated: "nod.keys")
    static let verb = NodeID(validated: "nod.verb")
    static let shortcut = NodeID(validated: "nod.ch7")
    static let draftID = DraftID(validated: "dft.nodes")

    static func draft(_ edits: [GraphEdit] = [], on graph: GraphDocument = Fixture.graph) -> DraftEdits {
        DraftEdits(id: draftID, graph: graph.id, baseRevision: graph.revision, edits: edits)
    }

    static func nodeID(_ raw: String) -> NodeID { Fixture.id(raw) }

    static func edgeID(_ raw: String) -> EdgeID { Fixture.id(raw) }

    static func revision(_ value: Int) throws -> ContractRevision {
        try ContractRevision(value)
    }

    /// A routable node with one output port, or the given ports.
    static func node(_ raw: String, ports: [GraphPort]? = nil, label: String? = nil) -> GraphNode {
        var node = Fixture.node(raw, ports: ports ?? [Fixture.audio("out", .output, 2)], at: 9)
        if let label { node.label = label }
        return node
    }

    /// `count` ports with distinct IDs.
    static func ports(_ count: Int) -> [GraphPort] {
        (0..<count).map { Fixture.audio("p" + padded($0), .output, 1) }
    }

    /// `value` as five digits, so ID order equals numeric order.
    static func padded(_ value: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, 5 - digits.count)) + digits
    }

    static func wire(_ id: String, _ from: String, _ to: String) -> GraphEdge {
        Fixture.edge(id, Fixture.address(from, "out"), Fixture.address(to, "in"))
    }

    /// `nodes` nodes (the first two are nod.a and nod.b) and `edges` edges from nod.a to nod.b.
    static func large(nodes: Int, edges: Int) -> GraphDocument {
        let list = (0..<nodes).map { index -> GraphNode in
            switch index {
            case 0: node("nod.a", ports: [])
            case 1: node("nod.b", ports: [])
            default: node("nod.n" + padded(index), ports: [])
            }
        }
        let wires = (0..<edges).map { wire("edg." + padded($0), "nod.a", "nod.b") }
        return GraphDocument(id: Fixture.graphID, nodes: list, edges: wires)
    }

    /// A draft that disconnects the first `count` edges of `graph`.
    static func disconnecting(_ count: Int, in graph: GraphDocument) -> DraftEdits {
        draft(graph.edges.prefix(count).map { GraphEdit.disconnect($0.id) }, on: graph)
    }

    /// A draft based on revision 7 against an active graph at revision 3, so the preview refuses it.
    static func stale() throws -> (draft: DraftEdits, active: GraphDocument) {
        var active = Fixture.graph
        active.revision = try revision(3)
        var stale = draft(on: active)
        stale.baseRevision = try revision(7)
        return (stale, active)
    }

    static func mismatch() throws -> WiringNodeRefusal {
        .preview(.draftBaseMismatch(draft: try revision(7), active: try revision(3)))
    }

    /// The refusal of `add`, after checking that nothing the caller passed in changed.
    static func addRefusal(
        _ node: GraphNode, to draft: DraftEdits, active: GraphDocument = Fixture.graph
    ) -> WiringNodeRefusal? {
        let (draftBefore, activeBefore) = (draft, active)
        var refusal: WiringNodeRefusal?
        do { _ = try WiringNodeComposer.add(node, to: draft, active: active) } catch { refusal = error }
        #expect(draft == draftBefore)
        #expect(active == activeBefore)
        return refusal
    }

    /// The refusal of `remove`, after checking that nothing the caller passed in changed.
    static func removeRefusal(
        _ node: NodeID, from draft: DraftEdits, active: GraphDocument = Fixture.graph
    ) -> WiringNodeRefusal? {
        let (draftBefore, activeBefore) = (draft, active)
        var refusal: WiringNodeRefusal?
        do { _ = try WiringNodeComposer.remove(node: node, from: draft, active: active) } catch { refusal = error }
        #expect(draft == draftBefore)
        #expect(active == activeBefore)
        return refusal
    }

    /// The refusal of `removalPlan`.
    static func planRefusal(
        _ node: NodeID, from draft: DraftEdits, active: GraphDocument = Fixture.graph
    ) -> WiringNodeRefusal? {
        do { _ = try WiringNodeComposer.removalPlan(node: node, from: draft, active: active) } catch { return error }
        return nil
    }

    /// `disconnect` edits for the raw edge IDs, in order.
    static func disconnects(_ raws: [String]) -> [GraphEdit] {
        raws.map { GraphEdit.disconnect(edgeID($0)) }
    }

    @Test func nodeFixtureGraphIsValidAndTheShortcutIsNotRoutable() {
        #expect(Fixture.graph.nodes.count == 7)
        #expect(Fixture.graph.node(Self.shortcut)?.kind == .observedShortcut)
        #expect(Fixture.graph.node(Self.shortcut)?.kind.isRoutable == false)
    }

    @Test func nodeLargeFixtureHasTheRequestedCounts() {
        let graph = Self.large(nodes: 4_096, edges: 3)
        #expect(graph.nodes.count == 4_096)
        #expect(graph.edges.map(\.id.rawValue) == ["edg.00000", "edg.00001", "edg.00002"])
        #expect(Self.large(nodes: 2, edges: 0).edges.isEmpty)
    }

    @Test func nodePlanIsBuiltOnlyByTheFactoryAndMatchesTheComposerEntryPoint() throws {
        let draft = Self.draft()
        let direct = try WiringNodeRemovalPlan.make(node: Self.verb, from: draft, active: Fixture.graph)
        let viaComposer = try WiringNodeComposer.removalPlan(node: Self.verb, from: draft, active: Fixture.graph)
        #expect(direct == viaComposer)
        #expect(direct.node == Self.verb)
        #expect(direct.gesture.last == .removeNode(Self.verb))
        #expect(direct.gesture.count == direct.edgesToDisconnect.count + 1)
    }
}
