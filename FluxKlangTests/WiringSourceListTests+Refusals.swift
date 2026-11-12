//
//  WiringSourceListTests+Refusals.swift
//  FluxKlangTests
//
//  The "From" list's refusals (#101 WSRC1): the bounds, a repeated node ID and a repeated port ID, their fixed
//  order, the exact maximum that is still listed, and the fixtures the source list suites share. Pure: graphs are
//  built in memory.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WiringSourceListTests {
    @Test func sourceListRefusesTooManyNodesPortsAndEdgesWithTheContractError() {
        let nodes = (0...ProjectGraphLimits.nodes).map { Fixture.node("f\($0)", "", ports: []) }
        let ports = (0...ProjectGraphLimits.portsPerNode).map { Fixture.output("p\($0)") }
        let wide = Fixture.node("wide", "Wide", ports: ports)
        var edges = Fixture.graph([])
        edges.edges = (0...ProjectGraphLimits.edges).map {
            GraphEdge(id: Fixture.edge("e\($0)"), from: Fixture.address("a", "out"), to: Fixture.address("b", "in"))
        }
        let graphs = [Fixture.graph(nodes), Fixture.graph([wide]), edges]
        let paths = ["$.nodes", "$.nodes[nod.wide].ports", "$.edges"]
        let maximums = [ProjectGraphLimits.nodes, ProjectGraphLimits.portsPerNode, ProjectGraphLimits.edges]
        for (graph, (path, maximum)) in zip(graphs, zip(paths, maximums)) {
            #expect(Self.refusal(graph) == .bounds(.exceeded(path: path, maximum: maximum)))
            #expect(Self.refusal(graph) == Self.boundsError(graph).map { .bounds($0) })
        }
    }

    @Test func sourceListAcceptsExactlyTheMaximumNodesPortsAndEdges() throws {
        let nodes = (0..<ProjectGraphLimits.nodes).map { Fixture.node("f\($0)", "", ports: []) }
        #expect(try WiringSourceList.make(in: Fixture.graph(nodes)).sections.isEmpty)
        let ports = (0..<ProjectGraphLimits.portsPerNode).map { Fixture.output("p\($0)") }
        let wide = try WiringSourceList.make(in: Fixture.graph([Fixture.node("wide", "Wide", ports: ports)]))
        #expect(wide.rows.count == ProjectGraphLimits.portsPerNode)
        var full = Fixture.docGraph()
        full.edges = (0..<ProjectGraphLimits.edges).map {
            GraphEdge(id: Fixture.edge("e\($0)"), from: Fixture.address("k", "out"), to: Fixture.address("v", "in"))
        }
        #expect(try WiringSourceList.make(in: full).rows.count == 6)
    }

    @Test func sourceListRefusesTheFirstRepeatedNodeID() {
        let out = [Fixture.output("out")]
        let nodes = [
            Fixture.node("a", "A", ports: out), Fixture.node("b", "B", ports: out),
            Fixture.node("b", "B2", ports: out), Fixture.node("a", "A2", ports: out)
        ]
        #expect(Self.refusal(Fixture.graph(nodes)) == .duplicateNode(Fixture.node("b")))
        let shortcuts = [
            Fixture.node("s", "S", kind: .observedShortcut, ports: []), Fixture.node("s", "T", ports: out)
        ]
        #expect(Self.refusal(Fixture.graph(shortcuts)) == .duplicateNode(Fixture.node("s")))
    }

    @Test func sourceListRefusesARepeatedPortIDInAnyDirectionOnARoutableNode() {
        let sameID = Fixture.node("a", "A", ports: [Fixture.input("x"), Fixture.output("x")])
        #expect(Self.refusal(Fixture.graph([sameID])) == .duplicatePort(Fixture.address("a", "x")))
        let noOutput = Fixture.node("b", "B", ports: [Fixture.input("x"), Fixture.input("x", .control)])
        #expect(Self.refusal(Fixture.graph([noOutput])) == .duplicatePort(Fixture.address("b", "x")))
        let outputs = Fixture.node("c", "C", ports: [Fixture.output("x"), Fixture.output("x", .midi)])
        #expect(Self.refusal(Fixture.graph([outputs])) == .duplicatePort(Fixture.address("c", "x")))
        let fine = Fixture.node("d", "D", ports: [Fixture.output("p"), Fixture.output("q")])
        let first = Fixture.node("e", "E", ports: [Fixture.output("a"), Fixture.output("b"), Fixture.output("b")])
        let second = Fixture.node("f", "F", ports: [Fixture.output("q"), Fixture.output("q")])
        #expect(Self.refusal(Fixture.graph([fine, second, first])) == .duplicatePort(Fixture.address("f", "q")))
        #expect(Self.refusal(Fixture.graph([fine, first, second])) == .duplicatePort(Fixture.address("e", "b")))
    }

    @Test func sourceListDoesNotExamineAnObservedShortcutsPorts() throws {
        let shortcut = Fixture.node("ch7", "Console channel 7", kind: .observedShortcut, ports: [
            Fixture.output("x"), Fixture.output("x"), Fixture.input("x")
        ])
        let list = try WiringSourceList.make(in: Fixture.graph([shortcut]))
        #expect(list.sections.map(\.node.rawValue) == ["nod.ch7"])
        #expect(list.rows.isEmpty)
    }

    @Test func sourceListRefusesInTheOrderBoundsNodePort() {
        let dupPorts = Fixture.node("p", "P", ports: [Fixture.output("x"), Fixture.output("x")])
        let dupNode = [Fixture.node("d", "D", ports: []), Fixture.node("d", "D", ports: [])]
        var nodes = (0...ProjectGraphLimits.nodes).map { Fixture.node("f\($0)", "", ports: []) }
        nodes += dupNode + [dupPorts]
        let bounds = WiringSourceListRefusal.bounds(.exceeded(path: "$.nodes", maximum: ProjectGraphLimits.nodes))
        #expect(Self.refusal(Fixture.graph(nodes)) == bounds)
        #expect(Self.refusal(Fixture.graph([dupPorts] + dupNode)) == .duplicateNode(Fixture.node("d")))
        #expect(Self.refusal(Fixture.graph([dupPorts])) == .duplicatePort(Fixture.address("p", "x")))
    }

    @Test func sourceListThatIsRefusedListsNothing() {
        let graph = Fixture.graph([Fixture.node("a", "A", ports: [Fixture.output("x"), Fixture.output("x")])])
        #expect(throws: WiringSourceListRefusal.duplicatePort(Fixture.address("a", "x"))) {
            try WiringSourceList.make(in: graph)
        }
        #expect(Self.refusal(Fixture.docGraph()) == nil)
    }

    static func refusal(_ graph: GraphDocument) -> WiringSourceListRefusal? {
        do {
            _ = try WiringSourceList.make(in: graph)
            return nil
        } catch {
            return error
        }
    }

    static func boundsError(_ graph: GraphDocument) -> ProjectGraphLimitError? {
        do {
            try graph.checkCollectionBounds()
            return nil
        } catch {
            return error
        }
    }
}

