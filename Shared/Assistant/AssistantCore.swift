import Foundation
import Observation

struct AssistantUntrustedText: Codable, Hashable, Sendable, CustomStringConvertible {
    let value: String

    init(_ value: String) {
        self.value = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }.prefix(512))
    }

    var description: String { value }
}

enum AssistantScreen: String, Codable, CaseIterable, Hashable, Sendable {
    case studio, assistant, mix, routing, connection, learn, compatibility
}

struct AssistantConnectionState: Hashable, Sendable {
    enum Status: String, Hashable, Sendable {
        case disconnected, connecting, connected, failed
    }

    var status: Status
    var detail: AssistantUntrustedText?
    var isDemo: Bool
}

struct AssistantResourceSummary: Identifiable, Hashable, Sendable {
    var endpointID: StudioEndpoint.ID
    var endpointName: AssistantUntrustedText
    var controlReference: String
    var id: StudioEndpoint.ID { endpointID }
}

struct AssistantToolContext: Sendable {
    var currentScreen: AssistantScreen
    var connection: AssistantConnectionState
    var equipment: [Equipment]
    var homeConnections: StudioHomeConnections
    var effectiveConnections: StudioHomeConnections
    var activeMoves: [TemporaryDeviceMove]
    var environments: [RoutingEnvironment]
    var activeEnvironmentID: RoutingEnvironment.ID?
    var presets: [Preset]
    var resources: [AssistantResourceSummary]
    var validationIssues: [AssistantUntrustedText]
    var graph: StudioGraph
    var endpoints: [StudioEndpoint]
    var effects: [Effect]
    var globalConnections: GlobalStudioConnections
}

enum AssistantNavigationTarget: Hashable, Sendable {
    case reviewPendingDraft
    case help(AssistantHelpTopic)
}

enum AssistantHelpTopic: String, Codable, CaseIterable, Hashable, Sendable {
    case studio
    case mix
    case routing
    case connection
    case environments
    case presets
    case temporaryMoves
    case validation
    case resources
}

struct FluxKlangHelpEntry: Identifiable, Hashable, Sendable {
    var topic: AssistantHelpTopic
    var title: String
    var overview: String
    var errorGuidance: [String]
    var id: AssistantHelpTopic { topic }
}

enum FluxKlangHelpCatalog {
    static let entries: [FluxKlangHelpEntry] = [
        .init(
            topic: .studio,
            title: "Studio",
            overview: "Build semantic instrument, effect, and Mix or Space paths, then review before listening.",
            errorGuidance: ["Unfinished branches are safe to keep; only complete valid branches can be compiled."]
        ),
        .init(
            topic: .mix,
            title: "Mix",
            overview: "Control generated faders and scenes without changing the physical cable map.",
            errorGuidance: ["A disabled control usually means the WING is disconnected or the resource is unavailable."]
        ),
        .init(
            topic: .routing,
            title: "Routing",
            overview: "Inspect channel inputs, physical outputs, and routing snapshots.",
            errorGuidance: ["Resolve duplicate or missing connector assignments in Settings before applying routing."]
        ),
        .init(
            topic: .connection,
            title: "Connection",
            overview: "Connect to a WING or enter offline Demo Mode.",
            errorGuidance: ["Failed connections preserve local Studio data; reconnect before using Listen."]
        ),
        .init(
            topic: .environments,
            title: "Environments",
            overview: "Each environment owns its effects, semantic Studio graph, and spatial placements.",
            errorGuidance: ["Missing linked Equipment prevents an outboard effect from resolving physical jacks."]
        ),
        .init(
            topic: .presets,
            title: "Presets",
            overview: "Presets capture mixer settings; routing snapshots capture patching separately.",
            errorGuidance: ["Recall writes to the console and therefore requires an active connection."]
        ),
        .init(
            topic: .temporaryMoves,
            title: "Temporary Moves",
            overview: "Active moves overlay Home connectors without changing the saved Home cable map.",
            errorGuidance: ["Return moved equipment Home before editing an affected Home assignment."]
        ),
        .init(
            topic: .validation,
            title: "Validation",
            overview: "Studio validation reports missing gear, incomplete branches, cycles, and connector conflicts.",
            errorGuidance: ["Errors block acceptance or listening; warnings can describe incomplete ideas."]
        ),
        .init(
            topic: .resources,
            title: "Resources",
            overview: "FluxKlang allocates endpoint buses after reserving speaker and effect buses.",
            errorGuidance: ["Remove or simplify endpoints when no free bus remains."]
        )
    ]

