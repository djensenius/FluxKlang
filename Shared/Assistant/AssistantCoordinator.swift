import Foundation
import Observation

enum StudioDraftBuildResult: Sendable, Equatable {
    case notPublished
    // Historical outcome for this invocation's full-value snapshot, not current-file authority.
    case staged(draft: StudioPatchDraft, storageOutcome: PendingStudioPatchMutationOutcome)

    var draft: StudioPatchDraft? {
        guard case .staged(let draft, _) = self else { return nil }
        return draft
    }
}

enum StudioDraftValidationResult: Sendable, Equatable {
    case notPublished
    // Historical outcome for this invocation's full-value snapshot, not current-file authority.
    case staged(draft: StudioPatchDraft, storageOutcome: PendingStudioPatchMutationOutcome)

    var draft: StudioPatchDraft? {
        guard case .staged(let draft, _) = self else { return nil }
        return draft
    }
}

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
    fileprivate enum AcceptanceState { case fresh, accepted, unknown }

    @MainActor
    @Observable
    fileprivate final class Acceptance {
        var state: AcceptanceState

        init(_ state: AcceptanceState = .fresh) { self.state = state }
    }

    @MainActor
    private struct Publication {
        var draft: StudioPatchDraft
        let id = UUID()
        let acceptance: Acceptance

        init(draft: StudioPatchDraft, acceptance: Acceptance = Acceptance()) {
            self.draft = draft
            self.acceptance = acceptance
        }
    }

    private let draftStore: any PendingStudioPatchPersisting
    // Tokens are registered before suspension; only the actual store associates one with file bytes.
    // Result delivery order and equal draft values cannot establish which logical draft a load observed.
    @ObservationIgnored private var savedAcceptances: [UUID: Acceptance] = [:]
    // Unknown provenance is ambiguous only after graph application in this coordinator's session.
    private var appliedEnvironmentIDs: Set<RoutingEnvironment.ID> = []
    private var settledPublication: Publication?
    private var pendingPublication: Publication?
    private var routingSubmissionID: UUID?
    // Pending-draft persistence calls in flight; overlapping mutations each hold one count.
    private var mutationsInFlight = 0

    // Latest submitted invocation, not latest completion or current persisted state.
    private(set) var latestStorageAttempt: PendingStudioPatchStorageAttempt?
    var pendingStudioDraft: StudioPatchDraft? { pendingPublication?.draft }
    var pendingPublicationID: UUID? { pendingPublication?.id }
    var isPendingDraftAccepted: Bool { pendingPublication?.acceptance.state == .accepted }
    var isPendingDraftAcceptanceUnknown: Bool { pendingPublication?.acceptance.state == .unknown }

    func canAcceptPendingDraft(hasActiveEnvironment: Bool) -> Bool {
        guard let publication = pendingPublication else { return false }
        switch publication.acceptance.state {
        case .fresh: return true
        case .accepted: return false
        case .unknown:
            guard hasActiveEnvironment, let environmentID = publication.draft.request.environmentID else { return true }
            return !appliedEnvironmentIDs.contains(environmentID)
        }
    }

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
        let observation: PendingStudioPatchLoadObservation
        if let store = draftStore as? any PendingStudioPatchProvenancePersisting {
            observation = await store.loadWithProvenance()
        } else {
            observation = .init(outcome: await draftStore.load(), provenance: nil)
        }
        let outcome = observation.outcome
        attempt.complete(outcome)
        // A superseded load, or one started during a mutation, records its own outcome but never publishes.
        guard latestStorageAttempt === attempt, quiescent else { return }
        switch outcome {
        case .loaded(let draft):
            let acceptance = observation.provenance.flatMap { savedAcceptances[$0] } ?? Acceptance(.unknown)
            pendingPublication = Publication(draft: draft, acceptance: acceptance)
        case .absent: pendingPublication = nil
        case .malformedOrUnsupported, .readFailed: return
        }
        settledPublication = pendingPublication
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
            // Compatibility: pendingDraft still means in-memory success, even if saving fails.
            let result = await buildStudioDraftResult(request, context: context)
            return .pendingDraft(result.draft)
        case .validatePendingStudioDraft:
            // Compatibility: validation remains reviewable in memory even if saving fails.
            let result = await validatePendingStudioDraftResult(context: context)
            return .pendingDraft(result.draft)
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

    /// Revalidation retains its existing cancellation and settled/unsettled semantics.
    func validatePendingStudioDraftResult(context: AssistantToolContext) async -> StudioDraftValidationResult {
        guard let draft = pendingStudioDraft else { return .notPublished }
        let wasSettled = settledPublication?.id == pendingPublication?.id
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
        pendingPublication?.draft = refreshed
        if wasSettled { settledPublication = pendingPublication }
        let storageOutcome = await persistPendingDraft()
        guard pendingStudioDraft == refreshed else { return .notPublished }
        return .staged(draft: refreshed, storageOutcome: storageOutcome)
    }

    /// Typed builds retain their existing admission/cancellation semantics, unlike prepared commits.
    func buildStudioDraftResult(
        _ request: StudioWiringRequest, context: AssistantToolContext
    ) async -> StudioDraftBuildResult {
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
        pendingPublication = Publication(draft: draft)
        settledPublication = pendingPublication
        routingSubmissionID = nil
        let storageOutcome = await persistPendingDraft()
        // A discard, newer draft or commit during the save owns the pending draft; never report it as ours.
        guard pendingStudioDraft == draft else { return .notPublished }
        return .staged(draft: draft, storageOutcome: storageOutcome)
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
        let rollback = settledPublication
        let submissionID = UUID()
        routingSubmissionID = submissionID
        defer {
            if routingSubmissionID == submissionID { routingSubmissionID = nil }
        }
        let publication = Publication(draft: draft)
        pendingPublication = publication
        let storageOutcome = await persistPendingDraft()
        if Task.isCancelled, routingSubmissionID == submissionID {
            pendingPublication = rollback
            await persistPendingDraft()
        }
        guard !Task.isCancelled, pendingStudioDraft == draft else { return .notPublished }
        // Historical equal-value ABA success is not permission to promote this old publication.
        if pendingPublication?.id == publication.id { settledPublication = pendingPublication }
        return .staged(draft: draft, storageOutcome: storageOutcome)
    }

    func discardPendingStudioDraft() async {
        _ = await discardPendingStudioDraftResult()
    }

    /// Historical nil-snapshot outcome, not a guarantee about the current saved draft.
    func discardPendingStudioDraftResult() async -> PendingStudioPatchMutationOutcome {
        clearPendingDraft()
        return await persistPendingDraft()
    }

    func markPendingDraftAccepted(
        publicationID: UUID, snapshot: StudioPatchDraft, hasActiveEnvironment: Bool
    ) -> Bool {
        guard let publication = pendingPublication, publication.id == publicationID,
              publication.draft == snapshot,
              canAcceptPendingDraft(hasActiveEnvironment: hasActiveEnvironment) else { return false }
        publication.acceptance.state = .accepted
        if hasActiveEnvironment, let environmentID = snapshot.request.environmentID {
            appliedEnvironmentIDs.insert(environmentID)
        }
        return true
    }

    /// Check and clear in one main-actor turn before awaiting the legacy removal path.
    func retireAcceptedDraft(
        publicationID: UUID, snapshot: StudioPatchDraft
    ) async -> PendingStudioPatchMutationOutcome? {
        guard pendingPublicationID == publicationID, pendingStudioDraft == snapshot,
              isPendingDraftAccepted else { return nil }
        clearPendingDraft()
        return await persistPendingDraft()
    }

    private func clearPendingDraft() {
        pendingPublication = nil
        settledPublication = nil
        routingSubmissionID = nil
        navigationTarget = nil
    }

    @discardableResult
    private func persistPendingDraft() async -> PendingStudioPatchMutationOutcome {
        mutationsInFlight += 1
        defer { mutationsInFlight -= 1 }
        let entrySnapshot = pendingStudioDraft
        var saved = entrySnapshot
        var acceptance = pendingPublication?.acceptance
        var entryOutcome: PendingStudioPatchMutationOutcome?
        while true {
            let attempt = PendingStudioPatchStorageAttempt(.mutation(snapshot: saved, outcome: nil))
            latestStorageAttempt = attempt
            let outcome: PendingStudioPatchMutationOutcome
            if let store = draftStore as? any PendingStudioPatchProvenancePersisting {
                let provenance = UUID()
                savedAcceptances[provenance] = acceptance
                outcome = await store.save(saved, provenance: provenance)
            } else {
                outcome = await draftStore.save(saved)
            }
            attempt.complete(outcome)
            // Retain the first result and replace it only for this invocation's same full-value snapshot.
            if entryOutcome == nil || saved == entrySnapshot { entryOutcome = outcome }
            guard outcome.completed, saved != pendingStudioDraft else { break }
            saved = pendingStudioDraft
            acceptance = pendingPublication?.acceptance
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
