/// Resource preflight precedes dictionaries, sorting, full validation and lowering.
/// ContractID and ContractRevision enforce scalar bounds in every constructor
/// (including in-memory construction); labels are inert and never retained.
enum AudioRoutingAdmission {
    struct Geometry {
        let inputChannels: Int
        let outputChannels: Int
        let termCount: Int
        let inputSamples: Int
        let muteChannels: Int
        let muteResultOffset: Int
        let outputOffset: Int
        let peakOffset: Int
        let outputSamples: Int
        let scratchFloats: Int
        let scratchBytes: Int
        let sampleWork: Int
    }

    static func add(_ left: Int, _ right: Int) throws -> Int {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw AudioRoutingPreparationError.arithmeticOverflow }
        return value
    }

    static func multiply(_ left: Int, _ right: Int) throws -> Int {
        let (value, overflow) = left.multipliedReportingOverflow(by: right)
        guard !overflow else { throw AudioRoutingPreparationError.arithmeticOverflow }
        return value
    }

    static func preflight(
        project: ProjectDocument, graph: GraphDocument, limits: AudioRoutingLimits
    ) throws -> Geometry {
        guard limits.maxFrames > 0, limits.maxInputChannels >= 0, limits.maxOutputChannels >= 0,
              limits.maxTerms >= 0, limits.maxScratchBytes > 0, limits.maxSampleWork >= 0 else {
            throw AudioRoutingPreparationError.invalidConfiguration
        }
        try collectionBounds(project: project, graph: graph)
        var inputs = 0
        var outputs = 0
        var muteChannels = 0
        for node in graph.nodes {
            if node.kind == .audioMute {
                guard muteChannels == 0, node.hasValidMuteShape, node.muted != nil,
                      node.requiredCapabilities.isEmpty, node.advisoryCapabilities.isEmpty,
                      let channels = node.ports.first?.channels else {
                    throw AudioRoutingPreparationError.unsupported
                }
                muteChannels = channels
                continue
            }
            guard node.kind == .roleInput || node.kind == .roleOutput, node.ports.count == 1,
                  node.role != nil, node.asset == nil, node.graph == nil,
                  node.requiredCapabilities.isEmpty, node.advisoryCapabilities.isEmpty,
                  let port = node.ports.first, port.signal == .audio,
                  port.direction == (node.kind == .roleInput ? .output : .input),
                  let channels = port.channels, GraphPort.channelRange.contains(channels) else {
                throw AudioRoutingPreparationError.unsupported
            }
            if node.kind == .roleInput {
                inputs = try add(inputs, channels)
            } else {
                outputs = try add(outputs, channels)
            }
        }
        guard inputs <= limits.maxInputChannels, outputs <= limits.maxOutputChannels else {
            throw AudioRoutingPreparationError.resourceLimit
        }
        let terms = try countTerms(graph, maximum: limits.maxTerms)
        let inputSamples = try multiply(inputs, limits.maxFrames)
        let muteSamples = try multiply(muteChannels, limits.maxFrames)
        let muteResultOffset = try add(inputSamples, muteSamples)
        let outputOffset = try add(muteResultOffset, muteSamples)
        let outputSamples = try multiply(outputs, limits.maxFrames)
        let peakOffset = try add(outputOffset, outputSamples)
        let scratchFloats = max(1, try add(peakOffset, outputs))
        let scratchBytes = try multiply(scratchFloats, MemoryLayout<Float>.stride)
        // F * (2I + T + 4O + 4C) + 2O, including disconnected/true mute work.
        let routingWork = try add(add(multiply(2, inputs), terms), multiply(4, outputs))
        let perFrame = try add(routingWork, multiply(4, muteChannels))
        let work = try add(multiply(limits.maxFrames, perFrame), multiply(2, outputs))
        guard scratchBytes <= limits.maxScratchBytes, scratchBytes <= ScratchArena.maximumByteCapacity,
              work <= limits.maxSampleWork else {
            throw AudioRoutingPreparationError.resourceLimit
        }
        return Geometry(
            inputChannels: inputs, outputChannels: outputs, termCount: terms,
            inputSamples: inputSamples, muteChannels: muteChannels,
            muteResultOffset: muteResultOffset, outputOffset: outputOffset, peakOffset: peakOffset,
            outputSamples: outputSamples,
            scratchFloats: scratchFloats, scratchBytes: scratchBytes, sampleWork: work
        )
    }

    private static func collectionBounds(project: ProjectDocument, graph: GraphDocument) throws {
        do {
            try project.checkCollectionBounds()
            try ProjectGraphLimits.check(graph.nodes.count, maximum: ProjectGraphLimits.nodes, path: "$.nodes")
            try ProjectGraphLimits.check(graph.edges.count, maximum: ProjectGraphLimits.edges, path: "$.edges")
            try ProjectGraphLimits.check(
                graph.capabilities.count, maximum: ProjectGraphLimits.capabilities, path: "$.capabilities"
            )
            for node in graph.nodes {
                try ProjectGraphLimits.check(
                    node.ports.count, maximum: ProjectGraphLimits.portsPerNode, path: "$.node.ports"
                )
                let count = try add(node.requiredCapabilities.count, node.advisoryCapabilities.count)
                try ProjectGraphLimits.check(count, maximum: ProjectGraphLimits.capabilities, path: "$.node.caps")
            }
        } catch let error as ProjectGraphLimitError {
            throw AudioRoutingPreparationError.collectionBounds(error)
        }
    }

    private static func countTerms(_ graph: GraphDocument, maximum: Int) throws -> Int {
        var terms = 0
        for edge in graph.edges {
            guard edge.feedback == nil else { throw AudioRoutingPreparationError.unsupported }
            if let conversion = edge.conversion {
                // Bound the outer collection before walking rows; count every term
                // before full validation inspects even the first source index.
                guard conversion.map.count <= GraphPort.channelRange.upperBound else {
                    throw AudioRoutingPreparationError.resourceLimit
                }
                for row in conversion.map {
                    terms = try add(terms, row.count)
                    guard terms <= maximum else { throw AudioRoutingPreparationError.resourceLimit }
                }
            } else {
                // Linear bounded lookup deliberately avoids a pre-preflight dictionary.
                guard let destination = graph.nodes.first(where: { $0.id == edge.to.node }),
                      let port = destination.ports.first(where: { $0.id == edge.to.port }),
                      let channels = port.channels else {
                    throw AudioRoutingPreparationError.unsupported
                }
                terms = try add(terms, channels)
                guard terms <= maximum else { throw AudioRoutingPreparationError.resourceLimit }
            }
        }
        return terms
    }

    static func validateSelectedContext(project: ProjectDocument, graph: GraphDocument) throws {
        try checkMetadata(project: project, graph: graph)
        guard project.patches.isEmpty, project.assets.isEmpty, project.actions.isEmpty else {
            throw AudioRoutingPreparationError.unsupported
        }
        var graphIDs: Set<GraphID> = []
        var selected: ProjectGraphReference?
        for reference in project.graphs {
            guard graphIDs.insert(reference.graph).inserted else {
                throw AudioRoutingPreparationError.contractFailure(.duplicateGraph(reference.graph))
            }
            if reference.graph == graph.id { selected = reference }
        }
        var roleIDs: Set<RoleID> = []
        for role in project.roles {
            guard roleIDs.insert(role.id).inserted else {
                throw AudioRoutingPreparationError.contractFailure(.duplicateRole(role.id))
            }
        }
        guard let selected, selected.revision == graph.revision else {
            throw AudioRoutingPreparationError.contractFailure(
                .graphNotSupplied(graph.id, revision: selected?.revision ?? graph.revision)
            )
        }
        // This is NOT whole-project validation. Unsupplied unrelated references
        // are checked above for identity/metadata only; their documents are neither
        // validated nor compiled. All original roles remain in the selected context.
        var context = project
        context.graphs = [selected]
        do {
            try context.validate(graphs: [graph], strict: true)
        } catch {
            throw AudioRoutingPreparationError.contractFailure(error)
        }
        try validateBindings(graph)
    }

    private static func validateBindings(_ graph: GraphDocument) throws {
        // Supported capability set is empty: preflight rejects both required and
        // advisory dependencies. Unused valid definitions have no routing meaning.
        var bindings: Set<RoleID> = []
        for node in graph.nodes where node.kind == .roleInput || node.kind == .roleOutput {
            guard let role = node.role, bindings.insert(role).inserted else {
                throw AudioRoutingPreparationError.unsupported
            }
        }
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        var destinations: Set<AudioRoutingPortKey> = []
        for edge in graph.edges {
            let source = nodes[edge.from.node]?.kind
            let destination = nodes[edge.to.node]?.kind
            let supported = source == .roleInput && (destination == .roleOutput || destination == .audioMute)
                || source == .audioMute && destination == .roleOutput
            guard supported,
                  destinations.insert(AudioRoutingPortKey(edge.to)).inserted else {
                throw AudioRoutingPreparationError.unsupported
            }
        }
    }

    private static func empty(_ unknown: [String: JSONValue], _ extensions: [String: JSONValue]?) throws {
        guard unknown.isEmpty, extensions?.isEmpty != false else {
            throw AudioRoutingPreparationError.unsupported
        }
    }

    private static func checkMetadata(project: ProjectDocument, graph: GraphDocument) throws {
        try empty(project.unknownFields, project.extensions)
        for reference in project.graphs { try empty(reference.unknownFields, reference.extensions) }
        for role in project.roles { try empty(role.unknownFields, role.extensions) }
        try empty(graph.unknownFields, graph.extensions)
        for capability in graph.capabilities { try empty(capability.unknownFields, capability.extensions) }
        for node in graph.nodes {
            try empty(node.unknownFields, node.extensions)
            if let position = node.position { try empty(position.unknownFields, position.extensions) }
            for port in node.ports { try empty(port.unknownFields, port.extensions) }
        }
        for edge in graph.edges {
            try empty(edge.unknownFields, edge.extensions)
            try empty(edge.from.unknownFields, edge.from.extensions)
            try empty(edge.to.unknownFields, edge.to.extensions)
            if let conversion = edge.conversion { try empty(conversion.unknownFields, conversion.extensions) }
        }
    }
}

/// Port identity deliberately excludes optional PortAddress metadata.
struct AudioRoutingPortKey: Hashable {
    let node: NodeID
    let port: PortID

    init(_ address: PortAddress) {
        node = address.node
        port = address.port
    }

    init(node: NodeID, port: PortID) {
        self.node = node
        self.port = port
    }
}
