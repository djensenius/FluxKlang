//
//  WiringComposeTests+Destinations.swift
//  FluxKlangTests
//
//  The destination list (#101 WP2): every other port of the graph, classified
//  bare, grouped by connection class in `WiringDestinationClass` order with
//  empty groups omitted, sorted by (node ID, port ID) whatever the graph order.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture
private typealias Compose = WiringComposeFixture

@Suite("Wiring destination list")
struct WiringDestinationListTests {
    static func list(
        _ node: String, _ port: String, in graph: GraphDocument = Fixture.graph
    ) throws -> WiringDestinationList {
        try WiringDestinationList.make(from: Fixture.address(node, port), in: graph)
    }

    /// The list as (class, ["node/port", …]) rows.
    static func layout(_ list: WiringDestinationList) -> [(WiringDestinationClass, [String])] {
        list.groups.map { group in
            let destinations = group.candidates.map(\.to) + group.uncheckable.map(\.to)
            return (group.connectionClass, destinations.map { "\($0.node.rawValue)/\($0.port.rawValue)" })
        }
    }

    static func expectLayout(
        _ list: WiringDestinationList, _ expected: [(WiringDestinationClass, [String])],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let actual = layout(list)
        #expect(actual.map(\.0) == expected.map(\.0), sourceLocation: sourceLocation)
        #expect(actual.map(\.1) == expected.map(\.1), sourceLocation: sourceLocation)
    }

    @Test func keysOutputIsGroupedByClass() throws {
        let list = try Self.list("nod.keys", "out")
        #expect(list.source == Fixture.address("nod.keys", "out"))
        Self.expectLayout(list, [
            (.valid, ["nod.delay/in", "nod.echo/in", "nod.mains/in"]),
            (.existing, ["nod.verb/in"]),
            (.disabled, ["nod.verb/mod"]),
            (.notOffered, ["nod.delay/out", "nod.echo/out", "nod.mic/out", "nod.verb/out"])
        ])
        #expect(list.group(.existing)?.candidates.first?.connection == .existing(Fixture.id("edg.keys-verb")))
        #expect(list.group(.needsConversion) == nil)
    }

