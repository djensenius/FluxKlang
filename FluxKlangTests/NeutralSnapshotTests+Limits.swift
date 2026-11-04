import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension NeutralSnapshotTests {
    @Test func duplicatePortsAreDroppedAndCounted() throws {
        let node = try Self.node("node.a", ports: ["port.b", "port.a", "port.b", "port.c"])
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: GraphDocument(
            id: GraphID(validated: "graph.p"), nodes: [node]
        )))
        #expect(snapshot.node(Self.nodeA)?.ports.map(\.id.rawValue) == ["port.a", "port.c"])
        #expect(snapshot.truncation.ports == Snapshot.CategoryCount(
            offered: 4, kept: 2, droppedOverLimit: 0, droppedDuplicates: 2
        ))
    }

    @Test func tiesUnderCapsBreakByIDAfterDroppingDuplicates() throws {
        let records = try ["dgn.1", "dgn.4", "dgn.2", "dgn.1", "dgn.5", "dgn.3"].map {
            try Self.diagnostic($0, .warning)
        }
        let routes = try ["rte.c", "rte.a", "rte.a", "rte.d", "rte.b"].map {
            try Self.routeInput($0, binding: .confirmed, presence: .present)
        }
        var limits = Snapshot.Limits()
        limits.diagnostics = 2
        limits.routes = 2
        for _ in 0..<5 {
            let snapshot = Snapshot.build(
                from: Snapshot.Inputs(
                    graph: Self.emptyGraph, routes: routes.shuffled(), diagnostics: records.shuffled()
                ),
                limits: limits
            )
            #expect(snapshot.diagnostics.map(\.id.rawValue) == ["dgn.2", "dgn.3"])
            #expect(snapshot.truncation.diagnostics == Snapshot.CategoryCount(
                offered: 6, kept: 2, droppedOverLimit: 2, droppedDuplicates: 2
            ))
            #expect(snapshot.routes.map(\.id.rawValue) == ["rte.b", "rte.c"])
            #expect(snapshot.truncation.routes.droppedDuplicates == 2)
            #expect(snapshot.truncation.routes.droppedOverLimit == 1)
        }
    }

    @Test func portLabelsAreSanitizedAndCounted() throws {
        var node = try Self.node("node.a", label: "Plain")
        node.ports[0].label = "In\u{202E}\u{0}" + String(repeating: "x", count: 200)
        node.ports[1].label = nil
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: GraphDocument(
            id: GraphID(validated: "graph.s"), nodes: [node]
        )))
        let label = try #require(snapshot.node(Self.nodeA)?.ports.first?.label)
        #expect(label.text.hasPrefix("In x") && label.text.utf8.count == 128)
        #expect(label.isTruncated && label.wasSanitized)
        #expect(snapshot.node(Self.nodeA)?.ports.last?.label == nil)
        #expect(snapshot.truncation.sanitizedLabels == 1 && snapshot.truncation.truncatedLabels == 1)
    }

    @Test func nonPositiveLimitsAreClampedToKeepNothing() throws {
        let limits = Snapshot.Limits(
            nodes: 0, portsPerNode: -1, edges: -5, parameters: 0, routes: -1, diagnostics: 0, labelBytes: -3
        )
        let snapshot = try Snapshot.build(from: Self.sampleInputs(), limits: limits)
        #expect(snapshot.nodes.isEmpty && snapshot.edges.isEmpty && snapshot.parameters.isEmpty)
        #expect(snapshot.routes.isEmpty && snapshot.diagnostics.isEmpty)
        #expect(snapshot.truncation.nodes.droppedOverLimit == 3 && snapshot.truncation.edges.droppedDangling == 2)
        #expect(snapshot.truncation.routes.droppedOverLimit == 3 && snapshot.truncation.diagnostics.isTruncated)
        #expect(snapshot.graph.label == UntrustedLabel("Main", maximumBytes: 0))
        #expect(snapshot.graph.label?.text == "" && snapshot.graph.label?.isTruncated == true)
        #expect(UntrustedLabel("abc", maximumBytes: -1) == UntrustedLabel("abc", maximumBytes: 0))
    }

    @Test func encodedShapeIsPinned() throws {
        var port = GraphPort(id: Self.portIn, direction: .input, signal: .audio, label: "In")
        port.extensions = ["x": .string("dropped")]
        let node = GraphNode(id: Self.nodeA, kind: .plugin, label: "A", ports: [port])
        var limits = Snapshot.Limits()
        limits.nodes = 4
        let inputs = try Snapshot.Inputs(
            graph: GraphDocument(id: GraphID(validated: "graph.g"), nodes: [node]),
            routes: [Self.routeInput("rte.a", binding: .confirmed, presence: nil)],
            diagnostics: [
                Self.diagnostic("dgn.a", .error, summary: "S", subject: .port(node: Self.nodeA, port: Self.portIn)),
                Self.diagnostic("dgn.b", .info, summary: "T"),
                Self.diagnostic("dgn.c", .warning, summary: "U", subject: .graph)
            ]
        )
        let data = try Self.encode(Snapshot.build(from: inputs, limits: limits))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == Self.golden)
    }
}
