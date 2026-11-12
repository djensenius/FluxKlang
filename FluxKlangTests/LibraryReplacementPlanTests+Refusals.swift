//
//  LibraryReplacementPlanTests+Refusals.swift
//  FluxKlangTests
//
//  The refusals of the Library replacement plan (#101 REP1) in the order of `LibraryReplacementRefusal`'s cases,
//  the accepted maxima, the proof that a refused or a dropped edge is never bypassed, and the graphs the suite
//  builds through the production API.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension LibraryReplacementPlanTests {
    @Test func graphBoundsAreCheckedBeforeEverythingElse() {
        let nodes = (0...ProjectGraphLimits.nodes).map { Fixture.plugin("n\($0)", "N", ports: []) }
        let ports = (0...ProjectGraphLimits.portsPerNode).map { Fixture.lport("p\($0)", .input) }
        let refusal = Self.refusal(Fixture.layout(ports: ports), replacing: "zzz", in: Fixture.graph(nodes: nodes))
        #expect(refusal == .bounds(.exceeded(path: "$.nodes", maximum: 4_096)))
    }

    @Test func layoutPortBoundsComeBeforeTheNodeChecks() {
        let ports = (0...ProjectGraphLimits.portsPerNode).map { Fixture.lport("p\($0)", .input) }
        #expect(Self.refusal(Fixture.layout(ports: ports), replacing: "zzz") == .bounds(
            .exceeded(path: "$.replacement.ports", maximum: 256)
        ))
        let duplicated = Fixture.layout(ports: ports + [Fixture.lport("p0", .input)])
        #expect(Self.refusal(duplicated) == .bounds(.exceeded(path: "$.replacement.ports", maximum: 256)))
    }

    @Test func aRepeatedNodeIDIsRefusedBeforeAnUnknownTarget() {
        let nodes = Fixture.nodes() + [Fixture.plugin("verb", "Again", ports: [])]
        let graph = Fixture.graph(nodes: nodes)
        #expect(Self.refusal(Fixture.spring(), replacing: "zzz", in: graph) == .duplicateNode(Fixture.node("verb")))
        #expect(Self.refusal(Fixture.spring(), in: graph) == .duplicateNode(Fixture.node("verb")))
    }

    @Test func anUnknownTargetIsRefusedBeforeItsKind() {
        #expect(Self.refusal(Fixture.spring(), replacing: "zzz") == .unknownNode(Fixture.node("zzz")))
    }

    @Test func aNonPluginTargetIsRefusedBeforeAClashingReplacementID() {
        var keys = Fixture.keys()
        keys.kind = .externalInsert
        let graph = Fixture.graph(nodes: [Fixture.echo(), keys, Fixture.verb(), Fixture.mains(), Fixture.pads()])
        let refusal = Self.refusal(Fixture.spring(), replacing: "keys", as: "verb", in: graph)
        #expect(refusal == .notAPlugin(Fixture.node("keys")))
    }

    @Test func aRepeatedPortOfTheTargetIsRefusedBeforeAClashingReplacementID() {
        let echo = Fixture.echo(ports: [
            Fixture.gport("in", .input), Fixture.gport("out", .output), Fixture.gport("in", .input)
        ])
        let graph = Fixture.graph(nodes: [echo, Fixture.keys(), Fixture.verb(), Fixture.mains(), Fixture.pads()])
        #expect(Self.refusal(Fixture.spring(), as: "verb", in: graph) == .duplicatePort(Fixture.address("echo", "in")))
    }

    @Test func aReplacementIDAlreadyInTheGraphIsRefusedEvenWhenItIsTheOldNode() {
        #expect(Self.refusal(Fixture.spring(), as: "verb") == .replacementIDInUse(Fixture.node("verb")))
        #expect(Self.refusal(Fixture.spring(), as: "echo") == .replacementIDInUse(Fixture.node("echo")))
    }

    @Test func aRepeatedLayoutPortIsRefusedBeforeARepeatedEdge() {
        let layout = Fixture.layout(ports: [
            Fixture.lport("in", .input), Fixture.lport("out", .output), Fixture.lport("out", .output)
        ])
        let edges = Fixture.edges() + [Fixture.edges()[0]]
        #expect(Self.refusal(layout, in: Fixture.graph(edges: edges)) == .duplicateLayoutPort(Fixture.port("out")))
    }

    @Test func aRepeatedEdgeTouchingTheTargetIsRefused() {
        let edges = Fixture.edges() + [Fixture.edges()[0]]
        let refusal = Self.refusal(Fixture.spring(), in: Fixture.graph(edges: edges))
        #expect(refusal == .duplicateEdge(Fixture.edge("keys-echo")))
    }

    @Test func aRepeatedEdgeNotTouchingTheTargetIsNotRefused() throws {
        let pads = Fixture.edges()[3]
        let plan = try Fixture.plan(Fixture.spring(), in: Fixture.graph(edges: Fixture.edges() + [pads]))
        #expect(plan.keptEdges.count == 3)
    }

    @Test func aRefusalPlansNothingAndLeavesTheGraphAlone() {
        let graph = Fixture.graph()
        #expect(Self.refusal(Fixture.spring(), as: "verb", in: graph) != nil)
        #expect(graph == Fixture.graph())
    }

    @Test func theMaximumEdgesAndLayoutPortsAreAccepted() throws {
        let fillers = (0..<(ProjectGraphLimits.edges - Fixture.edges().count)).map {
            Fixture.wire("fill\($0)", from: ("keys", "out"), to: ("verb", "in"))
        }
        let graph = Fixture.graph(edges: Fixture.edges() + fillers)
        let extra = (0..<(ProjectGraphLimits.portsPerNode - 2)).map { Fixture.lport("x\($0)", .input, .control, nil) }
        let layout = Fixture.layout(ports: Fixture.stereoPorts() + extra)
        #expect(graph.edges.count == 16_384)
        #expect(layout.ports.count == 256)
        let plan = try Fixture.plan(layout, in: graph)
        #expect(plan.keptEdges.count == 3)
        #expect(plan.ports.count == 256)
    }

    @Test func aDroppedEdgeIsNeverBypassed() throws {
        let graph = Fixture.graph(edges: [Fixture.edges()[0], Fixture.edges()[1], Fixture.edges()[3]])
        let layout = Fixture.layout(ports: [Fixture.lport("aux", .output, .control, nil)])
        let plan = try Fixture.plan(layout, in: graph)
        #expect(plan.keptEdges.isEmpty)
        #expect(plan.droppedEdges.map(\.edge.id.rawValue) == ["edg.echo-verb", "edg.keys-echo"])
        try #require(plan.graphEdits.count == 2)
        #expect(plan.graphEdits[0] == .removeNode(Fixture.node("echo")))
        #expect(plan.graphEdits[1] == .addNode(plan.replacementNode))
        let applied = try graph.applying(plan.graphEdits)
        #expect(applied.edges.map(\.id.rawValue) == ["edg.pads-verb"])
        #expect(!applied.edges.contains { $0.from.node == Fixture.node("keys") && $0.to.node == Fixture.node("verb") })
        #expect(applied.nodes.map(\.id.rawValue) == ["nod.keys", "nod.verb", "nod.mains", "nod.pads", "nod.spring"])
    }

    @Test func everyKeptEdgeTouchesTheReplacementAndNoOtherEdgeIsAdded() throws {
        let layout = Fixture.layout(ports: [Fixture.lport("in", .input, .audio, 2)])
        let plan = try Fixture.plan(layout)
        try #require(plan.keptEdges.count == 1)
        for edit in plan.graphEdits {
            guard case .connect(let edge) = edit else { continue }
            #expect(edge.from.node == Fixture.node("spring") || edge.to.node == Fixture.node("spring"))
        }
        #expect(plan.graphEdits.count == 3)
        #expect(plan.droppedEdges.map(\.edge.id.rawValue) == ["edg.echo-mains", "edg.echo-verb"])
    }

    @Test func theFirstRepeatIsReportedWhenTwoIDsRepeatCrossed() {
        let crossedNodes = Fixture.graph(nodes: Fixture.nodes() + [Fixture.pads(), Fixture.mains()])
        #expect(Self.refusal(Fixture.spring(), in: crossedNodes) == .duplicateNode(Fixture.node("pads")))
        let echo = Fixture.echo(ports: [
            Fixture.gport("in", .input), Fixture.gport("out", .output),
            Fixture.gport("out", .output), Fixture.gport("in", .input)
        ])
        let crossedPorts = Fixture.graph(nodes: [echo, Fixture.keys(), Fixture.verb(), Fixture.mains(), Fixture.pads()])
        #expect(Self.refusal(Fixture.spring(), in: crossedPorts) == .duplicatePort(Fixture.address("echo", "out")))
        let layout = Fixture.layout(ports: [
            Fixture.lport("in", .input), Fixture.lport("out", .output),
            Fixture.lport("out", .output), Fixture.lport("in", .input)
        ])
        #expect(Self.refusal(layout) == .duplicateLayoutPort(Fixture.port("out")))
        let edges = Fixture.edges()
        let crossedEdges = Fixture.graph(edges: [edges[0], edges[1], edges[1], edges[0]])
        #expect(Self.refusal(Fixture.spring(), in: crossedEdges) == .duplicateEdge(Fixture.edge("echo-verb")))
    }

    @Test func aNonPluginTargetIsRefusedBeforeItsRepeatedPort() {
        var keys = Fixture.keys()
        keys.kind = .externalInsert
        keys.ports = [Fixture.gport("out", .output), Fixture.gport("out", .output)]
        let graph = Fixture.graph(nodes: [Fixture.echo(), keys, Fixture.verb(), Fixture.mains(), Fixture.pads()])
        #expect(Self.refusal(Fixture.spring(), replacing: "keys", in: graph) == .notAPlugin(Fixture.node("keys")))
    }

    @Test func aReplacementIDInUseIsRefusedBeforeARepeatedLayoutPort() {
        let layout = Fixture.layout(ports: [Fixture.lport("out", .output), Fixture.lport("out", .output)])
        #expect(Self.refusal(layout, as: "verb") == .replacementIDInUse(Fixture.node("verb")))
    }

    @Test func theEditCountMustFitOneBatch() throws {
        let accepted = try Fixture.plan(Fixture.spring(), in: Fixture.graph(edges: Fixture.echoWires(4_094)))
        #expect(accepted.keptEdges.count == 4_094)
        try #require(accepted.graphEdits.count == 4_096)
        try GraphEdit.validateBatch(accepted.graphEdits)
        let refusal = Self.refusal(Fixture.spring(), in: Fixture.graph(edges: Fixture.echoWires(4_095)))
        #expect(refusal == .bounds(.exceeded(path: "$.edits", maximum: 4_096)))
    }

    @Test func droppedEdgesDoNotCountTowardTheEditLimit() throws {
        let graph = Fixture.graph(edges: Fixture.echoWires(5_000))
        let plan = try Fixture.plan(Fixture.layout(ports: []), in: graph)
        #expect(plan.keptEdges.isEmpty)
        #expect(plan.droppedEdges.count == 5_000)
        #expect(plan.graphEdits.count == 2)
    }

    static func refusal(
        _ layout: LibraryReplacementLayout, replacing node: String = "echo", as replacement: String = "spring",
        in graph: GraphDocument = Fixture.graph()
    ) -> LibraryReplacementRefusal? {
        do {
            _ = try LibraryReplacementPlan.make(
                replacing: Fixture.node(node), with: layout, as: Fixture.node(replacement), in: graph
            )
            return nil
        } catch {
            return error
        }
    }

    /// Graphs for the replacement suite, built through the production API.
    enum Fixture {
        static func id<Tag>(_ raw: String) -> ContractID<Tag> {
            guard let id = ContractID<Tag>(rawValue: raw) else { preconditionFailure("invalid fixture ID \(raw)") }
            return id
        }

        static func node(_ name: String) -> NodeID { id("nod.\(name)") }
        static func edge(_ name: String) -> EdgeID { id("edg.\(name)") }
        static func port(_ name: String) -> PortID { id(name) }
        static func address(_ node: String, _ port: String) -> PortAddress {
            PortAddress(node: Self.node(node), port: Self.port(port))
        }

        static func gport(
            _ name: String, _ direction: PortDirection, _ signal: PortSignal = .audio, _ channels: Int? = 2
        ) -> GraphPort {
            GraphPort(id: port(name), direction: direction, signal: signal, channels: channels)
        }

        static func lport(
            _ name: String, _ direction: PortDirection, _ signal: PortSignal = .audio, _ channels: Int? = 2,
            label: String? = nil
        ) -> LibraryReplacementPort {
            LibraryReplacementPort(
                id: port(name), direction: direction, signal: signal, channels: channels, label: label
            )
        }

        static func plugin(_ name: String, _ label: String, ports: [GraphPort]) -> GraphNode {
            GraphNode(id: node(name), kind: .plugin, label: label, ports: ports)
        }

        static func stereoGraphPorts() -> [GraphPort] { [gport("in", .input), gport("out", .output)] }
        static func stereoPorts() -> [LibraryReplacementPort] { [lport("in", .input), lport("out", .output)] }

        /// The missing plugin: Tape Echo at (10, 20) with an advisory capability.
        static func echo(ports: [GraphPort]? = nil, position: GraphPoint = GraphPoint(x: 10, y: 20)) -> GraphNode {
            GraphNode(
                id: node("echo"), kind: .plugin, label: "Tape Echo", ports: ports ?? stereoGraphPorts(),
                advisoryCapabilities: [id("cap.echo")], position: position
            )
        }

        static func keys() -> GraphNode { plugin("keys", "Keys", ports: [gport("out", .output)]) }
        static func verb() -> GraphNode {
            plugin("verb", "Room Verb", ports: [gport("in", .input), gport("mod", .input, .control, nil)])
        }

        static func mains() -> GraphNode { plugin("mains", "Mains", ports: [gport("in", .input)]) }
        static func pads() -> GraphNode { plugin("pads", "Pads", ports: [gport("out", .output, .midi, nil)]) }
        static func nodes() -> [GraphNode] { [echo(), keys(), verb(), mains(), pads()] }

        static func wire(
            _ name: String, from: (String, String), to: (String, String), conversion: EdgeConversion? = nil,
            extensions: [String: JSONValue]? = nil
        ) -> GraphEdge {
            GraphEdge(
                id: edge(name), from: address(from.0, from.1), to: address(to.0, to.1), conversion: conversion,
                extensions: extensions
            )
        }

        /// In this order: keys-echo, echo-verb, echo-mains (with a conversion), pads-verb (not touching the echo).
        static func edges() -> [GraphEdge] {
            [
                wire("keys-echo", from: ("keys", "out"), to: ("echo", "in")),
                wire("echo-verb", from: ("echo", "out"), to: ("verb", "in"), extensions: ["note": .string("keep")]),
                wire(
                    "echo-mains", from: ("echo", "out"), to: ("mains", "in"),
                    conversion: EdgeConversion(map: [[0], [1]])
                ),
                wire("pads-verb", from: ("pads", "out"), to: ("verb", "mod"))
            ]
        }

        static func graph(nodes: [GraphNode]? = nil, edges: [GraphEdge]? = nil) -> GraphDocument {
            GraphDocument(
                id: GraphID(validated: "graph.replace"), nodes: nodes ?? self.nodes(), edges: edges ?? self.edges()
            )
        }

        static func layout(
            _ key: String = "lay.spring", _ name: String = "Spring Reverb", ports: [LibraryReplacementPort]
        ) -> LibraryReplacementLayout {
            LibraryReplacementLayout(key: key, name: name, ports: ports)
        }

        /// `Spring Reverb`: the echo's own `in` and `out`.
        static func spring() -> LibraryReplacementLayout { layout(ports: stereoPorts()) }

        static func plan(
            _ layout: LibraryReplacementLayout, in graph: GraphDocument = Fixture.graph()
        ) throws(LibraryReplacementRefusal) -> LibraryReplacementPlan {
            try LibraryReplacementPlan.make(
                replacing: node("echo"), with: layout, as: node("spring"), in: graph
            )
        }

        /// `count` edges `echo.out -> verb.in` with distinct IDs.
        static func echoWires(_ count: Int) -> [GraphEdge] {
            (0..<count).map { wire("wire\($0)", from: ("echo", "out"), to: ("verb", "in")) }
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
}
