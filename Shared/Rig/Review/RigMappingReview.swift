//
//  RigMappingReview.swift
//  FluxKlang
//
//  A reviewable rig mapping: the RG1 proposal for one device document, bound to
//  that document's revision, with everything the user may decide on listed:
//  - `additions`: the proposed routes (always `.proposed`, never `.confirmed`);
//  - `pendingChoices`: roles awaiting the user's choice of candidate;
//  - `removalCandidates`: routes the user may remove (orphan, mismatched,
//    `deviceMissing`, `stale` or without a role requirement), with a reason;
//  - `replacementOffers`: the candidates a `replace` may bind for the role of a
//    mismatched, `deviceMissing` or `stale` candidate. A single RG1 candidate
//    for such a role is held here as an offer, never added on its own;
//  - `unmapped`: roles that stay unmapped, with their reasons;
//  - `overlaps`: channel overlaps among the live document routes plus the
//    additions, under the policy in `RigChannelOverlap.swift`.
//
//  `apply` (RigMappingReview+Apply.swift) turns explicit decisions into one
//  candidate device document. Nothing here confirms a route, edits a device
//  descriptor or a portable role, or bumps the document revision.
//

/// Why a route is offered for removal. A route with several reasons gets the first of:
/// orphan, mismatched, device missing, stale, no requirement.
enum RigRemovalReason: Hashable, Sendable {
    /// The route's role is not among the project's roles.
    case orphan
    /// The route no longer fits its role (direction or channel count).
    case mismatched
    /// The route's device is missing ("Lost/Muted").
    case deviceMissing
    /// The route's binding is stale.
    case stale
    /// The route's role has no route requirement (non-audio, invalid or unconfirmed channel count).
    /// This includes valid, `.confirmed` routes of legacy (`nil` channel count) and non-audio roles:
    /// they are removal candidates, so review can remove them, as the spec's candidate list (RG1's
    /// `routesWithoutRequirement`) says. They are kept unless a decision removes them.
    case noRequirement
}

/// A route the user may remove or replace. Only `RigMappingReview` creates candidates.
struct RigRemovalCandidate: Hashable, Sendable {
    let route: RouteID
    let role: RoleID
    let reason: RigRemovalReason

    fileprivate init(route: RouteID, role: RoleID, reason: RigRemovalReason) {
        self.route = route
        self.role = role
        self.reason = reason
    }
}

/// A role that stays unmapped and why. Only `RigMappingReview` creates entries.
struct RigUnmappedRole: Hashable, Sendable {
    let role: RoleID
    let reason: RigUnmappedReason

    fileprivate init(role: RoleID, reason: RigUnmappedReason) {
        self.role = role
        self.reason = reason
    }
}

/// A review of the RG1 mapping proposal for one device document revision.
struct RigMappingReview: Hashable, Sendable {
    /// The revision of the device document the review was made from; `apply` refuses any other.
    let baseRevision: ContractRevision
    /// The device document the review was made from; `apply` refuses any other at `baseRevision`.
    let baseDocument: DeviceCapabilityDocument
    /// The original RG1 proposal; RG2 choices are kept separately in `chosenRoutes`.
    private(set) var proposal: RigMappingProposal
    /// RG2 choices; `proposal` does not reflect them.
    private(set) var chosenRoutes: [RoleID: AudioRoute]
    /// Routes the user may remove or replace, sorted by route. Routes are kept unless a decision
    /// removes them; a confirmed or proposed route that still fits its role is never a candidate.
    let removalCandidates: [RigRemovalCandidate]
    /// Channel overlaps among the live document routes plus `additions`, sorted.
    private(set) var overlaps: [RigChannelOverlap]
    /// The candidates a `replace` of a mismatched, `deviceMissing` or `stale` removal candidate may
    /// bind, by the candidate's role, in RG1's (device, first channel) order. A role is listed when
    /// RG1 offers it a candidate: in the review's proposal (a single `.proposed` candidate, which is
    /// held here instead of being added, or the candidates of a role awaiting a choice), or else in
    /// RG1's proposal over the document without those removal candidates, at the same revision (a
    /// mismatched role, or a role the route budget left unmapped). `choosing` a role drops its entry.
    ///
    /// Capacity: a `replace` swaps one route for one, so it is not counted against
    /// `DeviceCapabilityLimits.routes` and is accepted at 4,096 routes. A `choose` is checked against
    /// the final candidate count, excluding held offers and including explicit removals and replacements.
    /// RG1 still hands its route budget to
    /// single-candidate roles in `RoleID` order, so near the limit a role can get no offer (its
    /// `replace` is refused with `candidateNotOffered`); remove another eligible route to free capacity,
    /// then make a new review.
    private(set) var replacementOffers: [RoleID: [RigRouteCandidate]]

