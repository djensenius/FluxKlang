//
//  WiringMatrixTests+EdgeBound.swift
//  FluxKlangTests
//
//  Edge-bound wiring matrix behavior and validation-count regressions.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture
private typealias Edit = WiringEditFixture

extension WiringMatrixTests {
    @Test func nonWiredPairsToTwoPortsOfOneNodeStayAtBounds() throws {
        let echoOut = Fixture.address("nod.echo", "out"), mainsIn = Fixture.address("nod.mains", "in")
        var graph = Fixture.graph
        let mainsIndex = try #require(graph.nodes.firstIndex { $0.id == mainsIn.node })
        graph.nodes[mainsIndex].ports.append(Fixture.audio("in.alt", .input, 2))
        let alternateIn = Fixture.address("nod.mains", "in.alt")
        let filler = Fixture.address("nod.keys", "out")
        graph.edges += (graph.edges.count..<ProjectGraphLimits.edges).map {
            GraphEdge(id: Fixture.id("edg.fill-\($0)"), from: filler, to: Fixture.address("nod.verb", "in"))
        }
        let matrix = try WiringMatrix.window(
            rows: [echoOut], columns: [mainsIn, alternateIn], active: graph, draft: Edit.draft(on: graph)
        )
        let bound = WiringMatrixCellState.uncheckable(
            .bounds(.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges))
        )
        #expect(matrix.cell(row: 0, column: 0)?.state == bound)
        #expect(matrix.cell(row: 0, column: 1)?.state == bound)
    }

    @Test func unknownDestinationAtBound() throws {
        let ghost = Fixture.address("nod.ghost", "in")
        let belowBound = EndpointBoundFixture.graph(atLimit: false, withBrokenNode: false)
        #expect(try EndpointBoundFixture.cellState(in: belowBound, to: ghost)
            == .uncheckable(.unknownNode(ghost.node)))

        let atBound = EndpointBoundFixture.graph(atLimit: true, withBrokenNode: false)
        #expect(atBound.edges.count == ProjectGraphLimits.edges)
        #expect(try EndpointBoundFixture.cellState(in: atBound, to: ghost) == EndpointBoundFixture.bounds)
    }

    @Test func uncheckableDestinationAtBound() throws {
        let brokenNode = NodeID(validated: "nod.broken")
        let brokenInput = Fixture.address("nod.broken", "in")
        let belowBound = EndpointBoundFixture.graph(atLimit: false, withBrokenNode: true)
        #expect(try EndpointBoundFixture.cellState(in: belowBound, to: brokenInput)
            == .uncheckable(.endpointUncheckable(node: brokenNode)))

        let atBound = EndpointBoundFixture.graph(atLimit: true, withBrokenNode: true)
        #expect(atBound.edges.count == ProjectGraphLimits.edges)
        #expect(try EndpointBoundFixture.cellState(in: atBound, to: brokenInput) == EndpointBoundFixture.bounds)
    }

    @Test func wiredCellsAtTheEdgeBoundShowOnAndToggleOff() throws {
        let keysOut = Fixture.address("nod.keys", "out"), verbIn = Fixture.address("nod.verb", "in")
        let mainsIn = Fixture.address("nod.mains", "in")
        let verbOut = Fixture.address("nod.verb", "out"), echoIn = Fixture.address("nod.echo", "in")
        var graph = Fixture.graph
        graph.edges += (graph.edges.count..<ProjectGraphLimits.edges).map {
            GraphEdge(id: Fixture.id("edg.fill-\($0)"), from: keysOut, to: verbIn)
        }
        #expect(graph.edges.count == ProjectGraphLimits.edges)
        let draft = Edit.draft(on: graph)
        let matrix = try WiringMatrix.window(rows: [keysOut], columns: [verbIn, mainsIn], active: graph, draft: draft)
        let keysVerb = Fixture.id("edg.keys-verb") as EdgeID
        let wired = try #require(matrix.cell(row: 0, column: 0))
        #expect(wired.state == .classified(.existing(keysVerb)) && wired.connectionClass == .existing)
        #expect(wired.wiredEdge == keysVerb && wired.existingEdge == keysVerb && wired.isOn)
        let open = try #require(matrix.cell(row: 0, column: 1))
        let atBound = WiringMatrixCellState.uncheckable(
            .bounds(.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges))
        )
        #expect(open.state == atBound && open.wiredEdge == nil && open.existingEdge == nil && !open.isOn)
        #expect(try WiringCandidate.classify(from: keysOut, to: verbIn, in: graph).connection == .existing(keysVerb))
        #expect(try WiringCandidate.classify(from: verbOut, to: echoIn, in: Fixture.graph).connection
            == .feedbackOnly(cycle: [NodeID(validated: "nod.echo"), NodeID(validated: "nod.verb")]))
        let feedbackMatrix = try WiringMatrix.window(
            rows: [verbOut], columns: [echoIn], active: graph, draft: draft
        )
        #expect(feedbackMatrix.cell(row: 0, column: 0)?.state == .uncheckable(
            .bounds(.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges))
        ))
        let toggled = try WiringMatrix.toggle(wired, request: WiringMatrixConnect(edge: Fixture.id("edg.unused")),
                                              in: draft, active: graph)
        #expect(toggled == (try WiringRemoveComposer.remove(edge: keysVerb, from: draft, active: graph)))
        #expect(toggled.edits == [.disconnect(keysVerb)])
    }

    @Test func edgeBoundWindowUsesOneValidationPerRowForWiredPairs() throws {
        try WiringMatrixEdgeBoundRegression.run()
    }

    @Test func edgeBoundRefusalSkipsCycleSearch() throws {
        let graph = CycleSearchBoundFixture.graph(atLimit: true)
        let destinations = CycleSearchBoundFixture.destinations
        let source = CycleSearchBoundFixture.source
        let boundRefusal = WiringPreviewRefusal.bounds(
            .exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges)
        )
        #expect(graph.edges.count == ProjectGraphLimits.edges)
        var context = try WiringCandidateContext(
            source: source, in: graph, onValidate: {}, allowsExistingAtEdgeBound: true
        )
        let wired = try context.connection(to: destinations[0])
        #expect(wired == .existing(Fixture.id("edg.bound-existing")))
        #expect(context.cycles.isEmpty)
        for destination in destinations.dropFirst() {
            let cached = context.cycles
            #expect(throws: boundRefusal) { try context.connection(to: destination) }
            #expect(context.cycles == cached)
        }
        #expect(context.cycles.isEmpty)

        let belowBound = CycleSearchBoundFixture.graph(atLimit: false)
        var belowContext = try WiringCandidateContext(
            source: source, in: belowBound, onValidate: {}, allowsExistingAtEdgeBound: true
        )
        #expect(try belowContext.connection(to: destinations[0]) == wired)
        for destination in destinations.dropFirst() {
            let expected = WiringConnection.feedbackOnly(cycle: [source.node, destination.node].sorted())
            #expect(try belowContext.connection(to: destination) == expected)
            #expect(belowContext.cycles[destination.node] == expected)
        }
        #expect(belowContext.cycles.count == destinations.count - 1)
    }
}

