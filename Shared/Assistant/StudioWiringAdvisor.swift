import CoreGraphics
import Foundation

// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
enum StudioWiringAdvisor {
    static func build(
        request: StudioWiringRequest,
        equipment: [Equipment],
        effects: [Effect],
        connections: GlobalStudioConnections,
        currentGraph: StudioGraph,
        environmentID: RoutingEnvironment.ID? = nil
    ) -> StudioPatchDraft {
        let primary = StudioWiringRoute(
            sourceInstrumentIDs: request.sourceInstrumentIDs,
            effectChainIDs: request.effectChainIDs,
            destination: request.destination,
            includesDrySignal: request.includesDrySignal,
            outputConnectors: request.outputConnectors
        )
        let routes = [primary] + request.additionalRoutes
        guard routes.count > 1 else {
            return makeDraft(
                request: request,
                equipment: equipment,
                effects: effects,
                connections: connections,
                currentGraph: currentGraph,
                environmentID: environmentID,
                currentEnvironmentID: environmentID
            )
        }
        var placementGraph = request.applicationMode == .replace ? StudioGraph() : currentGraph
        let drafts = routes.map { route in
            let draft = makeDraft(
                request: StudioWiringRequest(
                    sourceInstrumentIDs: route.sourceInstrumentIDs,
                    effectChainIDs: route.effectChainIDs,
                    destination: route.destination,
                    includesDrySignal: route.includesDrySignal,
                    outputConnectors: route.outputConnectors
                ),
                equipment: equipment,
                effects: effects,
                connections: connections,
                currentGraph: placementGraph,
                environmentID: environmentID,
                currentEnvironmentID: environmentID
            )
            for spec in draft.fragment.nodes where placementGraph.node(spec.node.id) == nil {
                placementGraph.addNode(spec.node)
            }
            return draft
        }
        return StudioMultiRouteDraftBuilder.combine(
            drafts,
            request: request,
            equipment: equipment,
            effects: effects,
            currentGraph: currentGraph,
            environmentID: environmentID
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func makeDraft(
        request: StudioWiringRequest,
        equipment: [Equipment],
        effects: [Effect],
        connections: GlobalStudioConnections,
        currentGraph: StudioGraph,
        environmentID: RoutingEnvironment.ID?,
        currentEnvironmentID: RoutingEnvironment.ID?
    ) -> StudioPatchDraft {
        let persistedRequest = StudioPatchDraft.PersistedRequest(
            environmentID: environmentID,
            sourceInstrumentIDs: orderedUnique(request.sourceInstrumentIDs),
            effectChainIDs: orderedUnique(request.effectChainIDs),
            destination: request.destination,
            includesDrySignal: request.includesDrySignal,
            outputConnectors: request.outputConnectors,
            additionalRoutes: request.additionalRoutes
        )
        let signature = [
            environmentID?.uuidString ?? "no-environment",
            persistedRequest.sourceInstrumentIDs.map(\.uuidString).joined(separator: ","),
            persistedRequest.effectChainIDs.map(\.uuidString).joined(separator: ","),
            persistedRequest.destination.rawValue,
            persistedRequest.includesDrySignal.description,
            persistedRequest.outputConnectors?.map(\.label).joined(separator: ",") ?? "",
            request.applicationMode.rawValue
        ].joined(separator: "|")
        let equipmentByID = Dictionary(equipment.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let effectsByID = Dictionary(effects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let endpoint = makeEndpoint(
            signature: signature,
            request: persistedRequest,
            equipmentByID: equipmentByID,
            connections: connections
        )
        let nodeSpecs = makeNodes(
            request: persistedRequest,
            endpoint: endpoint,
            equipmentByID: equipmentByID,
            effectsByID: effectsByID,
            currentGraph: request.applicationMode == .replace ? StudioGraph() : currentGraph
        )
        let edges = makeEdges(
            signature: signature,
            sourceIDs: persistedRequest.sourceInstrumentIDs,
            effectIDs: persistedRequest.effectChainIDs,
            includesDrySignal: persistedRequest.includesDrySignal,
            endpointID: endpoint.id,
            nodes: nodeSpecs
        )
        let validation = validate(
            request: persistedRequest,
            equipmentByID: equipmentByID,
            effectsByID: effectsByID,
            connections: connections,
            currentEnvironmentID: currentEnvironmentID
        )
        return StudioPatchDraft(
            id: stableUUID("draft|\(signature)"),
            createdAt: Date(),
            request: persistedRequest,
            fragment: StudioGraphFragment(nodes: nodeSpecs, edges: edges, endpoints: [endpoint]),
            cableInstructions: cableInstructions(
                request: persistedRequest,
                equipmentByID: equipmentByID,
                effectsByID: effectsByID,
                connections: connections
            ),
            logicalRoutingSummary: routingSummary(
                request: persistedRequest,
                equipmentByID: equipmentByID,
                effectsByID: effectsByID,
                endpoint: endpoint
            ),
            validation: validation,
            applicationMode: request.applicationMode
        )
    }

    // swiftlint:disable:next function_parameter_count
    static func revalidate(
        _ draft: StudioPatchDraft,
        equipment: [Equipment],
        effects: [Effect],
        connections: GlobalStudioConnections,
        currentGraph: StudioGraph,
        currentEnvironmentID: RoutingEnvironment.ID?
    ) -> StudioPatchDraft {
        var refreshed = makeDraft(
            request: StudioWiringRequest(
                sourceInstrumentIDs: draft.request.sourceInstrumentIDs,
                effectChainIDs: draft.request.effectChainIDs,
                destination: draft.request.destination,
                includesDrySignal: draft.request.includesDrySignal,
                outputConnectors: draft.request.outputConnectors,
                additionalRoutes: draft.request.additionalRoutes,
                applicationMode: draft.applicationMode
            ),
            equipment: equipment,
            effects: effects,
            connections: connections,
            currentGraph: currentGraph,
            environmentID: draft.request.environmentID,
            currentEnvironmentID: currentEnvironmentID
        )
        refreshed.createdAt = draft.createdAt
        return refreshed
    }

    private static func makeEndpoint(
        signature: String,
        request: StudioPatchDraft.PersistedRequest,
        equipmentByID: [Equipment.ID: Equipment],
        connections: GlobalStudioConnections
    ) -> StudioEndpoint {
        let sourceNames = request.sourceInstrumentIDs.compactMap { equipmentByID[$0]?.name }
        let prefix = sourceNames.isEmpty ? "Studio" : sourceNames.joined(separator: " + ")
        let name: String
        if request.destination == .finalMix, let speakers = mainSpeakerName(in: connections.effectiveHome) {
            name = speakers
        } else if request.destination == .custom,
                  let outputName = customOutputName(
                    connectors: request.outputConnectors ?? [],
                    connections: connections.effectiveHome
                  ) {
            name = outputName
        } else {
            let suffix = request.destination == .space ? "Space" : "Mix"
            name = "\(prefix) \(suffix)"
        }
        return StudioEndpoint(
            id: stableUUID("endpoint|\(signature)"),
            name: name,
            destination: request.destination,
            outputConnectors: request.outputConnectors,
            colorName: request.destination == .space ? "purple" : "blue",
            placement: request.destination == .space ? VoicePlacement() : nil
        )
    }

    private static func makeNodes(
        request: StudioPatchDraft.PersistedRequest,
        endpoint: StudioEndpoint,
        equipmentByID: [Equipment.ID: Equipment],
        effectsByID: [Effect.ID: Effect],
        currentGraph: StudioGraph
    ) -> [StudioDraftNode] {
        var result: [StudioDraftNode] = []
        var placements = currentGraph.nodes.map { node in
            let lane: StudioCanvasGeometry.Lane = if case .endpoint = node.kind { .controls } else { .gear }
            return StudioCanvasGeometry.Placement(position: node.position, lane: lane)
        }
        func append(kind: StudioNodeKind, title: String, lane: StudioCanvasGeometry.Lane) {
            let spec = node(
                kind: kind, title: title,
                position: StudioCanvasGeometry.firstFreePosition(in: lane, avoiding: placements),
                currentGraph: currentGraph
            )
            result.append(spec)
            if !spec.reusesExistingNode {
                placements.append(StudioCanvasGeometry.Placement(position: spec.node.position, lane: lane))
            }
        }
        for id in request.sourceInstrumentIDs {
            guard let equipment = equipmentByID[id] else { continue }
            append(kind: .instrument(id), title: equipment.name, lane: .gear)
        }
        for id in request.effectChainIDs {
            guard let effect = effectsByID[id] else { continue }
            append(kind: .effect(id), title: effect.name, lane: .gear)
        }
        append(kind: .endpoint(endpoint.id), title: endpoint.name, lane: .controls)
        return result
    }

    private static func node(
        kind: StudioNodeKind,
        title: String,
        position: CGPoint,
        currentGraph: StudioGraph
    ) -> StudioDraftNode {
        if let existing = currentGraph.nodes.first(where: { $0.kind == kind }) {
            return StudioDraftNode(
                reference: "existing:\(existing.id.uuidString)",
                node: existing,
                reusesExistingNode: true
            )
        }
        let reference = reference(for: kind)
        return StudioDraftNode(
            reference: reference,
            node: StudioNode(id: stableUUID(reference), kind: kind, title: title, position: position),
            reusesExistingNode: false
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func makeEdges(
        signature: String,
        sourceIDs: [Equipment.ID],
        effectIDs: [Effect.ID],
        includesDrySignal: Bool,
        endpointID: StudioEndpoint.ID,
        nodes: [StudioDraftNode]
    ) -> [StudioDraftEdge] {
        let byKind = Dictionary(nodes.map { ($0.node.kind, $0) }, uniquingKeysWith: { first, _ in first })
        let destinationKind = effectIDs.first.map(StudioNodeKind.effect) ?? .endpoint(endpointID)
        var pairs: [(StudioNodeKind, StudioNodeKind)] = sourceIDs.map {
            (.instrument($0), destinationKind)
        }
        if includesDrySignal, !effectIDs.isEmpty {
            pairs.append(contentsOf: sourceIDs.map {
                (.instrument($0), .endpoint(endpointID))
            })
        }
        for (index, effectID) in effectIDs.enumerated() {
            let next = effectIDs.indices.contains(index + 1)
                ? StudioNodeKind.effect(effectIDs[index + 1])
                : .endpoint(endpointID)
            pairs.append((.effect(effectID), next))
        }
        return pairs.compactMap { fromKind, toKind in
            guard let from = byKind[fromKind]?.node, let to = byKind[toKind]?.node else { return nil }
            let reference = "edge:\(reference(for: fromKind))->\(reference(for: toKind))|\(signature)"
            return StudioDraftEdge(
                reference: reference,
                edge: StudioEdge(
                    id: stableUUID(reference),
                    from: StudioPortRef(nodeID: from.id, side: .output, port: 0),
                    to: StudioPortRef(nodeID: to.id, side: .input, port: 0)
                )
            )
        }
    }

    private static func validate(
        request: StudioPatchDraft.PersistedRequest,
        equipmentByID: [Equipment.ID: Equipment],
        effectsByID: [Effect.ID: Effect],
        connections: GlobalStudioConnections,
        currentEnvironmentID: RoutingEnvironment.ID?
    ) -> [StudioDraftValidationIssue] {
        var issues: [StudioDraftValidationIssue] = []
        if request.environmentID != currentEnvironmentID {
            issues.append(.error(
                "environment-changed",
                "This draft belongs to a different Studio environment."
            ))
        }
        if request.sourceInstrumentIDs.isEmpty {
            issues.append(.error("no-sources", "Choose at least one source instrument."))
        }
        for id in request.sourceInstrumentIDs where equipmentByID[id] == nil {
            issues.append(.error("missing-source-\(id)", "A selected source instrument no longer exists."))
        }
        for id in request.effectChainIDs where effectsByID[id] == nil {
            issues.append(.error("missing-effect-\(id)", "A selected effect no longer exists in this environment."))
        }
        let resolver = StudioPhysicalResolver(
            connections: connections.effectiveHome,
            equipment: Array(equipmentByID.values)
        )
        for id in request.sourceInstrumentIDs where equipmentByID[id] != nil {
            for issue in resolver.instrumentChannels(id).issues {
                issues.append(.error("source-\(id)-\(issue.id)", issue.message))
            }
        }
        for id in request.effectChainIDs {
            guard let effect = effectsByID[id] else { continue }
            for issue in resolver.effectJacks(effect).issues {
                issues.append(.error("effect-\(id)-\(issue.id)", issue.message))
            }
        }
        for issue in resolver.structuralIssues() {
            issues.append(.error("connections-\(issue.id)", issue.message))
        }
        return uniqueIssues(issues)
    }

    private static func cableInstructions(
        request: StudioPatchDraft.PersistedRequest,
        equipmentByID: [Equipment.ID: Equipment],
        effectsByID: [Effect.ID: Effect],
        connections: GlobalStudioConnections
    ) -> [StudioCableInstruction] {
        let effective = connections.effectiveHome
        let equipment = Array(equipmentByID.values)
        let activeMoveIDs = Set(connections.temporaryMoves.filter(\.lifecycle.isEffective).map(\.equipmentID))
        var instructions: [StudioCableInstruction] = []
        let effectEquipment = Set(request.effectChainIDs.compactMap { effectsByID[$0]?.equipmentID })
        let inputEquipment = Set(request.sourceInstrumentIDs).union(effectEquipment)
        for connection in effective.inputs where inputEquipment.contains(connection.equipmentID) {
            let label = connection.label(equipment: equipment)
            let moved = activeMoveIDs.contains(connection.equipmentID)
            instructions.append(StudioCableInstruction(
                id: "input-\(connection.connector)-\(connection.equipmentID)-\(connection.outputPort)",
                connectorKind: .wingInput,
                connector: connection.connector,
                configuredLabel: AssistantUntrustedText(label),
                instruction: AssistantUntrustedText(
                    "\(moved ? "Active Temporary Move: " : "")connect \(label) to WING input \(connection.connector)."
                ),
                usesActiveTemporaryMove: moved
            ))
        }
        for connection in effective.outputs {
            guard let equipmentID = connection.equipmentID,
                  effectEquipment.contains(equipmentID) else { continue }
            let label = connection.label(equipment: equipment)
            let moved = activeMoveIDs.contains(equipmentID)
            instructions.append(StudioCableInstruction(
                id: "output-\(connection.bank.rawValue)-\(connection.connector)-\(equipmentID)-"
                    + "\(connection.inputPort ?? -1)",
                connectorKind: .wingOutput,
                connector: connection.connector,
                configuredLabel: AssistantUntrustedText(label),
                instruction: AssistantUntrustedText(
                    "\(moved ? "Active Temporary Move: " : "")connect "
                        + "\(connection.outputConnector.label) to \(label)."
                ),
                usesActiveTemporaryMove: moved
            ))
        }
        if request.destination == .finalMix {
            for connection in mainSpeakerOutputs(in: effective) {
                let label = connection.label(equipment: equipment)
                instructions.append(StudioCableInstruction(
                    id: "destination-\(connection.bank.rawValue)-\(connection.connector)",
                    connectorKind: .wingOutput,
                    connector: connection.connector,
                    configuredLabel: AssistantUntrustedText(label),
                    instruction: AssistantUntrustedText(
                        "\(connection.outputConnector.label) feeds \(label)."
                    ),
                    usesActiveTemporaryMove: false
                ))
            }
        }
        return instructions.sorted {
            ($0.connectorKind.rawValue, $0.connector, $0.id) < ($1.connectorKind.rawValue, $1.connector, $1.id)
        }
    }

    private static func routingSummary(
        request: StudioPatchDraft.PersistedRequest,
        equipmentByID: [Equipment.ID: Equipment],
        effectsByID: [Effect.ID: Effect],
        endpoint: StudioEndpoint
    ) -> [AssistantUntrustedText] {
        let sources = request.sourceInstrumentIDs.compactMap { equipmentByID[$0]?.name }
        let effects = request.effectChainIDs.compactMap { effectsByID[$0]?.name }
        let source = sources.isEmpty ? "Missing source" : sources.joined(separator: " + ")
        let path = [source]
            + effects
            + [endpoint.name]
        if request.includesDrySignal, !effects.isEmpty {
            return [
                AssistantUntrustedText("\(source) → \(endpoint.name)"),
                AssistantUntrustedText(path.joined(separator: " → "))
            ]
        }
        return [AssistantUntrustedText(path.joined(separator: " → "))]
    }

    private static func reference(for kind: StudioNodeKind) -> String {
        switch kind {
        case .instrument(let id): "instrument:\(id.uuidString)"
        case .effect(let id): "effect:\(id.uuidString)"
        case .endpoint(let id): "endpoint:\(id.uuidString)"
        }
    }

    private static func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniqueIssues(_ issues: [StudioDraftValidationIssue]) -> [StudioDraftValidationIssue] {
        var seen: Set<String> = []
        return issues
            .filter { seen.insert($0.code).inserted }
            .sorted { $0.code < $1.code }
    }

    private static func mainSpeakerName(in connections: StudioHomeConnections) -> String? {
        mainSpeakerOutputs(in: connections).compactMap(\.destinationName).first.map {
            $0.replacingOccurrences(of: " L", with: "")
                .replacingOccurrences(of: " R", with: "")
        }
    }

    private static func customOutputName(
        connectors: [WingOutputConnector],
        connections: StudioHomeConnections
    ) -> String? {
        let connectorSet = Set(connectors)
        let names = connections.outputs.compactMap { output -> String? in
            guard connectorSet.contains(output.outputConnector),
                  let name = output.destinationName else { return nil }
            let suffixes = [" left", " right", " l", " r"]
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in suffixes where trimmed.lowercased().hasSuffix(suffix) {
                return String(trimmed.dropLast(suffix.count))
            }
            return trimmed
        }
        return names.first
    }

    private static func mainSpeakerOutputs(
        in connections: StudioHomeConnections
    ) -> [StudioOutputConnection] {
        connections.outputs.filter {
            $0.destinationName?.localizedCaseInsensitiveContains("main speaker") == true
        }.sorted {
            ($0.bank.rawValue, $0.connector) < ($1.bank.rawValue, $1.connector)
        }
    }

    private static func stableUUID(_ value: String) -> UUID {
        let bytes = Array(value.utf8)
        var high: UInt64 = 0xcbf29ce484222325
        var low: UInt64 = 0x84222325cbf29ce4
        for byte in bytes {
            high = (high ^ UInt64(byte)) &* 0x100000001b3
            low = (low ^ UInt64(byte)) &* 0x100000001b3
        }
        var raw = withUnsafeBytes(of: high.bigEndian, Array.init)
            + withUnsafeBytes(of: low.bigEndian, Array.init)
        raw[6] = (raw[6] & 0x0f) | 0x50
        raw[8] = (raw[8] & 0x3f) | 0x80
        return UUID(uuid: (
            raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
            raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]
        ))
    }
}

private extension StudioDraftValidationIssue {
    static func error(_ code: String, _ message: String) -> StudioDraftValidationIssue {
        StudioDraftValidationIssue(
            code: code,
            severity: .error,
            message: AssistantUntrustedText(message).value
        )
    }
}