    /// The proposed routes, in role order, without the single candidates held in `replacementOffers`.
    var additions: [AudioRoute] {
        (Self.additions(of: proposal, offers: replacementOffers) + chosenRoutes.values)
            .sorted { $0.role < $1.role }
    }

    /// Roles whose single RG1 candidate is held as a replacement offer instead of being added: with
    /// no decision or `.keep` they stay unmapped, and only a `replace` binds the candidate.
    var heldRoles: Set<RoleID> { Self.heldRoles(of: proposal, offers: replacementOffers) }

    /// Roles awaiting a choice, sorted.
    var pendingChoices: [RoleID] { proposal.awaitingChoice.filter { chosenRoutes[$0] == nil } }

    /// Roles that stay unmapped, sorted, with their reasons.
    var unmapped: [RigUnmappedRole] {
        proposal.mappings.compactMap { mapping in
            guard case .unmapped(let reason) = mapping.outcome else { return nil }
            return RigUnmappedRole(role: mapping.role, reason: reason)
        }
    }

    private init(base: DeviceCapabilityDocument, proposal: RigMappingProposal,
                 removalCandidates: [RigRemovalCandidate], replacementOffers: [RoleID: [RigRouteCandidate]],
                 chosenRoutes: [RoleID: AudioRoute] = [:]) {
        baseRevision = base.revision
        baseDocument = base
        self.proposal = proposal
        self.chosenRoutes = chosenRoutes
        self.removalCandidates = removalCandidates
        self.replacementOffers = replacementOffers
        let additions = Self.additions(of: proposal, offers: replacementOffers)
        overlaps = RigChannelOverlapScan.overlaps(in: base.routes + additions)
    }

    /// Builds the review: the RG1 proposal for `roles` over `document`, bound to its revision.
    static func make(
        roles: [ProjectRole], document: DeviceCapabilityDocument
    ) throws(RigReviewRefusal) -> RigMappingReview {
        let proposal = try RigReviewRefusal.lifting { () throws(RigMappingRefusal) in
            try RigMappingProposal.make(roles: roles, devices: document)
        }
        let candidates = removalCandidates(of: proposal, routes: document.routes)
        return RigMappingReview(
            base: document, proposal: proposal, removalCandidates: candidates,
            replacementOffers: try replacementOffers(for: candidates, roles: roles, proposal: proposal,
                                                     document: document)
        )
    }

    /// Binds one offered candidate of a role whose RG1 outcome awaits a choice and recomputes overlaps.
    /// Returns the updated review; the receiver is unchanged.
    func choosing(_ candidate: RigRouteCandidate, id: RouteID) throws(RigReviewRefusal) -> RigMappingReview {
        let route = try choiceRoute(candidate, id: id, selected: chosenRoutes)
        var updated = self
        updated.chosenRoutes[candidate.role] = route
        updated.replacementOffers[candidate.role] = nil
        updated.overlaps = RigChannelOverlapScan.overlaps(in: baseDocument.routes + updated.additions)
        return updated
    }

    /// Shared internal choice validation. `apply` supplies route/decline credits; `choosing` has none
    /// and is deliberately stricter. The accounting inputs are trusted.
    func choiceRoute(
        _ candidate: RigRouteCandidate, id: RouteID, selected: [RoleID: AudioRoute],
        removed: Set<RouteID> = [], replacementCount: Int = 0, declined: Set<RoleID> = []
    ) throws(RigReviewRefusal) -> AudioRoute {
        guard let mapping = proposal.mappings.first(where: { $0.role == candidate.role }) else {
            throw .mapping(.unknownRole(candidate.role))
        }
        guard case .awaitingChoice(let offered) = mapping.outcome,
              offered.candidates.contains(candidate), selected[candidate.role] == nil else {
            throw .mapping(.candidateNotOffered(candidate))
        }

        let proposed = Self.additions(of: proposal, offers: replacementOffers)
            .filter { !declined.contains($0.role) }
        let selectedRoutes = selected.values.filter { !declined.contains($0.role) }
        let finalCount = baseDocument.routes.count - removed.count + replacementCount
            + proposed.count + selectedRoutes.count + 1
        guard finalCount <= DeviceCapabilityLimits.routes else {
            throw .mapping(.routeCapacityExhausted(limit: DeviceCapabilityLimits.routes))
        }
        guard !baseDocument.routes.contains(where: { $0.id == id }),
              !proposed.contains(where: { $0.id == id }),
              !selectedRoutes.contains(where: { $0.id == id }) else {
            throw .mapping(.routeIDInUse(id))
        }
        return AudioRoute(id: id, role: candidate.role, device: candidate.device,
                          direction: candidate.direction, channels: candidate.channels, binding: .proposed)
    }

