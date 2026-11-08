//
//  WiringSelectionTests.swift
//  FluxKlangTests
//
//  The wiring focus order (#101 WSL1): the builders every WiringSelectionTests+*.swift file shares, the order of a
//  fixture graph, the limits and the refusals of the factories. The order is a pure value: nothing here reads a
//  view, a key or a clock.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct WiringSelectionTests {
    static let graphID = GraphID(validated: "gph.selection")

    static func id<Tag>(_ raw: String) -> ContractID<Tag> {
        guard let id = ContractID<Tag>(rawValue: raw) else { preconditionFailure("Invalid fixture ID \(raw)") }
        return id
    }

    static func nodeID(_ raw: String) -> NodeID { id(raw) }
    static func portID(_ raw: String) -> PortID { id(raw) }
    static func edgeID(_ raw: String) -> EdgeID { id(raw) }

    static func port(
        _ raw: String, _ direction: PortDirection = .input, _ signal: PortSignal = .audio
    ) -> GraphPort {
        GraphPort(id: portID(raw), direction: direction, signal: signal)
    }

    static func node(
        _ raw: String, kind: NodeKind = .plugin, label: String? = nil, ports: [GraphPort] = []
    ) -> GraphNode {
        GraphNode(id: nodeID(raw), kind: kind, label: label ?? raw, ports: ports)
    }

    static func edge(_ raw: String, from source: PortAddress, to sink: PortAddress) -> GraphEdge {
        GraphEdge(id: edgeID(raw), from: source, to: sink)
    }

    static func address(_ node: String, _ port: String) -> PortAddress {
        PortAddress(node: nodeID(node), port: portID(port))
    }

    static func graph(nodes: [GraphNode], edges: [GraphEdge] = []) -> GraphDocument {
        GraphDocument(id: graphID, nodes: nodes, edges: edges)
    }

    /// Nodes a (ports x, w), b (ports out, in), c (an observed shortcut with an empty label); edges e2, e1 and the
    /// dangling e0, all declared out of ID order.
    static var fixture: GraphDocument {
        let alpha = node("a", label: "Alpha", ports: [port("x", .input, .midi), port("w", .output, .audio)])
        let beta = node("b", label: "Beta", ports: [port("out", .output, .audio), port("in", .input, .audio)])
        let shortcut = node("c", kind: .observedShortcut, label: "")
        return graph(
            nodes: [shortcut, beta, alpha],
            edges: [
                edge("e2", from: address("b", "out"), to: address("a", "x")),
                edge("e1", from: address("a", "w"), to: address("b", "in")),
                edge("e0", from: address("ghost", "p"), to: address("a", "x"))
            ]
        )
    }

    static var fixtureTargets: [WiringSelectionTarget] {
        [
            .node(nodeID("a")), .node(nodeID("b")), .node(nodeID("c")),
            .port(node: nodeID("a"), port: portID("w")), .port(node: nodeID("a"), port: portID("x")),
            .port(node: nodeID("b"), port: portID("in")), .port(node: nodeID("b"), port: portID("out")),
            .edge(edgeID("e0")), .edge(edgeID("e1")), .edge(edgeID("e2"))
        ]
    }

    static func order(of graph: GraphDocument) throws -> WiringSelectionOrder {
        try WiringSelectionOrder.make(graph: graph)
    }

    static func refusal(of graph: GraphDocument) -> WiringSelectionRefusal? {
        do { _ = try WiringSelectionOrder.make(graph: graph) } catch { return error }
        return nil
    }

    /// `count` plain nodes `n0000`, `n0001`, ..., each with the same `ports`.
    static func numberedNodes(_ count: Int, ports: [GraphPort] = []) -> [GraphNode] {
        (0..<count).map { index in node("n" + padded(index, width: 4), ports: ports) }
    }

    static func numberedEdges(_ count: Int) -> [GraphEdge] {
        let from = address("n0000", "p000")
        return (0..<count).map { index in edge("e" + padded(index, width: 5), from: from, to: from) }
    }

    static func numberedPorts(_ count: Int) -> [GraphPort] {
        (0..<count).map { index in port("p" + padded(index, width: 3)) }
    }

    static func padded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    // MARK: Order

    @Test func theOrderOfTheFixtureListsNodesThenPortsThenEdgesByIdBytes() throws {
        let order = try Self.order(of: Self.fixture)
        let expected = Self.fixtureTargets
        #expect(order.targets == expected)
        #expect(order.count == 10)
    }

    @Test func idsOrderAsDigitsUppercaseLowercaseWithDashBeforeDot() throws {
        let names = ["a.b", "a", "Z", "a-b", "A", "9"]
        let nodes = names.map { Self.node($0) }
        let edges = names.map { Self.edge($0, from: Self.address("a", "p"), to: Self.address("a", "p")) }
        let carrier = Self.node("m", ports: names.map { Self.port($0) })
        let order = try Self.order(of: Self.graph(nodes: nodes + [carrier], edges: edges))
        let sorted = ["9", "A", "Z", "a", "a-b", "a.b"]
        let nodeStops = sorted.map { WiringSelectionTarget.node(Self.nodeID($0)) } + [.node(Self.nodeID("m"))]
        let portStops = sorted.map { WiringSelectionTarget.port(node: Self.nodeID("m"), port: Self.portID($0)) }
        let edgeStops = sorted.map { WiringSelectionTarget.edge(Self.edgeID($0)) }
        #expect(order.targets == nodeStops + portStops + edgeStops)
    }

    @Test func theSortedPortsOfOneNodeFollowTheirIdsWhateverTheDeclaredOrder() throws {
        let ports = ["m", "z", "a", "b"].map { Self.port($0) }
        let order = try Self.order(of: Self.graph(nodes: [Self.node("solo", ports: ports)]))
        let stops = Array(order.targets[order.range(of: .ports)])
        let expected = ["a", "b", "m", "z"].map {
            WiringSelectionTarget.port(node: Self.nodeID("solo"), port: Self.portID($0))
        }
        #expect(stops == expected)
    }

    @Test func thePortsOfDifferentNodesOrderByNodeIdBeforePortId() throws {
        let first = Self.node("a", ports: [Self.port("z")])
        let second = Self.node("b", ports: [Self.port("a")])
        let order = try Self.order(of: Self.graph(nodes: [second, first]))
        let ports = order.range(of: .ports)
        let stops = Array(order.targets[ports])
        let expected: [WiringSelectionTarget] = [
            .port(node: Self.nodeID("a"), port: Self.portID("z")),
            .port(node: Self.nodeID("b"), port: Self.portID("a"))
        ]
        #expect(stops == expected)
    }

    @Test func reversingTheDeclaredOrderOfNodesPortsAndEdgesBuildsTheSameOrder() throws {
        let graph = Self.fixture
        let reversed = Self.graph(
            nodes: graph.nodes.reversed().map { original in
                var copy = original
                copy.ports = original.ports.reversed()
                return copy
            },
            edges: graph.edges.reversed()
        )
        let straight = try Self.order(of: graph)
        let flipped = try Self.order(of: reversed)
        #expect(flipped == straight)
        let expected = Self.fixtureTargets
        #expect(flipped.targets == expected)
    }

    @Test func anEmptyDraftGivesTheSameOrderAsTheActiveGraphAlone() throws {
        let direct = try Self.order(of: Self.fixture)
        let drafted = try WiringSelectionOrder.make(active: Self.fixture, draft: Self.draft([]))
        #expect(direct == drafted)
    }

    @Test func anEmptyGraphIsAnEmptyOrderAndANodeWithoutPortsIsOneStop() throws {
        let empty = try Self.order(of: Self.graph(nodes: []))
        #expect(empty.count == 0)
        #expect(empty.targets.isEmpty)
        let emptyNodes = empty.range(of: .nodes)
        let emptyPorts = empty.range(of: .ports)
        let emptyEdges = empty.range(of: .edges)
        #expect(emptyNodes.isEmpty)
        #expect(emptyPorts.isEmpty)
        #expect(emptyEdges.isEmpty)
        let lone = try Self.order(of: Self.graph(nodes: [Self.node("solo")]))
        let expected: [WiringSelectionTarget] = [.node(Self.nodeID("solo"))]
        #expect(lone.targets == expected)
    }

    @Test func aDanglingEdgeAndAnObservedShortcutAreStops() throws {
        let order = try Self.order(of: Self.fixture)
        let dangling = WiringSelectionTarget.edge(Self.edgeID("e0"))
        let shortcut = WiringSelectionTarget.node(Self.nodeID("c"))
        let shortcutPort = WiringSelectionTarget.port(node: Self.nodeID("c"), port: Self.portID("x"))
        #expect(order.position(of: dangling) == 7)
        #expect(order.position(of: shortcut) == 2)
        #expect(order.position(of: shortcutPort) == nil)
    }

    @Test func theThreeSectionsAreContiguousRangesAndPositionsAreChecked() throws {
        let order = try Self.order(of: Self.fixture)
        let nodes = order.range(of: .nodes)
        let ports = order.range(of: .ports)
        let edges = order.range(of: .edges)
        #expect(nodes == 0..<3)
        #expect(ports == 3..<7)
        #expect(edges == 7..<10)
        #expect(order.target(at: 0) == .node(Self.nodeID("a")))
        #expect(order.target(at: 9) == .edge(Self.edgeID("e2")))
        #expect(order.target(at: -1) == nil)
        #expect(order.target(at: 10) == nil)
        let present = WiringSelectionTarget.port(node: Self.nodeID("b"), port: Self.portID("out"))
        let absent = WiringSelectionTarget.port(node: Self.nodeID("a"), port: Self.portID("out"))
        #expect(order.position(of: present) == 6)
        #expect(order.contains(present))
        #expect(order.position(of: absent) == nil)
        #expect(!order.contains(absent))
    }

    @Test func aFullSizeGraphBuildsAnOrderOfOneMillionSixtyNineThousandFiftySixStops() throws {
        let ports = Self.numberedPorts(ProjectGraphLimits.portsPerNode)
        let nodes = Self.numberedNodes(ProjectGraphLimits.nodes, ports: ports)
        let edges = Self.numberedEdges(ProjectGraphLimits.edges)
        let order = try Self.order(of: Self.graph(nodes: nodes, edges: edges))
        #expect(order.count == 1_069_056)
        let nodeRange = order.range(of: .nodes)
        let portRange = order.range(of: .ports)
        let edgeRange = order.range(of: .edges)
        #expect(nodeRange == 0..<4_096)
        #expect(portRange == 4_096..<1_052_672)
        #expect(edgeRange == 1_052_672..<1_069_056)
        #expect(order.target(at: 4_095) == .node(Self.nodeID("n4095")))
        #expect(order.target(at: 4_096) == .port(node: Self.nodeID("n0000"), port: Self.portID("p000")))
        #expect(order.target(at: 1_052_671) == .port(node: Self.nodeID("n4095"), port: Self.portID("p255")))
        #expect(order.target(at: 1_069_055) == .edge(Self.edgeID("e16383")))
        let middle = WiringSelectionTarget.port(node: Self.nodeID("n2000"), port: Self.portID("p100"))
        #expect(order.position(of: middle) == 4_096 + 2_000 * 256 + 100)
    }

    // MARK: Limits

    @Test func nodesAtTheLimitAreAcceptedAndOneMoreIsRefusedWithItsCount() throws {
        let accepted = try Self.order(of: Self.graph(nodes: Self.numberedNodes(ProjectGraphLimits.nodes)))
        #expect(accepted.count == 4_096)
        let refused = Self.refusal(of: Self.graph(nodes: Self.numberedNodes(ProjectGraphLimits.nodes + 1)))
        #expect(refused == .tooManyNodes(4_097))
    }

    @Test func edgesAtTheLimitAreAcceptedAndOneMoreIsRefusedWithItsCount() throws {
        let node = Self.node("n0000", ports: [Self.port("p000")])
        let edges = Self.numberedEdges(ProjectGraphLimits.edges)
        let accepted = try Self.order(of: Self.graph(nodes: [node], edges: edges))
        #expect(accepted.count == 2 + 16_384)
        let refused = Self.refusal(
            of: Self.graph(nodes: [node], edges: Self.numberedEdges(ProjectGraphLimits.edges + 1))
        )
        #expect(refused == .tooManyEdges(16_385))
    }

    @Test func portsOfANodeAtTheLimitAreAcceptedAndOneMoreIsRefusedNamingTheNode() throws {
        let full = Self.node("big", ports: Self.numberedPorts(ProjectGraphLimits.portsPerNode))
        let accepted = try Self.order(of: Self.graph(nodes: [full]))
        #expect(accepted.count == 257)
        let over = Self.node("big", ports: Self.numberedPorts(ProjectGraphLimits.portsPerNode + 1))
        let refused = Self.refusal(of: Self.graph(nodes: [over]))
        #expect(refused == .tooManyPorts(node: Self.nodeID("big"), count: 257))
    }

    @Test func thePortLimitNamesTheFirstOversizeNodeInGraphOrder() {
        let later = Self.node("a", ports: Self.numberedPorts(258))
        let earlier = Self.node("z", ports: Self.numberedPorts(257))
        let refused = Self.refusal(of: Self.graph(nodes: [earlier, later]))
        #expect(refused == .tooManyPorts(node: Self.nodeID("z"), count: 257))
    }

    // MARK: Duplicates

    @Test func aRepeatedNodeIdIsRefusedNamingTheFirstRepeat() {
        let nodes = ["a", "b", "b", "a"].map { Self.node($0) }
        let refused = Self.refusal(of: Self.graph(nodes: nodes))
        #expect(refused == .duplicateNode(Self.nodeID("b")))
    }

    @Test func aRepeatedPortIdIsRefusedNamingTheNodeAndPortButTheSameIdOnTwoNodesIsNot() throws {
        let twice = Self.node("n", ports: [Self.port("x"), Self.port("y"), Self.port("y"), Self.port("x")])
        let refused = Self.refusal(of: Self.graph(nodes: [Self.node("m", ports: [Self.port("y")]), twice]))
        #expect(refused == .duplicatePort(node: Self.nodeID("n"), port: Self.portID("y")))
        let shared = [Self.node("m", ports: [Self.port("y")]), Self.node("n", ports: [Self.port("y")])]
        let order = try Self.order(of: Self.graph(nodes: shared))
        #expect(order.count == 4)
    }

    @Test func aRepeatedEdgeIdIsRefusedNamingTheFirstRepeat() {
        let link = Self.address("a", "p")
        let edges = ["e1", "e2", "e2", "e1"].map { Self.edge($0, from: link, to: link) }
        let refused = Self.refusal(of: Self.graph(nodes: [], edges: edges))
        #expect(refused == .duplicateEdge(Self.edgeID("e2")))
    }

    // MARK: Refusal order

    @Test func tooManyNodesIsReportedBeforeTooManyEdges() {
        let graph = Self.graph(
            nodes: Self.numberedNodes(ProjectGraphLimits.nodes + 1),
            edges: Self.numberedEdges(ProjectGraphLimits.edges + 1)
        )
        #expect(Self.refusal(of: graph) == .tooManyNodes(4_097))
    }

    @Test func tooManyEdgesIsReportedBeforeTooManyPorts() {
        let wide = Self.node("n0000", ports: Self.numberedPorts(ProjectGraphLimits.portsPerNode + 1))
        let graph = Self.graph(nodes: [wide], edges: Self.numberedEdges(ProjectGraphLimits.edges + 1))
        #expect(Self.refusal(of: graph) == .tooManyEdges(16_385))
    }

    @Test func tooManyPortsIsReportedBeforeARepeatedNode() {
        let wide = Self.node("a", ports: Self.numberedPorts(ProjectGraphLimits.portsPerNode + 1))
        let refused = Self.refusal(of: Self.graph(nodes: [wide, Self.node("a")]))
        #expect(refused == .tooManyPorts(node: Self.nodeID("a"), count: 257))
    }

    @Test func aRepeatedNodeIsReportedBeforeARepeatedPort() {
        let twin = Self.node("b", ports: [Self.port("x"), Self.port("x")])
        let refused = Self.refusal(of: Self.graph(nodes: [twin, Self.node("a"), Self.node("a")]))
        #expect(refused == .duplicateNode(Self.nodeID("a")))
    }

    @Test func aRepeatedPortIsReportedBeforeARepeatedEdge() {
        let twin = Self.node("a", ports: [Self.port("x"), Self.port("x")])
        let link = Self.address("a", "x")
        let edges = [Self.edge("e", from: link, to: link), Self.edge("e", from: link, to: link)]
        let refused = Self.refusal(of: Self.graph(nodes: [twin], edges: edges))
        #expect(refused == .duplicatePort(node: Self.nodeID("a"), port: Self.portID("x")))
    }

    // MARK: Draft wrapper

    static func draft(_ edits: [GraphEdit], graph: GraphID = graphID) -> DraftEdits {
        DraftEdits(id: DraftID(validated: "drf.selection"), graph: graph, baseRevision: .initial, edits: edits)
    }

    static func wrapperRefusal(active: GraphDocument, draft: DraftEdits) -> WiringSelectionRefusal? {
        do { _ = try WiringSelectionOrder.make(active: active, draft: draft) } catch { return error }
        return nil
    }

    @Test func theDraftWrapperOrdersTheGraphTheDraftProduces() throws {
        let edits: [GraphEdit] = [.addNode(Self.node("d")), .disconnect(Self.edgeID("e0"))]
        let order = try WiringSelectionOrder.make(active: Self.fixture, draft: Self.draft(edits))
        let expected: [WiringSelectionTarget] = [
            .node(Self.nodeID("a")), .node(Self.nodeID("b")), .node(Self.nodeID("c")), .node(Self.nodeID("d")),
            .port(node: Self.nodeID("a"), port: Self.portID("w")),
            .port(node: Self.nodeID("a"), port: Self.portID("x")),
            .port(node: Self.nodeID("b"), port: Self.portID("in")),
            .port(node: Self.nodeID("b"), port: Self.portID("out")),
            .edge(Self.edgeID("e1")), .edge(Self.edgeID("e2"))
        ]
        #expect(order.targets == expected)
    }

    @Test func aDraftOfAnotherGraphIsRefusedAsAPreviewRefusal() {
        let other = GraphID(validated: "gph.other")
        let refused = Self.wrapperRefusal(active: Self.fixture, draft: Self.draft([], graph: other))
        let expected = WiringPreviewRefusal.draftGraphMismatch(draft: other, active: Self.graphID)
        #expect(refused == .preview(expected))
    }

    @Test func anOversizeActiveGraphWithARepeatedPortIsRefusedAsPreviewBounds() {
        let twin = Self.node("n0000", ports: [Self.port("x"), Self.port("x")])
        let crowd = Self.numberedNodes(ProjectGraphLimits.nodes + 1).dropFirst()
        let active = Self.graph(nodes: [twin] + crowd)
        let refused = Self.wrapperRefusal(active: active, draft: Self.draft([]))
        let limit = ProjectGraphLimitError.exceeded(path: "$.nodes", maximum: 4_096)
        #expect(refused == .preview(.bounds(limit)))
    }

    @Test func aRepeatedPortInTheDraftsGraphIsRefusedByTheWrapperAsARepeatedPort() {
        let twin = Self.node("a", ports: [Self.port("x"), Self.port("x")])
        let active = Self.graph(nodes: [twin])
        let draft = Self.draft([.moveNode(Self.nodeID("a"), to: nil)])
        let refused = Self.wrapperRefusal(active: active, draft: draft)
        #expect(refused == .duplicatePort(node: Self.nodeID("a"), port: Self.portID("x")))
    }
}
