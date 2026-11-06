//
//  RigMappingReview+Apply.swift
//  FluxKlang
//
//  Applies explicit decisions to a review, all or nothing, producing one
//  candidate device document:
//  - the document's routes in document order, without the routes a decision
//    removes (a `remove` or the removed half of a `replace`);
//  - then the proposed routes in role order: RG1's proposals, minus declined
//    roles, plus the chosen candidates (`choose` and the added half of `replace`).
//
//  The candidate keeps the base revision and every device descriptor; no route
//  becomes `.confirmed`. Refusals, in check order: `staleDocument`; per route
//  decision (by route) `unknownRoute`, `removeNotCandidate`,
//  `replaceRoleMismatch`; per choice (by role) the lifted RG1 refusals; per
//  decline (by role) `.mapping(.unknownRole)`, `declineNotOffered`; then
//  `invalidResult` and `outputChannelConflict` on the candidate.
//

/// The result of applying decisions to a review: a candidate document for the commit owner, who
/// bumps the revision and drives any confirmation. Only `apply` creates changes.
struct RigMappingChange: Hashable, Sendable {
    /// The revision the review was made from; `document.revision` is still this revision.
    let baseRevision: ContractRevision
    /// The candidate device document.
    let document: DeviceCapabilityDocument
    /// The routes added (all `.proposed`), in role order.
    let added: [RouteID]
    /// The routes removed by an explicit decision, in document order.
    let removed: [RouteID]
    /// The removal candidates kept (explicitly or by default), in document order.
    let kept: [RouteID]
    /// Audio roles with no live (`.proposed` or `.confirmed`) route in the candidate, sorted: RG1's
    /// unmapped roles, unchosen pending roles (including "Keep muted"), declined roles, and roles whose
    /// last live route was removed.
    let stillUnmapped: [RoleID]
    /// Input channels shared by several live routes of the candidate (allowed and reported).
    let sharedInputs: [RigChannelOverlap]

    fileprivate init(baseRevision: ContractRevision, document: DeviceCapabilityDocument, added: [RouteID],
                     removed: [RouteID], kept: [RouteID], stillUnmapped: [RoleID],
                     sharedInputs: [RigChannelOverlap]) {
        self.baseRevision = baseRevision
        self.document = document
        self.added = added
        self.removed = removed
        self.kept = kept
        self.stillUnmapped = stillUnmapped
        self.sharedInputs = sharedInputs
    }
}

extension RigMappingReview {
    /// Applies `decisions` to `document`, which must be at `baseRevision`. The candidate passes
    /// `validate()`, and its routes that are not removal candidates pass
    /// `validate(roles: proposal.requirements)`; kept removal candidates are exempt from the role check.
    func apply(
        _ decisions: RigMappingDecisions, to document: DeviceCapabilityDocument
    ) throws(RigReviewRefusal) -> RigMappingChange {
        guard document.revision == baseRevision else {
            throw .staleDocument(base: baseRevision, found: document.revision)
        }
        let removable = Set(removalCandidates.map(\.route))
        let removed = try removedRoutes(decisions, in: document, removable: removable)

        var chosen = proposal
        var choices: [(RigRouteCandidate, RouteID)] = decisions.roles.values.compactMap { decision in
            if case .choose(let candidate, let id) = decision { (candidate, id) } else { nil }
        }
        for decision in decisions.routes.values {
            if case .replace(_, let candidate, let id) = decision { choices.append((candidate, id)) }
        }
        for (candidate, id) in choices.sorted(by: { $0.0.role < $1.0.role }) {
            let current = chosen
            chosen = try RigReviewRefusal.lifting { () throws(RigMappingRefusal) in
                try current.choosing(candidate, id: id)
            }
        }
        let declined = try declinedRoles(decisions, in: chosen)

        let additions = chosen.proposedRoutes.filter { !declined.contains($0.role) }
        var candidate = document
        candidate.routes = document.routes.filter { !removed.contains($0.id) } + additions
        try validate(candidate, exempt: removable, requirements: chosen.requirements)
        let overlaps = RigChannelOverlapScan.overlaps(in: candidate.routes)
        if let conflict = overlaps.first(where: { $0.kind == .outputConflict }) {
            throw .outputChannelConflict(device: conflict.device, channel: conflict.channel, routes: conflict.routes)
        }
        return RigMappingChange(
            baseRevision: baseRevision, document: candidate, added: additions.map(\.id),
            removed: document.routes.map(\.id).filter { removed.contains($0) },
            kept: document.routes.map(\.id).filter { removable.contains($0) && !removed.contains($0) },
            stillUnmapped: Self.unrouted(chosen, in: candidate.routes),
            sharedInputs: overlaps.filter { $0.kind == .sharedInput }
        )
    }

    /// The routes removed by `remove` and `replace` decisions, checked in route order.
    private func removedRoutes(
        _ decisions: RigMappingDecisions, in document: DeviceCapabilityDocument, removable: Set<RouteID>
    ) throws(RigReviewRefusal) -> Set<RouteID> {
        let roles = Dictionary(document.routes.map { ($0.id, $0.role) }, uniquingKeysWith: { first, _ in first })
        var removed = Set<RouteID>()
        for (id, decision) in decisions.routes.sorted(by: { $0.key < $1.key }) {
            guard let role = roles[id] else { throw .unknownRoute(id) }
            switch decision {
            case .keep:
                continue
            case .remove:
                guard removable.contains(id) else { throw .removeNotCandidate(id) }
            case .replace(_, let candidate, _):
                guard removable.contains(id) else { throw .removeNotCandidate(id) }
                guard candidate.role == role else {
                    throw .replaceRoleMismatch(route: id, role: role, candidateRole: candidate.role)
                }
            }
            removed.insert(id)
        }
        return removed
    }

    /// The roles whose proposed route or pending choice is declined, sorted.
    private func declinedRoles(
        _ decisions: RigMappingDecisions, in proposal: RigMappingProposal
    ) throws(RigReviewRefusal) -> [RoleID] {
        let outcomes = Dictionary(proposal.mappings.map { ($0.role, $0.outcome) },
                                  uniquingKeysWith: { first, _ in first })
        var declined: [RoleID] = []
        for case .leaveUnmapped(let role) in decisions.roles.values.sorted(by: { $0.role < $1.role }) {
            guard let outcome = outcomes[role] else { throw .mapping(.unknownRole(role)) }
            switch outcome {
            case .proposed, .awaitingChoice: declined.append(role)
            default: throw .declineNotOffered(role)
            }
        }
        return declined
    }

    /// The non-skipped roles of `proposal` with no live route in `routes`, in role order.
    private static func unrouted(_ proposal: RigMappingProposal, in routes: [AudioRoute]) -> [RoleID] {
        let live = Set(routes.filter { $0.binding == .proposed || $0.binding == .confirmed }.map(\.role))
        return proposal.mappings.compactMap { mapping in
            if case .skipped = mapping.outcome { return nil }
            return live.contains(mapping.role) ? nil : mapping.role
        }
    }

    /// Intrinsic validity of the whole candidate, then the role check on every route that is not a
    /// removal candidate.
    private func validate(
        _ candidate: DeviceCapabilityDocument, exempt: Set<RouteID>, requirements: [RoleID: RouteRoleRequirement]
    ) throws(RigReviewRefusal) {
        do {
            try candidate.validate()
            var checked = candidate
            checked.routes = candidate.routes.filter { !exempt.contains($0.id) }
            try checked.validate(roles: requirements)
        } catch {
            throw .invalidResult(String(describing: error))
        }
    }
}
