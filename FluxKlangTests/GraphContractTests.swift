//
//  GraphContractTests.swift
//  FluxKlangTests
//
//  The neutral graph contract: versioning, unknown-data round trips, typed port
//  compatibility, dangling references and explicit feedback.
//

import Foundation
import Testing
@testable import FluxKlang

struct GraphContractTests {
    static let canonicalGraph = #"{"capabilities":[{"id":"cap.au-effect","label":"AU effect"}],"#
        + #""contract":"fluxklang.graph","edges":[{"conversion":{"kind":"channelMap","map":[[0],[0]]},"#
        + #""from":{"node":"nod.mic","port":"out"},"id":"edg.mic-mains","to":{"node":"nod.mains","port":"in"},"#
        + #""x-edge":1}],"extensions":{"vendor":{"k":true}},"future":{"x":[1,2.5]},"id":"gph.main","nodes":["#
        + #"{"id":"nod.mains","kind":"roleOutput","label":"Mains","ports":[{"channels":2,"direction":"input","#
        + #""id":"in","signal":"audio"}],"role":"rol.mains"},{"id":"nod.mic","kind":"roleInput","label":"Vocal","#
        + #""ports":[{"channels":1,"direction":"output","id":"out","signal":"audio","x-port":"p"}],"#
        + #""position":{"x":10,"y":-2.5,"z":3},"role":"rol.mic"},{"id":"nod.verb","kind":"plugin","label":"Verb","#
        + #""ports":[],"requiredCapabilities":["cap.au-effect"]}],"revision":43,"version":1}"#

