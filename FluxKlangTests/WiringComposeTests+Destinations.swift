//
//  WiringComposeTests+Destinations.swift
//  FluxKlangTests
//
//  The destination list (#101 WP2): every other port of the graph, classified
//  bare, grouped by connection class in `WiringDestinationClass` order with
//  empty groups omitted, sorted by (node ID, port ID) whatever the graph order.
//  The conversion step's offers for those destinations (#101 WCO1): named channel
//  maps for 1 → 2 and 2 → 1, one fixed feedback choice for a cycle, no default.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = WiringPreviewFixture
private typealias Compose = WiringComposeFixture
private typealias Offers = WiringConnectionOffers
private typealias OfferRefusal = WiringConnectionOfferRefusal

@Suite("Wiring destination list", .productionAccessAudit)
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

// MARK: - Conversion-step offers (#101 WCO1)

extension WiringDestinationListTests {
    static let expectedFeedback = EdgeFeedback(delayBlocks: 1, gainCeilingDb: -6)

    /// Composes `request` onto an empty draft of `graph`; returns the new edge and the draft graph's errors.
    static func composeOffer(
        _ request: WiringConnectRequest, in graph: GraphDocument
    ) throws -> (edge: GraphEdge, errors: [GraphValidationError]) {
        let composed = try WiringDraftComposer.compose(request, into: Compose.draft(on: graph), active: graph)
        let edge = try #require(WiringComposeTests.lastEdge(composed))
        return (edge, try graph.applying(composed.edits).validationErrors())
    }

