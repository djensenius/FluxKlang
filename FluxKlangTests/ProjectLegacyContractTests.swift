import CoreGraphics
import Foundation
import Testing
@testable import FluxKlang

struct ProjectLegacyContractTests {
    @Test func emptyLegacyImportStaysInertAndFutureEnvelopesReject() throws {
        let data = Data(#"{"nodes":[],"edges":[]}"#.utf8)
        let imported = try StudioGraphNeutralAdapter.adapt(graphData: data, id: GraphID(validated: "gph.empty"))
        #expect(imported.graph.validationErrors() == [.reviewRequired])
        let future = Data(#"{"nodes":[],"edges":[],"contract":"fluxklang.graph","version":99}"#.utf8)
        #expect(throws: StudioGraphNeutralAdapter.ImportError.versionedInput) {
            try StudioGraphNeutralAdapter.adapt(graphData: future, id: GraphID(validated: "gph.future"))
        }
    }

    @Test func actualLegacyModelsImportCompatiblyAndDeterministically() throws {
        let endpoint = StudioEndpoint(
            name: "Room", destination: .space, colorName: "purple",
            placement: VoicePlacement(position: CGPoint(x: 0.125, y: 0.875), width: 0.625)
        )
        let source = StudioNode(kind: .instrument(UUID()), title: "Synth", position: CGPoint(x: -40.5, y: 120.125))
        let destination = StudioNode(kind: .endpoint(endpoint.id), title: endpoint.name, position: CGPoint(x: 1, y: 2))
        var legacy = StudioGraph(nodes: [source, destination])
        legacy.connect(
            from: StudioPortRef(nodeID: source.id, side: .output, port: 0),
            to: StudioPortRef(nodeID: destination.id, side: .input, port: 1)
        )
        let graphData = try JSONEncoder().encode(legacy)
        let endpointsData = try JSONEncoder().encode([endpoint])
        let id = GraphID(validated: "gph.encoded-legacy")
        let imported = try StudioGraphNeutralAdapter.adapt(
            graphData: graphData, endpointsData: endpointsData, id: id
        )
        let repeated = try StudioGraphNeutralAdapter.adapt(
            graphData: graphData, endpointsData: endpointsData, id: id
        )

        #expect(imported.originalGraph == graphData)
        #expect(imported.originalEndpoints == endpointsData)
        #expect(imported.graph.id == id)
        #expect(imported.graph.requiresReview)
        #expect(imported.graph.nodes.map(\.id) == legacy.nodes.map { NodeID(uuid: $0.id) })
        #expect(imported.graph.nodes.map(\.kind) == [.roleInput, .spatialBus])
        #expect(imported.graph.nodes.map(\.position) == legacy.nodes.map {
            GraphPoint(x: Double($0.position.x), y: Double($0.position.y))
        })
        #expect(imported.graph.edges == legacy.edges.map {
            GraphEdge(
                id: EdgeID(uuid: $0.id),
                from: PortAddress(node: NodeID(uuid: source.id), port: PortID(validated: "out.0")),
                to: PortAddress(node: NodeID(uuid: destination.id), port: PortID(validated: "in.1"))
            )
        })
        #expect(repeated.originalGraph == graphData)
        #expect(repeated.originalEndpoints == endpointsData)
        #expect(repeated.graph == imported.graph)
        #expect(try repeated.graph.encoded() == imported.graph.encoded())
    }

    @Test func legacyAdapterPreservesGeometryAndLegacyDataReadOnly() throws {
        let endpoint = UUID(), nodeID = UUID(), outputID = UUID(), shortcutID = UUID()
        let instrument = endpoint
        let position = CGPoint(x: -40.50000000000001, y: 120.125)
        let encodedPosition = try JSONEncoder().encode(position)
        let positionJSON = try #require(String(data: encodedPosition, encoding: .utf8))
        let graphData = Data("""
        {"nodes":[
          {"id":"\(nodeID)","kind":{"instrument":{"_0":"\(instrument)"}},"title":"Synth","position":\(positionJSON)},
          {"id":"\(outputID)","kind":{"endpoint":{"_0":"\(endpoint)"}},"title":"Room","position":[1,2]},
          {"id":"\(shortcutID)","kind":{"liveChannel":{"_0":{"members":[{"channel":7}],"stale":true}}},
           "title":"Observed console","position":[3,4]}],
         "edges":[{"id":"\(UUID())","from":{"nodeID":"\(nodeID)","side":"output","port":0},
          "to":{"nodeID":"\(outputID)","side":"input","port":1}}],
         "futureLegacy":{"keep":true}}
        """.utf8)
        let endpointsData = Data("""
        [{"id":"\(endpoint)","name":"Room","destination":"space","controls":["volume","mute"],
          "outputConnectors":[{"bank":"local","index":7}],
          "outputReferences":[{"mention":"Room","groupName":"Room","connectors":[{"bank":"local","index":7}]}],
          "colorName":"purple","placement":{"position":[0.125,0.875],"width":0.625},"futureEndpoint":[1,null]}]
        """.utf8)
        let imported = try StudioGraphNeutralAdapter.adapt(
            graphData: graphData, endpointsData: endpointsData, id: GraphID(validated: "gph.legacy")
        )
        let graph = imported.graph
        #expect(imported.originalGraph == graphData)
        #expect(imported.originalEndpoints == endpointsData)
        #expect(graph.nodes.map(\.kind) == [.roleInput, .spatialBus, .observedShortcut])
        #expect(graph.nodes[0].id == NodeID(uuid: nodeID))
        #expect(graph.nodes[0].role == (try RoleID("legacy.instrument.\(instrument.uuidString)")))
        #expect(graph.nodes[1].role == (try RoleID("legacy.endpoint.\(endpoint.uuidString)")))
        #expect(graph.nodes[0].role != graph.nodes[1].role)
        #expect(graph.nodes[0].position == GraphPoint(x: Double(position.x), y: Double(position.y)))
        #expect(graph.nodes[1].ports.map(\.id.rawValue) == ["in.1"])
        #expect(graph.nodes[2].ports.isEmpty)
        #expect(graph.extensions?["legacyStudio"] == .object([
            "source": .string("StudioGraph"), "reviewRequired": .bool(true),
            "originalGraph": try ContractCoding.decode(JSONValue.self, from: graphData),
            "originalEndpoints": try ContractCoding.decode(JSONValue.self, from: endpointsData)
        ]))
        #expect(!graph.validationErrors().isEmpty)
        #expect(graph.revision == .initial)
        #expect(try GraphDocument.decode(from: graph.encoded()) == graph)
    }
}