    @Test func roundTripsVersionAndUnknownOptionalDataByteEqual() throws {
        let graph = try GraphDocument.decode(from: Data(Self.canonicalGraph.utf8))
        #expect(graph.revision == (try ContractRevision(43)))
        #expect(graph.unknownFields == ["future": .object(["x": .array([.int(1), .double(2.5)])])])
        #expect(graph.extensions == ["vendor": .object(["k": .bool(true)])])
        #expect(graph.edges.first?.unknownFields == ["x-edge": .int(1)])
        #expect(graph.node(Self.node("nod.mic"))?.position?.unknownFields == ["z": .int(3)])
        #expect(try graph.encoded() == Data(Self.canonicalGraph.utf8))
        #expect(graph.validationErrors().isEmpty)
        #expect(graph.validationErrors(strict: true) == [
            .unknownFields(path: "$"), .unknownFields(path: "$.nodes[nod.mic].position"),
            .unknownFields(path: "$.nodes[nod.mic].ports[out]"), .unknownFields(path: "$.edges[edg.mic-mains]")
        ])
    }

    @Test func versionPolicyRejectsOtherContractsNewerVersionsAndUnversionedData() throws {
        func decoding(_ replacement: String) throws -> GraphDocument {
            let json = Self.canonicalGraph.replacingOccurrences(
                of: #""contract":"fluxklang.graph""#, with: replacement
            )
            return try GraphDocument.decode(from: Data(json.utf8))
        }
        #expect(throws: ContractVersionError.wrongContract(expected: "fluxklang.graph", found: "fluxklang.project")) {
            try decoding(#""contract":"fluxklang.project""#)
        }
        let newer = Self.canonicalGraph.replacingOccurrences(of: #""version":1"#, with: #""version":2"#)
        #expect(throws: ContractVersionError.unsupportedVersion(found: 2, supported: 1)) {
            try GraphDocument.decode(from: Data(newer.utf8))
        }
        let unversioned = Self.canonicalGraph
            .replacingOccurrences(of: #""contract":"fluxklang.graph","#, with: "")
            .replacingOccurrences(of: #","version":1"#, with: "")
        #expect(throws: DecodingError.self) { try GraphDocument.decode(from: Data(unversioned.utf8)) }
        #expect(throws: DecodingError.self) { try decoding(#""contract":"fluxklang.graph","id":"gph.twin""#) }
        #expect(throws: ProjectGraphVersionError.unsupportedRequiredFeatures(["future-routing"])) {
            try decoding(#""contract":"fluxklang.graph","requiredFeatures":["future-routing"]"#)
        }
    }

    @Test func sampleGraphWithExplicitConversionAndFeedbackIsValid() throws {
        try Self.sampleGraph().validate(strict: true)
        let reencoded = try GraphDocument.decode(from: Self.sampleGraph().encoded())
        #expect(reencoded == Self.sampleGraph())
    }

    @Test(arguments: [
        ("nod.mic", "out", "nod.verb", "mod", GraphValidationError.signalMismatch(
            edge: EdgeID(validated: "edg.new"), from: .audio, to: .control)),
        ("nod.mic", "out", "nod.cue", "in", .channelMismatch(edge: EdgeID(validated: "edg.new"), from: 1, to: 2)),
        ("nod.cue", "in", "nod.verb", "in", .wrongDirection(edge: EdgeID(validated: "edg.new"))),
        ("nod.pads", "out", "nod.verb", "in", .signalMismatch(
            edge: EdgeID(validated: "edg.new"), from: .midi, to: .audio))
    ])
    func rejectsIncompatiblePorts(
        from: StaticString, fromPort: StaticString, to: StaticString, toPort: StaticString,
        expected: GraphValidationError
    ) {
        var graph = Self.sampleGraph()
        graph.edges.append(Self.edge("edg.new", Self.address(from, fromPort), Self.address(to, toPort)))
        #expect(graph.validationErrors() == [expected])
    }

    @Test(arguments: [[[0], [1]], [[0]], [[], []], [[0], [-1]]])
    func rejectsInvalidChannelConversions(map: [[Int]]) {
        var graph = Self.sampleGraph()
        graph.edges.append(Self.edge(
            "edg.new", Self.address("nod.mic", "out"), Self.address("nod.cue", "in"),
            conversion: EdgeConversion(map: map)
        ))
        #expect(graph.validationErrors() == [.invalidConversion(edge: EdgeID(validated: "edg.new"))])
    }

    @Test func rejectsDanglingReferences() {
        var graph = Self.sampleGraph()
        let edgeID = EdgeID(validated: "edg.new")
        graph.edges.append(Self.edge("edg.new", Self.address("nod.ghost", "out"), Self.address("nod.cue", "in")))
        #expect(graph.validationErrors() == [.missingNode(edge: edgeID, Self.node("nod.ghost"))])
        graph.edges[graph.edges.count - 1].from = Self.address("nod.keys", "nope")
        #expect(graph.validationErrors() == [.missingPort(edge: edgeID, Self.address("nod.keys", "nope"))])
        graph.edges.removeLast()
        graph.nodes[0].requiredCapabilities = [CapabilityID(validated: "cap.unknown")]
        graph.nodes[1].role = nil
        #expect(graph.validationErrors() == [
            .undefinedCapability(node: Self.node("nod.keys"), CapabilityID(validated: "cap.unknown")),
            .missingReference(node: Self.node("nod.mic"), field: "role")
        ])
    }

    @Test func nonRoutableShortcutsHaveNoPortsAndCannotBeWired() {
        var graph = Self.sampleGraph()
        let shortcut = graph.nodes.firstIndex { $0.kind == .observedShortcut } ?? 0
        graph.nodes[shortcut].ports = [GraphPort(id: PortID(validated: "out"), direction: .output, signal: .midi)]
        graph.edges.append(Self.edge("edg.new", Self.address("nod.ch7", "out"), Self.address("nod.synth", "in")))
        #expect(graph.validationErrors() == [
            .nonRoutableNodeHasPorts(Self.node("nod.ch7")),
            .missingPort(edge: EdgeID(validated: "edg.new"), Self.address("nod.ch7", "out"))
        ])
    }

    @Test func portIDsAreScopedPerNodeButUniqueWithinOne() {
        var graph = Self.sampleGraph()
        #expect(graph.nodes.filter { $0.port(PortID(validated: "in")) != nil }.count > 1)
        graph.nodes[0].ports.append(graph.nodes[0].ports[0])
        graph.edges.append(graph.edges[0])
        graph.edges[graph.edges.count - 1].id = EdgeID(validated: "edg.copy")
        #expect(graph.validationErrors() == [
            .duplicatePort(Self.node("nod.keys"), PortID(validated: "out")),
            .duplicateWire(EdgeID(validated: "edg.copy"))
        ])
    }

    @Test func edgeLookupKeepsFirstDuplicateNodeAndPortAndDiagnosticOrder() {
        let source = GraphNode(id: Self.node("nod.source"), kind: .plugin, label: "Source", ports: [
            Self.port("out", .output, .control), Self.port("out", .input, .control)
        ])
        let destination = GraphNode(id: Self.node("nod.destination"), kind: .plugin, label: "Destination",
                                    ports: [Self.port("in", .input, .control)])
        let shortcut = GraphNode(id: source.id, kind: .observedShortcut, label: "Duplicate shortcut")
        let edge = Self.edge("edg.lookup", Self.address("nod.source", "out"), Self.address("nod.destination", "in"))
        var graph = GraphDocument(id: GraphID(validated: "gph.lookup"),
                                  nodes: [source, destination, shortcut], edges: [edge])
        #expect(graph.validationErrors() == [
            .duplicatePort(source.id, PortID(validated: "out")), .duplicateNode(source.id)
        ])

        graph.nodes = [shortcut, destination, source]
        #expect(graph.validationErrors() == [
            .duplicateNode(source.id), .duplicatePort(source.id, PortID(validated: "out")),
            .missingPort(edge: edge.id, edge.from)
        ])
    }

    @Test func endpointMetadataDoesNotChangePortOrWireIdentity() {
        var graph = Self.sampleGraph()
        var duplicate = graph.edges[0]
        duplicate.id = EdgeID(validated: "edg.copy")
        graph.edges[0].from.extensions = ["note": .string("source metadata")]
        graph.edges[0].from.unknownFields = ["futureSource": .bool(true)]
        graph.edges[0].to.extensions = ["note": .string("destination metadata")]
        graph.edges[0].to.unknownFields = ["futureDestination": .int(1)]
        #expect(graph.validationErrors().isEmpty)
        #expect(graph.validationErrors(strict: true) == [
            .unknownFields(path: "$.edges[edg.keys-verb].from"),
            .unknownFields(path: "$.edges[edg.keys-verb].to")
        ])
        graph.edges.append(duplicate)
        #expect(graph.validationErrors() == [.duplicateWire(duplicate.id)])
    }

    @Test func validatesGraphAtNodeAndEdgeCollectionLimits() throws {
        let nodes = try (0..<ProjectGraphLimits.nodes).map { index in
            GraphNode(id: try NodeID("nod.\(index)"), kind: .plugin, label: "Node \(index)", ports: [
                Self.port("in", .input, .control), Self.port("out", .output, .control)
            ])
        }
        let half = nodes.count / 2
        let edges = try (0..<ProjectGraphLimits.edges).map { index in
            let source = nodes[index % half].id
            let destination = nodes[half + (index % half + index / half) % half].id
            return GraphEdge(
                id: try EdgeID("edg.\(index)"),
                from: PortAddress(node: source, port: PortID(validated: "out")),
                to: PortAddress(node: destination, port: PortID(validated: "in"))
            )
        }
        let graph = GraphDocument(id: GraphID(validated: "gph.bounded"), nodes: nodes, edges: edges)
        #expect(graph.nodes.count == ProjectGraphLimits.nodes)
        #expect(graph.edges.count == ProjectGraphLimits.edges)
        try graph.validate(strict: true)
    }

    @Test func cyclesNeedAnExplicitValidFeedbackEdge() {
        var graph = Self.sampleGraph()
        let feedback = graph.edges.firstIndex { $0.feedback != nil } ?? 0
        graph.edges[feedback].feedback = nil
        #expect(graph.validationErrors() == [.cycleWithoutFeedback([Self.node("nod.echo"), Self.node("nod.verb")])])
        for invalid in [
            EdgeFeedback(delayBlocks: 0, gainCeilingDb: -6),
            EdgeFeedback(delayBlocks: 1, gainCeilingDb: 3),
            EdgeFeedback(delayBlocks: 1, gainCeilingDb: -.infinity)
        ] {
            graph.edges[feedback].feedback = invalid
            #expect(graph.validationErrors() == [.invalidFeedback(edge: graph.edges[feedback].id)])
        }
    }

    @Test func boundsRejectBeforeTopologyWorkAndCoding() throws {
        var graph = Self.sampleGraph()
        graph.nodes[0].ports = Array(repeating: graph.nodes[0].ports[0], count: ProjectGraphLimits.portsPerNode + 1)
        #expect(graph.validationErrors() == [
            .bounds(.exceeded(path: "$.nodes[nod.keys].ports", maximum: ProjectGraphLimits.portsPerNode))
        ])
        #expect(throws: ProjectGraphLimitError.self) { try graph.encoded() }
        let oversized = Data(repeating: 32, count: ProjectGraphLimits.documentBytes + 1)
        #expect(throws: ProjectGraphLimitError.self) { try GraphDocument.decode(from: oversized) }
        var finite = Self.sampleGraph()
        finite.nodes[0].position = GraphPoint(x: .infinity, y: 0)
        #expect(finite.validationErrors().contains(.invalidPosition(finite.nodes[0].id)))
    }

    @Test func unknownRequiredCapabilitiesBlockPreparationButAdvisoryOnesDoNot() throws {
        let graph = Self.sampleGraph()
        #expect(throws: GraphValidationError.unsupportedRequiredCapability(
            node: Self.node("nod.synth"), CapabilityID(validated: "cap.au-instrument")
        )) {
            try graph.validateForPreparation(supportedCapabilities: [])
        }
        try graph.validateForPreparation(supportedCapabilities: [
            CapabilityID(validated: "cap.au-instrument"), CapabilityID(validated: "cap.au-effect")
        ])
    }

    @Test func strictCapabilityExtensionsRoundTripButUnknownMembersReject() throws {
        var graph = Self.sampleGraph()
        let extensionBag: [String: JSONValue] = ["vendor": .object(["options": .array([.int(1), .null])])]
        graph.capabilities[0] = CapabilityDefinition(
            id: graph.capabilities[0].id, label: graph.capabilities[0].label, extensions: extensionBag
        )
        let data = try graph.encoded()
        var decoded = try GraphDocument.decode(from: data)
        #expect(decoded == graph)
        #expect(decoded.capabilities[0].extensions == extensionBag)
        #expect(decoded.capabilities[0].unknownFields.isEmpty)
        #expect(decoded.validationErrors(strict: true).isEmpty)
        #expect(try decoded.encoded() == data)

        decoded.capabilities[0].unknownFields = ["futureCapability": .bool(true)]
        let future = try GraphDocument.decode(from: decoded.encoded())
        #expect(future == decoded)
        #expect(future.validationErrors().isEmpty)
        #expect(future.validationErrors(strict: true) == [
            .unknownFields(path: "$.capabilities[cap.au-effect]")
        ])
    }

    @Test func nestedExtensionsStayDistinctFromUnknownOptionalMembers() throws {
        var graph = Self.sampleGraph()
        graph.nodes[0].ports[0].extensions = ["vendor": .array([.int(1), .null])]
        graph.nodes[0].ports[0].unknownFields = ["futurePort": .object(["keep": .bool(true)])]
        graph.edges[0].from.extensions = ["endpointNote": .string("inert")]
        graph.edges[3].feedback?.extensions = ["review": .string("portable note")]
        let decoded = try GraphDocument.decode(from: graph.encoded())
        #expect(decoded == graph)
        #expect(decoded.validationErrors(strict: true) == [
            .unknownFields(path: "$.nodes[nod.keys].ports[out]")
        ])
    }

}

