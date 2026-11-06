import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct NeutralSnapshotTests {
    typealias Snapshot = NeutralSnapshot

    // MARK: - Determinism and empty inputs

    @Test func shuffledInputsBuildEqualSnapshotsAndBytes() throws {
        let inputs = try Self.sampleInputs()
        let shuffled = Snapshot.Inputs(
            graph: GraphDocument(
                id: inputs.graph.id, revision: inputs.graph.revision, label: inputs.graph.label,
                nodes: inputs.graph.nodes.reversed().map { node in
                    var node = node
                    node.ports.reverse()
                    return node
                },
                edges: inputs.graph.edges.reversed()
            ),
            parameters: inputs.parameters.reversed(), routes: inputs.routes.reversed(),
            diagnostics: inputs.diagnostics.reversed(), project: inputs.project
        )
        let first = Snapshot.build(from: inputs)
        let second = Snapshot.build(from: shuffled)
        #expect(first == second)
        #expect(try Self.encode(first) == Self.encode(second))
        #expect(first.nodes.map(\.id.rawValue) == ["node.a", "node.b", "node.c"])
        #expect(first.node(Self.nodeA)?.ports.map(\.id.rawValue) == ["port.in", "port.out"])
        #expect(first.edges.map(\.id.rawValue) == ["edge.ab", "edge.bc"])
        #expect(first.routes.map(\.id.rawValue) == ["rte.cue", "rte.mains", "rte.space"])
        #expect(first.project?.revision.value == 7)
        #expect(!first.truncation.isTruncated)
    }

    @Test func emptyInputsBuildAnEmptyUntruncatedSnapshot() throws {
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: Self.emptyGraph))
        #expect(snapshot.nodes.isEmpty && snapshot.edges.isEmpty && snapshot.parameters.isEmpty)
        #expect(snapshot.routes.isEmpty && snapshot.diagnostics.isEmpty && snapshot.unavailableRoutes.isEmpty)
        #expect(snapshot.project == nil && snapshot.graph.label == nil)
        #expect(snapshot.truncation.nodes == Snapshot.CategoryCount(
            offered: 0, kept: 0, droppedOverLimit: 0, droppedDuplicates: 0
        ))
        #expect(!snapshot.truncation.isTruncated && snapshot.truncation.truncatedLabels == 0)
        #expect(snapshot.node(Self.nodeA) == nil && snapshot.edges(node: Self.nodeA, port: Self.portOut).isEmpty)
    }

    // MARK: - Caps

    @Test func graphCapsKeepLowestIDsAndCountDrops() throws {
        let nodes = try (0..<6).map { index in
            try Self.node("node.\(index)", ports: (0..<4).map { "port.\($0)" })
        }
        let edges = try (0..<5).map { try Self.edge("edge.\($0)", from: "node.0", "port.0", to: "node.1", "port.1") }
        var limits = Snapshot.Limits()
        limits.nodes = 2
        limits.portsPerNode = 3
        limits.edges = 4
        let graph = GraphDocument(id: GraphID(validated: "graph.cap"), nodes: nodes.shuffled(), edges: edges.shuffled())
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: graph), limits: limits)
        #expect(snapshot.nodes.map(\.id.rawValue) == ["node.0", "node.1"])
        #expect(snapshot.truncation.nodes == Snapshot.CategoryCount(
            offered: 6, kept: 2, droppedOverLimit: 4, droppedDuplicates: 0
        ))
        #expect(snapshot.nodes.allSatisfy { $0.ports.map(\.id.rawValue) == ["port.0", "port.1", "port.2"] })
        #expect(snapshot.truncation.ports == Snapshot.CategoryCount(
            offered: 24, kept: 6, droppedOverLimit: 2, droppedDuplicates: 0, droppedDangling: 16
        ))
        #expect(snapshot.edges.map(\.id.rawValue) == ["edge.0", "edge.1", "edge.2", "edge.3"])
        #expect(snapshot.truncation.edges.isTruncated && snapshot.truncation.edges.droppedOverLimit == 1)
        #expect(snapshot.truncation.isTruncated)
    }

    @Test func parameterCapKeepsLowestIDs() throws {
        let parameters = try (0..<5).map { try Self.parameter("par.\($0)") }
        var limits = Snapshot.Limits()
        limits.parameters = 2
        let snapshot = Snapshot.build(
            from: Snapshot.Inputs(graph: Self.emptyGraph, parameters: parameters.shuffled()), limits: limits
        )
        #expect(snapshot.parameters.map(\.id.rawValue) == ["par.0", "par.1"])
        #expect(snapshot.truncation.parameters == Snapshot.CategoryCount(
            offered: 5, kept: 2, droppedOverLimit: 3, droppedDuplicates: 0
        ))
        #expect(snapshot.truncation.isTruncated)
    }

    @Test func routeCapKeepsUnavailableRoutesFirst() throws {
        let routes = try [
            Self.routeInput("rte.a", binding: .confirmed, presence: .present),
            Self.routeInput("rte.b", binding: .confirmed, presence: .present),
            Self.routeInput("rte.y", binding: .confirmed, presence: .missing),
            Self.routeInput("rte.z", binding: .stale, presence: .present)
        ]
        var limits = Snapshot.Limits()
        limits.routes = 3
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: Self.emptyGraph, routes: routes), limits: limits)
        #expect(snapshot.routes.map(\.id.rawValue) == ["rte.a", "rte.y", "rte.z"])
        #expect(snapshot.truncation.routes == Snapshot.CategoryCount(
            offered: 4, kept: 3, droppedOverLimit: 1, droppedDuplicates: 0
        ))
        #expect(snapshot.unavailableRoutes.map(\.id.rawValue) == ["rte.y", "rte.z"])
    }

    @Test func diagnosticCapKeepsMostSevereFirst() throws {
        let records = try [
            Self.diagnostic("dgn.a", .info), Self.diagnostic("dgn.b", .warning),
            Self.diagnostic("dgn.c", .error), Self.diagnostic("dgn.d", .warning), Self.diagnostic("dgn.e", .info)
        ]
        var limits = Snapshot.Limits()
        limits.diagnostics = 2
        let snapshot = Snapshot.build(
            from: Snapshot.Inputs(graph: Self.emptyGraph, diagnostics: records.shuffled()), limits: limits
        )
        #expect(snapshot.diagnostics.map(\.id.rawValue) == ["dgn.b", "dgn.c"])
        #expect(snapshot.truncation.diagnostics.droppedOverLimit == 3 && snapshot.truncation.diagnostics.isTruncated)
    }

    @Test func duplicateIDsAreDroppedAndCountedNotTruncation() throws {
        let graph = try GraphDocument(
            id: GraphID(validated: "graph.dup"),
            nodes: [Self.node("node.a", label: "One"), Self.node("node.a", label: "Two"), Self.node("node.b")]
        )
        let routes = try [
            Self.routeInput("rte.a", binding: .confirmed, presence: .present),
            Self.routeInput("rte.a", binding: .stale, presence: .stale)
        ]
        let snapshot = Snapshot.build(from: Snapshot.Inputs(graph: graph, routes: routes))
        #expect(snapshot.nodes.map(\.id.rawValue) == ["node.b"])
        #expect(snapshot.truncation.nodes == Snapshot.CategoryCount(
            offered: 3, kept: 1, droppedOverLimit: 0, droppedDuplicates: 2
        ))
        #expect(snapshot.routes.isEmpty && snapshot.truncation.routes.dropped == 2)
        #expect(!snapshot.truncation.isTruncated)
    }
}
