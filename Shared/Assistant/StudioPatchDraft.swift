import Foundation

struct StudioWiringRoute: Codable, Hashable, Sendable {
    var sourceInstrumentIDs: [Equipment.ID]
    var effectChainIDs: [Effect.ID]
    var destination: StudioEndpointDestination
    var includesDrySignal: Bool
    var outputConnectors: [WingOutputConnector]?

    init(
        sourceInstrumentIDs: [Equipment.ID],
        effectChainIDs: [Effect.ID] = [],
        destination: StudioEndpointDestination,
        includesDrySignal: Bool = false,
        outputConnectors: [WingOutputConnector]? = nil
    ) {
        self.sourceInstrumentIDs = sourceInstrumentIDs
        self.effectChainIDs = effectChainIDs
        self.destination = destination
        self.includesDrySignal = includesDrySignal
        self.outputConnectors = outputConnectors
    }
}

struct StudioWiringRequest: Hashable, Sendable {
    var sourceInstrumentIDs: [Equipment.ID]
    var effectChainIDs: [Effect.ID]
    var destination: StudioEndpointDestination
    var includesDrySignal: Bool
    var outputConnectors: [WingOutputConnector]?
    var additionalRoutes: [StudioWiringRoute]
    var applicationMode: StudioDraftApplicationMode
    var liveReferences: [AssistantLiveReference] = []
    var outputReferences: [AssistantRoutingOutputReference] = []

    init(
        sourceInstrumentIDs: [Equipment.ID],
        effectChainIDs: [Effect.ID] = [],
        destination: StudioEndpointDestination = .finalMix,
        includesDrySignal: Bool = false,
        outputConnectors: [WingOutputConnector]? = nil,
        additionalRoutes: [StudioWiringRoute] = [],
        applicationMode: StudioDraftApplicationMode = .append
    ) {
        self.sourceInstrumentIDs = sourceInstrumentIDs
        self.effectChainIDs = effectChainIDs
        self.destination = destination
        self.includesDrySignal = includesDrySignal
        self.outputConnectors = outputConnectors
        self.additionalRoutes = additionalRoutes
        self.applicationMode = applicationMode
    }
}

enum StudioDraftApplicationMode: String, Codable, Hashable, Sendable {
    case append
    case replace
}

struct StudioPatchRequest: Codable, Hashable, Sendable {
    var environmentID: RoutingEnvironment.ID?
    var sourceInstrumentIDs: [Equipment.ID]
    var effectChainIDs: [Effect.ID]
    var destination: StudioEndpointDestination
    var includesDrySignal: Bool
    var outputConnectors: [WingOutputConnector]?
    var additionalRoutes: [StudioWiringRoute]

    private enum CodingKeys: String, CodingKey {
        case environmentID, sourceInstrumentIDs, effectChainIDs, destination, includesDrySignal
        case outputConnectors, additionalRoutes
    }

    init(
        environmentID: RoutingEnvironment.ID?,
        sourceInstrumentIDs: [Equipment.ID],
        effectChainIDs: [Effect.ID],
        destination: StudioEndpointDestination,
        includesDrySignal: Bool = false,
        outputConnectors: [WingOutputConnector]? = nil,
        additionalRoutes: [StudioWiringRoute] = []
    ) {
        self.environmentID = environmentID
        self.sourceInstrumentIDs = sourceInstrumentIDs
        self.effectChainIDs = effectChainIDs
        self.destination = destination
        self.includesDrySignal = includesDrySignal
        self.outputConnectors = outputConnectors
        self.additionalRoutes = additionalRoutes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environmentID = try container.decodeIfPresent(RoutingEnvironment.ID.self, forKey: .environmentID)
        sourceInstrumentIDs = try container.decode([Equipment.ID].self, forKey: .sourceInstrumentIDs)
        effectChainIDs = try container.decode([Effect.ID].self, forKey: .effectChainIDs)
        destination = try container.decode(StudioEndpointDestination.self, forKey: .destination)
        includesDrySignal = try container.decodeIfPresent(Bool.self, forKey: .includesDrySignal) ?? false
        outputConnectors = try container.decodeIfPresent(
            [WingOutputConnector].self,
            forKey: .outputConnectors
        )
        additionalRoutes = try container.decodeIfPresent(
            [StudioWiringRoute].self,
            forKey: .additionalRoutes
        ) ?? []
    }
}

struct StudioPatchDraft: Identifiable, Codable, Hashable, Sendable {
    typealias PersistedRequest = StudioPatchRequest

    var id: UUID
    var createdAt: Date
    var request: PersistedRequest
    var fragment: StudioGraphFragment
    var cableInstructions: [StudioCableInstruction]
    var logicalRoutingSummary: [AssistantUntrustedText]
    var validation: [StudioDraftValidationIssue]
    var applicationMode: StudioDraftApplicationMode
    var liveReferences: [AssistantLiveReference]?
    var outputReferences: [AssistantRoutingOutputReference]?
    var nameReferences: [AssistantRoutingNameReference]?
    var hasErrors: Bool { validation.contains { $0.severity == .error } }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, request, fragment, cableInstructions, logicalRoutingSummary, validation
        case applicationMode, liveReferences, outputReferences, nameReferences
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        request = try container.decode(PersistedRequest.self, forKey: .request)
        fragment = try container.decode(StudioGraphFragment.self, forKey: .fragment)
        cableInstructions = try container.decodeIfPresent(
            [StudioCableInstruction].self,
            forKey: .cableInstructions
        ) ?? []
        logicalRoutingSummary = try container.decodeIfPresent(
            [AssistantUntrustedText].self,
            forKey: .logicalRoutingSummary
        ) ?? []
        validation = try container.decodeIfPresent(
            [StudioDraftValidationIssue].self,
            forKey: .validation
        ) ?? []
        liveReferences = try container.decodeIfPresent([AssistantLiveReference].self, forKey: .liveReferences)
        outputReferences = try container.decodeIfPresent(
            [AssistantRoutingOutputReference].self, forKey: .outputReferences)
        nameReferences = try container.decodeIfPresent(
            [AssistantRoutingNameReference].self, forKey: .nameReferences)
        applicationMode = try container.decodeIfPresent(
            StudioDraftApplicationMode.self,
            forKey: .applicationMode
        ) ?? .append
    }

    init(
        id: UUID,
        createdAt: Date,
        request: PersistedRequest,
        fragment: StudioGraphFragment,
        cableInstructions: [StudioCableInstruction],
        logicalRoutingSummary: [AssistantUntrustedText],
        validation: [StudioDraftValidationIssue],
        applicationMode: StudioDraftApplicationMode = .append
    ) {
        self.id = id
        self.createdAt = createdAt
        self.request = request
        self.fragment = fragment
        self.cableInstructions = cableInstructions
        self.logicalRoutingSummary = logicalRoutingSummary
        self.validation = validation
        self.applicationMode = applicationMode
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