extension GraphContractTests {
    static func node(_ id: StaticString) -> NodeID { NodeID(validated: id) }

    static func address(_ node: StaticString, _ port: StaticString) -> PortAddress {
        PortAddress(node: NodeID(validated: node), port: PortID(validated: port))
    }

    static func port(
        _ id: StaticString, _ direction: PortDirection, _ signal: PortSignal = .audio, channels: Int? = nil
    ) -> GraphPort {
        GraphPort(id: PortID(validated: id), direction: direction, signal: signal, channels: channels)
    }

    static func edge(
        _ id: StaticString, _ from: PortAddress, _ to: PortAddress,
        conversion: EdgeConversion? = nil, feedback: EdgeFeedback? = nil
    ) -> GraphEdge {
        GraphEdge(id: EdgeID(validated: id), from: from, to: to, conversion: conversion, feedback: feedback)
    }

    static func roleNode(
        _ id: StaticString, _ kind: NodeKind, role: StaticString, _ ports: [GraphPort]
    ) -> GraphNode {
        GraphNode(id: NodeID(validated: id), kind: kind, label: "\(id)", role: RoleID(validated: role), ports: ports)
    }

    /// A small rig in the shape of the #98 `graph.json` draft.
    static func sampleGraph() -> GraphDocument {
        let effect = CapabilityID(validated: "cap.au-effect")
        let instrument = CapabilityID(validated: "cap.au-instrument")
        let tapeEcho = CapabilityID(validated: "cap.tape-echo")
        let stereoIn = port("in", .input, channels: 2)
        let stereoOut = port("out", .output, channels: 2)
        return GraphDocument(
            id: GraphID(validated: "gph.main"),
            revision: (try? ContractRevision(43)) ?? .initial,
            capabilities: [
                CapabilityDefinition(id: effect, label: "AU effect"),
                CapabilityDefinition(id: instrument, label: "AU instrument"),
                CapabilityDefinition(id: tapeEcho, label: "Tape Echo")
            ],
            nodes: [
                roleNode("nod.keys", .roleInput, role: "rol.keys", [stereoOut]),
                roleNode("nod.mic", .roleInput, role: "rol.mic", [port("out", .output, channels: 1)]),
                roleNode("nod.pads", .roleInput, role: "rol.pads", [port("out", .output, .midi)]),
                GraphNode(id: node("nod.synth"), kind: .plugin, label: "Synth",
                          ports: [port("in", .input, .midi), stereoOut], requiredCapabilities: [instrument]),
                GraphNode(id: node("nod.verb"), kind: .plugin, label: "Verb",
                          ports: [stereoIn, port("mod", .input, .control), stereoOut], requiredCapabilities: [effect]),
                GraphNode(id: node("nod.echo"), kind: .plugin, label: "Echo",
                          ports: [stereoIn, stereoOut], advisoryCapabilities: [tapeEcho]),
                roleNode("nod.mains", .roleOutput, role: "rol.mains", [stereoIn]),
                roleNode("nod.cue", .roleOutput, role: "rol.cue", [stereoIn]),
                GraphNode(id: node("nod.ch7"), kind: .observedShortcut, label: "Console channel 7")
            ],
            edges: [
                edge("edg.keys-verb", address("nod.keys", "out"), address("nod.verb", "in")),
                edge("edg.keys-echo", address("nod.keys", "out"), address("nod.echo", "in")),
                edge("edg.echo-verb", address("nod.echo", "out"), address("nod.verb", "in")),
                edge("edg.verb-echo-fb", address("nod.verb", "out"), address("nod.echo", "in"),
                     feedback: EdgeFeedback(delayBlocks: 1, gainCeilingDb: -6)),
                edge("edg.verb-mains", address("nod.verb", "out"), address("nod.mains", "in")),
                edge("edg.mic-mains", address("nod.mic", "out"), address("nod.mains", "in"),
                     conversion: EdgeConversion(map: [[0], [0]], label: "Mono to both sides")),
                edge("edg.pads-synth", address("nod.pads", "out"), address("nod.synth", "in")),
                edge("edg.synth-mains", address("nod.synth", "out"), address("nod.mains", "in"))
            ]
        )
    }
}
