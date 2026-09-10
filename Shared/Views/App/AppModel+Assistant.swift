import Foundation

extension AppModel {
    /// A transport-free snapshot for typed assistant tools. The coordinator
    /// cannot access `WingController`; only this value projection crosses the
    /// boundary.
    func assistantToolContext() -> AssistantToolContext {
        let compiled = studioCompiledRouting()
        let routingIssues = studioRoutingPlan().issues.map { AssistantUntrustedText($0.message) }
        let resourcePlan = studioResourcePlan()
        let resourceIssues = resourcePlan.issues.map { AssistantUntrustedText($0.message) }
        let compileIssues = compiled.issues.map { AssistantUntrustedText($0.message) }
        return AssistantToolContext(
            currentScreen: AssistantScreen(section),
            connection: AssistantConnectionState(wing.connection, isDemo: isDemo),
            equipment: equipment.items,
            homeConnections: studioConnections.connections.home,
            effectiveConnections: studioConnections.connections.effectiveHome,
            activeMoves: studioConnections.connections.temporaryMoves.filter(\.lifecycle.isEffective),
            environments: environments.environments,
            activeEnvironmentID: environments.activeID,
            presets: presets.presets,
            resources: resourcePlan.allocations.map {
                AssistantResourceSummary(
                    endpointID: $0.endpoint.id,
                    endpointName: AssistantUntrustedText($0.endpoint.name),
                    controlReference: $0.controlNode.defaultLabel
                )
            },
            validationIssues: routingIssues + resourceIssues + compileIssues,
            graph: environments.activeStudioGraph,
            endpoints: environments.activeStudioEndpoints,
            effects: environments.activeEffects,
            globalConnections: studioConnections.connections
        )
    }

    /// Appends a reviewed draft to the active semantic graph. This method never
    /// calls `wing` or compiles/applies settings; Listen remains the only Studio
    /// hardware-write action.
    @discardableResult
    func acceptPendingAssistantDraft() async -> StudioPatchMergeResult? {
        guard let draft = assistant.pendingStudioDraft else { return nil }
        let refreshed = StudioWiringAdvisor.revalidate(
            draft,
            equipment: equipment.items,
            effects: environments.activeEffects,
            connections: studioConnections.connections,
            currentGraph: environments.activeStudioGraph,
            currentEnvironmentID: environments.activeID
        )
        guard !refreshed.hasErrors else { return nil }
        let result = StudioPatchDraftMerger.merge(
            refreshed,
            into: environments.activeStudioGraph,
            endpoints: environments.activeStudioEndpoints,
            equipment: equipment.items,
            effects: environments.activeEffects
        )
        environments.replaceStudio(graph: result.graph, endpoints: result.endpoints)
        await assistant.discardPendingStudioDraft()
        return result
    }
}

private extension AssistantScreen {
    init(_ section: AppSection) {
        switch section {
        case .studio: self = .studio
        case .mix: self = .mix
        case .patchbay: self = .routing
        case .connection: self = .connection
        case .tutorial: self = .learn
        case .advanced: self = .compatibility
        }
    }
}

private extension AssistantConnectionState {
    init(_ connection: WingConnectionState, isDemo: Bool) {
        self.isDemo = isDemo
        switch connection {
        case .disconnected:
            status = .disconnected
            detail = nil
        case .connecting:
            status = .connecting
            detail = nil
        case .connected(let name):
            status = .connected
            detail = name.map(AssistantUntrustedText.init)
        case .failed(let reason):
            status = .failed
            detail = AssistantUntrustedText(reason)
        }
    }
}
