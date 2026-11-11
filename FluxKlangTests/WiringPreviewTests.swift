//
//  WiringPreviewTests.swift
//  FluxKlangTests
//
//  Connection candidates (#101 WP1): every class of wiring.md's "Connection
//  validation" table on one fixture graph, the fixed precedence, explicit
//  conversion and feedback, and pre-existing errors that must not leak in.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum WiringPreviewFixture {
    static let graphID = GraphID(validated: "gph.wiring")
    static let feedback = EdgeFeedback(delayBlocks: 1, gainCeilingDb: -6)
    static let upmix = EdgeConversion(map: [[0], [0]], label: "Mono to both sides")

    static func id<Tag>(_ raw: String) -> ContractID<Tag> {
        guard let id = ContractID<Tag>(rawValue: raw) else { preconditionFailure("Invalid fixture ID \(raw)") }
        return id
    }

    static func address(_ node: String, _ port: String) -> PortAddress {
        PortAddress(node: id(node), port: id(port))
    }

    static func audio(_ id: String, _ direction: PortDirection, _ channels: Int?) -> GraphPort {
        GraphPort(id: Self.id(id), direction: direction, signal: .audio, channels: channels)
    }

    static func node(
        _ id: String, _ kind: NodeKind = .plugin, role: String? = nil, ports: [GraphPort], at column: Double = 0
    ) -> GraphNode {
        GraphNode(
            id: Self.id(id), kind: kind, label: id, role: role.map { Self.id($0) },
            ports: ports, position: GraphPoint(x: column, y: 0)
        )
    }

    static func edge(
        _ id: String, _ from: PortAddress, _ to: PortAddress,
        conversion: EdgeConversion? = nil, feedback: EdgeFeedback? = nil
    ) -> GraphEdge {
        GraphEdge(id: Self.id(id), from: from, to: to, conversion: conversion, feedback: feedback)
    }

    static func stereo(_ id: String, at column: Double) -> GraphNode {
        node(id, ports: [audio("in", .input, 2), audio("out", .output, 2)], at: column)
    }

    /// keys, mic (mono, converted) and echo → verb → mains; verb → delay → verb is closed by explicit
    /// feedback; nod.ch7 is an observed shortcut.
    static var graph: GraphDocument {
        let verbPorts = [
            audio("in", .input, 2), audio("out", .output, 2),
            GraphPort(id: PortID(validated: "mod"), direction: .input, signal: .control)
        ]
        let nodes = [
            node("nod.keys", ports: [audio("out", .output, 2)], at: 1),
            node("nod.mic", .roleInput, role: "rol.mic", ports: [audio("out", .output, 1)], at: 2),
            node("nod.mains", .roleOutput, role: "rol.mains", ports: [audio("in", .input, 2)], at: 3),
            node("nod.verb", ports: verbPorts, at: 4), stereo("nod.echo", at: 5), stereo("nod.delay", at: 6),
            node("nod.ch7", .observedShortcut, ports: [], at: 7)
        ]
        let edges = [
            edge("edg.keys-verb", address("nod.keys", "out"), address("nod.verb", "in")),
            edge("edg.echo-verb", address("nod.echo", "out"), address("nod.verb", "in")),
            edge("edg.verb-mains", address("nod.verb", "out"), address("nod.mains", "in")),
            edge("edg.mic-verb", address("nod.mic", "out"), address("nod.verb", "in"), conversion: upmix),
            edge("edg.verb-delay", address("nod.verb", "out"), address("nod.delay", "in")),
            edge("edg.delay-verb-fb", address("nod.delay", "out"), address("nod.verb", "in"), feedback: feedback)
        ]
        return GraphDocument(id: graphID, nodes: nodes, edges: edges)
    }

    static func with(_ edges: [GraphEdge], nodes: [GraphNode] = [], in base: GraphDocument = graph) -> GraphDocument {
        var graph = base
        graph.nodes += nodes
        graph.edges += edges
        return graph
    }

    static func classify(
        _ from: (String, String), _ to: (String, String), in graph: GraphDocument = graph,
        conversion: EdgeConversion? = nil, feedback: EdgeFeedback? = nil
    ) throws(WiringPreviewRefusal) -> WiringConnection {
        try WiringCandidate.classify(
            from: address(from.0, from.1), to: address(to.0, to.1), in: graph,
            conversion: conversion, feedback: feedback
        ).connection
    }

    /// One documented pair and its class.
    struct Documented: Sendable {
        let from: (String, String)
        let to: (String, String)
        let expected: WiringConnection
    }

    /// The seven documented classes, one pair each.
    static let documented: [Documented] = [
        Documented(from: ("nod.keys", "out"), to: ("nod.mains", "in"), expected: .valid),
        Documented(from: ("nod.mic", "out"), to: ("nod.mains", "in"),
                   expected: .needsConversion(sourceChannels: 1, destinationChannels: 2)),
        Documented(from: ("nod.keys", "out"), to: ("nod.verb", "mod"),
                   expected: .disabled(.signalMismatch(from: .audio, to: .control))),
        Documented(from: ("nod.mains", "in"), to: ("nod.verb", "in"), expected: .notOffered),
        Documented(from: ("nod.verb", "out"), to: ("nod.echo", "in"),
                   expected: .feedbackOnly(cycle: [NodeID(validated: "nod.echo"), NodeID(validated: "nod.verb")])),
        Documented(from: ("nod.keys", "out"), to: ("nod.verb", "in"),
                   expected: .existing(EdgeID(validated: "edg.keys-verb"))),
        Documented(from: ("nod.ch7", "out"), to: ("nod.verb", "in"),
                   expected: .notRoutable(NodeID(validated: "nod.ch7")))
    ]
}

