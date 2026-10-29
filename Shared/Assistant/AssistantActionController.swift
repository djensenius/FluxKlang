import Foundation
import Observation

struct AssistantActionScope: Equatable {
    var environmentID: UUID?
    var graph: StudioGraph
    var endpoints: [StudioEndpoint]
    var equipment: [Equipment]
    var connections: StudioHomeConnections
}

/// Separate reviewed boundary; neither an interpreter nor a persisted conversation can send a SET.
@MainActor
@Observable
final class AssistantActionController: AssistantActionPlanning {
    private(set) var pendingReview: AssistantActionReview?
    private(set) var latestResult: AssistantActionResult?

    let controller: @MainActor () -> WingController?
    let layout: @MainActor () -> FaderLayout
    let scope: @MainActor () -> AssistantActionScope
    let addShortcut: @MainActor (StudioLiveChannelBinding, String, UUID, StudioGraph) -> (nodeID: UUID, added: Bool)?
    let timeout: Duration
    let reviewLifetime: TimeInterval
    var operationID = UUID()
    var pending: Pending?
    var confirming = false
    var activeAuthorization: WingMixerWriteAuthorization?

    struct Pending {
        let request: AssistantActionInterpretationRequest
        let intent: AssistantActionIntent
        let wing: WingController
        let session: UUID
        let scope: AssistantActionScope
        let strips: [FaderStrip]
        let discovery: [String: WingValue]
        let review: AssistantActionReview
        let deadline: ContinuousClock.Instant
        let validity: AssistantActionReviewValidity
    }

    init(
        controller: @escaping @MainActor () -> WingController?,
        layout: @escaping @MainActor () -> FaderLayout,
        scope: @escaping @MainActor () -> AssistantActionScope,
        addShortcut:
            @escaping @MainActor (StudioLiveChannelBinding, String, UUID, StudioGraph)
            -> (nodeID: UUID, added: Bool)?,
        timeout: Duration = .milliseconds(750), reviewLifetime: TimeInterval = 60
    ) {
        self.controller = controller
        self.layout = layout
        self.scope = scope
        self.addShortcut = addShortcut
        self.timeout = timeout
        self.reviewLifetime = reviewLifetime
    }

    func cancel() {
        operationID = UUID()
        activeAuthorization?.invalidate()
        activeAuthorization = nil
        pending = nil
        pendingReview = nil
    }

    func prepare(
        _ request: AssistantActionInterpretationRequest,
        interpretation: AssistantActionInterpretation
    ) async -> AssistantActionPreparation {
        cancel()
        latestResult = nil
        switch interpretation {
        case .answer: return .answer
        case .clarification(let message): return .clarification(message)
        case .proposal(let intent):
            guard !confirming else {
                return .clarification("A previous action is stopping; submit again after its outcome.")
            }
            if let message = AssistantActionIntentValidator.clarification(for: intent, text: request.text) {
                return .clarification(message)
            }
            return await prepareProposal(request, intent: intent)
        }
    }

    func selectCandidate(reviewID: UUID, candidateID: String) async -> AssistantActionPreparation {
        guard !confirming, let original = pending, original.review.id == reviewID,
            original.review.stage == .chooseCandidate,
            let chosen = original.review.candidates.first(where: { $0.id == candidateID }),
            original.validity.isValid,
            original.deadline > .now, original.review.expiresAt > Date()
        else {
            return .clarification("This selection expired. Submit a new request; no changes were made.")
        }
        cancel()
        return await prepareProposal(
            original.request, intent: original.intent,
            selection: chosen, previous: original)
    }