private enum CycleSearchBoundFixture {
    static let source = Fixture.address("nod.bound-source", "out")
    static let sourceInput = Fixture.address("nod.bound-source", "in")
    static let relay = Fixture.address("nod.bound-relay", "in")
    static let relayOutput = Fixture.address("nod.bound-relay", "out")
    static let destinations = (0..<8).map { Fixture.address("nod.bound-d\($0)", "in") }

    static func graph(atLimit: Bool) -> GraphDocument {
        let nodes = [
            Fixture.node("nod.bound-source", ports: [Fixture.audio("in", .input, 1),
                                                     Fixture.audio("out", .output, 1)]),
            Fixture.node("nod.bound-relay", ports: [Fixture.audio("in", .input, 1),
                                                    Fixture.audio("out", .output, 1)])
        ] + (0..<destinations.count).map {
            Fixture.node("nod.bound-d\($0)", ports: [Fixture.audio("in", .input, 1),
                                                      Fixture.audio("out", .output, 1)])
        }
        var edges = [
            Fixture.edge("edg.bound-source-relay", source, relay),
            Fixture.edge("edg.bound-relay-source", relayOutput, sourceInput),
            Fixture.edge("edg.bound-existing", source, destinations[0])
        ]
        for index in destinations.indices {
            let next = (index + 1) % destinations.count
            edges.append(Fixture.edge(
                "edg.bound-cycle-\(index)",
                Fixture.address("nod.bound-d\(index)", "out"),
                destinations[next]
            ))
        }
        let limit = ProjectGraphLimits.edges - (atLimit ? 0 : 1)
        for index in edges.count..<limit {
            edges.append(Fixture.edge("edg.bound-fill-\(index)", source, relay))
        }
        return GraphDocument(id: Fixture.graphID, nodes: nodes, edges: edges)
    }
}

