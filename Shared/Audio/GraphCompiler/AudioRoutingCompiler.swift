/// Immutable, document-free lowered data. Only this file can construct a plan.
struct PreparedAudioRoutingPlan {
    struct Row {
        let firstTerm: Int
        let termCount: Int
        let isIdentity: Bool
    }

    struct Mute {
        let node: NodeID
        let inputPort: PortID
        let outputPort: PortID
        let muted: Bool
        let inputOffset: Int
        let resultOffset: Int
        let rows: [Row]
    }

    let layout: AudioRoutingLayout
    let bounds: AudioRoutingLimits
    let scratchFloats: Int
    let scratchBytes: Int
    let outputScratchOffset: Int
    let peakScratchOffset: Int
    let sampleWork: Int
    let rows: [Row]
    let mute: Mute?
    /// Staged input or materialized mute-result offsets, in declared order including duplicates.
    let terms: [Int]

    fileprivate init(
        layout: AudioRoutingLayout, bounds: AudioRoutingLimits, geometry: AudioRoutingAdmission.Geometry,
        mute: Mute?, rows: [Row], terms: [Int]
    ) {
        self.layout = layout
        self.bounds = bounds
        scratchFloats = geometry.scratchFloats
        scratchBytes = geometry.scratchBytes
        outputScratchOffset = geometry.outputOffset
        peakScratchOffset = geometry.peakOffset
        sampleWork = geometry.sampleWork
        self.rows = rows
        self.mute = mute
        self.terms = terms
    }
}

enum AudioRoutingCompiler {
    static func compile(
        project: ProjectDocument, selectedGraph: GraphDocument, limits: AudioRoutingLimits
    ) throws -> PreparedAudioRoutingPlan {
        let geometry = try AudioRoutingAdmission.preflight(project: project, graph: selectedGraph, limits: limits)
        try AudioRoutingAdmission.validateSelectedContext(project: project, graph: selectedGraph)
        let inputs = try endpoints(selectedGraph, kind: .roleInput)
        let outputs = try endpoints(selectedGraph, kind: .roleOutput)
        var sources = try Dictionary(uniqueKeysWithValues: inputs.map {
            (AudioRoutingPortKey(node: $0.node, port: $0.port),
             try AudioRoutingAdmission.multiply($0.firstChannel, limits.maxFrames))
        })
        let incoming = Dictionary(uniqueKeysWithValues: selectedGraph.edges.map {
            (AudioRoutingPortKey($0.to), $0)
        })
        var rows: [PreparedAudioRoutingPlan.Row] = []
        var terms: [Int] = []
        rows.reserveCapacity(geometry.outputChannels)
        terms.reserveCapacity(geometry.termCount)
        var mute: PreparedAudioRoutingPlan.Mute?
        if let node = selectedGraph.nodes.first(where: { $0.kind == .audioMute }) {
            guard let input = node.ports.first(where: { $0.direction == .input }),
                  let output = node.ports.first(where: { $0.direction == .output }),
                  let muted = node.muted else {
                throw AudioRoutingPreparationError.unsupported
            }
            let muteRows = try lowerRows(
                edge: incoming[AudioRoutingPortKey(node: node.id, port: input.id)],
                channels: geometry.muteChannels, sources: sources, stride: limits.maxFrames, terms: &terms
            )
            mute = PreparedAudioRoutingPlan.Mute(
                node: node.id, inputPort: input.id, outputPort: output.id,
                muted: muted, inputOffset: geometry.inputSamples,
                resultOffset: geometry.muteResultOffset, rows: muteRows
            )
            sources[AudioRoutingPortKey(node: node.id, port: output.id)] = geometry.muteResultOffset
        }
        for output in outputs {
            let edge = incoming[AudioRoutingPortKey(node: output.node, port: output.port)]
            rows.append(contentsOf: try lowerRows(
                edge: edge, channels: output.channels, sources: sources, stride: limits.maxFrames, terms: &terms
            ))
        }
        let layout = AudioRoutingLayout(
            graph: selectedGraph.id, revision: selectedGraph.revision, maxFrames: limits.maxFrames,
            inputs: inputs, outputs: outputs, inputSampleCount: geometry.inputSamples,
            outputSampleCount: geometry.outputSamples, peakCount: geometry.outputChannels
        )
        let componentCount = try AudioRoutingAdmission.add(
            AudioRoutingAdmission.add(inputs.count, outputs.count), mute == nil ? 0 : 1
        )
        guard componentCount == selectedGraph.nodes.count else {
            throw AudioRoutingPreparationError.unsupported
        }
        return PreparedAudioRoutingPlan(
            layout: layout, bounds: limits, geometry: geometry,
            mute: mute, rows: rows, terms: terms
        )
    }

    private static func lowerRows(
        edge: GraphEdge?, channels: Int, sources: [AudioRoutingPortKey: Int],
        stride: Int, terms: inout [Int]
    ) throws -> [PreparedAudioRoutingPlan.Row] {
        var rows: [PreparedAudioRoutingPlan.Row] = []
        for channel in 0..<channels {
            let start = terms.count
            if let edge {
                guard let source = sources[AudioRoutingPortKey(edge.from)] else {
                    throw AudioRoutingPreparationError.unsupported
                }
                let indices = edge.conversion?.map[channel] ?? [channel]
                _ = try AudioRoutingAdmission.add(start, indices.count)
                for index in indices {
                    terms.append(try AudioRoutingAdmission.add(
                        source, AudioRoutingAdmission.multiply(index, stride)
                    ))
                }
            }
            rows.append(PreparedAudioRoutingPlan.Row(
                firstTerm: start, termCount: terms.count - start,
                isIdentity: edge != nil && edge?.conversion == nil
            ))
        }
        return rows
    }

    private static func endpoints(_ graph: GraphDocument, kind: NodeKind) throws -> [AudioRoutingEndpoint] {
        var result: [AudioRoutingEndpoint] = []
        var firstChannel = 0
        // Stable scalar identity order, independent of document order and presentation.
        for node in graph.nodes.filter({ $0.kind == kind }).sorted(by: { $0.id < $1.id }) {
            guard let role = node.role, let port = node.ports.first, let channels = port.channels else {
                throw AudioRoutingPreparationError.unsupported
            }
            result.append(AudioRoutingEndpoint(
                node: node.id, port: port.id, role: role, channels: channels, firstChannel: firstChannel
            ))
            firstChannel = try AudioRoutingAdmission.add(firstChannel, channels)
        }
        return result
    }
}