private typealias Fixture = WiringPreviewFixture

#if os(macOS)
@Suite("Wiring preview candidates", .productionAccessAudit)
#else
@Suite("Wiring preview candidates")
#endif
struct WiringPreviewTests {
    @Test func fixtureGraphIsValid() {
        #expect(Fixture.graph.validationErrors().isEmpty)
    }

    @Test func eachDocumentedClassOnTheFixture() throws {
        for row in Fixture.documented {
            let candidate = try WiringCandidate.classify(
                from: Fixture.address(row.from.0, row.from.1), to: Fixture.address(row.to.0, row.to.1),
                in: Fixture.graph
            )
            #expect(candidate.connection == row.expected, "\(row.from) → \(row.to)")
            #expect(candidate.from == Fixture.address(row.from.0, row.from.1))
            #expect(candidate.to == Fixture.address(row.to.0, row.to.1))
            #expect(candidate.conversion == nil && candidate.feedback == nil)
        }
    }

    @Test func inputToInputWithSignalMismatchIsNotOffered() throws {
        #expect(try Fixture.classify(("nod.mains", "in"), ("nod.verb", "mod")) == .notOffered)
        #expect(try Fixture.classify(("nod.verb", "mod"), ("nod.mains", "in")) == .notOffered)
        #expect(try Fixture.classify(("nod.verb", "out"), ("nod.keys", "out")) == .notOffered)
    }

