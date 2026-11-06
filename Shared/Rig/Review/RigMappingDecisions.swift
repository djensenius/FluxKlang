//
//  RigMappingDecisions.swift
//  FluxKlang
//
//  The user's explicit decisions on a rig mapping review. Every route is kept
//  unless a decision removes it: there is no implicit removal. A role awaiting a
//  choice stays unmapped unless a decision chooses one of its candidates.
//
//  Workspace UX actions on a Lost/Muted (`deviceMissing`) route:
//  - "Keep muted" is `.keep(route)` (or no decision at all);
//  - "Choose another device" is `.replace(route, with: candidate, id:)` with a
//    candidate from the review's `replacementOffers`: the removal and the
//    choice for the same role succeed or fail together. This works for a role
//    with one candidate too: the review holds that candidate as an offer
//    instead of adding it, so "Keep muted" leaves the role unmapped.
//

/// A decision about one existing route of the device document.
enum RigRouteDecision: Hashable, Sendable {
    /// Keep the route as it is. This is the default for every route.
    case keep(RouteID)
    /// Remove the route. Only a removal candidate of the review can be removed.
    case remove(RouteID)
    /// Remove the route and bind `candidate`, offered for the same role in the review's
    /// `replacementOffers`, as a `.proposed` route `id`.
    case replace(RouteID, with: RigRouteCandidate, id: RouteID)

    /// The existing route this decision is about.
    var route: RouteID {
        switch self {
        case .keep(let route), .remove(let route), .replace(let route, _, _): route
        }
    }

    /// The role a `replace` binds, or `nil`.
    var replacementRole: RoleID? {
        if case .replace(_, let candidate, _) = self { candidate.role } else { nil }
    }
}

/// A decision about one role of the review.
enum RigRoleDecision: Hashable, Sendable {
    /// Bind one candidate offered to a role awaiting a choice as a `.proposed` route `id`.
    case choose(RigRouteCandidate, id: RouteID)
    /// Decline the role's proposed route or pending choice; the role stays unmapped.
    case leaveUnmapped(RoleID)

    /// The role this decision is about.
    var role: RoleID {
        switch self {
        case .choose(let candidate, _): candidate.role
        case .leaveUnmapped(let role): role
        }
    }
}

/// A validated decision set: at most one decision per route and per role. The result of `apply`
/// does not depend on the order the decisions were given in.
struct RigMappingDecisions: Hashable, Sendable {
    /// No decisions: every route is kept, every review addition is added, no choice is made.
    static let empty = RigMappingDecisions(routes: [:], roles: [:])

    /// Route decisions by route.
    private(set) var routes: [RouteID: RigRouteDecision]
    /// Role decisions by role (`replace` decisions are listed in `routes` only).
    private(set) var roles: [RoleID: RigRoleDecision]

    private init(routes: [RouteID: RigRouteDecision], roles: [RoleID: RigRoleDecision]) {
        self.routes = routes
        self.roles = roles
    }

    /// Builds a decision set. Refuses more than `DeviceCapabilityLimits.routes` route decisions or
    /// `RigMappingLimits.roles` role decisions, and any second decision for one route or one role
    /// (a `replace` decides its candidate's role too), reporting the smallest such subject.
    static func make(
        routes: [RigRouteDecision] = [], roles: [RigRoleDecision] = []
    ) throws(RigReviewRefusal) -> RigMappingDecisions {
        guard routes.count <= DeviceCapabilityLimits.routes else {
            throw .tooManyDecisions(count: routes.count, maximum: DeviceCapabilityLimits.routes)
        }
        guard roles.count <= RigMappingLimits.roles else {
            throw .tooManyDecisions(count: roles.count, maximum: RigMappingLimits.roles)
        }
        var byRoute: [RouteID: RigRouteDecision] = [:]
        var routeRepeats: [RouteID] = []
        for decision in routes where byRoute.updateValue(decision, forKey: decision.route) != nil {
            routeRepeats.append(decision.route)
        }
        if let first = routeRepeats.min() { throw .duplicateDecision(.route(first)) }
        var byRole: [RoleID: RigRoleDecision] = [:]
        var decidedRoles = Set<RoleID>()
        var roleRepeats: [RoleID] = []
        for decision in roles {
            byRole[decision.role] = decision
            if !decidedRoles.insert(decision.role).inserted { roleRepeats.append(decision.role) }
        }
        for role in routes.compactMap(\.replacementRole) where !decidedRoles.insert(role).inserted {
            roleRepeats.append(role)
        }
        if let first = roleRepeats.min() { throw .duplicateDecision(.role(first)) }
        return RigMappingDecisions(routes: byRoute, roles: byRole)
    }
}
