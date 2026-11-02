/// Immutable, document-free lowered data. Only this file can construct a plan.
struct PreparedAudioRoutingPlan {
    struct Row {
        let firstTerm: Int
        let termCount: Int
        let isIdentity: Bool
    }

    let layout: AudioRoutingLayout
    let bounds: AudioRoutingLimits
    let scratchFloats: Int
    let scratchBytes: Int
    let outputScratchOffset: Int
    let peakScratchOffset: Int
    let sampleWork: Int
    let rows: [Row]
    /// Input channel sample offsets, in declared order including duplicates.
    let terms: [Int]

    fileprivate init(
        layout: AudioRoutingLayout, bounds: AudioRoutingLimits, geometry: AudioRoutingAdmission.Geometry,
        peakScratchOffset: Int, rows: [Row], terms: [Int]
    ) {
        self.layout = layout
        self.bounds = bounds
        scratchFloats = geometry.scratchFloats
        scratchBytes = geometry.scratchBytes
        outputScratchOffset = geometry.inputSamples
        self.peakScratchOffset = peakScratchOffset
        sampleWork = geometry.sampleWork
        self.rows = rows
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
        let sources = Dictionary(uniqueKeysWithValues: inputs.map {
            (AudioRoutingPortKey(node: $0.node, port: $0.port), $0)
        })
        let incoming = Dictionary(uniqueKeysWithValues: selectedGraph.edges.map {
            (AudioRoutingPortKey($0.to), $0)
        })
        var rows: [PreparedAudioRoutingPlan.Row] = []
        var terms: [Int] = []
        rows.reserveCapacity(geometry.outputChannels)
        terms.reserveCapacity(geometry.termCount)
        for output in outputs {
            let edge = incoming[AudioRoutingPortKey(node: output.node, port: output.port)]
            for channel in 0..<output.channels {
                let start = terms.count
                if let edge, let source = sources[AudioRoutingPortKey(edge.from)] {
                    if let conversion = edge.conversion {
                        for index in conversion.map[channel] {
                            terms.append(try sampleOffset(source.firstChannel, index, stride: limits.maxFrames))
                        }
                    } else {
                        terms.append(try sampleOffset(source.firstChannel, channel, stride: limits.maxFrames))
                    }
                }
                rows.append(PreparedAudioRoutingPlan.Row(
                    firstTerm: start, termCount: terms.count - start,
                    isIdentity: edge != nil && edge?.conversion == nil
                ))
            }
        }
        let layout = AudioRoutingLayout(
            graph: selectedGraph.id, revision: selectedGraph.revision, maxFrames: limits.maxFrames,
            inputs: inputs, outputs: outputs, inputSampleCount: geometry.inputSamples,
            outputSampleCount: geometry.outputSamples, peakCount: geometry.outputChannels
        )
        return PreparedAudioRoutingPlan(
            layout: layout, bounds: limits, geometry: geometry,
            peakScratchOffset: try AudioRoutingAdmission.add(geometry.inputSamples, geometry.outputSamples),
            rows: rows, terms: terms
        )
    }

    private static func sampleOffset(_ first: Int, _ channel: Int, stride: Int) throws -> Int {
        try AudioRoutingAdmission.multiply(AudioRoutingAdmission.add(first, channel), stride)
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
