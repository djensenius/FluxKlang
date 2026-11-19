import Foundation
import Observation

enum PreparedRoutingCommitResult: Sendable, Equatable {
    case notPublished
    // The outcome belongs to this invocation's full-value snapshot, not the current file.
    case staged(draft: StudioPatchDraft, storageOutcome: PendingStudioPatchMutationOutcome)
}

@MainActor
@Observable
final class PendingStudioPatchStorageAttempt {
    enum Value: Sendable, Equatable {
        case load(PendingStudioPatchLoadOutcome?)
        case mutation(snapshot: StudioPatchDraft?, outcome: PendingStudioPatchMutationOutcome?)
    }

    private(set) var observation: Value

    fileprivate init(_ observation: Value) {
        self.observation = observation
    }

    fileprivate func complete(_ outcome: PendingStudioPatchLoadOutcome) {
        guard case .load(nil) = observation else { preconditionFailure("Attempt already completed") }
        observation = .load(outcome)
    }

    fileprivate func complete(_ outcome: PendingStudioPatchMutationOutcome) {
        guard case .mutation(let snapshot, nil) = observation else {
            preconditionFailure("Attempt already completed")
        }
        observation = .mutation(snapshot: snapshot, outcome: outcome)
    }
}

@MainActor
@Observable
final class AssistantCoordinator {
    private let draftStore: any PendingStudioPatchPersisting
    private var settledStudioDraft: StudioPatchDraft?
    private var routingSubmissionID: UUID?
    // Pending-draft persistence calls in flight; overlapping mutations each hold one count.
    private var mutationsInFlight = 0

    // Latest submitted invocation, not latest completion or current persisted state.
    private(set) var latestStorageAttempt: PendingStudioPatchStorageAttempt?
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
        let attempt = PendingStudioPatchStorageAttempt(.load(nil))
        latestStorageAttempt = attempt
        // A read that starts during a mutation can return disk older than the pending draft.
        let quiescent = mutationsInFlight == 0
        let outcome = await draftStore.load()
        attempt.complete(outcome)
        // A superseded load, or one started during a mutation, records its own outcome but never publishes.
        guard latestStorageAttempt === attempt, quiescent else { return }
        switch outcome {
        case .loaded(let draft): pendingStudioDraft = draft
        case .absent: pendingStudioDraft = nil
        case .malformedOrUnsupported, .readFailed: return
        }
        settledStudioDraft = pendingStudioDraft
        routingSubmissionID = nil
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
        case .inspectLiveWing:
            return .liveWing(context.liveWing)
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
            var draft = StudioWiringAdvisor.build(
                request: request,
                equipment: context.equipment,
                effects: context.effects,
                connections: context.globalConnections,
                currentGraph: context.graph,
                environmentID: context.activeEnvironmentID
            )
            draft.liveReferences = request.liveReferences
            draft.outputReferences = request.outputReferences
            pendingStudioDraft = draft
            settledStudioDraft = draft
            routingSubmissionID = nil
            await persistPendingDraft()
            // A discard, newer draft or commit during the save owns the pending draft; never report it as ours.
            return .pendingDraft(pendingStudioDraft == draft ? draft : nil)
        case .validatePendingStudioDraft:
            guard let draft = pendingStudioDraft else { return .pendingDraft(nil) }
            let wasSettled = settledStudioDraft == draft
            var refreshed = StudioWiringAdvisor.revalidate(
                draft,
                equipment: context.equipment,
                effects: context.effects,
                connections: context.globalConnections,
                currentGraph: context.graph,
                currentEnvironmentID: context.activeEnvironmentID,
                currentEndpoints: context.endpoints
            )
            refreshed.liveReferences = draft.liveReferences
            if !(draft.liveReferences ?? []).allSatisfy({ $0.isValid(in: context.liveWing) }) {
                refreshed.validation.append(StudioDraftValidationIssue(
                    code: "live-alias-changed", severity: .error,
                    message: "The WING session, label or saved input link used by this draft changed or is stale. "
                        + "Relink and create a new draft before accepting."
                ))
            }
            if !(draft.nameReferences ?? []).allSatisfy({ $0.isValid(in: context) }) {
                refreshed.validation.append(StudioDraftValidationIssue(
                    code: "routing-name-changed", severity: .error,
                    message: "A routing name now resolves differently. Create a new draft before accepting."))
            }
            pendingStudioDraft = refreshed
            if wasSettled { settledStudioDraft = refreshed }
            await persistPendingDraft()
            return .pendingDraft(pendingStudioDraft == refreshed ? refreshed : nil)
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