    @Test func monoSourceNeedsConversionAndLoopsNeedFeedback() throws {
        Self.expectLayout(try Self.list("nod.mic", "out"), [
            (.needsConversion, ["nod.delay/in", "nod.echo/in", "nod.mains/in"]),
            (.existing, ["nod.verb/in"]),
            (.disabled, ["nod.verb/mod"]),
            (.notOffered, ["nod.delay/out", "nod.echo/out", "nod.keys/out", "nod.verb/out"])
        ])
        let fromVerb = try Self.list("nod.verb", "out")
        #expect(fromVerb.group(.feedbackOnly)?.candidates.map(\.to) == [
            Fixture.address("nod.echo", "in"), Fixture.address("nod.verb", "in")
        ])
        #expect(fromVerb.group(.existing)?.candidates.map(\.to) == [
            Fixture.address("nod.delay", "in"), Fixture.address("nod.mains", "in")
        ])
    }

    @Test func observedShortcutSourceListsEveryPortAsNotRoutable() throws {
        let list = try Self.list("nod.ch7", "out")
        #expect(list.groups.map(\.connectionClass) == [.notRoutable])
        #expect(list.candidates.count == Fixture.graph.nodes.map(\.ports.count).reduce(0, +))
        #expect(list.candidates.allSatisfy { $0.connection == .notRoutable(Fixture.id("nod.ch7")) })
    }

    @Test func everyOtherPortIsListedOnceAndMatchesClassify() throws {
        let graph = Fixture.graph
        for node in graph.nodes {
            for port in node.ports {
                let source = PortAddress(node: node.id, port: port.id)
                let list = try WiringDestinationList.make(from: source, in: graph)
                let listed = list.candidates.map(\.to)
                #expect(Set(listed).count == listed.count)
                #expect(!listed.contains(source))
                #expect(listed.count == graph.nodes.map(\.ports.count).reduce(0, +) - 1)
                for candidate in list.candidates {
                    #expect(candidate == (try WiringCandidate.classify(from: source, to: candidate.to, in: graph)))
                    #expect(candidate.conversion == nil && candidate.feedback == nil)
                }
                let classes = list.groups.map(\.connectionClass)
                #expect(classes == classes.sorted() && Set(classes).count == classes.count)
                #expect(list.groups.allSatisfy { !$0.candidates.isEmpty })
                for group in list.groups {
                    let classes = group.candidates.map { WiringDestinationClass($0.connection) }
                    #expect(classes.allSatisfy { $0 == group.connectionClass })
                    let keys = group.candidates.map { [$0.to.node.rawValue, $0.to.port.rawValue] }
                    #expect(keys == keys.sorted { $0.lexicographicallyPrecedes($1) })
                }
            }
        }
    }

    @Test func orderIsStableWhateverTheGraphOrder() throws {
        let baseline = try Self.list("nod.keys", "out")
        var reversed = Fixture.graph
        reversed.nodes = reversed.nodes.reversed().map { node in
            var node = node
            node.ports.reverse()
            return node
        }
        reversed.edges.reverse()
        var rotated = Fixture.graph
        rotated.nodes = Array(rotated.nodes[3...] + rotated.nodes[..<3])
        for graph in [reversed, rotated] {
            #expect(try WiringDestinationList.make(from: Fixture.address("nod.keys", "out"), in: graph) == baseline)
        }
        #expect(try Self.list("nod.keys", "out") == baseline)
    }

    @Test func classHeadingsFollowTheDocumentedOrder() {
        #expect(WiringDestinationClass.allCases == [
            .valid, .needsConversion, .feedbackOnly, .existing, .disabled, .notOffered, .notRoutable, .uncheckable
        ])
        let expected: [WiringDestinationClass] = [
            .valid, .needsConversion, .disabled, .notOffered, .feedbackOnly, .existing, .notRoutable
        ]
        #expect(Fixture.documented.map { WiringDestinationClass($0.expected) } == expected)
    }

    @Test func unknownSourceIsRefused() throws {
        #expect(throws: WiringPreviewRefusal.unknownNode(Fixture.id("nod.ghost"))) {
            try Self.list("nod.ghost", "out")
        }
        #expect(throws: WiringPreviewRefusal.unknownPort(Fixture.address("nod.keys", "aux"))) {
            try Self.list("nod.keys", "aux")
        }
        // With no other port to classify, only the explicit source check can refuse.
        var lonely = Fixture.graph
        lonely.nodes = [Fixture.node("nod.solo", ports: [Fixture.audio("out", .output, 2)])]
        lonely.edges = []
        #expect(try Self.list("nod.solo", "out", in: lonely).groups.isEmpty)
        var portless = lonely
        portless.nodes = [Fixture.node("nod.solo", ports: [])]
        #expect(throws: WiringPreviewRefusal.unknownNode(Fixture.id("nod.ghost"))) {
            try Self.list("nod.ghost", "out", in: portless)
        }
        #expect(throws: WiringPreviewRefusal.unknownPort(Fixture.address("nod.solo", "aux"))) {
            try Self.list("nod.solo", "aux", in: portless)
        }
    }

    @Test func destinationsWithAnUncheckableNodeStillListTheRest() throws {
        // A legacy node whose only audio input has no confirmed channel count.
        let legacy = Fixture.node("nod.legacy", ports: [Fixture.audio("in", .input, nil)], at: 8)
        let graph = Fixture.with([], nodes: [legacy])
        let legacyIn = Fixture.address("nod.legacy", "in")
        let refusal = WiringPreviewRefusal.endpointUncheckable(node: Fixture.id("nod.legacy"))
        #expect(throws: refusal) {
            try WiringCandidate.classify(from: Fixture.address("nod.keys", "out"), to: legacyIn, in: graph)
        }
        let list = try Self.list("nod.keys", "out", in: graph)
        Self.expectLayout(list, [
            (.valid, ["nod.delay/in", "nod.echo/in", "nod.mains/in"]),
            (.existing, ["nod.verb/in"]),
            (.disabled, ["nod.verb/mod"]),
            (.notOffered, ["nod.delay/out", "nod.echo/out", "nod.mic/out", "nod.verb/out"]),
            (.uncheckable, ["nod.legacy/in"])
        ])
        let row = try #require(list.group(.uncheckable)?.uncheckable.first)
        #expect(row.from == Fixture.address("nod.keys", "out") && row.to == legacyIn && row.refusal == refusal)
        #expect(list.group(.uncheckable)?.candidates.isEmpty == true)
        #expect(!list.candidates.map(\.to).contains(legacyIn))
        // The draft composer lists the same rows; the legacy node as a source refuses the whole list.
        let drafted = try WiringDraftComposer.destinations(
            from: Fixture.address("nod.keys", "out"), active: graph, draft: Compose.draft(on: graph)
        )
        #expect(drafted == list)
        #expect(throws: refusal) { try Self.list("nod.legacy", "in", in: graph) }
    }

    @Test func oversizedGraphIsRefusedBeforePortsAreCollected() {
        // Past the node bound, with no destination at all: the list is refused, never empty.
        let portless = (0..<ProjectGraphLimits.nodes).map { Fixture.node("nod.pad.\($0)", ports: []) }
        let graph = GraphDocument(
            id: Fixture.graphID, nodes: [Fixture.node("nod.solo", ports: [Fixture.audio("out", .output, 2)])] + portless
        )
        let limit = ProjectGraphLimitError.exceeded(path: "$.nodes", maximum: ProjectGraphLimits.nodes)
        #expect(throws: WiringPreviewRefusal.bounds(limit)) { try Self.list("nod.solo", "out", in: graph) }
        // Bounds come first, before the source is looked up.
        #expect(throws: WiringPreviewRefusal.bounds(limit)) { try Self.list("nod.ghost", "out", in: graph) }
    }

    @Test func draftDestinationsRefuseBrokenAndOversizedDrafts() {
        let source = Fixture.address("nod.keys", "out")
        let broken = Compose.draft([.disconnect(Fixture.id("edg.missing"))])
        #expect(throws: WiringComposeRefusal.preview(.draftDoesNotApply(.missingEdge(Fixture.id("edg.missing"))))) {
            try WiringDraftComposer.destinations(from: source, active: Fixture.graph, draft: broken)
        }
        // The active graph is exactly at the node bound; the draft adds one more node.
        let pads = (Fixture.graph.nodes.count..<ProjectGraphLimits.nodes).map {
            Fixture.node("nod.pad.\($0)", ports: [])
        }
        let full = Fixture.with([], nodes: pads)
        let oversized = Compose.draft([.addNode(Compose.comp)], on: full)
        let limit = ProjectGraphLimitError.exceeded(path: "$.nodes", maximum: ProjectGraphLimits.nodes)
        #expect(throws: WiringComposeRefusal.preview(.bounds(limit))) {
            try WiringDraftComposer.destinations(from: source, active: full, draft: oversized)
        }
    }

    @Test func draftDestinationsUseTheDraftGraph() throws {
        let draft = Compose.draft([.addNode(Compose.comp), .disconnect(Fixture.id("edg.keys-verb"))])
        let source = Fixture.address("nod.keys", "out")
        let list = try WiringDraftComposer.destinations(from: source, active: Fixture.graph, draft: draft)
        #expect(list.group(.valid)?.candidates.map(\.to) == [
            Fixture.address("nod.comp", "in"), Fixture.address("nod.delay", "in"), Fixture.address("nod.echo", "in"),
            Fixture.address("nod.mains", "in"), Fixture.address("nod.verb", "in")
        ])
        #expect(list.group(.existing) == nil)
        #expect(throws: WiringComposeRefusal.preview(.unknownNode(Fixture.id("nod.ghost")))) {
            try WiringDraftComposer.destinations(from: Fixture.address("nod.ghost", "out"), active: Fixture.graph,
                                                 draft: draft)
        }
        var foreign = draft
        foreign.graph = Fixture.id("gph.other")
        #expect(throws: WiringComposeRefusal.preview(.draftGraphMismatch(draft: Fixture.id("gph.other"),
                                                                           active: Fixture.graphID))) {
            try WiringDraftComposer.destinations(from: source, active: Fixture.graph, draft: foreign)
        }
    }
}
