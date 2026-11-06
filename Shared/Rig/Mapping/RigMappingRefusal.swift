//
//  RigMappingRefusal.swift
//  FluxKlang
//
//  Why a role-to-route mapping proposal (or a caller's choice within one)
//  cannot be produced, and the bounds that keep a proposal small. A refusal is
//  never a mapping outcome: nothing is proposed and nothing is changed.
//

/// The documented bounds of a mapping proposal.
enum RigMappingLimits {
    /// At most this many candidates are listed per role. Any further compatible
    /// blocks are counted and reported in `RigCandidateTruncation`, never dropped silently.
    static let candidatesPerRole = 64
    /// At most this many roles per proposal: the project contract's record bound.
    static let roles = ProjectGraphLimits.projectRecords
}

/// Why a mapping proposal or a choice is refused.
enum RigMappingRefusal: Error, Hashable, Sendable {
    /// More roles than `RigMappingLimits.roles`.
    case tooManyRoles(count: Int, maximum: Int)
    /// Two roles share one `RoleID`; nothing is merged.
    case duplicateRole(RoleID)
    /// The device document fails its own `validate()`; the payload describes the first error.
    case invalidDevices(String)
    /// A choice names a role the proposal does not list.
    case unknownRole(RoleID)
    /// A choice names a candidate the proposal does not offer for a role awaiting a choice
    /// (including a block past the candidate cap, or a role that is not awaiting a choice).
    case candidateNotOffered(RigRouteCandidate)
    /// A chosen route ID is already used by an existing or proposed route.
    case routeIDInUse(RouteID)
}