private enum EndpointBoundFixture {
    static let source = Fixture.address("nod.keys", "out")
    static let fillerTarget = Fixture.address("nod.verb", "in")
    static let bounds = WiringMatrixCellState.uncheckable(
        .bounds(.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges))
    )

    static func graph(atLimit: Bool, withBrokenNode: Bool) -> GraphDocument {
        var graph = Fixture.graph
        if withBrokenNode {
            graph.nodes.append(Fixture.node("nod.broken", ports: [Fixture.audio("in", .input, nil)]))
        }
        if atLimit {
            graph.edges += (graph.edges.count..<ProjectGraphLimits.edges).map {
                GraphEdge(id: Fixture.id("edg.endpoint-fill-\($0)"), from: source, to: fillerTarget)
            }
        }
        return graph
    }

    static func cellState(in graph: GraphDocument, to destination: PortAddress) throws -> WiringMatrixCellState? {
        let matrix = try WiringMatrix.window(
            rows: [source], columns: [destination], active: graph, draft: Edit.draft(on: graph)
        )
        return matrix.cell(row: 0, column: 0)?.state
    }
}

private enum WiringMatrixEdgeBoundRegression {
    static func run() throws {
        let keysOut = Fixture.address("nod.keys", "out"), echoOut = Fixture.address("nod.echo", "out")
        let verbOut = Fixture.address("nod.verb", "out"), verbIn = Fixture.address("nod.verb", "in")
        let tapOut = Fixture.address("nod.tap", "out"), mainsIn = Fixture.address("nod.mains", "in")
        let delayIn = Fixture.address("nod.delay", "in"), micOut = Fixture.address("nod.mic", "out")
        let modIn = Fixture.address("nod.verb", "mod")
        var graph = Fixture.graph
        graph.nodes.append(Fixture.node("nod.tap", .observedShortcut, ports: [Fixture.audio("out", .output, 2)]))
        let fillDestinations = [verbIn, mainsIn, delayIn]
        graph.edges += (graph.edges.count..<ProjectGraphLimits.edges).map {
            GraphEdge(id: Fixture.id("edg.fill-\($0)"), from: keysOut,
                      to: fillDestinations[$0 % fillDestinations.count])
        }
        let draft = Edit.draft(on: graph), rows = [keysOut, echoOut, verbOut, verbIn, tapOut, micOut]
        let columns = [verbIn, mainsIn, delayIn, keysOut, modIn]
        let validationCount = ValidationCount()
        var rowValidations = 0
        let matrix = try WiringCandidateValidationObserver.$observer.withValue(
            { validationCount.increment() },
            operation: {
                try WiringMatrix.window(rows: rows, columns: columns, active: graph, draft: draft, onValidate: {
                    rowValidations += 1
                })
            }
        )
        #expect(rowValidations == rows.count)
        if validationCount.value != rows.count {
            Issue.record("expected \(rows.count) graph validations, observed \(validationCount.value)")
        }
        #expect(validationCount.value == rows.count,
                "observed \(validationCount.value) graph validations for \(rows.count) rows")
        let wiredCells = matrix.cells.filter { $0.wiredEdge != nil }
        #expect(wiredCells.count >= rows.count && wiredCells.filter { $0.from == keysOut }.count >= 3)
        #expect(Set(wiredCells.map(\.from)).count > 1)
        let classifierCount = ValidationCount()
        let firstWired = try #require(wiredCells.first)
        _ = try WiringCandidateValidationObserver.$observer.withValue(
            { classifierCount.increment() },
            operation: {
                try WiringCandidate.classify(from: firstWired.from, to: firstWired.to, in: graph)
            }
        )
        #expect(classifierCount.value > 0)
        #expect(try wiredCells.allSatisfy { cell in
            let expected = try WiringCandidate.classify(from: cell.from, to: cell.to, in: graph).connection
            guard cell.state == .classified(expected), let edge = cell.wiredEdge else { return false }
            let toggled = try WiringMatrix.toggle(
                cell, request: WiringMatrixConnect(edge: Fixture.id("edg.unused")), in: draft, active: graph
            )
            return toggled.edits == [.disconnect(edge)]
        })
        let bound = WiringMatrixCellState.uncheckable(
            .bounds(.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges))
        )
        #expect(matrix.cell(row: 3, column: 3)?.state == bound)
        #expect(matrix.cell(row: 4, column: 0)?.state == bound)
        #expect(matrix.cell(row: 5, column: 1)?.state == bound)
        #expect(matrix.cell(row: 0, column: 4)?.state == bound)
        #expect(matrix.cell(row: 1, column: 1)?.state == bound)
        let open = matrix.cells.filter {
            $0.wiredEdge == nil && $0.from != verbIn && $0.from != tapOut && $0.from != micOut
                && $0.to != keysOut && $0.to != modIn
        }
        #expect(!open.isEmpty && open.allSatisfy { $0.state == bound })
        try uncheckableWiredCellTogglesOff(keysOut: keysOut, verbIn: verbIn)
    }

    private static func uncheckableWiredCellTogglesOff(keysOut: PortAddress, verbIn: PortAddress) throws {
        let unknownIn = Fixture.address("nod.unknown", "in")
        let unknown = Fixture.node("nod.unknown", ports: [Fixture.audio("in", .input, nil)])
        var graph = Fixture.with([Fixture.edge("edg.unknown", keysOut, unknownIn)], nodes: [unknown])
        graph.edges += (graph.edges.count..<ProjectGraphLimits.edges).map {
            GraphEdge(id: Fixture.id("edg.unknown-fill-\($0)"), from: keysOut, to: verbIn)
        }
        let draft = Edit.draft(on: graph), count = ValidationCount()
        var rowValidations = 0
        let cell = try WiringCandidateValidationObserver.$observer.withValue(
            { count.increment() },
            operation: {
                try #require(WiringMatrix.window(
                    rows: [keysOut], columns: [unknownIn], active: graph, draft: draft,
                    onValidate: { rowValidations += 1 }
                ).cell(row: 0, column: 0))
            }
        )
        #expect(count.value == 1 && rowValidations == 1)
        #expect(cell.state == .uncheckable(.endpointUncheckable(node: unknown.id)))
        #expect(cell.isOn && cell.existingEdge == Fixture.id("edg.unknown"))
        #expect(try WiringMatrix.toggle(cell, request: WiringMatrixConnect(edge: Fixture.id("edg.unused")),
                                        in: draft, active: graph).edits == [.disconnect(Fixture.id("edg.unknown"))])
    }
}

private final class ValidationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
