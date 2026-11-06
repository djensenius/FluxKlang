//
//  RigReviewRefusal.swift
//  FluxKlang
//
//  Why a reviewed rig mapping change (or a decision set for one) is refused.
//  A refusal is all or nothing: the review is a value and is never changed,
//  and no candidate document is produced.
//

/// What two entries of one decision set both decide.
enum RigDecisionSubject: Hashable, Sendable {
    /// Two route decisions name the same route.
    case route(RouteID)
    /// Two decisions (a `choose`, a `leaveUnmapped` or a `replace`) bind or decline the same role.
    case role(RoleID)
}

/// Why a review, a choice, a decision set or an apply is refused.
enum RigReviewRefusal: Error, Hashable, Sendable {
    /// The RG1 proposal (or a choice within it) is refused.
    case mapping(RigMappingRefusal)
    /// `apply` got a device document whose revision is not the one the review was made from.
    case staleDocument(base: ContractRevision, found: ContractRevision)
    /// A route decision names a route that is not in the device document.
    case unknownRoute(RouteID)
    /// More than one decision for one route or one role; the smallest such subject is reported.
    case duplicateDecision(RigDecisionSubject)
    /// More route decisions than `DeviceCapabilityLimits.routes`, or more role decisions than
    /// `RigMappingLimits.roles`.
    case tooManyDecisions(count: Int, maximum: Int)
    /// A `remove` or `replace` names a route that is not a removal candidate, such as a confirmed
    /// route that still fits its role. Removing a working route is a route edit, not a mapping review.
    case removeNotCandidate(RouteID)
    /// A `replace` offers a candidate for another role than the replaced route's.
    case replaceRoleMismatch(route: RouteID, role: RoleID, candidateRole: RoleID)
    /// A `leaveUnmapped` names a role with no proposed route and no pending choice to decline.
    case declineNotOffered(RoleID)
    /// Two live routes of the candidate document write one output channel of one device.
    case outputChannelConflict(device: DeviceID, channel: Int, routes: [RouteID])
    /// The candidate document failed validation; the payload describes the first error.
    case invalidResult(String)
}

extension RigReviewRefusal {
    /// Runs an RG1 step and lifts its refusal into `.mapping`.
    static func lifting<T>(_ body: () throws(RigMappingRefusal) -> T) throws(RigReviewRefusal) -> T {
        do {
            return try body()
        } catch {
            throw .mapping(error)
        }
    }
}
