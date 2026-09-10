import CoreGraphics
import Foundation

struct StudioWiringRequest: Hashable, Sendable {
    var sourceInstrumentIDs: [Equipment.ID]
    var effectChainIDs: [Effect.ID]
    var destination: StudioEndpointDestination

    init(
        sourceInstrumentIDs: [Equipment.ID],
        effectChainIDs: [Effect.ID] = [],
        destination: StudioEndpointDestination = .finalMix
    ) {
        self.sourceInstrumentIDs = sourceInstrumentIDs
        self.effectChainIDs = effectChainIDs
        self.destination = destination
    }
}

struct StudioPatchDraft: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var createdAt: Date
    var request: PersistedRequest
    var fragment: StudioGraphFragment
    var cableInstructions: [StudioCableInstruction]
    var logicalRoutingSummary: [AssistantUntrustedText]
    var validation: [StudioDraftValidationIssue]

    var hasErrors: Bool { validation.contains { $0.severity == .error } }

    struct PersistedRequest: Codable, Hashable, Sendable {
        var environmentID: RoutingEnvironment.ID?
        var sourceInstrumentIDs: [Equipment.ID]
        var effectChainIDs: [Effect.ID]
        var destination: StudioEndpointDestination
    }
}

struct StudioGraphFragment: Codable, Hashable, Sendable {
    var nodes: [StudioDraftNode]
    var edges: [StudioDraftEdge]
    var endpoints: [StudioEndpoint]
}

struct StudioDraftNode: Identifiable, Codable, Hashable, Sendable {
    var reference: String
    var node: StudioNode
    var reusesExistingNode: Bool

    var id: String { reference }
}

struct StudioDraftEdge: Identifiable, Codable, Hashable, Sendable {
    var reference: String
    var edge: StudioEdge

    var id: String { reference }
}

struct StudioCableInstruction: Identifiable, Codable, Hashable, Sendable {
    enum ConnectorKind: String, Codable, Hashable, Sendable {
        case wingInput
        case wingOutput
    }

    var id: String
    var connectorKind: ConnectorKind
    var connector: Int
    var configuredLabel: AssistantUntrustedText
    var instruction: AssistantUntrustedText
    var usesActiveTemporaryMove: Bool
}

struct StudioDraftValidationIssue: Identifiable, Codable, Hashable, Sendable {
    enum Severity: String, Codable, Hashable, Sendable {
        case warning
        case error
    }

    var code: String
    var severity: Severity
    var message: String

    var id: String { code }
}

struct StudioPatchMergeResult: Hashable, Sendable {
    var graph: StudioGraph
    var endpoints: [StudioEndpoint]
    var addedNodeCount: Int
    var addedEdgeCount: Int
}

