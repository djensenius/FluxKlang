import Foundation

extension AppModel {
    /// A transport-free snapshot for typed assistant tools. The coordinator
    /// cannot access `WingController`; only this value projection crosses the
    /// boundary.
    func assistantToolContext() -> AssistantToolContext {
        let currentConnections = studioConnectionsForCurrentWing()
        let compiled = studioCompiledRouting(connections: currentConnections)
        let routingIssues = studioRoutingPlan().issues.map { AssistantUntrustedText($0.message) }
        let resourcePlan = studioResourcePlan()
        let resourceIssues = resourcePlan.issues.map { AssistantUntrustedText($0.message) }
        let compileIssues = compiled.issues.map { AssistantUntrustedText($0.message) }
        return AssistantToolContext(
            currentScreen: AssistantScreen(section),
            connection: AssistantConnectionState(wing.connection, isDemo: isDemo),
            equipment: equipment.items,
            homeConnections: currentConnections.home,
            effectiveConnections: currentConnections.effectiveHome,
            activeMoves: currentConnections.temporaryMoves.filter(\.lifecycle.isEffective),
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
            globalConnections: currentConnections,
            liveWing: AssistantLiveWingContext.project(wing.confirmedSnapshot(), equipment: equipment.items,
                                                       connections: currentConnections.effectiveHome)
        )
    }

    func studioConnectionsForCurrentWing() -> GlobalStudioConnections {
        // A console scribble is observation metadata, not authorization to move
        // cables or replace saved Home. Aliases use the effective saved port map.
        studioConnections.connections
    }

    /// Appends a reviewed draft to the active semantic graph. This method never
    /// applies settings; it only refreshes referenced metadata with bounded GETs.
    /// Listen remains the only Studio routing hardware-write action.
    @discardableResult
    func acceptPendingAssistantDraft() async -> StudioPatchMergeResult? {
        guard let original = assistant.pendingStudioDraft else { return nil }
        let controller = wing
        let refreshedReferences = await controller.refreshLiveReferences(original.liveReferences ?? [])
        guard refreshedReferences, !Task.isCancelled, wing === controller,
              assistant.pendingStudioDraft?.id == original.id else { return nil }
        let validation = await assistant.perform(
            .validatePendingStudioDraft,
            context: assistantToolContext()
        )
        guard case .pendingDraft(let refreshed?) = validation,
              !refreshed.hasErrors, !Task.isCancelled, wing === controller,
              assistant.pendingStudioDraft?.id == refreshed.id,
              (refreshed.liveReferences ?? []).allSatisfy({ $0.isValid(in: assistantToolContext().liveWing) })
        else { return nil }
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
        case .assistant: self = .assistant
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
