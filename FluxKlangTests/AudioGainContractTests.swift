import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct AudioGainContractTests {
    private static let gainToken = GraphDocument.constantGainFeature
    private static let muteToken = GraphDocument.constantMuteFeature
    private static let validGains: [Double] = [
        Double(Float.leastNormalMagnitude), 1, 16, 0.10000000149011612
    ]
    private static let invalidGains: [Double] = [
        0, -0.0, -1, -16, Double(Float.leastNonzeroMagnitude), Double.leastNonzeroMagnitude,
        Double(Float.leastNormalMagnitude).nextDown, 16.000001, Double(Float(16).nextUp), 0.1, 1e300,
        .nan, -.nan, .signalingNaN, .infinity, -.infinity
    ]
    private static let values: [(String, JSONValue)] = [
        ("true", .bool(true)), ("null", .null), ("1", .int(1)), ("0.5", .double(0.5)),
        (#""gain""#, .string("gain")), (#"[null,false,3]"#, .array([.null, .bool(false), .int(3)])),
        (#"{"nested":"gain"}"#, .object(["nested": .string("gain")]))
    ]

    @Test(arguments: validGains)
    func boundaryGainsRoundTripAtChannelBoundaries(gain: Double) throws {
        for channels in [1, 2, 64] {
            var node = Self.gain(gain, channels: channels)
            for reverse in [false, true] {
                if reverse { node.ports.reverse() }
                let graph = Self.graph([node])
                try graph.validate(strict: true)
                try graph.validateForPreparation(supportedCapabilities: [])
                let data = try graph.encoded()
                let decoded = try GraphDocument.decode(from: data)
                #expect(decoded == graph)
                #expect(decoded.nodes[0].linearGain?.bitPattern == gain.bitPattern)
                #expect(decoded.nodes[0].muted == nil)
                #expect(decoded.nodes[0].unknownFields.isEmpty)
                #expect(try decoded.encoded() == data)
            }
        }
    }

    @Test func gainValueIsRequiredAndStrictlyNumeric() throws {
        let base = try Self.object(Self.graph([Self.gain(1)]))
        var missing = base
        missing["nodes"] = try Self.replacingGain(in: base, with: nil)
        #expect(throws: DecodingError.self) { try GraphDocument.decode(from: Self.data(missing)) }
        for raw in [NSNull(), "1", true, false, [1], ["linearGain": 1]] as [Any] {
            var wire = base
            wire["nodes"] = try Self.replacingGain(in: base, with: raw)
            #expect(throws: DecodingError.self) { try GraphDocument.decode(from: Self.data(wire)) }
        }
        var node = Self.gain(1)
        node.linearGain = nil
        let graph = Self.graph([node])
        #expect(graph.validationErrors() == [.invalidGainState(node.id)])
        #expect(throws: GraphValidationError.invalidGainState(node.id)) { try graph.encoded() }
        let constructed = GraphNode(id: node.id, kind: .audioGain, label: "No default", ports: node.ports)
        #expect(constructed.linearGain == nil)
        #expect(throws: GraphValidationError.invalidGainState(node.id)) {
            try ContractCoding.makeEncoder().encode(constructed)
        }
    }

    @Test(arguments: invalidGains)
    func invalidGainsRejectAndOnlyNonfiniteValuesRefuseEncoding(gain: Double) throws {
        let node = Self.gain(gain)
        let graph = Self.graph([node])
        #expect(!GraphNode.isValidLinearGain(gain))
        #expect(graph.validationErrors() == [.invalidGainValue(node.id)])
        #expect(throws: GraphValidationError.invalidGainValue(node.id)) { try graph.validate() }
        guard gain.isFinite else {
            #expect(throws: GraphValidationError.invalidGainValue(node.id)) { try graph.encoded() }
            #expect(throws: GraphValidationError.invalidGainValue(node.id)) {
                try ContractCoding.makeEncoder().encode(node)
            }
            return
        }
        // Finite candidates keep their exact bits; validation, not coding, is the gate.
        let data = try graph.encoded()
        let decoded = try GraphDocument.decode(from: data)
        #expect(decoded.nodes[0].linearGain?.bitPattern == gain.bitPattern)
        #expect(decoded.validationErrors() == [.invalidGainValue(node.id)])
        #expect(try decoded.encoded() == data)
    }

    @Test func wireGainLiteralsDecodeExactlyAndRejectInexactFloat32() throws {
        let cases: [(String, UInt64?)] = [
            ("1", 1.0.bitPattern), ("1.0", 1.0.bitPattern), ("16", 16.0.bitPattern), ("1.6e1", 16.0.bitPattern),
            ("0.10000000149011612", Double(Float(0.1)).bitPattern),
            ("1.1754943508222875e-38", Double(Float.leastNormalMagnitude).bitPattern),
            ("0.1", nil), ("16.000001", nil), ("0", nil), ("-0", nil), ("-1", nil), ("1e-45", nil)
        ]
        let base = try #require(String(data: Self.graph([Self.gain(2)]).encoded(), encoding: .utf8))
        #expect(base.contains(#""kind":"audioGain","label":"Gain","linearGain":2,"ports":"#))
        for (raw, expected) in cases {
            let wire = base.replacingOccurrences(of: #""linearGain":2"#, with: #""linearGain":"# + raw)
            let decoded = try GraphDocument.decode(from: Data(wire.utf8))
            let gain = try #require(decoded.nodes[0].linearGain)
            if let expected {
                #expect(gain.bitPattern == expected)
                try decoded.validate(strict: true)
            } else {
                #expect(decoded.validationErrors() == [.invalidGainValue(decoded.nodes[0].id)])
            }
            let canonical = try decoded.encoded()
            #expect(try GraphDocument.decode(from: canonical).encoded() == canonical)
        }
        let tenth = try #require(String(
            bytes: Self.graph([Self.gain(0.10000000149011612)]).encoded(), encoding: .utf8
        ))
        #expect(tenth.contains(#""linearGain":0.10000000149011612"#))
        // Foundation refuses unrepresentable literals outright rather than rounding to ±inf or ±0.
        for raw in ["1e400", "-1e400", "1e-400", "-1e-400"] {
            let wire = base.replacingOccurrences(of: #""linearGain":2"#, with: #""linearGain":"# + raw)
            #expect(throws: DecodingError.self) { try GraphDocument.decode(from: Data(wire.utf8)) }
        }
    }

    @Test func validationErrorsFollowProfileOrderPerNodeInNodeOrder() throws {
        var mute = Self.mute()
        mute.muted = nil
        mute.ports.removeLast()
        var gain = Self.gain(0.1)
        gain.unknownFields["linearGain"] = .int(1)
        gain.ports[1].direction = .input
        var typed = try Self.gain(16.5, id: NodeID("node.gain.2"))
        typed.muted = true
        typed.role = RoleID(validated: "role.extra")
        let graph = GraphDocument(
            id: GraphID(validated: "graph.gain"), nodes: [mute, gain, typed],
            requiredFeatures: [Self.gainToken, Self.muteToken]
        )
        #expect(graph.validationErrors() == [
            .invalidMuteState(mute.id), .invalidMuteShape(mute.id),
            .invalidGainState(gain.id), .invalidGainValue(gain.id), .invalidGainShape(gain.id),
            .invalidMuteState(typed.id), .invalidGainValue(typed.id), .invalidGainShape(typed.id)
        ])
    }

    @Test(arguments: NodeKind.allCases.filter { $0 != .audioGain })
    func otherKindsPreserveUnknownLinearGain(kind: NodeKind) throws {
        let node = kind == .audioMute ? Self.mute() : Self.legacy(kind)
        let base = Self.graph([node], features: kind == .audioMute ? [Self.muteToken] : [])
        let canonical = try #require(String(data: base.encoded(), encoding: .utf8))
        let label = #""label":"\#(node.label)""#
        for (raw, value) in Self.values {
            let wire = canonical.replacingOccurrences(of: label, with: label + #","linearGain":"# + raw)
            let data = Data(wire.utf8)
            let graph = try GraphDocument.decode(from: data)
            #expect(graph.nodes[0].linearGain == nil)
            #expect(graph.nodes[0].unknownFields == ["linearGain": value])
            #expect(graph.validationErrors().isEmpty)
            #expect(graph.validationErrors(strict: true) == [.unknownFields(path: "$.nodes[\(node.id)]")])
            #expect(try graph.encoded() == data)
            #expect(try GraphDocument.decode(from: graph.encoded()) == graph)
        }
    }

    @Test(arguments: NodeKind.allCases.filter { $0 != .audioGain })
    func typedGainOnOtherKindsRejectsWithoutLosingUnknownData(kind: NodeKind) throws {
        for gain in [1, 0, Double.nan] {
            var node = kind == .audioMute ? Self.mute() : Self.legacy(kind)
            node.linearGain = gain
            node.unknownFields["linearGain"] = .object(["old": .null])
            let graph = Self.graph([node], features: kind == .audioMute ? [Self.muteToken] : [])
            #expect(graph.validationErrors() == [.invalidGainState(node.id)])
            #expect(throws: GraphValidationError.invalidGainState(node.id)) { try graph.encoded() }
            #expect(throws: GraphValidationError.invalidGainState(node.id)) {
                try ContractCoding.makeEncoder().encode(node)
            }
            let constructed = GraphNode(
                id: node.id, kind: kind, label: "Typed", muted: node.muted, linearGain: gain
            )
            #expect(throws: GraphValidationError.invalidGainState(node.id)) {
                try ContractCoding.makeEncoder().encode(constructed)
            }
            #expect(node.unknownFields["linearGain"] == .object(["old": .null]))
        }
    }

    @Test func gainUnknownValueCollisionAndMutedDataNeverDrop() throws {
        for (_, value) in Self.values {
            var node = Self.gain(1)
            node.unknownFields["linearGain"] = value
            let graph = Self.graph([node])
            #expect(graph.validationErrors() == [.invalidGainState(node.id)])
            #expect(throws: GraphValidationError.invalidGainState(node.id)) { try graph.encoded() }
            #expect(throws: GraphValidationError.invalidGainState(node.id)) {
                try ContractCoding.makeEncoder().encode(node)
            }
            #expect(node.unknownFields["linearGain"] == value)
            var muted = Self.gain(1)
            muted.unknownFields["muted"] = value
            let preserved = try GraphDocument.decode(from: Self.graph([muted]).encoded())
            #expect(preserved.nodes[0].unknownFields == ["muted": value])
            #expect(preserved.validationErrors(strict: true) == [.unknownFields(path: "$.nodes[node.gain]")])
        }
        var typed = Self.gain(1)
        typed.muted = false
        #expect(Self.graph([typed]).validationErrors() == [.invalidMuteState(typed.id)])
        #expect(throws: GraphValidationError.invalidMuteState(typed.id)) { try Self.graph([typed]).encoded() }
    }

    @Test func structuralValidationRejectsInvalidGainPortsAndReferences() throws {
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
            var node = Self.gain(1)
            mutate(&node)
            let graph = Self.graph([node])
            #expect(graph.validationErrors().contains(.invalidGainShape(node.id)))
            #expect(!graph.validationErrors().contains(.invalidMuteShape(node.id)))
            let decoded = try GraphDocument.decode(from: graph.encoded())
            #expect(decoded == graph)
            #expect(decoded.validationErrors().contains(.invalidGainShape(node.id)))
            #expect(throws: GraphValidationError.self) { try decoded.validate() }
        }
        var duplicate = Self.gain(1)
        duplicate.ports[1].id = duplicate.ports[0].id
        #expect(Self.graph([duplicate]).validationErrors() == [.duplicatePort(duplicate.id, duplicate.ports[0].id)])
    }
}

