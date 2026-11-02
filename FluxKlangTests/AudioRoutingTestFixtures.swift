import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

enum AudioRoutingTestFixtures {
    typealias Documents = (project: ProjectDocument, graph: GraphDocument)

    static func limits(
        frames: Int = 16, inputs: Int = 8, outputs: Int = 8, terms: Int = 32,
        scratch: Int = 4_096, work: Int = 4_096
    ) -> AudioRoutingLimits {
        AudioRoutingLimits(
            maxFrames: frames, maxInputChannels: inputs, maxOutputChannels: outputs,
            maxTerms: terms, maxScratchBytes: scratch, maxSampleWork: work
        )
    }

    static func documents(
        inputChannels: Int = 2, outputChannels: Int = 2, map: [[Int]]? = nil
    ) -> Documents {
        let sourceRole = ProjectRole(
            id: RoleID(validated: "role.source"), label: "Source", direction: .input,
            signal: .audio, channels: inputChannels
        )
        let outputRole = ProjectRole(
            id: RoleID(validated: "role.output"), label: "Output", direction: .output,
            signal: .audio, channels: outputChannels
        )
        let source = GraphNode(
            id: NodeID(validated: "node.source"), kind: .roleInput, label: "Source", role: sourceRole.id,
            ports: [GraphPort(id: PortID(validated: "audio"), direction: .output,
                              signal: .audio, channels: inputChannels)]
        )
        let destination = GraphNode(
            id: NodeID(validated: "node.output"), kind: .roleOutput, label: "Output", role: outputRole.id,
            ports: [GraphPort(id: PortID(validated: "audio"), direction: .input,
                              signal: .audio, channels: outputChannels)]
        )
        let edge = GraphEdge(
            id: EdgeID(validated: "edge.direct"),
            from: PortAddress(node: source.id, port: source.ports[0].id),
            to: PortAddress(node: destination.id, port: destination.ports[0].id),
            conversion: map.map { EdgeConversion(map: $0) }
        )
        let graph = GraphDocument(
            id: GraphID(validated: "graph.routing"), nodes: [source, destination], edges: [edge]
        )
        let project = ProjectDocument(
            id: ProjectID(validated: "project.routing"), name: "Offline",
            graphs: [ProjectGraphReference(graph: graph.id, revision: graph.revision)],
            roles: [sourceRole, outputRole]
        )
        return (project, graph)
    }

    static func compile(
        _ documents: Documents,
        limits: AudioRoutingLimits = limits()
    ) throws -> PreparedAudioRoutingPlan {
        try AudioRoutingCompiler.compile(
            project: documents.project, selectedGraph: documents.graph, limits: limits
        )
    }

    static func appendEndpoint(
        to documents: inout Documents, input: Bool, suffix: String, channels: Int = 2
    ) throws {
        let role = ProjectRole(
            id: try RoleID("role.\(suffix)"), label: suffix, direction: input ? .input : .output,
            signal: .audio, channels: channels
        )
        documents.project.roles.append(role)
        documents.graph.nodes.append(GraphNode(
            id: try NodeID("node.\(suffix)"), kind: input ? .roleInput : .roleOutput, label: suffix,
            role: role.id, ports: [GraphPort(
                id: PortID(validated: "audio"), direction: input ? .output : .input,
                signal: .audio, channels: channels
            )]
        ))
    }

    static func process(
        _ processor: inout OfflineAudioRoutingProcessor, frames: Int,
        input: [Float], output: inout [Float], peaks: inout [Float]
    ) -> AudioRoutingProcessResult {
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                peaks.withUnsafeMutableBufferPointer { meters in
                    processor.process(frames: frames, input: source, output: destination, peaks: meters)
                }
            }
        }
    }
}