    @Test func monoToStereoOffersThreeNamedMapsInOrder() throws {
        let offers = try Offers.conversions(sourceChannels: 1, destinationChannels: 2)
        try #require(offers.count == 3)
        #expect(offers.map(\.label) == ["Mono to both sides", "Left only", "Right only"])
        // One row per destination channel, listing the source channels summed into it; [] is silent.
        #expect(offers.map(\.conversion) == [
            EdgeConversion(map: [[0], [0]], label: "Mono to both sides"),
            EdgeConversion(map: [[0], []], label: "Left only"),
            EdgeConversion(map: [[], [0]], label: "Right only")
        ])
        #expect(offers[0].conversion == Fixture.upmix)
        // A mono → stereo destination's class gives the same list: nothing is picked out of it.
        let bare = try Fixture.classify(("nod.mic", "out"), ("nod.mains", "in"))
        #expect(bare == .needsConversion(sourceChannels: 1, destinationChannels: 2))
        #expect(try Offers.conversions(for: bare) == offers)
    }

    @Test func stereoToMonoOffersThreeNamedMapsInOrder() throws {
        let offers = try Offers.conversions(sourceChannels: 2, destinationChannels: 1)
        try #require(offers.count == 3)
        #expect(offers.map(\.label) == ["Left only", "Right only", "Both sides summed"])
        #expect(offers.map(\.conversion) == [
            EdgeConversion(map: [[0]], label: "Left only"),
            EdgeConversion(map: [[1]], label: "Right only"),
            EdgeConversion(map: [[0, 1]], label: "Both sides summed")
        ])
        let bare = try Fixture.classify(("nod.keys", "out"), ("nod.mono", "in"), in: Compose.monoLoop)
        #expect(bare == .needsConversion(sourceChannels: 2, destinationChannels: 1))
        #expect(try Offers.conversions(for: bare) == offers)
    }

    @Test func equalOutOfRangeAndUnnamedChannelCountsAreRefused() {
        for channels in [1, 2, 6, 64] {
            #expect(throws: OfferRefusal.channelCountsMatch(channels: channels)) {
                try Offers.conversions(sourceChannels: channels, destinationChannels: channels)
            }
        }
        for (source, destination) in [(2, 6), (6, 2), (1, 6), (2, 4), (4, 2), (1, 3), (1, 64), (64, 1)] {
            #expect(throws: OfferRefusal.unsupportedChannelCounts(source: source, destination: destination)) {
                try Offers.conversions(sourceChannels: source, destinationChannels: destination)
            }
        }
        // The range is checked first: 0 → 0 and 65 → 65 are out of range, not matching counts.
        for (source, destination) in [(0, 2), (2, 0), (0, 1), (0, 0), (-1, 2), (1, 65), (65, 2), (65, 65)] {
            #expect(throws: OfferRefusal.channelCountOutOfRange(source: source, destination: destination)) {
                try Offers.conversions(sourceChannels: source, destinationChannels: destination)
            }
        }
        // The class entry point passes the count refusal through unchanged.
        #expect(throws: OfferRefusal.unsupportedChannelCounts(source: 2, destination: 6)) {
            try Offers.conversions(for: .needsConversion(sourceChannels: 2, destinationChannels: 6))
        }
    }

    @Test func conversionsAndFeedbackAreOfferedOnlyForTheirClass() throws {
        var offered: [WiringDestinationClass] = []
        for row in Fixture.documented {
            let connectionClass = WiringDestinationClass(row.expected)
            if connectionClass == .needsConversion {
                #expect(try Offers.conversions(for: row.expected).count == 3)
                offered.append(connectionClass)
            } else {
                #expect(throws: OfferRefusal.conversionNotNeeded(connectionClass)) {
                    try Offers.conversions(for: row.expected)
                }
            }
            if connectionClass == .feedbackOnly {
                #expect(try Offers.feedback(for: row.expected).feedback == Self.expectedFeedback)
                offered.append(connectionClass)
            } else {
                #expect(throws: OfferRefusal.feedbackNotNeeded(connectionClass)) {
                    try Offers.feedback(for: row.expected)
                }
            }
        }
        #expect(offered == [.needsConversion, .feedbackOnly])
    }

    @Test func everyConversionOfferPassesTheContract() throws {
        // mic (1) feeds three stereo inputs; keys (2) feeds the mono node of `monoLoop`.
        let sources = [
            (Fixture.graph, Fixture.address("nod.mic", "out")), (Compose.monoLoop, Fixture.address("nod.keys", "out"))
        ]
        var composed = 0
        for (graph, source) in sources {
            let group = try #require(try WiringDestinationList.make(from: source, in: graph).group(.needsConversion))
            for candidate in group.candidates {
                let offers = try Offers.conversions(for: candidate.connection)
                try #require(offers.count == 3)
                for offer in offers {
                    let chosen = try WiringCandidate.classify(
                        from: candidate.from, to: candidate.to, in: graph, conversion: offer.conversion
                    )
                    #expect(chosen.connection == .valid)
                    let request = WiringConnectRequest(
                        edge: Fixture.id("edg.offer"), from: candidate.from, to: candidate.to,
                        conversion: offer.conversion
                    )
                    let result = try Self.composeOffer(request, in: graph)
                    #expect(result.edge.conversion == offer.conversion)
                    #expect(result.edge.feedback == nil)
                    #expect(result.errors.isEmpty)
                    composed += 1
                }
            }
        }
        #expect(composed == 12)
    }

    @Test func feedbackIsOneFixedChoiceThatPassesTheContract() throws {
        let from = Fixture.address("nod.verb", "out"), to = Fixture.address("nod.echo", "in")
        let bare = try WiringCandidate.classify(from: from, to: to, in: Fixture.graph).connection
        #expect(bare == .feedbackOnly(cycle: WiringComposeTests.verbEchoCycle))
        let offer = try Offers.feedback(for: bare)
        #expect(offer.label == "Feedback (1-block delay, ceiling −6 dB)")
        #expect(offer.feedback.delayBlocks == 1)
        #expect(offer.feedback.gainCeilingDb == -6)
        #expect(offer.feedback == Self.expectedFeedback)
        #expect(offer.feedback.isValid)
        // The same single choice whatever the cycle; a cycle never takes a conversion.
        #expect(try Offers.feedback(for: .feedbackOnly(cycle: [])) == offer)
        #expect(throws: OfferRefusal.conversionNotNeeded(.feedbackOnly)) { try Offers.conversions(for: bare) }
        let chosen = try WiringCandidate.classify(from: from, to: to, in: Fixture.graph, feedback: offer.feedback)
        #expect(chosen.connection == .valid)
        let request = WiringConnectRequest(
            edge: Fixture.id("edg.verb-echo-fb"), from: from, to: to, feedback: offer.feedback
        )
        let result = try Self.composeOffer(request, in: Fixture.graph)
        #expect(result.edge.feedback == offer.feedback)
        #expect(result.edge.conversion == nil)
        #expect(result.errors.isEmpty)
    }

    @Test func aConvertedCycleIsOfferedFeedbackOnceItsConversionIsChosen() throws {
        // mono (1) → verb (2) needs a conversion and closes verb → mono → verb.
        let graph = Compose.monoLoop
        let from = Fixture.address("nod.mono", "out"), to = Fixture.address("nod.verb", "in")
        let bare = try WiringCandidate.classify(from: from, to: to, in: graph).connection
        #expect(bare == .needsConversion(sourceChannels: 1, destinationChannels: 2))
        #expect(throws: OfferRefusal.feedbackNotNeeded(.needsConversion)) { try Offers.feedback(for: bare) }
        let offers = try Offers.conversions(for: bare)
        try #require(offers.count == 3)
        for offer in offers {
            let converted = try WiringCandidate.classify(from: from, to: to, in: graph, conversion: offer.conversion)
            #expect(WiringDestinationClass(converted.connection) == .feedbackOnly)
            let feedback = try Offers.feedback(for: converted.connection)
            let both = try WiringCandidate.classify(
                from: from, to: to, in: graph, conversion: offer.conversion, feedback: feedback.feedback
            )
            #expect(both.connection == .valid)
            let request = WiringConnectRequest(
                edge: Fixture.id("edg.mono-verb-fb"), from: from, to: to,
                conversion: offer.conversion, feedback: feedback.feedback
            )
            let result = try Self.composeOffer(request, in: graph)
            #expect(result.edge.conversion == offer.conversion)
            #expect(result.edge.feedback == Self.expectedFeedback)
            #expect(result.errors.isEmpty)
        }
    }
}
