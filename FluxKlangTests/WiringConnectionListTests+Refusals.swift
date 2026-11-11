//
//  WiringConnectionListTests+Refusals.swift
//  FluxKlangTests
//
//  The Connections list's refusals (#101 WCL1): their fixed order, which unknown node is reported, every edge-ID
//  clause a real review can reach, the review checked against another active graph, bounds and presence for a
//  node that only the draft adds. Pure: graphs and reviews are built in memory.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WiringConnectionListTests {
    @Test func wiringConnectionListRefusesInTheFixedOrder() throws {
        let base = Fixture.graph()
        let review = try Fixture.review(base)
        var broken = base
        broken.edges.removeAll { $0.id == Fixture.edge("keys-echo") }
        let keys = Fixture.out("keys")
        broken.edges.append(GraphEdge(id: Fixture.edge("keys-verb"), from: keys, to: Fixture.input("cue")))
        broken.edges.append(GraphEdge(id: Fixture.edge("ghost"), from: keys, to: Fixture.input("ghost")))
        broken.nodes.append(base.nodes[0])
        var presence = Fixture.presence()
        presence[Fixture.node("cue")] = nil
        var steps = broken
        steps.nodes += (0...ProjectGraphLimits.nodes).map {
            GraphNode(id: Fixture.id("f.\($0)"), kind: .plugin, label: "")
        }
        let make = { (graph: GraphDocument) in
            Self.refusal { () throws(WiringConnectionListRefusal) in
                try WiringConnectionList.make(active: graph, review: review, presence: presence)
            }
        }
        #expect(make(steps) == .bounds(.exceeded(path: "$.nodes", maximum: ProjectGraphLimits.nodes)))
        #expect(make(broken) == .duplicateNode(Fixture.node("keys")))
        broken.nodes.removeLast()
        #expect(make(broken) == .unknownNode(Fixture.node("ghost")))
        broken.edges.removeLast()
        #expect(make(broken) == .duplicateEdge(Fixture.edge("keys-verb")))
        broken.edges.removeLast()
        #expect(make(broken) == .removedEdgeNotActive(Fixture.edge("keys-echo")))
        broken = base
        #expect(make(broken) == .presenceMissing(Fixture.node("cue")))
        presence = Fixture.presence()
        #expect(make(broken) == nil)
    }

    @Test func wiringConnectionListRefusesTheUnknownPresenceKeyWithTheLeastBytes() {
        var presence = Fixture.presence()
        for raw in ["nod.zz", "nod.yy", "nod.b", "nod.Z", "nod.a1", "nod.z9"] { presence[Fixture.id(raw)] = .ready }
        let refusal = Self.refusal { () throws(WiringConnectionListRefusal) in
            try WiringConnectionList.make(active: Fixture.graph(), review: nil, presence: presence)
        }
        #expect(refusal == .unknownNode(Fixture.id("nod.Z")))
    }

    @Test func wiringConnectionListReportsAnUnknownEdgeEndBeforeAnUnknownPresenceKey() {
        var graph = Fixture.graph()
        graph.edges.append(GraphEdge(id: Fixture.edge("ghost"), from: Fixture.out("keys"), to: Fixture.input("ghost")))
        var presence = Fixture.presence()
        presence[Fixture.id("nod.a")] = .ready
        let refusal = Self.refusal { () throws(WiringConnectionListRefusal) in
            try WiringConnectionList.make(active: graph, review: nil, presence: presence)
        }
        #expect(refusal == .unknownNode(Fixture.node("ghost")))
    }

    @Test func wiringConnectionListRefusesARemovedEdgeWhoseActiveEndpointsDiffer() throws {
        let graphA = Fixture.graph()
        let review = try Fixture.review(graphA)
        var graphB = graphA
        let index = try #require(graphB.edges.firstIndex { $0.id == Fixture.edge("keys-echo") })
        graphB.edges[index].to = Fixture.input("cue")
        let refusal = Self.refusal { () throws(WiringConnectionListRefusal) in
            try WiringConnectionList.make(active: graphB, review: review, presence: Fixture.presence())
        }
        #expect(refusal == .removedEdgeNotActive(Fixture.edge("keys-echo")))
    }

    @Test func wiringConnectionListRefusesAnAddedEdgeReusingAnActiveIDTheReviewKeeps() throws {
        let graphA = Fixture.graph()
        let review = try Fixture.review(graphA)
        var graphB = graphA
        graphB.edges.append(GraphEdge(id: Fixture.edge("mic-cue"), from: Fixture.out("keys"), to: Fixture.input("cue")))
        let refusal = Self.refusal { () throws(WiringConnectionListRefusal) in
            try WiringConnectionList.make(active: graphB, review: review, presence: Fixture.presence())
        }
        #expect(refusal == .duplicateEdge(Fixture.edge("mic-cue")))
    }

    @Test func wiringConnectionListRefusesTooManyEdgesAndTooManyPortsOnANode() {
        var edges = Fixture.graph()
        let edge = GraphEdge(id: Fixture.edge("x"), from: Fixture.out("keys"), to: Fixture.input("cue"))
        edges.edges = Array(repeating: edge, count: ProjectGraphLimits.edges + 1)
        var ports = Fixture.graph()
        ports.nodes[0].ports = (0...ProjectGraphLimits.portsPerNode).map {
            GraphPort(id: Fixture.id("p\($0)"), direction: .input, signal: .control)
        }
        let make = { (graph: GraphDocument) in
            Self.refusal { () throws(WiringConnectionListRefusal) in
                try WiringConnectionList.make(active: graph, review: nil, presence: Fixture.presence())
            }
        }
        #expect(make(edges) == .bounds(.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges)))
        #expect(make(ports) == .bounds(.exceeded(
            path: "$.nodes[nod.keys].ports", maximum: ProjectGraphLimits.portsPerNode
        )))
    }

    @Test func wiringConnectionListRefusesADraftAddedDestinationWithoutPresence() throws {
        let active = Fixture.graph()
        let monitor = GraphNode(id: Fixture.node("monitor"), kind: .roleOutput, label: "Monitor", ports: [
            GraphPort(id: Fixture.port("in"), direction: .input, signal: .audio, channels: 2)
        ])
        let review = try Fixture.review(active, [.addNode(monitor)])
        let refusal = Self.refusal { () throws(WiringConnectionListRefusal) in
            try WiringConnectionList.make(active: active, review: review, presence: Fixture.presence())
        }
        #expect(refusal == .presenceMissing(monitor.id))
    }
}