extension AudioGainContractTests {
    @Test func exactFeatureNodeMatrixAgreesAcrossConstructionAndCoding() throws {
        let gain = Self.gainToken, mute = Self.muteToken
        let declarations = [
            [], [gain], [mute], [gain, mute], [mute, gain], [gain, gain], [mute, mute],
            [gain, gain, mute], ["future"], [gain, "future"], ["future", gain], ["audioGain.constant.v2"]
        ]
        let supported = Set([[], [gain], [mute], [gain, mute]])
        let nodeSets: [([GraphNode], [String])] = try [
            ([], []), ([Self.gain(1)], [gain]), ([Self.mute()], [mute]),
            ([Self.gain(2), Self.mute()], [gain, mute]), ([Self.mute(), Self.gain(2)], [gain, mute]),
            ([Self.gain(1), Self.gain(0.5, id: NodeID("node.gain.2"))], [gain])
        ]
        for (nodes, expected) in nodeSets {
            for features in declarations {
                let candidate = GraphDocument(
                    id: GraphID(validated: "graph.gain"), nodes: nodes, requiredFeatures: features
                )
                #expect(candidate.requiredFeatures == features)
                var wire = try Self.object(Self.graph(nodes, features: expected))
                wire["requiredFeatures"] = features
                if features == expected {
                    try candidate.validate(strict: true)
                    #expect(try GraphDocument.decode(from: candidate.encoded()) == candidate)
                    #expect(try GraphDocument.decode(from: Self.data(wire)) == candidate)
                    continue
                }
                #expect(candidate.validationErrors() == [.invalidRequiredFeatures(features)])
                #expect(throws: GraphValidationError.invalidRequiredFeatures(features)) { try candidate.encoded() }
                if supported.contains(features) {
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

    @Test func unsupportedHeadersRejectBeforeNodeInterpretation() throws {
        var object = try Self.object(Self.graph([Self.gain(1)]))
        object["nodes"] = [["kind": "not-a-node", "linearGain": "invalid"]]
        let rejected = [
            [Self.muteToken, Self.gainToken], [Self.gainToken, Self.gainToken], ["future"],
            [Self.gainToken, "future"], ["audioGain.constant.v2"], ["audiogain.constant.v1"]
        ]
        for features in rejected {
            object["requiredFeatures"] = features
            #expect(throws: ProjectGraphVersionError.unsupportedRequiredFeatures(features)) {
                try GraphDocument.decode(from: Self.data(object))
            }
        }
        object["requiredFeatures"] = [Self.gainToken]
        #expect(throws: DecodingError.self) { try GraphDocument.decode(from: Self.data(object)) }
    }

    @Test func collectionBoundsPrecedeFeatureConsistency() throws {
        let base = Self.graph([Self.gain(1)])
        var graph = base
        graph.nodes = Array(repeating: base.nodes[0], count: ProjectGraphLimits.nodes + 1)
        graph.requiredFeatures = []
        #expect(graph.validationErrors() == [.bounds(.exceeded(path: "$.nodes", maximum: ProjectGraphLimits.nodes))])
        #expect(throws: ProjectGraphLimitError.self) { try graph.encoded() }
        var wire = try Self.object(base)
        let node = try #require((wire["nodes"] as? [[String: Any]])?.first)
        wire["nodes"] = Array(repeating: node, count: ProjectGraphLimits.nodes + 1)
        wire["requiredFeatures"] = []
        #expect(throws: ProjectGraphLimitError.exceeded(path: "$.nodes", maximum: ProjectGraphLimits.nodes)) {
            try GraphDocument.decode(from: Self.data(wire))
        }
    }

    @Test func byteBoundsAndInertMinorVersionStillApply() throws {
        var large = Self.graph([Self.gain(1)])
        large.label = String(repeating: "x", count: ProjectGraphLimits.documentBytes)
        #expect(throws: ProjectGraphLimitError.exceeded(path: "$bytes", maximum: ProjectGraphLimits.documentBytes)) {
            try large.encoded()
        }
        let oversized = Data(repeating: 123, count: ProjectGraphLimits.documentBytes + 1)
        #expect(throws: ProjectGraphLimitError.exceeded(path: "$bytes", maximum: ProjectGraphLimits.documentBytes)) {
            try GraphDocument.decode(from: oversized)
        }
        var graph = Self.graph([Self.gain(1)])
        graph.unknownFields["minorVersion"] = .int(2)
        #expect(try GraphDocument.decode(from: graph.encoded()) == graph)
        #expect(graph.validationErrors(strict: true) == [.unknownFields(path: "$")])
        var object = try Self.object(graph)
        object["requiredFeatures"] = [Self.gainToken, "future"]
        #expect(throws: ProjectGraphVersionError.unsupportedRequiredFeatures([Self.gainToken, "future"])) {
            try GraphDocument.decode(from: Self.data(object))
        }
        object["requiredFeatures"] = [Self.gainToken]
        object["version"] = 2
        #expect(throws: ContractVersionError.unsupportedVersion(found: 2, supported: 1)) {
            try GraphDocument.decode(from: Self.data(object))
        }
    }

    @Test func projectAndPackageEnvelopesRejectGainTokens() throws {
        let projectObject = try #require(JSONSerialization.jsonObject(
            with: AudioRoutingTestFixtures.documents().project.encoded()
        ) as? [String: Any])
        let manifestObject = try ManifestTestSupport.json(ManifestTestSupport.manifest())
        let policy = try ManifestTestSupport.policy()
        for features in [[Self.gainToken], [Self.gainToken, Self.muteToken]] {
            var projectWire = projectObject
            var manifestWire = manifestObject
            projectWire["requiredFeatures"] = features
            manifestWire["requiredFeatures"] = features
            #expect(throws: ProjectGraphVersionError.unsupportedRequiredFeatures(features)) {
                try ProjectDocument.decode(from: Self.data(projectWire))
            }
            #expect(throws: ProjectGraphVersionError.unsupportedRequiredFeatures(features)) {
                try ProjectPackageManifest.decode(from: Self.data(manifestWire), policy: policy)
            }
        }
    }

    @Test func validDisconnectedGainIsStillRefusedByTheCompiler() throws {
        for withMute in [false, true] {
            var documents = AudioRoutingTestFixtures.documents()
            documents.graph.nodes.append(Self.gain(1))
            documents.graph.requiredFeatures = [Self.gainToken]
            if withMute {
                documents.graph.nodes.append(Self.mute())
                documents.graph.requiredFeatures.append(Self.muteToken)
            }
            try documents.graph.validate(strict: true)
            try documents.project.validate(graphs: [documents.graph], strict: true)
            documents.graph = try GraphDocument.decode(from: documents.graph.encoded())
            #expect(throws: AudioRoutingPreparationError.unsupported) {
                try AudioRoutingTestFixtures.compile(documents)
            }
        }
    }

    private static func gain(
        _ gain: Double, channels: Int = 2, id: NodeID = NodeID(validated: "node.gain")
    ) -> GraphNode {
        GraphNode(id: id, kind: .audioGain, label: "Gain", ports: [
            GraphPort(id: PortID(validated: "in"), direction: .input, signal: .audio, channels: channels),
            GraphPort(id: PortID(validated: "out"), direction: .output, signal: .audio, channels: channels)
        ], linearGain: gain)
    }

    private static func mute() -> GraphNode {
        GraphNode(id: NodeID(validated: "node.mute"), kind: .audioMute, label: "Mute", ports: [
            GraphPort(id: PortID(validated: "in"), direction: .input, signal: .audio, channels: 2),
            GraphPort(id: PortID(validated: "out"), direction: .output, signal: .audio, channels: 2)
        ], muted: false)
    }

    private static func legacy(_ kind: NodeKind) -> GraphNode {
        GraphNode(
            id: NodeID(validated: "node.legacy"), kind: kind, label: "Legacy",
            role: kind.requiresRole ? RoleID(validated: "role.old") : nil,
            asset: kind == .mediaPlayer ? AssetID(validated: "asset.old") : nil,
            graph: kind == .sharedGraph ? GraphID(validated: "graph.old") : nil
        )
    }

    private static func graph(_ nodes: [GraphNode], features: [String] = [gainToken]) -> GraphDocument {
        GraphDocument(id: GraphID(validated: "graph.gain"), nodes: nodes, requiredFeatures: features)
    }

    private static func object(_ graph: GraphDocument) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: graph.encoded()) as? [String: Any])
    }

    private static func replacingGain(in object: [String: Any], with value: Any?) throws -> [[String: Any]] {
        var nodes = try #require(object["nodes"] as? [[String: Any]])
        nodes[0]["linearGain"] = value
        return nodes
    }

    private static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