    static func entry(for topic: AssistantHelpTopic) -> FluxKlangHelpEntry {
        entries.first { $0.topic == topic } ?? entries[0]
    }
}

enum AssistantTool: Hashable, Sendable {
    case describeCurrentScreen
    case inspectConnectionState
    case listEquipment
    case listHomeConnections
    case listEffectiveConnections
    case listActiveMoves
    case listEnvironments
    case listPresets
    case listResources
    case explainValidationIssues
    case inspectStudioGraph
    case buildStudioDraft(StudioWiringRequest)
    case validatePendingStudioDraft
    case openReview
    case openHelp(AssistantHelpTopic)
}

enum AssistantGrounding: String, Hashable, Sendable {
    case currentScreen
    case connectionState
    case equipment
    case homeConnections
    case effectiveConnections
    case activeMoves
    case environments
    case presets
    case resources
    case validation
    case studioGraph
    case pendingDraft
    case help
}

enum AssistantToolResult: Sendable {
    case currentScreen(AssistantScreen)
    case connectionState(AssistantConnectionState)
    case equipment([Equipment])
    case homeConnections(StudioHomeConnections)
    case effectiveConnections(StudioHomeConnections)
    case activeMoves([TemporaryDeviceMove])
    case environments([RoutingEnvironment])
    case presets([Preset])
    case resources([AssistantResourceSummary])
    case validationIssues([AssistantUntrustedText])
    case studioGraph(StudioGraph)
    case pendingDraft(StudioPatchDraft?)
    case help(FluxKlangHelpEntry)
    case navigation(AssistantNavigationTarget)

    var grounding: AssistantGrounding {
        switch self {
        case .currentScreen: .currentScreen
        case .connectionState: .connectionState
        case .equipment: .equipment
        case .homeConnections: .homeConnections
        case .effectiveConnections: .effectiveConnections
        case .activeMoves: .activeMoves
        case .environments: .environments
        case .presets: .presets
        case .resources: .resources
        case .validationIssues: .validation
        case .studioGraph: .studioGraph
        case .pendingDraft: .pendingDraft
        case .help: .help
        case .navigation(let target):
            switch target {
            case .reviewPendingDraft: .pendingDraft
            case .help: .help
            }
        }
    }
}

struct AssistantResponseRequest: Hashable, Sendable {
    var question: AssistantUntrustedText
    var requiredGrounding: Set<AssistantGrounding>

    static func catalog(_ question: String) -> AssistantResponseRequest {
        AssistantResponseRequest(question: AssistantUntrustedText(question), requiredGrounding: [.help])
    }

    static func live(_ question: String, requires grounding: Set<AssistantGrounding>) -> AssistantResponseRequest {
        AssistantResponseRequest(question: AssistantUntrustedText(question), requiredGrounding: grounding)
    }
}

enum AssistantResponseError: Error, Equatable {
    case missingGrounding(Set<AssistantGrounding>)
}

enum AssistantFallbackResponder {
    static func response(
        to request: AssistantResponseRequest,
        groundedBy results: [AssistantToolResult]
    ) throws -> String {
        let available = Set(results.map(\.grounding))
        let missing = request.requiredGrounding.subtracting(available)
        guard missing.isEmpty else { throw AssistantResponseError.missingGrounding(missing) }
        return results.compactMap(summary).joined(separator: "\n")
    }