enum StudioWiringAdvisor {
    static func build(
        request: StudioWiringRequest,
        equipment: [Equipment],
        effects: [Effect],
        connections: GlobalStudioConnections,
        currentGraph: StudioGraph,
        environmentID: RoutingEnvironment.ID? = nil
    ) -> StudioPatchDraft {
        let persistedRequest = StudioPatchDraft.PersistedRequest(
            environmentID: environmentID,
            sourceInstrumentIDs: orderedUnique(request.sourceInstrumentIDs),
            effectChainIDs: orderedUnique(request.effectChainIDs),
            destination: request.destination
        )
        let signature = [
            environmentID?.uuidString ?? "no-environment",
            persistedRequest.sourceInstrumentIDs.map(\.uuidString).joined(separator: ","),
            persistedRequest.effectChainIDs.map(\.uuidString).joined(separator: ","),
            persistedRequest.destination.rawValue
        ].joined(separator: "|")
        let equipmentByID = Dictionary(equipment.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let effectsByID = Dictionary(effects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let endpoint = makeEndpoint(signature: signature, request: persistedRequest, equipmentByID: equipmentByID)
        let nodeSpecs = makeNodes(
            request: persistedRequest,
            endpoint: endpoint,
            equipmentByID: equipmentByID,
            effectsByID: effectsByID,
            currentGraph: currentGraph
        )
        let edges = makeEdges(
            signature: signature,
            sourceIDs: persistedRequest.sourceInstrumentIDs,
            effectIDs: persistedRequest.effectChainIDs,
            endpointID: endpoint.id,
            nodes: nodeSpecs
        )
        let validation = validate(
            request: persistedRequest,
            equipmentByID: equipmentByID,
            effectsByID: effectsByID,
            connections: connections,
            currentEnvironmentID: environmentID
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
            validation: validation
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
        var refreshed = build(
            request: StudioWiringRequest(
                sourceInstrumentIDs: draft.request.sourceInstrumentIDs,
                effectChainIDs: draft.request.effectChainIDs,
                destination: draft.request.destination
            ),
            equipment: equipment,
            effects: effects,
            connections: connections,
            currentGraph: currentGraph,
            environmentID: draft.request.environmentID
        )
        refreshed.createdAt = draft.createdAt
        refreshed.validation = validate(
            request: draft.request,
            equipmentByID: Dictionary(equipment.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            effectsByID: Dictionary(effects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            connections: connections,
            currentEnvironmentID: currentEnvironmentID
        )
        return refreshed
    }

    private static func makeEndpoint(
        signature: String,
        request: StudioPatchDraft.PersistedRequest,
        equipmentByID: [Equipment.ID: Equipment]
    ) -> StudioEndpoint {
        let sourceNames = request.sourceInstrumentIDs.compactMap { equipmentByID[$0]?.name }
        let prefix = sourceNames.isEmpty ? "Studio" : sourceNames.joined(separator: " + ")
        let suffix = request.destination == .space ? "Space" : "Mix"
        return StudioEndpoint(
            id: stableUUID("endpoint|\(signature)"),
            name: "\(prefix) \(suffix)",
            destination: request.destination,
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
        for (index, id) in request.sourceInstrumentIDs.enumerated() {
            guard let equipment = equipmentByID[id] else { continue }
            result.append(node(
                kind: .instrument(id),
                title: equipment.name,
                position: CGPoint(x: 120, y: 100 + index * 110),
                currentGraph: currentGraph
            ))
        }
        for (index, id) in request.effectChainIDs.enumerated() {
            guard let effect = effectsByID[id] else { continue }
            result.append(node(
                kind: .effect(id),
                title: effect.name,
                position: CGPoint(x: 360 + index * 190, y: 160),
                currentGraph: currentGraph
            ))
        }
        result.append(node(
            kind: .endpoint(endpoint.id),
            title: endpoint.name,
            position: CGPoint(x: 650 + request.effectChainIDs.count * 190, y: 160),
            currentGraph: currentGraph
        ))
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

    private static func makeEdges(
        signature: String,
        sourceIDs: [Equipment.ID],
        effectIDs: [Effect.ID],
        endpointID: StudioEndpoint.ID,
        nodes: [StudioDraftNode]
    ) -> [StudioDraftEdge] {
        let byKind = Dictionary(nodes.map { ($0.node.kind, $0) }, uniquingKeysWith: { first, _ in first })
        let destinationKind = effectIDs.first.map(StudioNodeKind.effect) ?? .endpoint(endpointID)
        var pairs: [(StudioNodeKind, StudioNodeKind)] = sourceIDs.map {
            (.instrument($0), destinationKind)
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
        let activeMoveIDs = Set(connections.temporaryMoves.filter(\.lifecycle.isEffective).map(\.equipmentID))
        var instructions: [StudioCableInstruction] = []
        let relevantEquipment = Set(request.sourceInstrumentIDs + request.effectChainIDs.compactMap {
            effectsByID[$0]?.equipmentID
        })
        for connection in effective.inputs where relevantEquipment.contains(connection.equipmentID) {
            let label = connection.label(equipment: Array(equipmentByID.values))
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
        for connection in effective.outputs where relevantEquipment.contains(connection.equipmentID) {
            let label = connection.label(equipment: Array(equipmentByID.values))
            let moved = activeMoveIDs.contains(connection.equipmentID)
            instructions.append(StudioCableInstruction(
                id: "output-\(connection.connector)-\(connection.equipmentID)-\(connection.inputPort)",
                connectorKind: .wingOutput,
                connector: connection.connector,
                configuredLabel: AssistantUntrustedText(label),
                instruction: AssistantUntrustedText(
                    "\(moved ? "Active Temporary Move: " : "")connect WING output \(connection.connector) to \(label)."
                ),
                usesActiveTemporaryMove: moved
            ))
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
        let path = (sources.isEmpty ? ["Missing source"] : [sources.joined(separator: " + ")])
            + effects
            + [endpoint.name]
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
        return issues.filter { seen.insert($0.code).inserted }
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
        StudioDraftValidationIssue(code: code, severity: .error, message: message)
    }
}
