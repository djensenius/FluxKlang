//
//  WiringComposeTests+Bulk.swift
//  FluxKlangTests
//
//  The destination list classifies through one shared context per source
//  (`WiringCandidateBatch`). These differential tests check it against WP1's
//  per-pair `WiringCandidate.classify` for every source and destination of the
//  fixtures and of seeded pseudo-random graphs (unfed and fed cycles, existing
//  and repeated wires, mismatched signals and widths, conversions, dangling
//  edges, legacy nil-channel ports, repeated node and port IDs, shortcuts), and
//  that a large list validates the graph once.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture
private typealias Compose = WiringComposeFixture

/// SplitMix64: a deterministic generator, so every run sees the same graphs.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func chance(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &self) < percent }
}

private enum SeededGraph {
    static let portNames = ["in", "out", "aux", "mod"]

    static func port(_ name: String, using random: inout SeededGenerator) -> GraphPort {
        let direction: PortDirection = random.chance(50) ? .output : .input
        let roll = Int.random(in: 0..<100, using: &random)
        guard roll < 70 else {
            let signal: PortSignal = [.midi, .control, .clock][roll % 3]
            return GraphPort(id: Fixture.id(name), direction: direction, signal: signal)
        }
        // Mostly stereo or mono; now and then a legacy port with no confirmed count.
        let channels: Int? = random.chance(6) ? nil : (random.chance(55) ? 2 : 1)
        return Fixture.audio(name, direction, channels)
    }

    static func node(_ index: Int, using random: inout SeededGenerator) -> GraphNode {
        // Now and then a node repeats an earlier node's ID.
        let id = index > 2 && random.chance(5) ? "nod.n\(Int.random(in: 0..<index, using: &random))" : "nod.n\(index)"
        var names = portNames.shuffled(using: &random).prefix(Int.random(in: 0...3, using: &random)).map { $0 }
        if let first = names.first, random.chance(4) { names.append(first) }
        let ports = names.map { port($0, using: &random) }
        let roll = Int.random(in: 0..<100, using: &random)
        if roll < 8 {
            var node = Fixture.node(id, .observedShortcut, ports: random.chance(50) ? [] : ports)
            node.position = nil
            return node
        }
        var node = Fixture.node(id, ports: ports)
        if roll < 12 {
            node.kind = .audioGain
            node.linearGain = 1
        } else if roll < 16 {
            node.kind = .audioMute
            node.muted = false
        }
        return node
    }

    static func edge(
        _ index: Int, among ports: [(PortAddress, GraphPort)], earlier: [GraphEdge], using random: inout SeededGenerator
    ) -> GraphEdge {
        let outputs = ports.filter { $0.1.direction == .output }, inputs = ports.filter { $0.1.direction == .input }
        let id = !earlier.isEmpty && random.chance(4) ? earlier[0].id : Fixture.id("edg.e\(index)")
        var from = (outputs.randomElement(using: &random) ?? ports.randomElement(using: &random))?.0
        var to = (inputs.randomElement(using: &random) ?? ports.randomElement(using: &random))?.0
        if random.chance(15) { from = ports.randomElement(using: &random)?.0 }
        if random.chance(5) { to = Fixture.address("nod.ghost", "in") }
        if let repeated = earlier.randomElement(using: &random), random.chance(8) {
            (from, to) = (repeated.from, repeated.to)
        }
        let ghost = Fixture.address("nod.ghost", "out")
        var edge = Fixture.edge("edg.tmp", from ?? ghost, to ?? Fixture.address("nod.ghost", "in"))
        edge.id = id
        if random.chance(25) { edge.feedback = Fixture.feedback }
        if random.chance(12) { edge.conversion = random.chance(50) ? Fixture.upmix : EdgeConversion(map: [[0, 1]]) }
        return edge
    }

    static func make(seed: UInt64) -> GraphDocument {
        var random = SeededGenerator(state: seed)
        let nodes = (0..<Int.random(in: 4...9, using: &random)).map { node($0, using: &random) }
        let ports = nodes.flatMap { node in node.ports.map { (PortAddress(node: node.id, port: $0.id), $0) } }
        var edges: [GraphEdge] = []
        if !ports.isEmpty {
            for index in 0..<Int.random(in: 0...14, using: &random) {
                edges.append(edge(index, among: ports, earlier: edges, using: &random))
            }
        }
        var graph = GraphDocument(id: Fixture.graphID, nodes: nodes, edges: edges)
        // The exact declaration the contract expects for the kinds present (gain, then mute).
        if nodes.contains(where: { $0.kind == .audioGain }) {
            graph.requiredFeatures.append(GraphDocument.constantGainFeature)
        }
        if nodes.contains(where: { $0.kind == .audioMute }) {
            graph.requiredFeatures.append(GraphDocument.constantMuteFeature)
        }
        return graph
    }
}

