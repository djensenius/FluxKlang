import Foundation
import Observation

extension AssistantActionController {
    // Keep consumption, per-await validation and partial outcomes in one execution audit trail.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func confirm(reviewID: UUID) async -> AssistantActionResult {
        guard !confirming else { return unavailableResult(reviewID, "Another confirmation is stopping or executing.") }
        // Consume synchronously before the first suspension. Text, history and duplicate taps cannot replay.
        guard let plan = pending, plan.review.id == reviewID, plan.review.stage == .ready else {
            return unavailableResult(
                reviewID, "This review is no longer actionable. Prepare and confirm a new preview.")
        }
        _ = consumePending()
        confirming = true
        defer {
            confirming = false
            activeAuthorization?.invalidate()
            activeAuthorization = nil
        }
        let version = operationID
        var executionScope = plan.scope
        var localStatus: AssistantActionResult.LocalStatus = plan.intent.addToStudio ? .notAttempted : .notRequested
        var shortcutID: UUID?
        var outcomes = plan.review.faderChanges.map { AssistantActionResult.Member(node: $0.node, status: .notSent) }
        func result(_ message: String) -> AssistantActionResult {
            recordResult(
                .init(
                    id: UUID(), reviewID: reviewID, localStatus: localStatus,
                    shortcutNodeID: shortcutID, members: outcomes, message: message))
        }
        func current() -> Bool {
            isCurrent(
                version, wing: plan.wing, session: plan.session,
                originalScope: executionScope, strips: plan.strips)
                && plan.deadline > .now && plan.review.expiresAt > Date()
        }
        guard current(), let target = plan.review.target,
            let candidate = plan.review.candidates.first(where: { $0.id == plan.review.selectedCandidateID })
        else {
            return result(
                "No changes: review expired, cancelled or its console/environment/layout changed. "
                    + "Prepare a new preview."
            )
        }
        let evidenceDeadline = ContinuousClock.now.advanced(by: timeout)
        guard
            let discovery = await plan.wing.readFreshConfirmed(
                Self.discoveryAddresses, session: plan.session, timeout: timeout, preservingCache: true),
            current(), discovery == plan.discovery
        else {
            return result(
                "No changes: live names/source evidence changed or could not be refreshed. "
                    + "Prepare a new preview and confirm again."
            )
        }
        guard
            let fresh = await plan.wing.readFreshConfirmed(
                Self.memberAddresses(candidate.members),
                session: plan.session, timeout: timeout, preservingCache: true), current(),
            Self.discoveryUnchanged(discovery, snapshot: plan.wing.confirmedSnapshot()),
            let latest = Self.targetEvidence(candidate, session: plan.session, fresh: fresh), latest == target
        else {
            return result(
                "No changes: the reviewed identity, source or baseline changed. "
                    + "Prepare a new preview and confirm again; the change was not rebased."
            )
        }
        guard current(), ContinuousClock.now < evidenceDeadline else {
            return result("No changes: final evidence expired. Prepare a new preview.")
        }
        if plan.intent.addToStudio {
            guard let environmentID = executionScope.environmentID,
                target.members.allSatisfy({ $0.identity.node.kind == .channel })
            else {
                localStatus = .failed
                return result("Shortcut could not be added locally. No mixer SET was attempted.")
            }
            let binding = StudioLiveChannelBinding(
                observedSessionID: plan.session,
                members: target.members.map { member in
                    .init(
                        channel: member.identity.node.index, label: member.identity.label,
                        sourceGroup: member.identity.sourceGroup, sourceIndex: member.identity.sourceIndex,
                        equipmentID: member.identity.equipmentID)
                }, pairStripID: target.pairStripID)
            guard let insertion = addShortcut(binding, candidate.title, environmentID, executionScope.graph) else {
                localStatus = .failed
                return result("Shortcut could not be added locally. No mixer SET was attempted.")
            }
            shortcutID = insertion.nodeID
            localStatus = insertion.added ? .added : .alreadyPresent
            let after = scope()
            guard Self.validInsertion(insertion, binding: binding, before: executionScope, after: after) else {
                return result(
                    "Local shortcut outcome could not be validated. No mixer SET was attempted; inspect the canvas.")
            }
            executionScope = after
        }
        // Independent, allowlisted one-shot capability per member. Stop after any uncertainty;
        // stereo is explicitly non-atomic and never retries or sends compensation.
        for (index, change) in plan.review.faderChanges.enumerated() {
            guard current(), Self.discoveryUnchanged(discovery, snapshot: plan.wing.confirmedSnapshot()),
                Self.baselinesMatch(Array(target.members.dropFirst(index)), snapshot: plan.wing.confirmedSnapshot()),
                ContinuousClock.now < evidenceDeadline
            else { break }
            let value: WingValue = change.changesMute ? .int(change.afterMuted ? 1 : 0) : .float(change.afterPosition)
            let authorization = WingMixerWriteAuthorization(
                deadline: evidenceDeadline, node: change.node,
                value: value, muted: change.changesMute)
            activeAuthorization = authorization
            let allowed = withObservationTracking {
                _ = plan.wing.assistantActionEvidence.revision
                return current()
            } onChange: {
                authorization.invalidate()
            }
            guard allowed else {
                authorization.invalidate()
                break
            }
            // A transport failure may happen after a UDP send. Record uncertainty before awaiting.
            outcomes[index] = .init(node: change.node, status: .sentUnconfirmed)
            let sent = await withTaskCancellationHandler {
                await plan.wing.setConfirmedMixerValue(
                    change.node, value: value, muted: change.changesMute,
                    session: plan.session, authorization: authorization)
            } onCancel: {
                authorization.invalidate()
            }
            authorization.invalidate()
            activeAuthorization = nil
            if !authorization.wasConsumed { outcomes[index] = .init(node: change.node, status: .notSent) }
            guard sent else { break }
        }
        let attempted = outcomes.enumerated().filter { $0.element.status == .sentUnconfirmed }
        if !attempted.isEmpty, current(),
            let readback = await plan.wing.readFreshConfirmed(
                Self.memberAddresses(candidate.members),
                session: plan.session, timeout: timeout, preservingCache: true), current(),
            Self.identitiesMatch(candidate, fresh: readback) {
            for (index, _) in attempted {
                let change = plan.review.faderChanges[index]
                outcomes[index] = .init(
                    node: change.node,
                    status: Self.readbackMatches(change, fresh: readback) ? .confirmed : .readbackDiffers)
            }
        }
        return result(Self.outcomeMessage(localStatus: localStatus, members: outcomes))
    }

    private func unavailableResult(_ reviewID: UUID, _ message: String) -> AssistantActionResult {
        // Do not overwrite an in-flight/final outcome with a duplicate-tap result.
        .init(
            id: UUID(), reviewID: reviewID, localStatus: .notAttempted, shortcutNodeID: nil, members: [],
            message: message)
    }

    private static func validInsertion(
        _ insertion: (nodeID: UUID, added: Bool), binding: StudioLiveChannelBinding,
        before: AssistantActionScope, after: AssistantActionScope
    ) -> Bool {
        guard let node = after.graph.node(insertion.nodeID), case .liveChannel(let saved) = node.kind,
            saved.observedSessionID == binding.observedSessionID, saved.members == binding.members,
            saved.pairStripID == binding.pairStripID
        else { return false }
        var expected = before
        if insertion.added {
            expected.graph.addNode(node)
        } else {
            guard let index = expected.graph.nodes.firstIndex(where: { $0.id == node.id }),
                case .liveChannel(let old) = expected.graph.nodes[index].kind,
                old.observedSessionID == binding.observedSessionID,
                old.members.map(\.channel) == binding.members.map(\.channel),
                node.position == expected.graph.nodes[index].position
            else { return false }
            expected.graph.nodes[index] = node
        }
        return expected == after
    }

    private static func baselinesMatch(_ members: [AssistantActionMemberEvidence], snapshot: WingConfirmedSnapshot)
        -> Bool {
        members.allSatisfy { member in
            let node = member.identity.node
            return snapshot.freshValue(WingAddress.fader(node.kind, node.index))?.floatValue == member.position
                && snapshot.freshValue(WingAddress.mute(node.kind, node.index))?.intValue == (member.muted ? 1 : 0)
        }
    }

    private static func identitiesMatch(_ candidate: AssistantActionCandidate, fresh: [String: WingValue]) -> Bool {
        candidate.members.allSatisfy { identity in
            let node = identity.node
            return fresh[WingAddress.name(node.kind, node.index)]?.stringValue == identity.label
                && (node.kind != .channel
                    || (fresh[WingAddress.channelSourceGroup(node.index)]?.stringValue == identity.sourceGroup
                        && fresh[WingAddress.channelSourceIndex(node.index)]?.intValue.map(Int.init)
                            == identity.sourceIndex))
        }
    }

    private static func readbackMatches(_ change: AssistantActionFaderChange, fresh: [String: WingValue]) -> Bool {
        if change.changesMute {
            return fresh[WingAddress.mute(change.node.kind, change.node.index)]?.intValue == (change.afterMuted ? 1 : 0)
        }
        guard let value = fresh[WingAddress.fader(change.node.kind, change.node.index)]?.floatValue,
            value.isFinite, (0...1).contains(value)
        else { return false }
        return FaderMath.isOff(position: value) == FaderMath.isOff(position: change.afterPosition)
            && abs(value - change.afterPosition) <= 0.001
    }

    private static func outcomeMessage(
        localStatus: AssistantActionResult.LocalStatus,
        members: [AssistantActionResult.Member]
    ) -> String {
        let local: String
        switch localStatus {
        case .added: local = "Live shortcut added locally. "
        case .alreadyPresent: local = "Existing live shortcut reused. "
        case .notRequested: local = ""
        case .failed: local = "Local shortcut failed. "
        case .notAttempted: local = "Local shortcut was not attempted. "
        }
        if members.isEmpty { return local + "No mixer SET was requested. No routing, Home or Equipment changes." }
        if members.allSatisfy({ $0.status == .confirmed }) {
            return local + "All reviewed mixer changes confirmed by fresh readback. This is not a hardware lock."
        }
        if members.allSatisfy({ $0.status == .notSent }) {
            return local + "Mixer changes were not sent: cancellation, expiry or context change. Prepare a new review."
        }
        return local
            + "Partial or uncertain mixer outcome; inspect each channel on WING. No retry or rollback was attempted."
    }
}
