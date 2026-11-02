import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct AudioMuteContractTests {
    private static let token = GraphDocument.constantMuteFeature
    private static let values: [(String, JSONValue)] = [
        ("true", .bool(true)), ("false", .bool(false)), ("null", .null),
        ("42", .int(42)), ("2.5", .double(2.5)), (#""state""#, .string("state")),
        (#"[null,false,3]"#, .array([.null, .bool(false), .int(3)])),
        (#"{"nested":"state"}"#, .object(["nested": .string("state")]))
    ]

    @Test(arguments: NodeKind.allCases.filter { $0 != .audioMute })
    func legacyMutedIsUnknownForEveryJSONKind(kind: NodeKind) throws {
        let base = GraphDocument(id: GraphID(validated: "graph.mute"), nodes: [Self.legacy(kind)])
        let canonical = try #require(String(data: base.encoded(), encoding: .utf8))
        for (raw, value) in Self.values {
            let wire = canonical.replacingOccurrences(
                of: #""label":"Legacy""#, with: #""label":"Legacy","muted":"# + raw
            )
            let data = Data(wire.utf8)
            let graph = try GraphDocument.decode(from: data)
            #expect(graph.nodes[0].muted == nil)
            #expect(graph.nodes[0].unknownFields == ["muted": value])
            #expect(graph.validationErrors().isEmpty)
            #expect(graph.validationErrors(strict: true) == [.unknownFields(path: "$.nodes[node.legacy]")])
            #expect(try graph.encoded() == data)
            #expect(try GraphDocument.decode(from: graph.encoded()) == graph)
        }
    }

    @Test(arguments: NodeKind.allCases.filter { $0 != .audioMute })
    func typedLegacyStateRejectsWithoutLosingUnknownData(kind: NodeKind) throws {
        for muted in [false, true] {
            var node = Self.legacy(kind)
            node.muted = muted
            node.unknownFields["muted"] = .object(["old": .null])
            let graph = GraphDocument(id: GraphID(validated: "graph.mute"), nodes: [node])
            #expect(graph.validationErrors() == [.invalidMuteState(node.id)])
            #expect(throws: GraphValidationError.invalidMuteState(node.id)) { try graph.encoded() }
            #expect(throws: GraphValidationError.invalidMuteState(node.id)) {
                try ContractCoding.makeEncoder().encode(node)
            }
            let constructed = GraphNode(id: node.id, kind: kind, label: "Typed", muted: muted)
            #expect(throws: GraphValidationError.invalidMuteState(node.id)) {
                try ContractCoding.makeEncoder().encode(constructed)
            }
            #expect(node.unknownFields["muted"] == .object(["old": .null]))
        }
    }

    @Test(arguments: [false, true])
    func explicitMuteStateRoundTripsAtChannelBoundaries(muted: Bool) throws {
        for channels in [1, 2, 64] {
            var node = Self.mute(muted, channels: channels)
            for reverse in [false, true] {
                if reverse { node.ports.reverse() }
                let graph = Self.graph([node])
                try graph.validate(strict: true)
                try graph.validateForPreparation(supportedCapabilities: [])
                let data = try graph.encoded()
                let decoded = try GraphDocument.decode(from: data)
                #expect(decoded == graph)
                #expect(decoded.nodes[0].muted == muted)
                #expect(decoded.nodes[0].unknownFields.isEmpty)
                #expect(try decoded.encoded() == data)
            }
        }
    }

    @Test func muteStateIsRequiredAndStrictlyBoolean() throws {
        let base = try #require(String(data: Self.graph([Self.mute(true)]).encoded(), encoding: .utf8))
        let missing = base.replacingOccurrences(of: #""muted":true,"#, with: "")
        #expect(throws: DecodingError.self) { try GraphDocument.decode(from: Data(missing.utf8)) }
        for raw in ["null", "0", "1", #""true""#, "[]", "{}"] {
            let wire = base.replacingOccurrences(of: #""muted":true"#, with: #""muted":"# + raw)
            #expect(throws: DecodingError.self) { try GraphDocument.decode(from: Data(wire.utf8)) }
        }
        var node = Self.mute(true)
        node.muted = nil
        let graph = Self.graph([node])
        #expect(graph.validationErrors() == [.invalidMuteState(node.id)])
        #expect(throws: GraphValidationError.invalidMuteState(node.id)) { try graph.encoded() }
        let constructed = GraphNode(id: node.id, kind: .audioMute, label: "No default", ports: node.ports)
        #expect(constructed.muted == nil)
        #expect(throws: GraphValidationError.invalidMuteState(node.id)) {
            try ContractCoding.makeEncoder().encode(constructed)
        }
    }

    @Test func muteUnknownStateCollisionNeverDropsData() {
        for (_, value) in Self.values {
            for muted in [false, true] {
                var node = Self.mute(muted)
                node.unknownFields["muted"] = value
                let graph = Self.graph([node])
                #expect(graph.validationErrors() == [.invalidMuteState(node.id)])
                #expect(throws: GraphValidationError.invalidMuteState(node.id)) { try graph.encoded() }
                #expect(throws: GraphValidationError.invalidMuteState(node.id)) {
                    try ContractCoding.makeEncoder().encode(node)
                }
                #expect(node.unknownFields["muted"] == value)
            }
        }
    }

    @Test func structuralValidationRejectsInvalidMutePortsAndReferences() throws {
        let mutations: [(inout GraphNode) -> Void] = [
            { $0.ports = [] }, { $0.ports.removeLast() }, { $0.ports.append($0.ports[0]) },
            { $0.ports[0].direction = .output }, { $0.ports[1].direction = .input },
            { $0.ports[0].signal = .midi }, { $0.ports[1].signal = .control },
            { $0.ports[0].signal = .clock }, { $0.ports[0].channels = nil },
            { $0.ports[1].channels = nil }, { $0.ports[0].channels = 0 },
            { $0.ports[1].channels = 65 }, { $0.ports[0].channels = -1 },
            { $0.ports[1].channels = 1 }, { $0.role = RoleID(validated: "role.extra") },
            { $0.asset = AssetID(validated: "asset.extra") }, { $0.graph = GraphID(validated: "graph.extra") }
        ]
        for mutate in mutations {
            var node = Self.mute(false)
            mutate(&node)
            let graph = Self.graph([node])
            #expect(graph.validationErrors().contains(.invalidMuteShape(node.id)))
            // Coding preserves structural candidates; validate remains the structural gate.
            let decoded = try GraphDocument.decode(from: graph.encoded())
            #expect(decoded == graph)
            #expect(decoded.validationErrors().contains(.invalidMuteShape(node.id)))
            #expect(throws: GraphValidationError.self) { try decoded.validate() }
        }
        var duplicate = Self.mute(false)
        duplicate.ports[1].id = duplicate.ports[0].id
        #expect(Self.graph([duplicate]).validationErrors() == [.duplicatePort(duplicate.id, duplicate.ports[0].id)])
    }

    @Test func exactFeatureNodeMatrixAgreesAcrossConstructionMutationAndCoding() throws {
        let declarations = [
            [], [Self.token], ["future"], [Self.token, Self.token],
            [Self.token, "future"], ["future", Self.token]
        ]
        for count in 0...2 {
            let nodes = try (0..<count).map { index in
                var node = Self.mute(index == 0)
                node.id = try NodeID("node.mute.\(index)")
                return node
            }
            for features in declarations {
                let candidate = GraphDocument(
                    id: GraphID(validated: "graph.mute"), nodes: nodes, requiredFeatures: features
                )
                var mutated = Self.graph([Self.mute(true)])
                mutated.nodes = nodes
                mutated.requiredFeatures = features
                #expect(mutated == candidate)
                #expect(candidate.requiredFeatures == features)
                let valid = count == 0 ? features.isEmpty : features == [Self.token]
                for graph in [candidate, mutated] {
                    if valid {
                        try graph.validate(strict: true)
                        #expect(try GraphDocument.decode(from: graph.encoded()) == graph)
                    } else {
                        #expect(graph.validationErrors() == [.invalidRequiredFeatures(features)])
                        #expect(throws: GraphValidationError.invalidRequiredFeatures(features)) {
                            try graph.validate()
                        }
                        #expect(throws: GraphValidationError.invalidRequiredFeatures(features)) { try graph.encoded() }
                    }
                    #expect(graph.requiredFeatures == features)
                }
                var wire = try Self.object(Self.graph(nodes, features: count == 0 ? [] : [Self.token]))
                wire["requiredFeatures"] = features
                if valid {
                    #expect(try GraphDocument.decode(from: Self.data(wire)) == candidate)
                } else if features.isEmpty || features == [Self.token] {
                    #expect(throws: GraphValidationError.invalidRequiredFeatures(features)) {
                        try GraphDocument.decode(from: Self.data(wire))
                    }
                } else {
                    #expect(throws: ProjectGraphVersionError.unsupportedRequiredFeatures(features)) {
                        try GraphDocument.decode(from: Self.data(wire))
                    }
                }
            }
        }
    }

    @Test func wireEmptyNormalizationAndDefaultConstructorDoNotInferFeatures() throws {
        let empty = GraphDocument(id: GraphID(validated: "graph.mute"))
        let canonical = try empty.encoded()
        let text = try #require(String(data: canonical, encoding: .utf8))
        #expect(!text.contains("requiredFeatures"))
        let undeclared = GraphDocument(id: empty.id, nodes: [Self.mute(false)])
        #expect(undeclared.requiredFeatures.isEmpty)
        #expect(throws: GraphValidationError.invalidRequiredFeatures([])) { try undeclared.encoded() }
        for nodes in [[], [Self.mute(false)]] {
            let base = try Self.object(Self.graph(nodes, features: nodes.isEmpty ? [] : [Self.token]))
            for value in [nil, NSNull(), []] as [Any?] {
                var object = base
                object["requiredFeatures"] = value
                if nodes.isEmpty {
                    let decoded = try GraphDocument.decode(from: Self.data(object))
                    #expect(decoded == empty)
                    #expect(try decoded.encoded() == canonical)
                } else {
                    #expect(throws: GraphValidationError.invalidRequiredFeatures([])) {
                        try GraphDocument.decode(from: Self.data(object))
                    }
                }
            }
        }
    }

    @Test func nodeKindAndFeatureMutationsRequireExplicitConsistentState() throws {
        var graph = Self.graph([Self.mute(true)])
        graph.nodes[0].kind = .plugin
        #expect(graph.validationErrors() == [.invalidRequiredFeatures([Self.token])])
        #expect(throws: GraphValidationError.self) { try graph.encoded() }
        graph.requiredFeatures = []
        #expect(graph.validationErrors() == [.invalidMuteState(graph.nodes[0].id)])
        #expect(throws: GraphValidationError.self) { try graph.encoded() }
        graph.nodes[0].muted = nil
        try graph.validate()
        #expect(try GraphDocument.decode(from: graph.encoded()) == graph)
        graph.nodes[0].unknownFields["muted"] = .bool(true)
        graph.nodes[0].kind = .audioMute
        graph.requiredFeatures = [Self.token]
        #expect(graph.validationErrors() == [.invalidMuteState(graph.nodes[0].id)])
        graph.nodes[0].muted = false
        #expect(throws: GraphValidationError.self) { try graph.encoded() }
        graph.nodes[0].unknownFields = [:]
        try graph.validate(strict: true)
        graph.nodes.removeAll()
        #expect(throws: GraphValidationError.invalidRequiredFeatures([Self.token])) { try graph.encoded() }
    }

    @Test func requiredFeatureUnknownFieldCollisionsRejectEvenEmptyValues() {
        for nodes in [[], [Self.mute(false)]] {
            for value in Self.values.map(\.1) + [.array([]), .array([.string(Self.token)])] {
                var graph = Self.graph(nodes, features: nodes.isEmpty ? [] : [Self.token])
                graph.unknownFields["requiredFeatures"] = value
                #expect(graph.validationErrors() == [.requiredFeaturesCollision])
                #expect(throws: GraphValidationError.requiredFeaturesCollision) { try graph.encoded() }
                #expect(graph.unknownFields["requiredFeatures"] == value)
            }
        }
    }
}