    // Keep every post-suspension guard in a linear preparation audit trail.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func prepareProposal(
        _ request: AssistantActionInterpretationRequest, intent: AssistantActionIntent,
        selection: AssistantActionCandidate? = nil, previous: Pending? = nil
    )
        async -> AssistantActionPreparation {
        let version = operationID
        if case .invalidIdentity = AssistantActionTargetResolver.target(intent.targetMention) {
            return .clarification("No changes: channels are 1...40 and mains are 1...4.")
        }
        guard !Task.isCancelled, let wing = controller(), !wing.isDemo, wing.connection.isConnected,
            let session = wing.sessionID, request.liveContext.sessionID == session
        else {
            return .clarification(
                "Connect to a real WING in the request's current session first. No changes were made.")
        }
        let originalScope = scope()
        guard !intent.addToStudio || originalScope.environmentID != nil else {
            return .clarification("Select an active environment before reviewing a live shortcut addition. No changes.")
        }
        let strips = layout().strips
        if let previous {
            guard previous.wing === wing, previous.session == session, previous.scope == originalScope,
                previous.strips == strips
            else {
                return .clarification("The console, environment or layout changed. Submit a new request.")
            }
        }
        func current() -> Bool {
            isCurrent(version, wing: wing, session: session, originalScope: originalScope, strips: strips)
                && (previous?.validity.isValid ?? true)
        }
        guard
            let discovery = await wing.readFreshConfirmed(
                Self.discoveryAddresses, session: session, timeout: timeout),
            current(), Self.channelNames(discovery) != nil
        else {
            return .clarification("No changes: could not freshly confirm all channel names and sources.")
        }
        var candidates = Self.candidates(
            intent: intent, wing: wing, discovery: discovery,
            scope: originalScope, strips: strips)
        if case .node(let main) = AssistantActionTargetResolver.target(intent.targetMention), main.kind == .main {
            guard !intent.addToStudio else {
                return .clarification("Only existing input channels can be added as live shortcuts.")
            }
            let address = WingAddress.name(.main, main.index)
            guard let fresh = await wing.readFreshConfirmed(
                [address], session: session, timeout: timeout), current(),
                let label = fresh[address]?.stringValue
            else { return .clarification("Could not confirm the main identity.") }
            candidates = [
                .init(
                    id: main.id, title: main.defaultLabel + " · " + label,
                    members: [.init(node: main, label: label, sourceGroup: nil, sourceIndex: nil, equipmentID: nil)],
                    pairStripID: nil, match: .explicitIdentity)
            ]
        }
        let selected: AssistantActionCandidate?
        if let selection {
            guard let fresh = candidates.first(where: { $0.id == selection.id }), fresh.members == selection.members,
                fresh.pairStripID == selection.pairStripID
            else {
                return .clarification(
                    "The selected channel identity/source changed. Submit a new request for a new review.")
            }
            selected = fresh
        } else {
            let only = candidates.count == 1 ? candidates.first : nil
            selected = only?.match == .exact || only?.match == .explicitIdentity ? only : nil
        }
        guard !candidates.isEmpty else {
            return .clarification(
                "No fresh unambiguous live channel matches. Specify channel N; "
                    + "saved gear or LOCAL input N is not channel N."
            )
        }
        var evidence: AssistantActionTargetEvidence?
        var changes: [AssistantActionFaderChange] = []
        if let selected {
            let addresses = Self.memberAddresses(selected.members)
            guard let fresh = await wing.readFreshConfirmed(
                addresses, session: session, timeout: timeout), current(),
                Self.discoveryUnchanged(discovery, snapshot: wing.confirmedSnapshot()),
                let target = Self.targetEvidence(selected, session: session, fresh: fresh)
            else {
                return .clarification(
                    "No changes: target names, sources or finite baselines could not be freshly confirmed.")
            }
            evidence = target
            guard let planned = AssistantActionFaderPlanner.changes(intent: intent, target: target) else {
                return .clarification(
                    "No changes: a relative fader is off (−∞), or a result is out of bounds. "
                    + "Use an explicit absolute level; values are never clamped."
                )
            }
            changes = planned
        }
        guard current() else { return .clarification("The request was cancelled or its context changed.") }
        let suggested: Float? = intent.amount == nil && (intent.action == .lower || intent.action == .raise) ? 3 : nil
        let review = AssistantActionReview(
            id: UUID(), submissionID: request.submissionID,
            stage: selected == nil ? .chooseCandidate : .ready, targetMention: intent.targetMention,
            candidates: candidates, selectedCandidateID: selected?.id, target: evidence, faderChanges: changes,
            addsLiveShortcut: intent.addToStudio, suggestedAmountDB: suggested,
            expiresAt: Date().addingTimeInterval(reviewLifetime),
            summary: Self.summary(intent: intent, candidate: selected, suggested: suggested),
            warnings: Self.warnings(intent: intent, target: evidence))
        let validity = AssistantActionReviewValidity()
        let prepared = Pending(
            request: request, intent: intent, wing: wing, session: session,
            scope: originalScope, strips: strips, discovery: discovery, review: review,
            deadline: .now.advanced(by: .seconds(reviewLifetime)), validity: validity)
        withObservationTracking {
            wing.assistantActionEvidence.observeChanges(
                at: Self.discoveryAddresses + Self.memberAddresses(evidence?.members.map(\.identity) ?? []))
            _ = controller()
            _ = wing.sessionID
            _ = wing.connection
            _ = scope()
            _ = layout().strips
        } onChange: {
            validity.invalidate()
        }
        pending = prepared
        pendingReview = review
        return .review(review)
    }

    func consumePending() -> Pending? {
        let original = pending
        pending = nil
        pendingReview = nil
        return original
    }

    func recordResult(_ result: AssistantActionResult) -> AssistantActionResult {
        latestResult = result
        return result
    }

    func isCurrent(
        _ version: UUID, wing: WingController, session: UUID,
        originalScope: AssistantActionScope, strips: [FaderStrip]
    ) -> Bool {
        !Task.isCancelled && operationID == version && controller() === wing && !wing.isDemo
            && wing.sessionID == session && wing.connection.isConnected
            && scope() == originalScope && layout().strips == strips
    }
}