/// Densely wired audio nodes, so linked cycles, bridges between loops and wires among looping nodes are
/// common; some wires run backwards, carry feedback or carry a (valid or invalid) conversion.
private enum SeededLoopGraph {
    static func make(seed: UInt64) -> GraphDocument {
        var random = SeededGenerator(state: seed)
        let nodes = (0..<Int.random(in: 4...8, using: &random)).map { index in
            let width = random.chance(20) ? 1 : 2
            return Fixture.node("nod.l\(index)", ports: [
                Fixture.audio("in", .input, width), Fixture.audio("out", .output, width)
            ])
        }
        let ports = nodes.flatMap { node in node.ports.map { PortAddress(node: node.id, port: $0.id) } }
        let edges = (0..<Int.random(in: 4...12, using: &random)).map { index in
            var from = Fixture.address(nodes.randomElement(using: &random)?.id.rawValue ?? "nod.l0", "out")
            var to = Fixture.address(nodes.randomElement(using: &random)?.id.rawValue ?? "nod.l0", "in")
            if random.chance(10) {
                (from, to) = (ports.randomElement(using: &random) ?? from, ports.randomElement(using: &random) ?? to)
            }
            var edge = Fixture.edge("edg.l\(index)", from, to)
            if random.chance(10) { edge.feedback = Fixture.feedback }
            if random.chance(15) {
                edge.conversion = random.chance(50) ? EdgeConversion(map: [[0, 1]]) : EdgeConversion(map: [[0], [1]])
            }
            return edge
        }
        return GraphDocument(id: Fixture.graphID, nodes: nodes, edges: edges)
    }
}

extension WiringDestinationListTests {
    /// Every port address of `graph` (each once), plus an `out` address on each observed shortcut.
    static func sources(_ graph: GraphDocument) -> [PortAddress] {
        var addresses = graph.nodes.flatMap { node in node.ports.map { PortAddress(node: node.id, port: $0.id) } }
        addresses += graph.nodes.filter { !$0.kind.isRoutable }.map {
            PortAddress(node: $0.id, port: Fixture.id("out"))
        }
        var seen: Set<PortAddress> = []
        return addresses.filter { seen.insert($0).inserted }
    }

    /// The refusals that may refuse a whole list: the source's or the graph's.
    static func refusesTheList(_ refusal: WiringPreviewRefusal, source: PortAddress) -> Bool {
        switch refusal {
        case .bounds, .uncheckableGraph, .probeUnavailable: true
        case .unknownNode(let node), .endpointUncheckable(let node): node == source.node
        case .unknownPort(let address): address == source
        default: false
        }
    }

