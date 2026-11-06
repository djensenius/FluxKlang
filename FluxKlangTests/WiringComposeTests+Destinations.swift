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
            (group.connectionClass, group.candidates.map { "\($0.to.node.rawValue)/\($0.to.port.rawValue)" })
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
            .valid, .needsConversion, .feedbackOnly, .existing, .disabled, .notOffered, .notRoutable
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