    /// The proposed routes of `proposal`, in role order, without the held roles' routes.
    private static func additions(
        of proposal: RigMappingProposal, offers: [RoleID: [RigRouteCandidate]]
    ) -> [AudioRoute] {
        let held = heldRoles(of: proposal, offers: offers)
        return proposal.proposedRoutes.filter { !held.contains($0.role) }
    }

    /// The roles with a replacement offer whose RG1 outcome is the auto-proposal of their single
    /// candidate. A role chosen through `choosing` has no offer left, so its route is never held.
    private static func heldRoles(
        of proposal: RigMappingProposal, offers: [RoleID: [RigRouteCandidate]]
    ) -> Set<RoleID> {
        Set(proposal.mappings.compactMap { mapping in
            guard case .proposed = mapping.outcome, offers[mapping.role] != nil else { return nil }
            return mapping.role
        })
    }

    /// The replacement offers for the roles of the mismatched, `deviceMissing` and `stale` removal
    /// candidates: RG1's candidates in `proposal`, or else in RG1's proposal over `document` without
    /// those routes (made only when a role still has no offer).
    private static func replacementOffers(
        for candidates: [RigRemovalCandidate], roles: [ProjectRole], proposal: RigMappingProposal,
        document: DeviceCapabilityDocument
    ) throws(RigReviewRefusal) -> [RoleID: [RigRouteCandidate]] {
        let replaceable = candidates.filter { [.mismatched, .deviceMissing, .stale].contains($0.reason) }
        let wanted = Set(replaceable.map(\.role))
        var offers: [RoleID: [RigRouteCandidate]] = [:]
        for mapping in proposal.mappings where wanted.contains(mapping.role) {
            offers[mapping.role] = offered(by: mapping.outcome)
        }
        guard offers.count < wanted.count else { return offers }
        let removed = Set(replaceable.map(\.route))
        var without = document
        without.routes.removeAll { removed.contains($0.id) }
        let fallback = try RigReviewRefusal.lifting { () throws(RigMappingRefusal) in
            try RigMappingProposal.make(roles: roles, devices: without)
        }
        for mapping in fallback.mappings where wanted.contains(mapping.role) && offers[mapping.role] == nil {
            offers[mapping.role] = offered(by: mapping.outcome)
        }
        return offers
    }

    /// The candidates an RG1 outcome offers, or `nil` when it offers none.
    private static func offered(by outcome: RigRoleOutcome) -> [RigRouteCandidate]? {
        switch outcome {
        case .proposed(_, let candidate): [candidate]
        case .awaitingChoice(let offered): offered.candidates
        default: nil
        }
    }

    /// One candidate per route of RG1's reported lists, with the highest-precedence reason.
    private static func removalCandidates(
        of proposal: RigMappingProposal, routes: [AudioRoute]
    ) -> [RigRemovalCandidate] {
        var reasons: [RouteID: RigRemovalReason] = [:]
        // Lowest precedence first: a later assignment overrides an earlier one.
        for route in proposal.routesWithoutRequirement { reasons[route] = .noRequirement }
        for report in proposal.existingRoutes {
            reasons[report.route] = report.state == .stale ? .stale : .deviceMissing
        }
        for route in proposal.mismatchedRoutes { reasons[route] = .mismatched }
        for route in proposal.orphanRoutes { reasons[route] = .orphan }
        return routes.compactMap { route in
            reasons[route.id].map { RigRemovalCandidate(route: route.id, role: route.role, reason: $0) }
        }.sorted { $0.route < $1.route }
    }
}