/// Graphs for the source list suites, built through the production API.
enum WiringSourceFixture {
    static func id<Tag>(_ raw: String) -> ContractID<Tag> {
        guard let id = ContractID<Tag>(rawValue: raw) else { preconditionFailure("invalid fixture ID \(raw)") }
        return id
    }

    static func node(_ name: String) -> NodeID { id("nod.\(name)") }
    static func edge(_ name: String) -> EdgeID { id("edg.\(name)") }
    static func address(_ node: String, _ port: String) -> PortAddress {
        PortAddress(node: Self.node(node), port: id(port))
    }

    static func output(
        _ name: String, _ signal: PortSignal = .audio, _ channels: Int? = nil, label: String? = nil
    ) -> GraphPort {
        GraphPort(id: id(name), direction: .output, signal: signal, channels: channels, label: label)
    }

    static func input(_ name: String, _ signal: PortSignal = .audio, _ channels: Int? = nil) -> GraphPort {
        GraphPort(id: id(name), direction: .input, signal: signal, channels: channels)
    }

    static func node(
        _ name: String, _ label: String, kind: NodeKind = .plugin, ports: [GraphPort]
    ) -> GraphNode {
        GraphNode(id: node(name), kind: kind, label: label, ports: ports)
    }

    static func graph(_ nodes: [GraphNode]) -> GraphDocument {
        GraphDocument(id: GraphID(validated: "graph.source"), nodes: nodes)
    }

    /// A source-side reading of the phone-compact-routing.md example graph, in an order unlike the list's: Keys,
    /// Vocal, Pads, Soft Synth, Room Verb, Tape Echo, Mains, Space, Cue and the `nod.ch7` shortcut. The mock shows
    /// Soft Synth's MIDI input and its link to Space, so its 2ch audio output is inferred from that link.
    static func docGraph() -> GraphDocument {
        let stereo = [input("in", .audio, 2), output("out", .audio, 2)]
        return graph([
            node("mains", "Mains", ports: [input("in", .audio, 2)]),
            node("space", "Space", ports: [input("in", .audio, 2)]),
            node("cue", "Cue", ports: [input("in", .audio, 2)]),
            node("ch7", "Console channel 7", kind: .observedShortcut, ports: []),
            node("mic", "Vocal", ports: [output("out", .audio, 1)]),
            node("echo", "Tape Echo", ports: stereo),
            node("verb", "Room Verb", ports: stereo + [input("mod", .control)]),
            node("synth", "Soft Synth", ports: [input("in", .midi), output("out", .audio, 2)]),
            node("pads", "Pads", ports: [output("out", .midi)]),
            node("keys", "Keys", ports: [output("out", .audio, 2)])
        ])
    }

    static func docEdges() -> [GraphEdge] {
        [
            GraphEdge(id: edge("keys-verb"), from: address("keys", "out"), to: address("verb", "in")),
            GraphEdge(id: edge("mic-mains"), from: address("mic", "out"), to: address("mains", "in")),
            GraphEdge(id: edge("pads-synth"), from: address("pads", "out"), to: address("synth", "in"))
        ]
    }

    /// Every ordering of `items`.
    static func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }
}