    @Test func monoToStereoHasNoDefaultConversion() throws {
        let from = Fixture.address("nod.mic", "out"), to = Fixture.address("nod.mains", "in")
        let bare = try WiringCandidate.classify(from: from, to: to, in: Fixture.graph)
        #expect(bare.connection == .needsConversion(sourceChannels: 1, destinationChannels: 2))
        #expect(bare.conversion == nil)
        let chosen = try WiringCandidate.classify(from: from, to: to, in: Fixture.graph, conversion: Fixture.upmix)
        #expect(chosen.connection == .valid)
        #expect(chosen.conversion == Fixture.upmix)
        let wrongWidth = EdgeConversion(map: [[0]])
        #expect(throws: WiringPreviewRefusal.invalidConversion(wrongWidth)) {
            try WiringCandidate.classify(from: from, to: to, in: Fixture.graph, conversion: wrongWidth)
        }
        let outOfRange = EdgeConversion(map: [[0], [1]])
        #expect(throws: WiringPreviewRefusal.invalidConversion(outOfRange)) {
            try WiringCandidate.classify(from: from, to: to, in: Fixture.graph, conversion: outOfRange)
        }
        #expect(try Fixture.classify(("nod.mic", "out"), ("nod.mains", "in"), feedback: Fixture.feedback)
            == .needsConversion(sourceChannels: 1, destinationChannels: 2))
    }

    @Test func cycleIsNeverGivenFeedbackAutomatically() throws {
        let from = Fixture.address("nod.verb", "out"), to = Fixture.address("nod.echo", "in")
        let bare = try WiringCandidate.classify(from: from, to: to, in: Fixture.graph)
        #expect(bare.connection == .feedbackOnly(cycle: [NodeID(validated: "nod.echo"), NodeID(validated: "nod.verb")]))
        #expect(bare.feedback == nil)
        let explicit = try WiringCandidate.classify(from: from, to: to, in: Fixture.graph, feedback: Fixture.feedback)
        #expect(explicit.connection == .valid)
        #expect(explicit.feedback == Fixture.feedback)
        let wired = try Fixture.graph.applying([.connect(Fixture.edge("edg.verb-echo-fb", from, to,
                                                                      feedback: Fixture.feedback))])
        #expect(wired.validationErrors().isEmpty)
        #expect(try Fixture.classify(("nod.verb", "out"), ("nod.echo", "in"),
                                     conversion: EdgeConversion(map: [[0], [1]]))
            == bare.connection)
        for invalid in [EdgeFeedback(delayBlocks: 0, gainCeilingDb: -6), EdgeFeedback(gainCeilingDb: 3)] {
            #expect(throws: WiringPreviewRefusal.invalidFeedback(invalid)) {
                try WiringCandidate.classify(from: from, to: to, in: Fixture.graph, feedback: invalid)
            }
        }
    }

    @Test func preExistingUnrelatedErrorsDoNotChangeTheClass() throws {
        var polluted = Fixture.with(
            [Fixture.edge("edg.a-b", Fixture.address("nod.a", "out"), Fixture.address("nod.b", "in")),
             Fixture.edge("edg.b-a", Fixture.address("nod.b", "out"), Fixture.address("nod.a", "in")),
             Fixture.edge("edg.stray", Fixture.address("nod.mains", "in"), Fixture.address("nod.echo", "in"))],
            nodes: [Fixture.stereo("nod.a", at: 8), Fixture.stereo("nod.b", at: 9),
                    Fixture.node("nod.broken", ports: [Fixture.audio("in", .input, nil)])]
        )
        polluted.requiresReview = true
        #expect(polluted.validationErrors().count == 4)
        for row in Fixture.documented {
            #expect(try Fixture.classify(row.from, row.to, in: polluted) == row.expected, "\(row.from) → \(row.to)")
        }
    }

    @Test func wireAmongAlreadyLoopingNodesIsFeedbackOnly() throws {
        // `cycleWithoutFeedback` is one aggregate node list, so a wire that only closes another loop
        // among nodes already on an unfed cycle introduces no new error; it is still never valid
        // without explicit feedback.
        let names = ["nod.a", "nod.b", "nod.c"]
        let loop = Fixture.with(
            (0..<3).map { index in
                Fixture.edge("edg.loop\(index)", Fixture.address(names[index], "out"),
                             Fixture.address(names[(index + 1) % 3], "in"))
            },
            nodes: names.enumerated().map { Fixture.stereo($1, at: Double(8 + $0)) }
        )
        let ends = [NodeID(validated: "nod.a"), NodeID(validated: "nod.c")]
        #expect(try Fixture.classify(("nod.a", "out"), ("nod.c", "in"), in: loop) == .feedbackOnly(cycle: ends))
        #expect(try Fixture.classify(("nod.b", "out"), ("nod.a", "in"), in: loop)
            == .feedbackOnly(cycle: [NodeID(validated: "nod.a"), NodeID(validated: "nod.b")]))
        #expect(try Fixture.classify(("nod.c", "out"), ("nod.a", "in"), in: loop) == .existing(Fixture.id("edg.loop2")))
        #expect(try Fixture.classify(("nod.a", "out"), ("nod.a", "in"), in: loop)
            == .feedbackOnly(cycle: [NodeID(validated: "nod.a")]))
        let identity = EdgeConversion(map: [[0], [1]])
        #expect(try Fixture.classify(("nod.a", "out"), ("nod.c", "in"), in: loop, conversion: identity)
            == .feedbackOnly(cycle: ends))
        #expect(try Fixture.classify(("nod.a", "out"), ("nod.c", "in"), in: loop, feedback: Fixture.feedback) == .valid)
        // Only one looping endpoint and no new cycle: valid.
        #expect(try Fixture.classify(("nod.a", "out"), ("nod.mains", "in"), in: loop) == .valid)
        #expect(try Fixture.classify(("nod.keys", "out"), ("nod.a", "in"), in: loop) == .valid)
        #expect(try Fixture.classify(("nod.verb", "out"), ("nod.echo", "in"), in: loop)
            == .feedbackOnly(cycle: [NodeID(validated: "nod.echo"), NodeID(validated: "nod.verb")]))
    }

    @Test func endpointsWithBrokenPortsAreRefused() throws {
        let broken = Fixture.node("nod.broken", ports: [Fixture.audio("in", .input, nil),
                                                        Fixture.audio("out", .output, 2)])
        let unconfirmed = Fixture.with([], nodes: [broken])
        let refusal = WiringPreviewRefusal.endpointUncheckable(node: broken.id)
        #expect(throws: refusal) { try Fixture.classify(("nod.keys", "out"), ("nod.broken", "in"), in: unconfirmed) }
        #expect(throws: refusal) { try Fixture.classify(("nod.broken", "out"), ("nod.mains", "in"), in: unconfirmed) }
        #expect(try Fixture.classify(("nod.keys", "out"), ("nod.mains", "in"), in: unconfirmed) == .valid)
        var gain = Fixture.with([], nodes: [
            GraphNode(id: NodeID(validated: "nod.gain"), kind: .audioGain, label: "Gain",
                      ports: [Fixture.audio("in", .input, 2), Fixture.audio("out", .output, 1)], linearGain: 1)
        ])
        gain.requiredFeatures = [GraphDocument.constantGainFeature]
        #expect(gain.validationErrors() == [.invalidGainShape(NodeID(validated: "nod.gain"))])
        #expect(throws: WiringPreviewRefusal.endpointUncheckable(node: NodeID(validated: "nod.gain"))) {
            try Fixture.classify(("nod.keys", "out"), ("nod.gain", "in"), in: gain)
        }
        var mute = Fixture.with([], nodes: [
            GraphNode(id: NodeID(validated: "nod.mute"), kind: .audioMute, label: "Mute",
                      ports: [Fixture.audio("in", .input, 2), Fixture.audio("out", .output, 1)], muted: false)
        ])
        mute.requiredFeatures = [GraphDocument.constantMuteFeature]
        #expect(mute.validationErrors() == [.invalidMuteShape(NodeID(validated: "nod.mute"))])
        #expect(throws: WiringPreviewRefusal.endpointUncheckable(node: NodeID(validated: "nod.mute"))) {
            try Fixture.classify(("nod.mute", "out"), ("nod.mains", "in"), in: mute)
        }
        let twin = Fixture.node("nod.twin", ports: [Fixture.audio("in", .input, 2), Fixture.audio("in", .input, 2),
                                                    Fixture.audio("out", .output, 2)])
        let repeated = Fixture.with([], nodes: [twin])
        #expect(repeated.validationErrors() == [.duplicatePort(twin.id, Fixture.id("in"))])
        #expect(throws: WiringPreviewRefusal.endpointUncheckable(node: twin.id)) {
            try Fixture.classify(("nod.keys", "out"), ("nod.twin", "in"), in: repeated)
        }
        #expect(throws: WiringPreviewRefusal.endpointUncheckable(node: twin.id)) {
            try Fixture.classify(("nod.twin", "out"), ("nod.mains", "in"), in: repeated)
        }
        #expect(try Fixture.classify(("nod.keys", "out"), ("nod.mains", "in"), in: repeated) == .valid)
    }

    @Test func classesFollowTheFixedPrecedence() throws {
        // Duplicate outranks channels and cycle.
        #expect(try Fixture.classify(("nod.mic", "out"), ("nod.verb", "in"))
            == .existing(EdgeID(validated: "edg.mic-verb")))
        #expect(try Fixture.classify(("nod.delay", "out"), ("nod.verb", "in"))
            == .existing(EdgeID(validated: "edg.delay-verb-fb")))
        // Duplicate outranks signal; direction outranks duplicate.
        let badWire = Fixture.edge("edg.bad-wire", Fixture.address("nod.keys", "out"),
                                   Fixture.address("nod.verb", "mod"))
        #expect(try Fixture.classify(("nod.keys", "out"), ("nod.verb", "mod"), in: Fixture.with([badWire]))
            == .existing(EdgeID(validated: "edg.bad-wire")))
        let backwards = Fixture.edge("edg.backwards", Fixture.address("nod.mains", "in"),
                                     Fixture.address("nod.verb", "in"))
        #expect(try Fixture.classify(("nod.mains", "in"), ("nod.verb", "in"), in: Fixture.with([backwards]))
            == .notOffered)
        // Not routable outranks direction, on either end.
        let shortcut = NodeID(validated: "nod.ch7")
        #expect(try Fixture.classify(("nod.ch7", "x"), ("nod.keys", "out")) == .notRoutable(shortcut))
        #expect(try Fixture.classify(("nod.verb", "out"), ("nod.ch7", "in")) == .notRoutable(shortcut))
        // Supplied attributes never mask a structural class.
        #expect(try Fixture.classify(("nod.mains", "in"), ("nod.verb", "in"),
                                     feedback: EdgeFeedback(delayBlocks: 0, gainCeilingDb: 1)) == .notOffered)
        #expect(try Fixture.classify(("nod.mic", "out"), ("nod.verb", "in"), conversion: Fixture.upmix)
            == .existing(EdgeID(validated: "edg.mic-verb")))
        #expect(try Fixture.classify(("nod.keys", "out"), ("nod.verb", "mod"), conversion: Fixture.upmix)
            == .disabled(.signalMismatch(from: .audio, to: .control)))
    }

    @Test func unknownEndpointsAreRefusedBeforeAnyClass() {
        #expect(throws: WiringPreviewRefusal.unknownPort(Fixture.address("nod.keys", "nope"))) {
            try Fixture.classify(("nod.ch7", "x"), ("nod.keys", "nope"))
        }
        #expect(throws: WiringPreviewRefusal.unknownNode(NodeID(validated: "nod.ghost"))) {
            try Fixture.classify(("nod.ch7", "x"), ("nod.ghost", "in"))
        }
        #expect(throws: WiringPreviewRefusal.unknownPort(Fixture.address("nod.keys", "nope"))) {
            try Fixture.classify(("nod.keys", "nope"), ("nod.ghost", "in"))
        }
        #expect(throws: WiringPreviewRefusal.unknownPort(Fixture.address("nod.verb", "side"))) {
            try Fixture.classify(("nod.mains", "in"), ("nod.verb", "side"))
        }
    }

    @Test func existingNamesTheFirstRepeatedWireCountingRepeats() throws {
        let twin = Fixture.edge("edg.keys-verb-2", Fixture.address("nod.keys", "out"),
                                Fixture.address("nod.verb", "in"))
        #expect(try Fixture.classify(("nod.keys", "out"), ("nod.verb", "in"), in: Fixture.with([twin]))
            == .existing(EdgeID(validated: "edg.keys-verb")))
        // The same edge entered twice already reports its own duplicate wire; the candidate still adds one.
        let repeated = Fixture.graph.edges[0]
        #expect(try Fixture.classify(("nod.keys", "out"), ("nod.verb", "in"), in: Fixture.with([repeated]))
            == .existing(repeated.id))
    }

    @Test func probeEdgeIDNeverCollides() throws {
        let taken = [
            Fixture.edge("wpv.probe", Fixture.address("nod.echo", "out"), Fixture.address("nod.mains", "in")),
            Fixture.edge("wpv.probe.1", Fixture.address("nod.keys", "out"), Fixture.address("nod.delay", "in"))
        ]
        let graph = Fixture.with(taken)
        #expect(graph.validationErrors().isEmpty)
        #expect(try WiringCandidateClassifier.probeID(avoiding: graph.edges) == EdgeID(validated: "wpv.probe.2"))
        #expect(try WiringCandidateClassifier.probeID(avoiding: Fixture.graph.edges) == EdgeID(validated: "wpv.probe"))
        for row in Fixture.documented {
            #expect(try Fixture.classify(row.from, row.to, in: graph) == row.expected, "\(row.from) → \(row.to)")
        }
    }

    @Test func uncheckableGraphsAreRefused() {
        var gain = Fixture.graph
        gain.nodes.append(GraphNode(id: NodeID(validated: "nod.gain"), kind: .audioGain, label: "Gain",
                                    linearGain: 1))
        #expect(throws: WiringPreviewRefusal.uncheckableGraph(.invalidRequiredFeatures([]))) {
            try Fixture.classify(("nod.keys", "out"), ("nod.mains", "in"), in: gain)
        }
        var collision = Fixture.graph
        collision.unknownFields["requiredFeatures"] = .array([])
        #expect(throws: WiringPreviewRefusal.uncheckableGraph(.requiredFeaturesCollision)) {
            try Fixture.classify(("nod.keys", "out"), ("nod.mains", "in"), in: collision)
        }
    }

    @Test func edgeBoundIsEnforcedAtNAndNPlusOne() throws {
        func filled(to count: Int) -> GraphDocument {
            let filler = Fixture.graph.edges[2]
            let extra = (0..<(count - Fixture.graph.edges.count)).map { index in
                Fixture.edge("edg.fill.\(index)", filler.from, filler.to)
            }
            return Fixture.with(extra)
        }
        let limit = ProjectGraphLimits.edges
        #expect(try Fixture.classify(("nod.keys", "out"), ("nod.mains", "in"), in: filled(to: limit - 1)) == .valid)
        let exceeded = WiringPreviewRefusal.bounds(.exceeded(path: "$.edges", maximum: limit))
        #expect(throws: exceeded) {
            try Fixture.classify(("nod.keys", "out"), ("nod.mains", "in"), in: filled(to: limit))
        }
        #expect(throws: exceeded) {
            try Fixture.classify(("nod.keys", "out"), ("nod.mains", "in"), in: filled(to: limit + 1))
        }
        // An existing wire adds no edge: at N it is still `existing`, naming the first repeat.
        #expect(try Fixture.classify(("nod.keys", "out"), ("nod.verb", "in"), in: filled(to: limit))
            == .existing(EdgeID(validated: "edg.keys-verb")))
        #expect(try Fixture.classify(("nod.verb", "out"), ("nod.mains", "in"), in: filled(to: limit))
            == .existing(EdgeID(validated: "edg.verb-mains")))
        let last = Fixture.edge("edg.last", Fixture.address("nod.echo", "out"), Fixture.address("nod.mains", "in"))
        let lastOnly = Fixture.with([last], in: filled(to: limit - 1))
        #expect(try Fixture.classify(("nod.echo", "out"), ("nod.mains", "in"), in: lastOnly) == .existing(last.id))
        // Deliberate: at N a new (non-repeated) wire is refused with bounds even if it would be notOffered
        // or disabled, because the contract cannot validate the probe without exceeding the limit.
        #expect(throws: exceeded) {
            try Fixture.classify(("nod.mains", "in"), ("nod.echo", "out"), in: lastOnly)
        }
        #expect(throws: exceeded) {
            try Fixture.classify(("nod.keys", "out"), ("nod.verb", "mod"), in: lastOnly)
        }
        // Direction still outranks a repeated wire at the bound.
        let backwards = Fixture.edge("edg.backwards", Fixture.address("nod.mains", "in"),
                                     Fixture.address("nod.verb", "in"))
        #expect(try Fixture.classify(("nod.mains", "in"), ("nod.verb", "in"),
                                     in: Fixture.with([backwards], in: filled(to: limit - 1))) == .notOffered)
    }

    @Test func introducedErrorsAreAMultisetDifference() {
        let wire = GraphValidationError.duplicateWire(EdgeID(validated: "edg.a"))
        let cycle = GraphValidationError.cycleWithoutFeedback([NodeID(validated: "nod.a")])
        #expect(WiringCandidateClassifier.introduced([wire, cycle, wire], over: [wire]) == [cycle, wire])
        #expect(WiringCandidateClassifier.introduced([wire], over: [wire, wire]).isEmpty)
        #expect(WiringCandidateClassifier.introduced([], over: [cycle]).isEmpty)
    }
}