extension AudioMuteContractTests {
    @Test func unsupportedAndMalformedHeadersRejectBeforeNodeInterpretation() throws {
        var object = try Self.object(Self.graph([Self.mute(false)]))
        object["nodes"] = [["kind": "not-a-node", "muted": "invalid"]]
        for features in [["future"], [Self.token, Self.token], [Self.token, "future"], ["future", Self.token]] {
            object["requiredFeatures"] = features
            #expect(throws: ProjectGraphVersionError.unsupportedRequiredFeatures(features)) {
                try GraphDocument.decode(from: Self.data(object))
            }
        }
        object["nodes"] = []
        for malformed in ["future", true, 1, [1], [NSNull()], [:]] as [Any] {
            object["requiredFeatures"] = malformed
            #expect(throws: DecodingError.self) { try GraphDocument.decode(from: Self.data(object)) }
        }
    }

    @Test func duplicateMemberScanPrecedesHeaderAndNodeDecoding() throws {
        let base = try #require(String(data: Self.graph([Self.mute(true)]).encoded(), encoding: .utf8))
        let duplicates = [
            base.replacingOccurrences(of: #""muted":true"#, with: #""muted":true,"muted":false"#),
            base.replacingOccurrences(of: #""muted":true"#, with: #""muted":true,"mut\u0065d":false"#),
            base.replacingOccurrences(of: #""requiredFeatures":["#,
                                      with: #""requiredFeatures":[],"requiredFeatures":["#),
            base.replacingOccurrences(of: #""muted":true"#, with: #""muted":null,"muted":1"#)
                .replacingOccurrences(of: Self.token, with: "future")
        ]
        for text in duplicates {
            #expect(throws: DecodingError.self) { try GraphDocument.decode(from: Data(text.utf8)) }
        }
    }

    @Test func collectionBoundsPrecedeFeatureConsistencyAndTopology() throws {
        let base = Self.graph([Self.mute(false)])
        let mutations: [(inout GraphDocument) -> Void] = [
            { $0.nodes = Array(repeating: $0.nodes[0], count: ProjectGraphLimits.nodes + 1) },
            { $0.nodes[0].ports = Array(repeating: $0.nodes[0].ports[0], count: ProjectGraphLimits.portsPerNode + 1) },
            { $0.capabilities = Array(repeating: CapabilityDefinition(
                id: CapabilityID(validated: "cap.one"), label: "One"
            ), count: ProjectGraphLimits.capabilities + 1) },
            { $0.edges = Array(repeating: GraphEdge(
                id: EdgeID(validated: "edge.loop"),
                from: PortAddress(node: $0.nodes[0].id, port: $0.nodes[0].ports[1].id),
                to: PortAddress(node: $0.nodes[0].id, port: $0.nodes[0].ports[0].id)
            ), count: ProjectGraphLimits.edges + 1) },
            { $0.nodes[0].requiredCapabilities = Array(
                repeating: CapabilityID(validated: "cap.one"), count: ProjectGraphLimits.capabilities + 1
            ) }
        ]
        for mutate in mutations {
            var graph = base
            mutate(&graph)
            graph.requiredFeatures = [] // Both errors exist; bounds must win.
            #expect(graph.validationErrors().count == 1)
            guard case .bounds = graph.validationErrors().first else {
                Issue.record("Expected collection bounds before feature mismatch")
                continue
            }
            #expect(throws: ProjectGraphLimitError.self) { try graph.encoded() }
        }
        var wire = try Self.object(base)
        let node = try #require((wire["nodes"] as? [[String: Any]])?.first)
        wire["nodes"] = Array(repeating: node, count: ProjectGraphLimits.nodes + 1)
        wire["requiredFeatures"] = []
        #expect(throws: ProjectGraphLimitError.exceeded(path: "$.nodes", maximum: ProjectGraphLimits.nodes)) {
            try GraphDocument.decode(from: Self.data(wire))
        }
    }

    @Test func byteBoundsStillProtectInputAndOutput() throws {
        let oversized = Data(repeating: 123, count: ProjectGraphLimits.documentBytes + 1)
        #expect(throws: ProjectGraphLimitError.exceeded(path: "$bytes", maximum: ProjectGraphLimits.documentBytes)) {
            try GraphDocument.decode(from: oversized)
        }
        var graph = Self.graph([Self.mute(false)])
        graph.label = String(repeating: "x", count: ProjectGraphLimits.documentBytes)
        #expect(throws: ProjectGraphLimitError.exceeded(path: "$bytes", maximum: ProjectGraphLimits.documentBytes)) {
            try graph.encoded()
        }
    }

    @Test func minorVersionIsUnknownDataAndNeverNegotiatesMajorOrFeatures() throws {
        var graph = Self.graph([Self.mute(false)])
        graph.unknownFields["minorVersion"] = .object(["not": .string("negotiation")])
        #expect(try GraphDocument.decode(from: graph.encoded()) == graph)
        #expect(graph.validationErrors(strict: true) == [.unknownFields(path: "$")])
        var object = try Self.object(graph)
        object["version"] = 2
        #expect(throws: ContractVersionError.unsupportedVersion(found: 2, supported: 1)) {
            try GraphDocument.decode(from: Self.data(object))
        }
        object["version"] = 1
        object["requiredFeatures"] = ["future"]
        #expect(throws: ProjectGraphVersionError.unsupportedRequiredFeatures(["future"])) {
            try GraphDocument.decode(from: Self.data(object))
        }
    }

    @Test func projectAndPackageEnvelopesStillRejectRecognizedGraphToken() throws {
        let project = AudioRoutingTestFixtures.documents().project
        let manifest = ManifestTestSupport.manifest()
        let policy = try ManifestTestSupport.policy()
        let projectObject = try #require(JSONSerialization.jsonObject(with: project.encoded()) as? [String: Any])
        let manifestObject = try ManifestTestSupport.json(manifest)
        for malformedBody in [false, true] {
            var projectWire = projectObject
            var manifestWire = manifestObject
            projectWire["requiredFeatures"] = [Self.token]
            manifestWire["requiredFeatures"] = [Self.token]
            if malformedBody {
                projectWire["roles"] = "invalid"
                manifestWire["project"] = "invalid"
            }
            #expect(throws: ProjectGraphVersionError.unsupportedRequiredFeatures([Self.token])) {
                try ProjectDocument.decode(from: Self.data(projectWire))
            }
            #expect(throws: ProjectGraphVersionError.unsupportedRequiredFeatures([Self.token])) {
                try ProjectPackageManifest.decode(from: Self.data(manifestWire), policy: policy)
            }
        }
    }

    @Test(arguments: [false, true])
    func validDisconnectedMuteRemainsUnsupportedByRoutingCompiler(muted: Bool) throws {
        var documents = AudioRoutingTestFixtures.documents()
        documents.graph.nodes.append(Self.mute(muted))
        documents.graph.requiredFeatures = [Self.token]
        try documents.graph.validate(strict: true)
        try documents.project.validate(graphs: [documents.graph], strict: true)
        documents.graph = try GraphDocument.decode(from: documents.graph.encoded())
        #expect(throws: AudioRoutingPreparationError.unsupported) {
            try AudioRoutingTestFixtures.compile(documents)
        }
    }

    private static func mute(_ muted: Bool, channels: Int = 2) -> GraphNode {
        GraphNode(id: NodeID(validated: "node.mute"), kind: .audioMute, label: "Mute", ports: [
            GraphPort(id: PortID(validated: "in"), direction: .input, signal: .audio, channels: channels),
            GraphPort(id: PortID(validated: "out"), direction: .output, signal: .audio, channels: channels)
        ], muted: muted)
    }

    private static func legacy(_ kind: NodeKind) -> GraphNode {
        GraphNode(
            id: NodeID(validated: "node.legacy"), kind: kind, label: "Legacy",
            role: kind.requiresRole ? RoleID(validated: "role.old") : nil,
            asset: kind == .mediaPlayer ? AssetID(validated: "asset.old") : nil,
            graph: kind == .sharedGraph ? GraphID(validated: "graph.old") : nil
        )
    }

    private static func graph(_ nodes: [GraphNode], features: [String] = [token]) -> GraphDocument {
        GraphDocument(id: GraphID(validated: "graph.mute"), nodes: nodes, requiredFeatures: features)
    }

    private static func object(_ graph: GraphDocument) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: graph.encoded()) as? [String: Any])
    }

    private static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
