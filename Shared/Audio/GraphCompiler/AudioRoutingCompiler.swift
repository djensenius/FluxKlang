/// Immutable, document-free lowered data.
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

    init(
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
            var muteRows: [PreparedAudioRoutingPlan.Row] = []
            try appendRows(
                edge: incoming[AudioRoutingPortKey(node: node.id, port: input.id)],
                channels: geometry.muteChannels, sources: sources, stride: limits.maxFrames,
                terms: &terms, rows: &muteRows
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
            try appendRows(
                edge: edge, channels: output.channels, sources: sources, stride: limits.maxFrames,
                terms: &terms, rows: &rows
            )
        }
        let layout = AudioRoutingLayout(
            graph: selectedGraph.id, revision: selectedGraph.revision, maxFrames: limits.maxFrames,
            inputs: inputs, outputs: outputs, inputSampleCount: geometry.inputSamples,
            outputSampleCount: geometry.outputSamples, peakCount: geometry.outputChannels
        )
        let plan = PreparedAudioRoutingPlan(
            layout: layout, bounds: limits, geometry: geometry,
            mute: mute, rows: rows, terms: terms
        )
        try validateCorrespondence(plan: plan, graph: selectedGraph, limits: limits, geometry: geometry)
        return plan
    }

    /// Checks the executable plan itself against the admitted nodes and their positional rows.
    /// This intentionally retains no second description of component coverage.
    static func validateCorrespondence(
        plan: PreparedAudioRoutingPlan, graph: GraphDocument, limits: AudioRoutingLimits,
        geometry: AudioRoutingAdmission.Geometry
    ) throws {
        var validator = CorrespondenceValidator(plan: plan, graph: graph, limits: limits, geometry: geometry)
        try validator.validate()
    }

    /// Ephemeral, per-compilation check state; nothing is attached to the lowered plan.
    private struct CorrespondenceValidator {
        let plan: PreparedAudioRoutingPlan
        let graph: GraphDocument
        let limits: AudioRoutingLimits
        let geometry: AudioRoutingAdmission.Geometry
        var nodes: [NodeID: GraphNode] = [:]
        var covered: Set<NodeID> = []
        var sources: [AudioRoutingPortKey: Int] = [:]
        var incoming: [AudioRoutingPortKey: GraphEdge] = [:]
        var inputChannels = 0
        var outputChannels = 0
        var termCursor = 0

        mutating func validate() throws {
            try validatePlanIdentity()
            try validateLimits()
            try validateLayoutAndScratchGeometry()
            try indexNodes()
            try validateEndpoints(kind: .roleInput)
            try validateEndpoints(kind: .roleOutput)
            try validateEndpointTotals()
            try validateMute()
            try validateComponentCoverage()
            try indexIncomingEdges()
            try validateMuteRows()
            try validateOutputRows()
            try validateTermCoverage()
        }

        private func validatePlanIdentity() throws {
            guard plan.layout.graph == graph.id, plan.layout.revision == graph.revision,
                  plan.layout.maxFrames == limits.maxFrames else {
                throw AudioRoutingPreparationError.unsupported
            }
        }

        private func validateLimits() throws {
            guard plan.bounds.maxFrames == limits.maxFrames,
                  plan.bounds.maxInputChannels == limits.maxInputChannels,
                  plan.bounds.maxOutputChannels == limits.maxOutputChannels,
                  plan.bounds.maxTerms == limits.maxTerms,
                  plan.bounds.maxScratchBytes == limits.maxScratchBytes,
                  plan.bounds.maxSampleWork == limits.maxSampleWork else {
                throw AudioRoutingPreparationError.unsupported
            }
        }

        private func validateLayoutAndScratchGeometry() throws {
            guard plan.layout.inputSampleCount == geometry.inputSamples,
                  plan.layout.outputSampleCount == geometry.outputSamples,
                  plan.layout.peakCount == geometry.outputChannels,
                  plan.rows.count == geometry.outputChannels,
                  plan.scratchFloats == geometry.scratchFloats,
                  plan.scratchBytes == geometry.scratchBytes,
                  plan.outputScratchOffset == geometry.outputOffset,
                  plan.peakScratchOffset == geometry.peakOffset,
                  plan.sampleWork == geometry.sampleWork,
                  plan.terms.count == geometry.termCount else {
                throw AudioRoutingPreparationError.unsupported
            }
        }

        private mutating func indexNodes() throws {
            for node in graph.nodes {
                guard nodes.updateValue(node, forKey: node.id) == nil else {
                    throw AudioRoutingPreparationError.unsupported
                }
            }
        }

        private mutating func validateEndpoints(kind: NodeKind) throws {
            let endpoints = kind == .roleInput ? plan.layout.inputs : plan.layout.outputs
            var previousNode: NodeID?
            for endpoint in endpoints {
                try validateEndpoint(endpoint, kind: kind, previousNode: previousNode)
                previousNode = endpoint.node
            }
        }

        private mutating func validateEndpoint(
            _ endpoint: AudioRoutingEndpoint, kind: NodeKind, previousNode: NodeID?
        ) throws {
            guard let node = nodes[endpoint.node], node.kind == kind else {
                throw AudioRoutingPreparationError.unsupported
            }
            guard let role = node.role, node.ports.count == 1, let port = node.ports.first else {
                throw AudioRoutingPreparationError.unsupported
            }
            guard endpoint.port == port.id, endpoint.role == role, endpoint.channels == port.channels,
                  endpoint.firstChannel == currentChannelCount(for: kind),
                  port.direction == (kind == .roleInput ? .output : .input) else {
                throw AudioRoutingPreparationError.unsupported
            }
            guard previousNode.map({ $0 < node.id }) ?? true,
                  covered.insert(node.id).inserted else {
                throw AudioRoutingPreparationError.unsupported
            }
            let sourceOffset = try AudioRoutingAdmission.multiply(endpoint.firstChannel, limits.maxFrames)
            if kind == .roleInput {
                sources[AudioRoutingPortKey(node: node.id, port: port.id)] = sourceOffset
            }
            if kind == .roleInput {
                inputChannels = try AudioRoutingAdmission.add(inputChannels, endpoint.channels)
            } else {
                outputChannels = try AudioRoutingAdmission.add(outputChannels, endpoint.channels)
            }
        }

        private func currentChannelCount(for kind: NodeKind) -> Int {
            kind == .roleInput ? inputChannels : outputChannels
        }

        private func validateEndpointTotals() throws {
            guard inputChannels == geometry.inputChannels, outputChannels == geometry.outputChannels else {
                throw AudioRoutingPreparationError.unsupported
            }
        }

        private mutating func validateMute() throws {
            let muteNode = graph.nodes.first { $0.kind == .audioMute }
            guard let muteNode else {
                guard plan.mute == nil else { throw AudioRoutingPreparationError.unsupported }
                return
            }
            guard let mute = plan.mute,
                  let input = muteNode.ports.first(where: { $0.direction == .input }),
                  let output = muteNode.ports.first(where: { $0.direction == .output }) else {
                throw AudioRoutingPreparationError.unsupported
            }
            try validateMuteIdentity(mute, node: muteNode, input: input, output: output)
            guard covered.insert(muteNode.id).inserted else {
                throw AudioRoutingPreparationError.unsupported
            }
            sources[AudioRoutingPortKey(node: muteNode.id, port: output.id)] = geometry.muteResultOffset
        }

        private func validateMuteIdentity(
            _ mute: PreparedAudioRoutingPlan.Mute, node: GraphNode, input: GraphPort, output: GraphPort
        ) throws {
            guard mute.node == node.id, mute.inputPort == input.id, mute.outputPort == output.id,
                  mute.muted == node.muted else {
                throw AudioRoutingPreparationError.unsupported
            }
        }

        private func validateComponentCoverage() throws {
            guard covered.count == graph.nodes.count else { throw AudioRoutingPreparationError.unsupported }
        }

        private mutating func indexIncomingEdges() throws {
            for edge in graph.edges {
                guard incoming.updateValue(edge, forKey: AudioRoutingPortKey(edge.to)) == nil else {
                    throw AudioRoutingPreparationError.unsupported
                }
            }
        }

        private mutating func validateMuteRows() throws {
            guard let mute = plan.mute else { return }
            guard let node = nodes[mute.node],
                  let input = node.ports.first(where: { $0.direction == .input }) else {
                throw AudioRoutingPreparationError.unsupported
            }
            guard mute.inputOffset == geometry.inputSamples,
                  mute.resultOffset == geometry.muteResultOffset,
                  mute.rows.count == geometry.muteChannels else {
                throw AudioRoutingPreparationError.unsupported
            }
            try validateRows(
                mute.rows, edge: incoming[AudioRoutingPortKey(node: node.id, port: input.id)],
                channels: geometry.muteChannels
            )
        }

        private mutating func validateOutputRows() throws {
            for endpoint in plan.layout.outputs {
                try validateRows(
                    plan.rows, firstRow: endpoint.firstChannel,
                    edge: incoming[AudioRoutingPortKey(node: endpoint.node, port: endpoint.port)],
                    channels: endpoint.channels
                )
            }
        }

        private mutating func validateRows(
            _ rows: [PreparedAudioRoutingPlan.Row], firstRow: Int = 0, edge: GraphEdge?, channels: Int
        ) throws {
            guard firstRow >= 0, firstRow <= rows.count, channels <= rows.count - firstRow else {
                throw AudioRoutingPreparationError.unsupported
            }
            if let conversion = edge?.conversion, conversion.map.count != channels {
                throw AudioRoutingPreparationError.unsupported
            }
            for channel in 0..<channels {
                try validateRow(rows[firstRow + channel], edge: edge, channel: channel)
            }
        }

        private mutating func validateRow(
            _ row: PreparedAudioRoutingPlan.Row, edge: GraphEdge?, channel: Int
        ) throws {
            let indices = edge?.conversion?.map[channel]
            let expectedCount = edge == nil ? 0 : (indices?.count ?? 1)
            let end = try AudioRoutingAdmission.add(termCursor, expectedCount)
            guard row.firstTerm == termCursor, row.termCount == expectedCount,
                  row.isIdentity == (edge != nil && edge?.conversion == nil), end <= plan.terms.count else {
                throw AudioRoutingPreparationError.unsupported
            }
            if let edge {
                try validateTermOccurrences(edge: edge, indices: indices, channel: channel)
            }
            termCursor = end
        }

        private func validateTermOccurrences(edge: GraphEdge, indices: [Int]?, channel: Int) throws {
            guard let source = sources[AudioRoutingPortKey(edge.from)] else {
                throw AudioRoutingPreparationError.unsupported
            }
            if let indices {
                for (offset, index) in indices.enumerated() {
                    try validateTerm(source: source, sourceChannel: index, termOffset: offset)
                }
            } else {
                try validateTerm(source: source, sourceChannel: channel, termOffset: 0)
            }
        }

        private func validateTerm(source: Int, sourceChannel: Int, termOffset: Int) throws {
            let channelOffset = try AudioRoutingAdmission.multiply(sourceChannel, limits.maxFrames)
            let expected = try AudioRoutingAdmission.add(source, channelOffset)
            guard plan.terms[termCursor + termOffset] == expected else {
                throw AudioRoutingPreparationError.unsupported
            }
        }

        private func validateTermCoverage() throws {
            guard termCursor == plan.terms.count else { throw AudioRoutingPreparationError.unsupported }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func appendRows(
        edge: GraphEdge?, channels: Int, sources: [AudioRoutingPortKey: Int],
        stride: Int, terms: inout [Int], rows: inout [PreparedAudioRoutingPlan.Row]
    ) throws {
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