    /// Compatibility: successful in-memory staging does not require successful storage.
    func commitPreparedRouting(
        _ draft: StudioPatchDraft, expectedPending: StudioPatchDraft?,
        preparedContext: AssistantToolContext, currentContext: AssistantToolContext
    ) async -> Bool {
        if case .staged = await commitPreparedRoutingResult(
            draft, expectedPending: expectedPending, preparedContext: preparedContext, currentContext: currentContext
        ) { return true }
        return false
    }

    /// Natural-language preparation is all-or-nothing. The last synchronous guard and mutation share
    /// the main actor; no await can admit a stale response or replace a newer pending review.
    func commitPreparedRoutingResult(
        _ draft: StudioPatchDraft, expectedPending: StudioPatchDraft?,
        preparedContext: AssistantToolContext, currentContext: AssistantToolContext
    ) async -> PreparedRoutingCommitResult {
        guard !Task.isCancelled, !draft.hasErrors, pendingStudioDraft == expectedPending,
              preparedContext.activeEnvironmentID == currentContext.activeEnvironmentID,
              preparedContext.equipment == currentContext.equipment,
              preparedContext.effects == currentContext.effects,
              preparedContext.globalConnections == currentContext.globalConnections,
              preparedContext.graph == currentContext.graph,
              preparedContext.endpoints == currentContext.endpoints,
              preparedContext.liveWing.sessionID == currentContext.liveWing.sessionID,
              (draft.nameReferences ?? []).allSatisfy({ $0.isValid(in: currentContext) }),
              (draft.liveReferences ?? []).allSatisfy({ $0.isValid(in: currentContext.liveWing) }),
              (draft.outputReferences ?? []).allSatisfy({ $0.isValid(in: currentContext.effectiveConnections) })
        else { return .notPublished }
        let rollback = settledStudioDraft
        let submissionID = UUID()
        routingSubmissionID = submissionID
        defer {
            if routingSubmissionID == submissionID { routingSubmissionID = nil }
        }
        pendingStudioDraft = draft
        let storageOutcome = await persistPendingDraft()
        if Task.isCancelled, routingSubmissionID == submissionID {
            pendingStudioDraft = rollback
            await persistPendingDraft()
        }
        guard !Task.isCancelled, pendingStudioDraft == draft else { return .notPublished }
        settledStudioDraft = draft
        return .staged(draft: draft, storageOutcome: storageOutcome)
    }

    func discardPendingStudioDraft() async {
        pendingStudioDraft = nil
        settledStudioDraft = nil
        routingSubmissionID = nil
        navigationTarget = nil
        await persistPendingDraft()
    }

    @discardableResult
    private func persistPendingDraft() async -> PendingStudioPatchMutationOutcome {
        mutationsInFlight += 1
        defer { mutationsInFlight -= 1 }
        let entrySnapshot = pendingStudioDraft
        var saved = entrySnapshot
        var entryOutcome: PendingStudioPatchMutationOutcome?
        while true {
            let attempt = PendingStudioPatchStorageAttempt(.mutation(snapshot: saved, outcome: nil))
            latestStorageAttempt = attempt
            let outcome = await draftStore.save(saved)
            attempt.complete(outcome)
            // Retain the first result and replace it only for this invocation's same full-value snapshot.
            if entryOutcome == nil || saved == entrySnapshot { entryOutcome = outcome }
            guard outcome.completed, saved != pendingStudioDraft else { break }
            saved = pendingStudioDraft
        }
        guard let entryOutcome else { preconditionFailure("Entry snapshot was not saved") }
        return entryOutcome
    }

    func clearNavigation() {
        navigationTarget = nil
    }

    /// Matches by draft id only. Ids derive from the request's parameters, so an identical later request
    /// (in any conversation, even after an accept or discard) or a revalidation still counts as that card's draft.
    func isPendingDraft(_ id: StudioPatchDraft.ID) -> Bool {
        pendingStudioDraft?.id == id
    }

    /// A Pending Draft card opens review only for its own draft. Otherwise navigation is left unchanged.
    /// This filters navigation only; it grants the draft no lifetime.
    @discardableResult
    func openReview(ofDraft id: StudioPatchDraft.ID) -> Bool {
        guard isPendingDraft(id) else { return false }
        navigationTarget = .reviewPendingDraft
        return true
    }
}