    /// The list of every source equals `classify` on every pair; returns the headings seen.
    static func expectEquivalent(
        _ graph: GraphDocument, sourceLocation: SourceLocation = #_sourceLocation
    ) -> Set<WiringDestinationClass> {
        var seen: Set<WiringDestinationClass> = []
        let ports = Set(graph.nodes.flatMap { node in node.ports.map { PortAddress(node: node.id, port: $0.id) } })
        for source in sources(graph) {
            let destinations = ports.subtracting([source])
            let list: WiringDestinationList
            do {
                list = try WiringDestinationList.make(from: source, in: graph)
            } catch {
                #expect(refusesTheList(error, source: source), "\(source): \(error)", sourceLocation: sourceLocation)
                for destination in destinations {
                    #expect(throws: WiringPreviewRefusal.self, "\(source) → \(destination)",
                            sourceLocation: sourceLocation) {
                        try WiringCandidate.classify(from: source, to: destination, in: graph)
                    }
                }
                continue
            }
            seen.formUnion(list.groups.map(\.connectionClass))
            for candidate in list.candidates {
                let expected = Result { () throws(WiringPreviewRefusal) in
                    try WiringCandidate.classify(from: source, to: candidate.to, in: graph)
                }
                #expect(expected == .success(candidate), "\(source) → \(candidate.to)", sourceLocation: sourceLocation)
            }
            let rows = list.group(.uncheckable)?.uncheckable ?? []
            for row in rows {
                let expected = Result { () throws(WiringPreviewRefusal) in
                    try WiringCandidate.classify(from: source, to: row.to, in: graph)
                }
                #expect(expected == .failure(row.refusal), "\(source) → \(row.to)", sourceLocation: sourceLocation)
                #expect(row.from == source, sourceLocation: sourceLocation)
            }
            let listed = list.candidates.map(\.to) + rows.map(\.to)
            #expect(listed.count == destinations.count && Set(listed) == destinations, sourceLocation: sourceLocation)
        }
        return seen
    }

    @Test func bulkListMatchesClassifyOnTheFixtures() {
        let legacy = Fixture.with([], nodes: [Fixture.node("nod.legacy", ports: [Fixture.audio("in", .input, nil)])])
        var seen: Set<WiringDestinationClass> = []
        for graph in [Fixture.graph, Compose.monoLoop, legacy] { seen.formUnion(Self.expectEquivalent(graph)) }
        #expect(seen == Set(WiringDestinationClass.allCases))
    }

    @Test func bulkListMatchesClassifyOnSeededGraphs() {
        var seen: Set<WiringDestinationClass> = []
        var feedbackCycles = 0
        for seed in UInt64(1)...40 {
            let graph = SeededGraph.make(seed: seed)
            seen.formUnion(Self.expectEquivalent(graph))
            for case .cycleWithoutFeedback in graph.validationErrors() { feedbackCycles += 1 }
        }
        // The seeds reach every heading, and some graphs already loop without feedback.
        #expect(seen == Set(WiringDestinationClass.allCases))
        #expect(feedbackCycles > 0)
    }

    @Test func bulkListMatchesClassifyOnSeededLoopGraphs() {
        var seen: Set<WiringDestinationClass> = []
        var loopingGraphs = 0
        for seed in UInt64(1)...60 {
            let graph = SeededLoopGraph.make(seed: seed)
            seen.formUnion(Self.expectEquivalent(graph))
            for case .cycleWithoutFeedback in graph.validationErrors() { loopingGraphs += 1 }
        }
        #expect(seen.isSuperset(of: [.valid, .needsConversion, .feedbackOnly, .existing, .notOffered]))
        #expect(loopingGraphs > 10)
    }

    @Test func bulkListRefusesAnUncheckableGraphAsClassifyDoes() {
        var graph = Fixture.graph
        graph.requiredFeatures = [GraphDocument.constantGainFeature]
        let declared = [GraphDocument.constantGainFeature]
        let refusal = WiringPreviewRefusal.uncheckableGraph(.invalidRequiredFeatures(declared))
        #expect(throws: refusal) { try Self.list("nod.keys", "out", in: graph) }
        #expect(throws: refusal) { try Fixture.classify(("nod.keys", "out"), ("nod.mains", "in"), in: graph) }
    }

    @Test func atTheEdgeBoundTheListIsRefusedAsAWhole() throws {
        let padding = (Fixture.graph.edges.count..<ProjectGraphLimits.edges).map { index in
            Fixture.edge("edg.pad.\(index)", Fixture.address("nod.gone", "out"), Fixture.address("nod.gone", "in"))
        }
        let full = Fixture.with(padding)
        let limit = WiringPreviewRefusal.bounds(.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges))
        // Every new wire is refused with bounds; only a wire that already exists still classifies.
        #expect(throws: limit) { try Fixture.classify(("nod.keys", "out"), ("nod.mains", "in"), in: full) }
        let existing = try Fixture.classify(("nod.keys", "out"), ("nod.verb", "in"), in: full)
        #expect(existing == .existing(Fixture.id("edg.keys-verb")))
        #expect(throws: limit) { try Self.list("nod.keys", "out", in: full) }
    }

    @Test func largeListValidatesTheGraphOnce() throws {
        // 2,000 stereo nodes (4,000 ports) wired in pairs n(2k) → n(2k+1).
        let nodes = (0..<2_000).map { Fixture.stereo("nod.s\($0)", at: Double($0)) }
        let edges = stride(from: 0, to: 2_000, by: 2).map { index in
            Fixture.edge("edg.s\(index)", Fixture.address("nod.s\(index)", "out"),
                         Fixture.address("nod.s\(index + 1)", "in"))
        }
        let graph = GraphDocument(id: Fixture.graphID, nodes: nodes, edges: edges)
        let source = Fixture.address("nod.s0", "out")
        var validations = 0
        let list = try WiringDestinationList.make(from: source, in: graph) { graph in
            validations += 1
            return graph.validationErrors()
        }
        #expect(validations == 1)
        #expect(list.group(.valid)?.candidates.count == 1_998)
        #expect(list.group(.feedbackOnly)?.candidates.map(\.to) == [Fixture.address("nod.s0", "in")])
        #expect(list.group(.existing)?.candidates.map(\.to) == [Fixture.address("nod.s1", "in")])
        #expect(list.group(.notOffered)?.candidates.count == 1_999)
        let sampled: Set<String> = ["nod.s0", "nod.s1", "nod.s2", "nod.s1999"]
        for candidate in list.candidates where sampled.contains(candidate.to.node.rawValue) {
            #expect(candidate == (try WiringCandidate.classify(from: source, to: candidate.to, in: graph)))
        }
    }
}