    // The result enum is intentionally exhaustive so unsupported data cannot
    // silently enter fallback prose.
    // swiftlint:disable:next cyclomatic_complexity
    private static func summary(_ result: AssistantToolResult) -> String? {
        switch result {
        case .currentScreen(let screen):
            "Current screen: \(screen.rawValue)."
        case .connectionState(let state):
            "Connection: \(state.status.rawValue)\(state.isDemo ? " (Demo Mode)" : "")."
        case .equipment(let equipment):
            namedList("Equipment", names: equipment.map(\.name))
        case .homeConnections(let connections):
            "Home connections: \(connections.inputs.count) inputs and \(connections.outputs.count) outputs."
        case .effectiveConnections(let connections):
            "Effective connections: \(connections.inputs.count) inputs and \(connections.outputs.count) outputs."
        case .activeMoves(let moves):
            "Active Temporary Moves: \(moves.filter(\.lifecycle.isEffective).count)."
        case .environments(let environments):
            namedList("Environments", names: environments.map(\.name))
        case .presets(let presets):
            namedList("Presets", names: presets.map(\.name))
        case .resources(let resources):
            "Allocated Studio resources: \(resources.count)."
        case .validationIssues(let issues):
            issues.isEmpty ? "No current validation issues." : "Validation issues: \(issues.count)."
        case .studioGraph(let graph):
            "Current Studio graph: \(graph.nodes.count) nodes and \(graph.edges.count) wires."
        case .pendingDraft(let draft):
            draft.map {
                "Pending Studio draft: \($0.logicalRoutingSummary.map(\.value).joined(separator: "; "))."
            }
                ?? "There is no pending Studio draft."
        case .help(let entry):
            "\(entry.title): \(entry.overview)"
        case .navigation:
            nil
        }
    }

    private static func namedList(_ label: String, names: [String]) -> String {
        guard !names.isEmpty else { return "No \(label.lowercased())." }
        return "\(label): \(names.map(quoted).joined(separator: ", "))."
    }

    private static func quoted(_ value: String) -> String {
        "\"\(AssistantUntrustedText(value).value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

@MainActor
@Observable
final class AssistantCoordinator {
    private let draftStore: any PendingStudioPatchPersisting

    private(set) var pendingStudioDraft: StudioPatchDraft?
    var navigationTarget: AssistantNavigationTarget? {
        didSet {
            if navigationTarget == .reviewPendingDraft, pendingStudioDraft == nil {
                navigationTarget = nil
            }
        }
    }

    init(draftStore: any PendingStudioPatchPersisting = PendingStudioPatchStore()) {
        self.draftStore = draftStore
    }

    func load() async {
        pendingStudioDraft = await draftStore.load()
    }

    // Every supported capability is explicit and typed; there is no arbitrary
    // selector or transport escape hatch.
    // swiftlint:disable:next cyclomatic_complexity
    func perform(_ tool: AssistantTool, context: AssistantToolContext) async -> AssistantToolResult {
        switch tool {
        case .describeCurrentScreen:
            return .currentScreen(context.currentScreen)
        case .inspectConnectionState:
            return .connectionState(context.connection)
        case .listEquipment:
            return .equipment(context.equipment)
        case .listHomeConnections:
            return .homeConnections(context.homeConnections)
        case .listEffectiveConnections:
            return .effectiveConnections(context.effectiveConnections)
        case .listActiveMoves:
            return .activeMoves(context.activeMoves)
        case .listEnvironments:
            return .environments(context.environments)
        case .listPresets:
            return .presets(context.presets)
        case .listResources:
            return .resources(context.resources)
        case .explainValidationIssues:
            return .validationIssues(context.validationIssues)
        case .inspectStudioGraph:
            return .studioGraph(context.graph)
        case .buildStudioDraft(let request):
            let draft = StudioWiringAdvisor.build(
                request: request,
                equipment: context.equipment,
                effects: context.effects,
                connections: context.globalConnections,
                currentGraph: context.graph,
                environmentID: context.activeEnvironmentID
            )
            pendingStudioDraft = draft
            await draftStore.save(draft)
            return .pendingDraft(draft)
        case .validatePendingStudioDraft:
            guard let draft = pendingStudioDraft else { return .pendingDraft(nil) }
            let refreshed = StudioWiringAdvisor.revalidate(
                draft,
                equipment: context.equipment,
                effects: context.effects,
                connections: context.globalConnections,
                currentGraph: context.graph,
                currentEnvironmentID: context.activeEnvironmentID
            )
            pendingStudioDraft = refreshed
            await draftStore.save(refreshed)
            return .pendingDraft(refreshed)
        case .openReview:
            guard pendingStudioDraft != nil else {
                navigationTarget = nil
                return .pendingDraft(nil)
            }
            navigationTarget = .reviewPendingDraft
            return .navigation(.reviewPendingDraft)
        case .openHelp(let topic):
            navigationTarget = .help(topic)
            return .help(FluxKlangHelpCatalog.entry(for: topic))
        }
    }

    func discardPendingStudioDraft() async {
        pendingStudioDraft = nil
        navigationTarget = nil
        await draftStore.save(nil)
    }

    func clearNavigation() {
        navigationTarget = nil
    }
}
