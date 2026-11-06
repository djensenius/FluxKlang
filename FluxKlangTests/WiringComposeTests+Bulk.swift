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

/// SplitMix64. Every draw comes straight from `next()`, with no stdlib `random(in:using:)`, `shuffled` or
/// `randomElement` (whose use of a generator may change between toolchains), so every run on every
/// toolchain sees the same graphs and the coverage checks below stay meaningful.
private struct SeededGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// A draw in `0..<count` (`count > 0`); the modulo bias does not matter here.
    mutating func below(_ count: Int) -> Int { Int(next() % UInt64(count)) }

    mutating func draw(_ range: ClosedRange<Int>) -> Int { range.lowerBound + below(range.count) }

    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }

    mutating func element<Element>(of items: [Element]) -> Element? { items.isEmpty ? nil : items[below(items.count)] }

    /// Fisher–Yates.
    mutating func shuffled<Element>(_ items: [Element]) -> [Element] {
        var items = items
        for index in items.indices.reversed() where index > 0 { items.swapAt(index, below(index + 1)) }
        return items
    }
}

private enum SeededGraph {
    static let portNames = ["in", "out", "aux", "mod"]

    static func port(_ name: String, using random: inout SeededGenerator) -> GraphPort {
        let direction: PortDirection = random.chance(50) ? .output : .input
        let roll = random.below(100)
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
        let id = index > 2 && random.chance(5) ? "nod.n\(random.below(index))" : "nod.n\(index)"
        var names = Array(random.shuffled(portNames).prefix(random.draw(0...3)))
        if let first = names.first, random.chance(4) { names.append(first) }
        let ports = names.map { port($0, using: &random) }
        let roll = random.below(100)
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
        var from = (random.element(of: outputs) ?? random.element(of: ports))?.0
        var to = (random.element(of: inputs) ?? random.element(of: ports))?.0
        if random.chance(15) { from = random.element(of: ports)?.0 }
        if random.chance(5) { to = Fixture.address("nod.ghost", "in") }
        if let repeated = random.element(of: earlier), random.chance(8) {
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
        let nodes = (0..<random.draw(4...9)).map { node($0, using: &random) }
        let ports = nodes.flatMap { node in node.ports.map { (PortAddress(node: node.id, port: $0.id), $0) } }
        var edges: [GraphEdge] = []
        if !ports.isEmpty {
            for index in 0..<random.draw(0...14) {
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
        let nodes = (0..<random.draw(4...8)).map { index in
            let width = random.chance(20) ? 1 : 2
            return Fixture.node("nod.l\(index)", ports: [
                Fixture.audio("in", .input, width), Fixture.audio("out", .output, width)
            ])
        }
        let ports = nodes.flatMap { node in node.ports.map { PortAddress(node: node.id, port: $0.id) } }
        let edges = (0..<random.draw(4...12)).map { index in
            var from = Fixture.address(random.element(of: nodes)?.id.rawValue ?? "nod.l0", "out")
            var to = Fixture.address(random.element(of: nodes)?.id.rawValue ?? "nod.l0", "in")
            if random.chance(10) {
                (from, to) = (random.element(of: ports) ?? from, random.element(of: ports) ?? to)
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

    /// When the list is refused with `refusal`, `classify` throws exactly the expected refusal for every
    /// destination. That is `refusal` itself, except for the destination-side deviation documented on
    /// `WiringDestinationList.make`: on a graph the baseline does not refuse, `classify` names the node of
    /// the pair that comes first, in baseline error order, among those the baseline reports uncheckable.
    /// (The edge-bound deviation is covered by `atTheEdgeBoundTheListIsRefusedAsAWhole`.)
    static func expectRefusedAsClassifyDoes(
        _ refusal: WiringPreviewRefusal, source: PortAddress, destinations: Set<PortAddress>, in graph: GraphDocument,
        sourceLocation: SourceLocation
    ) {
        #expect(refusesTheList(refusal, source: source), "\(source): \(refusal)", sourceLocation: sourceLocation)
        let baseline = graph.validationErrors()
        let graphRefused = (try? WiringCandidateClassifier.checked(baseline)) == nil
        for destination in destinations {
            let actual = Result { () throws(WiringPreviewRefusal) in
                try WiringCandidate.classify(from: source, to: destination, in: graph)
            }
            let named = graphRefused ? nil : baseline.lazy.compactMap(WiringCandidateClassifier.uncheckableNode)
                .first { $0 == source.node || $0 == destination.node }
            let expected = named.map { WiringPreviewRefusal.endpointUncheckable(node: $0) } ?? refusal
            #expect(actual == .failure(expected), "\(source) → \(destination): list \(refusal), classify \(actual)",
                    sourceLocation: sourceLocation)
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
                expectRefusedAsClassifyDoes(
                    error, source: source, destinations: destinations, in: graph, sourceLocation: sourceLocation
                )
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
        // A shortcut that (invalidly) carries a port: shortcut → shortcut names the source first.
        let tap = Fixture.node("nod.tap", .observedShortcut, ports: [Fixture.audio("in", .input, 2)])
        let shortcuts = Fixture.with([], nodes: [tap])
        var seen: Set<WiringDestinationClass> = []
        for graph in [Fixture.graph, Compose.monoLoop, legacy, shortcuts] {
            seen.formUnion(Self.expectEquivalent(graph))
        }
        #expect(seen == Set(WiringDestinationClass.allCases))
        let fromShortcut = try? Self.list("nod.ch7", "out", in: shortcuts)
        let toTap = fromShortcut?.candidates.first { $0.to == Fixture.address("nod.tap", "in") }
        #expect(toTap?.connection == .notRoutable(Fixture.id("nod.ch7")))
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
        // One input → input wire, then padding up to the edge bound.
        let inputs = Fixture.edge(
            "edg.verb-mains", Fixture.address("nod.verb", "in"), Fixture.address("nod.mains", "in")
        )
        let padding = (Fixture.graph.edges.count + 1..<ProjectGraphLimits.edges).map { index in
            Fixture.edge("edg.pad.\(index)", Fixture.address("nod.gone", "out"), Fixture.address("nod.gone", "in"))
        }
        let full = Fixture.with([inputs] + padding)
        let limit = WiringPreviewRefusal.bounds(.exceeded(path: "$.edges", maximum: ProjectGraphLimits.edges))
        // Every new wire is refused with bounds; only a pair that is already wired still classifies.
        #expect(throws: limit) { try Fixture.classify(("nod.keys", "out"), ("nod.mains", "in"), in: full) }
        let existing = try Fixture.classify(("nod.keys", "out"), ("nod.verb", "in"), in: full)
        #expect(existing == .existing(Fixture.id("edg.keys-verb")))
        // An already-wired pair whose `notOffered` outranks `existing`.
        #expect(try Fixture.classify(("nod.verb", "in"), ("nod.mains", "in"), in: full) == .notOffered)
        #expect(throws: limit) { try Self.list("nod.keys", "out", in: full) }
        #expect(throws: limit) { try Self.list("nod.verb", "in", in: full) }
    }

    @Test func largeListObservesOneValidation() throws {
        // 2,000 stereo nodes (4,000 ports) wired in pairs n(2k) → n(2k+1). The count is of `onValidate`
        // calls, not of `validationErrors()`: one validation is guaranteed by construction (the context
        // does not keep the graph); this weaker check is the price of a hook that cannot forge errors.
        let nodes = (0..<2_000).map { Fixture.stereo("nod.s\($0)", at: Double($0)) }
        let edges = stride(from: 0, to: 2_000, by: 2).map { index in
            Fixture.edge("edg.s\(index)", Fixture.address("nod.s\(index)", "out"),
                         Fixture.address("nod.s\(index + 1)", "in"))
        }
        let graph = GraphDocument(id: Fixture.graphID, nodes: nodes, edges: edges)
        let source = Fixture.address("nod.s0", "out")
        var validations = 0
        let list = try WiringDestinationList.make(from: source, in: graph) { validations += 1 }
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

    @Test func validationObserverCannotChangeTheList() throws {
        // A legacy input with no confirmed channel count: classify refuses the pair as uncheckable.
        let legacy = Fixture.node("nod.legacy", ports: [Fixture.audio("in", .input, nil)], at: 8)
        let graph = Fixture.with([], nodes: [legacy])
        let source = Fixture.address("nod.keys", "out")
        var validations = 0
        let observed = try WiringDestinationList.make(from: source, in: graph) { validations += 1 }
        #expect(validations == 1)
        #expect(observed == (try WiringDestinationList.make(from: source, in: graph)))
        let row = try #require(observed.group(.uncheckable)?.uncheckable.first)
        #expect(row.to == Fixture.address("nod.legacy", "in"))
        #expect(row.refusal == .endpointUncheckable(node: Fixture.id("nod.legacy")))
        #expect(!observed.candidates.map(\.to).contains(Fixture.address("nod.legacy", "in")))
        // Each source- or graph-level refusal is still computed internally, whatever the observer does.
        #expect(throws: WiringPreviewRefusal.endpointUncheckable(node: Fixture.id("nod.legacy"))) {
            try WiringDestinationList.make(from: Fixture.address("nod.legacy", "in"), in: graph) {}
        }
    }

    @Test func wholeListRefusalsFollowClassifyOrder() {
        let gain = [GraphDocument.constantGainFeature]
        var uncheckableGraph = Fixture.graph
        uncheckableGraph.requiredFeatures = gain
        let legacy = Fixture.node("nod.legacy", ports: [Fixture.audio("in", .input, nil)], at: 8)
        let withLegacy = Fixture.with([], nodes: [legacy])
        let padding = (Fixture.graph.edges.count..<ProjectGraphLimits.edges).map { index in
            Fixture.edge("edg.pad.\(index)", Fixture.address("nod.gone", "out"), Fixture.address("nod.gone", "in"))
        }
        let full = Fixture.with(padding)
        let graphRefusal = WiringPreviewRefusal.uncheckableGraph(.invalidRequiredFeatures(gain))
        let nope = Fixture.address("nod.keys", "nope")
        /// Both the list and classify(source → nod.mains/in) give exactly `refusal`.
        func expectBoth(
            _ refusal: WiringPreviewRefusal, _ source: PortAddress, in graph: GraphDocument,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            let mains = Fixture.address("nod.mains", "in")
            #expect(throws: refusal, "\(source)", sourceLocation: sourceLocation) {
                try WiringDestinationList.make(from: source, in: graph)
            }
            #expect(throws: refusal, "\(source)", sourceLocation: sourceLocation) {
                try WiringCandidate.classify(from: source, to: mains, in: graph)
            }
        }
        // The graph is checked before the source is resolved.
        expectBoth(graphRefusal, Fixture.address("nod.nope", "out"), in: uncheckableGraph)
        expectBoth(graphRefusal, nope, in: uncheckableGraph)
        // An uncheckable source node is named before its unknown port.
        expectBoth(.endpointUncheckable(node: Fixture.id("nod.legacy")), Fixture.address("nod.legacy", "nope"),
                   in: withLegacy)
        // At the edge bound an unknown source is still named (classify's wire-exists retry names it).
        expectBoth(.unknownNode(Fixture.id("nod.nope")), Fixture.address("nod.nope", "out"), in: full)
        expectBoth(.unknownPort(nope), nope, in: full)
        // The documented deviation: an unknown source with a destination on an uncheckable node. The list
        // refuses about the source; classify names the uncheckable destination node, and the source elsewhere.
        for source in [nope, Fixture.address("nod.nope", "out")] {
            let aboutSource: WiringPreviewRefusal = source == nope ? .unknownPort(nope) : .unknownNode(source.node)
            #expect(throws: aboutSource) { try WiringDestinationList.make(from: source, in: withLegacy) }
            #expect(throws: WiringPreviewRefusal.endpointUncheckable(node: Fixture.id("nod.legacy"))) {
                try WiringCandidate.classify(from: source, to: Fixture.address("nod.legacy", "in"), in: withLegacy)
            }
            #expect(throws: aboutSource) {
                try WiringCandidate.classify(from: source, to: Fixture.address("nod.mains", "in"), in: withLegacy)
            }
        }
    }
}
