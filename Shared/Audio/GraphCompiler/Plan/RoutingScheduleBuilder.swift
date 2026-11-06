enum RoutingScheduleBuilder {
    private struct EdgePlan {
        let edge: GraphEdge
        let source: GraphNode
        let destination: GraphNode
        let sourcePort: GraphPort
        let destinationPort: GraphPort
    }

    static func build(
        _ graph: GraphDocument, request: RoutingScheduleRequest
    ) throws(RoutingScheduleRefusal) -> RoutingSchedule {
        if let error = graph.validationErrors(strict: true).first {
            if case .invalidFeedback(let edgeID) = error,
               let feedback = graph.edges.first(where: { $0.id == edgeID })?.feedback {
                if feedback.delayBlocks < 1 { throw .feedbackDelayTooShort(edgeID, feedback.delayBlocks) }
                throw .feedbackGainNotCapped(edgeID)
            }
            throw translate(error)
        }
        return try plan(graph, request: request)
    }

    static func plan(
        _ graph: GraphDocument, request: RoutingScheduleRequest
    ) throws(RoutingScheduleRefusal) -> RoutingSchedule {
        try checkBounds(graph)
        let nodes = graph.nodes.sorted { $0.id < $1.id }
        guard Set(nodes.map(\.id)).count == nodes.count else { throw .inconsistentSchedule(.duplicateNode) }
        let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        try validateNodes(nodes)
        let plans = try resolve(graph.edges, nodes: nodeByID)
        try enforceTermBudget(plans, maximum: request.limits.maxTerms)
        let levels = try levelize(nodes.map(\.id), links: plans.filter { $0.edge.feedback == nil }
            .map { ($0.edge.from.node, $0.edge.to.node) })
        let ordered = nodes.filter { $0.kind != .roleInput }.sorted {
            (levels[$0.id] ?? 0, $0.id) < (levels[$1.id] ?? 0, $1.id)
        }
        return try makeSchedule(PreparedGraph(
            graph: graph, request: request, nodes: nodes, ordered: ordered, plans: plans, levels: levels
        ))
    }

    private struct SlotBundle {
        let inputs: [RoutingEndpoint]
        let inputSlots: [NodeID: RoutingSlot]
        let outputSlots: [NodeID: RoutingSlot]
        let delayLines: [RoutingDelayLine]
        let delayedByEdge: [EdgeID: RoutingSlot]
    }

    private struct PreparedGraph {
        let graph: GraphDocument
        let request: RoutingScheduleRequest
        let nodes: [GraphNode]
        let ordered: [GraphNode]
        let plans: [EdgePlan]
        let levels: [NodeID: Int]
    }

    private static func checkBounds(_ graph: GraphDocument) throws(RoutingScheduleRefusal) {
        do {
            try ProjectGraphLimits.check(graph.nodes.count, maximum: ProjectGraphLimits.nodes, path: "$.nodes")
            try ProjectGraphLimits.check(graph.edges.count, maximum: ProjectGraphLimits.edges, path: "$.edges")
            for node in graph.nodes {
                try ProjectGraphLimits.check(
                    node.ports.count, maximum: ProjectGraphLimits.portsPerNode, path: "$.nodes[\(node.id)].ports"
                )
            }
        } catch { throw .graphBounds(error) }
    }

    private static func makeSchedule(_ prepared: PreparedGraph) throws(RoutingScheduleRefusal) -> RoutingSchedule {
        let slots = try allocateSlots(
            prepared.nodes, ordered: prepared.ordered, plans: prepared.plans, frames: prepared.request.blockFrames
        )
        let steps = try makeSteps(prepared.ordered, plans: prepared.plans, slots: slots, levels: prepared.levels)
        let outputs = try makeOutputEndpoints(prepared.nodes, outputSlots: slots.outputSlots)
        let draft = RoutingScheduleDraft(
            graph: prepared.graph.id, revision: prepared.graph.revision, inputs: slots.inputs, steps: steps,
            outputs: outputs, delayLines: slots.delayLines
        )
        return try RoutingSchedule.make(draft: draft, request: prepared.request)
    }

    private static func allocateSlots(
        _ nodes: [GraphNode], ordered: [GraphNode], plans: [EdgePlan], frames: Int
    ) throws(RoutingScheduleRefusal) -> SlotBundle {
        var cursor = 0
        var inputSlots: [NodeID: RoutingSlot] = [:]
        var inputEndpoints: [RoutingEndpoint] = []
        var inputChannel = 0
        for node in nodes where node.kind == .roleInput {
            guard let port = node.ports.first, let channels = port.channels, let role = node.role else {
                throw .unsupportedNodeShape(node.id)
            }
            let slot = try allocate(channels, frames, cursor: &cursor)
            inputSlots[node.id] = slot
            inputEndpoints.append(RoutingEndpoint(
                endpoint: AudioRoutingEndpoint(
                    node: node.id, port: port.id, role: role, channels: channels, firstChannel: inputChannel
                ), slot: slot
            ))
            inputChannel = try RoutingMath.add(inputChannel, channels, resource: .inputChannels)
        }
        var outputSlots: [NodeID: RoutingSlot] = [:]
        for node in ordered {
            let port = node.kind == .roleOutput
                ? node.ports.first(where: { $0.direction == .input })
                : node.ports.first(where: { $0.direction == .output })
            guard let channels = port?.channels else { throw .unsupportedNodeShape(node.id) }
            outputSlots[node.id] = try allocate(channels, frames, cursor: &cursor)
        }

        var delayLines: [RoutingDelayLine] = []
        var delayedByEdge: [EdgeID: RoutingSlot] = [:]
        for plan in plans where plan.edge.feedback != nil {
            guard let feedback = plan.edge.feedback,
                  let source = inputSlots[plan.source.id] ?? outputSlots[plan.source.id],
                  let channels = plan.sourcePort.channels else { throw .inconsistentSchedule(.delayLine) }
            let cut = try FeedbackCut.make(
                edge: plan.edge.id, feedback: feedback, channels: channels, blockFrames: frames
            )
            let delayed = try allocate(channels, frames, cursor: &cursor)
            let storage = try allocate(channels, cut.delayFrames, cursor: &cursor)
            delayedByEdge[plan.edge.id] = delayed
            delayLines.append(RoutingDelayLine(cut: cut, source: source, delayed: delayed, storage: storage))
        }
        return SlotBundle(
            inputs: inputEndpoints, inputSlots: inputSlots, outputSlots: outputSlots,
            delayLines: delayLines, delayedByEdge: delayedByEdge
        )
    }

    private static func makeSteps(
        _ ordered: [GraphNode], plans: [EdgePlan], slots: SlotBundle, levels: [NodeID: Int]
    ) throws(RoutingScheduleRefusal) -> [RoutingStep] {
        var steps: [RoutingStep] = []
        for node in ordered {
            steps.append(try makeStep(node, plans: plans, slots: slots, level: levels[node.id] ?? 0))
        }
        return steps
    }

    private static func makeStep(
        _ node: GraphNode, plans: [EdgePlan], slots: SlotBundle, level: Int
    ) throws(RoutingScheduleRefusal) -> RoutingStep {
        guard let output = slots.outputSlots[node.id],
              let inputPort = node.ports.first(where: { $0.direction == .input }) else {
            throw .unsupportedNodeShape(node.id)
        }
        let incoming = plans.filter { $0.destination.id == node.id }
        let rows = try makeRows(
            incoming, inputPort: inputPort, inputSlots: slots.inputSlots,
            outputSlots: slots.outputSlots, delayedByEdge: slots.delayedByEdge
        )
        return RoutingStep(
            node: node.id, level: level, operation: try operation(node), output: output,
            rows: rows, mixOrder: incoming.map(\.edge.id)
        )
    }

    private static func operation(_ node: GraphNode) throws(RoutingScheduleRefusal) -> RoutingOperation {
        switch node.kind {
        case .roleOutput: return .copy
        case .audioMute: return node.muted == true ? .zero : .copy
        case .audioGain:
            guard let gain = node.linearGain, GraphNode.isValidLinearGain(gain) else {
                throw .invalidGain(node.id)
            }
            return gain == 1 ? .copy : .scale(Float(gain))
        default: throw .unsupportedNodeKind(node.id, node.kind)
        }
    }

    private static func makeOutputEndpoints(
        _ nodes: [GraphNode], outputSlots: [NodeID: RoutingSlot]
    ) throws(RoutingScheduleRefusal) -> [RoutingEndpoint] {
        var outputEndpoints: [RoutingEndpoint] = []
        var outputChannel = 0
        for node in nodes where node.kind == .roleOutput {
            guard let port = node.ports.first(where: { $0.direction == .input }),
                  let channels = port.channels, let role = node.role,
                  let slot = outputSlots[node.id] else {
                throw .unsupportedNodeShape(node.id)
            }
            outputEndpoints.append(RoutingEndpoint(
                endpoint: AudioRoutingEndpoint(
                    node: node.id, port: port.id, role: role, channels: channels, firstChannel: outputChannel
                ), slot: slot
            ))
            outputChannel = try RoutingMath.add(outputChannel, channels, resource: .outputChannels)
        }
        return outputEndpoints
    }

    static func levelize(
        _ nodes: [NodeID], links: [(NodeID, NodeID)]
    ) throws(RoutingScheduleRefusal) -> [NodeID: Int] {
        let unique = Array(Set(nodes)).sorted()
        var outgoing: [NodeID: [NodeID]] = [:]
        var degree = Dictionary(uniqueKeysWithValues: unique.map { ($0, 0) })
        for (source, destination) in links {
            guard degree[source] != nil, degree[destination] != nil else {
                throw .inconsistentSchedule(.unresolvedReference)
            }
            outgoing[source, default: []].append(destination)
            degree[destination, default: 0] += 1
        }
        var levels = Dictionary(uniqueKeysWithValues: unique.map { ($0, 0) })
        var queue = unique.filter { degree[$0] == 0 }
        var position = 0
        while position < queue.count {
            let source = queue[position]
            position += 1
            for destination in outgoing[source] ?? [] {
                levels[destination] = max(levels[destination] ?? 0, (levels[source] ?? 0) + 1)
                degree[destination, default: 0] -= 1
                if degree[destination] == 0 { queue.append(destination) }
            }
        }
        guard queue.count == unique.count else {
            throw .cycleWithoutDelay(unique.filter { degree[$0, default: 0] > 0 })
        }
        return levels
    }

    private static func validateNodes(_ nodes: [GraphNode]) throws(RoutingScheduleRefusal) {
        var roles: Set<RoleID> = []
        for node in nodes {
            try validateNodeShape(node)
            if node.kind == .roleInput || node.kind == .roleOutput { try validateUniqueRole(node, roles: &roles) }
            guard node.requiredCapabilities.isEmpty, node.advisoryCapabilities.isEmpty else {
                throw .unsupportedCapabilities(node.id)
            }
        }
    }

    private static func validateUniqueRole(
        _ node: GraphNode, roles: inout Set<RoleID>
    ) throws(RoutingScheduleRefusal) {
        guard let role = node.role else { throw .unsupportedNodeShape(node.id) }
        guard roles.insert(role).inserted else { throw .duplicateRoleBinding(role) }
    }

    private static func validateNodeShape(_ node: GraphNode) throws(RoutingScheduleRefusal) {
        switch node.kind {
        case .roleInput, .roleOutput:
            let expected: PortDirection = node.kind == .roleInput ? .output : .input
            guard node.ports.count == 1, node.ports[0].direction == expected,
                  node.ports[0].signal == .audio, node.ports[0].hasValidChannels,
                  node.role != nil, node.asset == nil, node.graph == nil else {
                throw .unsupportedNodeShape(node.id)
            }
        case .audioMute:
            guard node.hasValidMuteShape, node.muteStateError == nil, node.muted != nil else {
                throw .unsupportedNodeShape(node.id)
            }
        case .audioGain:
            guard node.hasValidGainShape, let gain = node.linearGain, GraphNode.isValidLinearGain(gain) else {
                throw .invalidGain(node.id)
            }
        default: throw .unsupportedNodeKind(node.id, node.kind)
        }
    }

    private static func resolve(
        _ edges: [GraphEdge], nodes: [NodeID: GraphNode]
    ) throws(RoutingScheduleRefusal) -> [EdgePlan] {
        var result: [EdgePlan] = []
        for edge in edges {
            guard let source = nodes[edge.from.node], let destination = nodes[edge.to.node],
                  let from = source.port(edge.from.port), let to = destination.port(edge.to.port),
                  from.direction == .output, to.direction == .input,
                  source.kind != .roleOutput, destination.kind != .roleInput,
                  from.signal == .audio, to.signal == .audio,
                  let sourceWidth = from.channels, let destinationWidth = to.channels else {
                throw .inconsistentSchedule(.unresolvedReference)
            }
            if let feedback = edge.feedback {
                guard feedback.delayBlocks >= 1 else { throw .feedbackDelayTooShort(edge.id, feedback.delayBlocks) }
                guard feedback.gainCeilingDb.isFinite, feedback.gainCeilingDb <= 0 else {
                    throw .feedbackGainNotCapped(edge.id)
                }
            }
            if let conversion = edge.conversion {
                let conversionIsValid = conversion.map.count == destinationWidth
                    && conversion.map.contains { !$0.isEmpty }
                    && conversion.map.allSatisfy { $0.allSatisfy { (0..<sourceWidth).contains($0) } }
                guard conversionIsValid else {
                    throw .inconsistentSchedule(.unresolvedReference)
                }
            } else if sourceWidth != destinationWidth {
                throw .inconsistentSchedule(.unresolvedReference)
            }
            result.append(EdgePlan(
                edge: edge, source: source, destination: destination,
                sourcePort: from, destinationPort: to
            ))
        }
        return result
    }

    private static func enforceTermBudget(
        _ plans: [EdgePlan], maximum: Int
    ) throws(RoutingScheduleRefusal) {
        var terms = 0
        for plan in plans {
            if let conversion = plan.edge.conversion {
                for row in conversion.map {
                    terms = try RoutingMath.add(terms, row.count, resource: .terms)
                }
            } else {
                guard let channels = plan.destinationPort.channels else {
                    throw .inconsistentSchedule(.unresolvedReference)
                }
                terms = try RoutingMath.add(terms, channels, resource: .terms)
            }
        }
        guard terms <= maximum else {
            throw .resourceLimit(.terms, required: terms, maximum: maximum)
        }
    }

    private static func makeRows(
        _ incoming: [EdgePlan], inputPort: GraphPort, inputSlots: [NodeID: RoutingSlot],
        outputSlots: [NodeID: RoutingSlot], delayedByEdge: [EdgeID: RoutingSlot]
    ) throws(RoutingScheduleRefusal) -> [RoutingRow] {
        guard let channels = inputPort.channels else { throw .inconsistentSchedule(.unresolvedReference) }
        var rows = Array(repeating: RoutingRow(terms: [], isBitCopy: false), count: channels)
        for channel in 0..<channels {
            var terms: [Int] = []
            var bitCopy = false
            for plan in incoming {
                let source = plan.edge.feedback == nil
                    ? inputSlots[plan.source.id] ?? outputSlots[plan.source.id]
                    : delayedByEdge[plan.edge.id]
                guard let source, let width = plan.sourcePort.channels else {
                    throw .inconsistentSchedule(.unresolvedReference)
                }
                let indices = plan.edge.conversion?.map[channel] ?? [channel]
                for index in indices {
                    terms.append(try RoutingMath.add(
                        source.offset,
                        RoutingMath.multiply(index, source.frames, resource: .slotSamples),
                        resource: .slotSamples
                    ))
                }
                bitCopy = incoming.count == 1 && plan.edge.conversion == nil && indices == [channel]
                if width < 1 { throw .inconsistentSchedule(.unresolvedReference) }
            }
            rows[channel] = RoutingRow(terms: terms, isBitCopy: bitCopy && terms.count == 1)
        }
        return rows
    }

    private static func allocate(
        _ channels: Int, _ frames: Int, cursor: inout Int
    ) throws(RoutingScheduleRefusal) -> RoutingSlot {
        let slot = RoutingSlot(offset: cursor, channels: channels, frames: frames)
        cursor = try RoutingMath.add(
            cursor, RoutingMath.multiply(channels, frames, resource: .slotSamples), resource: .scratchFloats
        )
        return slot
    }

    private static func translate(_ error: GraphValidationError) -> RoutingScheduleRefusal {
        switch error {
        case .bounds(let bounds): .graphBounds(bounds)
        case .invalidFeedback(let edge): .feedbackDelayTooShort(edge, 0)
        case .invalidGainValue(let node): .invalidGain(node)
        case .cycleWithoutFeedback(let nodes): .cycleWithoutDelay(nodes)
        default: .invalidGraph(error)
        }
    }
}
