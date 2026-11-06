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
    /// The RG1 proposal, updated by `choosing`.
    private(set) var proposal: RigMappingProposal
    /// Routes the user may remove or replace, sorted by route. Routes are kept unless a decision
    /// removes them; a confirmed or proposed route that still fits its role is never a candidate.
    let removalCandidates: [RigRemovalCandidate]
    /// Channel overlaps among the live document routes plus `additions`, sorted.
    private(set) var overlaps: [RigChannelOverlap]
    /// The base document's routes, for recomputing overlaps after a choice.
    private let baseRoutes: [AudioRoute]

    /// The proposed routes, in role order.
    var additions: [AudioRoute] { proposal.proposedRoutes }

    /// Roles awaiting a choice, sorted.
    var pendingChoices: [RoleID] { proposal.awaitingChoice }

    /// Roles that stay unmapped, sorted, with their reasons.
    var unmapped: [RigUnmappedRole] {
        proposal.mappings.compactMap { mapping in
            guard case .unmapped(let reason) = mapping.outcome else { return nil }
            return RigUnmappedRole(role: mapping.role, reason: reason)
        }
    }

    private init(baseRevision: ContractRevision, proposal: RigMappingProposal,
                 removalCandidates: [RigRemovalCandidate], baseRoutes: [AudioRoute]) {
        self.baseRevision = baseRevision
        self.proposal = proposal
        self.removalCandidates = removalCandidates
        self.baseRoutes = baseRoutes
        overlaps = RigChannelOverlapScan.overlaps(in: baseRoutes + proposal.proposedRoutes)
    }

    /// Builds the review: the RG1 proposal for `roles` over `document`, bound to its revision.
    static func make(
        roles: [ProjectRole], document: DeviceCapabilityDocument
    ) throws(RigReviewRefusal) -> RigMappingReview {
        let proposal = try RigReviewRefusal.lifting { () throws(RigMappingRefusal) in
            try RigMappingProposal.make(roles: roles, devices: document)
        }
        return RigMappingReview(
            baseRevision: document.revision, proposal: proposal,
            removalCandidates: removalCandidates(of: proposal, routes: document.routes), baseRoutes: document.routes
        )
    }

    /// Binds one offered candidate of a role awaiting a choice (RG1 `choosing`) and recomputes the
    /// overlaps. Returns the updated review; the receiver is unchanged.
    func choosing(_ candidate: RigRouteCandidate, id: RouteID) throws(RigReviewRefusal) -> RigMappingReview {
        let chosen = try RigReviewRefusal.lifting { () throws(RigMappingRefusal) in
            try proposal.choosing(candidate, id: id)
        }
        var updated = self
        updated.proposal = chosen
        updated.overlaps = RigChannelOverlapScan.overlaps(in: baseRoutes + chosen.proposedRoutes)
        return updated
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
