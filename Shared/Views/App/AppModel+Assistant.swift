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

    /// Review must refresh stale aliases before validation disables Accept.
    /// This is GET-only; acceptance still independently refreshes and validates.
    func refreshPendingAssistantDraftForReview() async {
        guard let original = assistant.pendingStudioDraft else { return }
        let controller = wing
        let refreshed = await controller.refreshLiveReferences(original.liveReferences ?? [])
        guard !Task.isCancelled, wing === controller, assistant.pendingStudioDraft?.id == original.id else { return }
        var context = assistantToolContext()
        if !refreshed { context.liveWing = .unavailable }
        _ = await assistant.perform(.validatePendingStudioDraft, context: context)
    }

    /// Appends a reviewed draft to the active semantic graph. This method never
    /// applies settings; it only refreshes referenced metadata with bounded GETs.
    /// Listen remains the only Studio routing hardware-write action.
    @discardableResult
    func acceptPendingAssistantDraft() async -> StudioPatchMergeResult? {
        await acceptPendingAssistantDraftResult().merge
    }

    /// Preserves legacy acceptance policy, including no-active-environment behavior.
    /// Once merged, cancellation cannot undo acceptance or stop local-save acknowledgement.
    /// The optional observer lets tests hold receipt consumption without substituting storage.
    func acceptPendingAssistantDraftResult(
        beforeAwaitingLocalSave: (@MainActor () async -> Void)? = nil
    ) async -> StudioDraftAcceptanceResult {
        // Held environments (#943) refuse acceptance: no merge, no save and no draft retirement.
        guard environments.hold == nil,
              let original = assistant.pendingStudioDraft, let publicationID = assistant.pendingPublicationID,
              assistant.canAcceptPendingDraft(hasActiveEnvironment: environments.active != nil) else {
            return .notAccepted
        }
        let controller = wing
        let refreshedReferences = await controller.refreshLiveReferences(original.liveReferences ?? [])
        guard refreshedReferences, !Task.isCancelled, wing === controller,
              assistant.pendingPublicationID == publicationID, assistant.pendingStudioDraft == original,
              assistant.canAcceptPendingDraft(hasActiveEnvironment: environments.active != nil) else {
            return .notAccepted
        }
        let validationContext = assistantToolContext()
        let validation = await assistant.perform(
            .validatePendingStudioDraft,
            context: validationContext
        )
        let currentContext = assistantToolContext()
        guard case .pendingDraft(let refreshed?) = validation, environments.hold == nil,
              !refreshed.hasErrors, !Task.isCancelled, wing === controller,
              assistant.pendingStudioDraft == refreshed,
              validationContext.activeEnvironmentID == currentContext.activeEnvironmentID,
              validationContext.equipment == currentContext.equipment,
              validationContext.effects == currentContext.effects,
              validationContext.globalConnections == currentContext.globalConnections,
              validationContext.graph == currentContext.graph,
              validationContext.endpoints == currentContext.endpoints,
              validationContext.liveWing.sessionID == currentContext.liveWing.sessionID,
              (refreshed.nameReferences ?? []).allSatisfy({ $0.isValid(in: currentContext) }),
              (refreshed.outputReferences ?? []).allSatisfy({
                  $0.isValid(in: currentContext.effectiveConnections)
              }),
              (refreshed.liveReferences ?? []).allSatisfy({ $0.isValid(in: currentContext.liveWing) }),
              assistant.markPendingDraftAccepted(
                  publicationID: publicationID, snapshot: refreshed, hasActiveEnvironment: environments.active != nil)
        else { return .notAccepted }
        let result = StudioPatchDraftMerger.merge(
            refreshed,
            into: environments.activeStudioGraph,
            endpoints: environments.activeStudioEndpoints,
            equipment: equipment.items,
            effects: environments.activeEffects
        )
        guard environments.active != nil else {
            environments.replaceStudio(graph: result.graph, endpoints: result.endpoints)
            let removalOutcome = await assistant.discardPendingStudioDraftResult()
            return .accepted(merge: result, removalOutcome: removalOutcome)
        }
        let receipt = environments.replaceStudioReportingLocalSave(graph: result.graph, endpoints: result.endpoints)
        if let beforeAwaitingLocalSave { await beforeAwaitingLocalSave() }
        guard await receipt.value == .localWriteCompleted else {
            let retainedID = assistant.pendingPublicationID == publicationID ? publicationID : nil
            return .acceptedLocalWriteUnconfirmed(merge: result, retainedPublicationID: retainedID)
        }
        // Environments held while the receipt was awaited (#943) keep the draft for review.
        guard environments.hold == nil, let removalOutcome = await assistant.retireAcceptedDraft(
            publicationID: publicationID, snapshot: refreshed
        ) else {
            return .acceptedWithoutRetirement(merge: result)
        }
        return .accepted(merge: result, removalOutcome: removalOutcome)
    }
}

private extension AssistantScreen {
    init(_ section: AppSection) {
        switch section {
        case .studio: self = .studio
        case .workspace: self = .workspace
        case .assistant: self = .assistant
        case .mix: self = .mix
        case .more: self = .more
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
