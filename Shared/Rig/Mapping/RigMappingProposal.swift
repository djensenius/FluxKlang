//
//  RigMappingProposal.swift
//  FluxKlang
//
//  A pure, deterministic proposal for binding a project's audio roles to the
//  rig's device channels. It only ever produces `.proposed` routes: nothing
//  here confirms a route, attaches evidence, discovers or opens a device, or
//  plays a tone. Confirmation stays with the device contract's host-local
//  evidence path.
//
//  Per role, in this precedence:
//  1. a non-audio role is skipped (out of scope);
//  2. an audio role with an out-of-range channel count is unmapped;
//  3. a role with existing confirmed or proposed routes is left alone: it is
//     already routed when every such route still fits the role (direction,
//     and channel count and device bounds when the count is known), and
//     otherwise reports the routes that no longer fit (`mismatchedRoute`),
//     with no new proposal, so a role never gets a second route beside a
//     stale one; the caller removes or replaces the mismatched routes;
//  4. an audio role with an unconfirmed (`nil`) channel count is unmapped;
//  5. otherwise exactly one candidate yields a proposed route, more than one
//     awaits the caller's choice (nothing is auto-picked), and none leaves the
//     role unmapped.
//
//  Route budget: the existing routes plus all proposed routes never exceed
//  `DeviceCapabilityLimits.routes`. `make` hands the remaining budget to
//  single-candidate roles in `RoleID` order; once it is spent, every later role
//  with candidates (one or several) is unmapped with `.routeCapacityExhausted`,
//  and the rest of the proposal stands. No budget is reserved for roles awaiting
//  a choice, so `choosing` refuses a choice that would exceed the limit.
//
//  Validity claim (tested): the device document with `proposedRoutes` added and
//  the routes in `routesWithoutRequirement`, `mismatchedRoutes` and
//  `existingRoutes` removed passes `validate(roles: requirements)`. The claim is
//  a sufficient condition, not a deletion list: the three lists name what
//  `validate(roles: requirements)` cannot accept, and `routesWithoutRequirement`
//  includes valid, confirmed routes of legacy (`nil` count) already-routed roles,
//  non-audio roles and orphans, which a caller may well keep. The lists may
//  overlap (a stale orphan route is in `existingRoutes` and
//  `routesWithoutRequirement`; a mismatched route of a `nil`-count role is in
//  `mismatchedRoutes` and `routesWithoutRequirement`), so take their union.
//
//  Existing `stale` and `deviceMissing` routes are reported, never reused:
//  their IDs, bindings and evidence are not carried into any proposal. Routes
//  for roles that are not in the input are reported as orphans.
//

/// The state of an existing route that is reported instead of reused.
enum RigExistingRouteState: Hashable, Sendable {
    case stale
    case deviceMissing
}

/// An existing `stale` or `deviceMissing` route in the device document.
struct RigExistingRouteReport: Hashable, Sendable {
    let route: RouteID
    let role: RoleID
    let device: DeviceID
    let state: RigExistingRouteState
}

/// What the proposal says about one role.
enum RigRoleOutcome: Hashable, Sendable {
    /// Exactly one candidate fits: a `.proposed` route for it (never confirmed, no evidence).
    case proposed(AudioRoute, from: RigRouteCandidate)
    /// More than one candidate fits; nothing is picked until the caller chooses one.
    case awaitingChoice(RigRoleCandidates)
    /// The role already has confirmed or proposed routes (sorted by ID) that all fit it; nothing
    /// more is proposed.
    case alreadyRouted([RouteID])
    /// Existing confirmed or proposed routes of the role (sorted by ID) no longer fit it (direction
    /// or channel count). Nothing is proposed: the caller removes or replaces these routes.
    case mismatchedRoute([RouteID])
    /// The audio role cannot be offered a route.
    case unmapped(RigUnmappedReason)
    /// A non-audio role (MIDI, control, clock), out of scope for route mapping.
    case skipped(PortSignal)
}

/// One role's entry in a proposal. Only `RigMappingProposal` creates entries.
struct RigRoleMapping: Hashable, Sendable {
    let role: RoleID
    let outcome: RigRoleOutcome

    fileprivate init(role: RoleID, outcome: RigRoleOutcome) {
        self.role = role
        self.outcome = outcome
    }
}

/// A role-to-route mapping proposal over one device document.
struct RigMappingProposal: Hashable, Sendable {
    /// Prefix of derived route IDs; long role IDs are shortened to fit `RouteID.maximumLength`.
    static let routeIDPrefix = "route.proposed."

    /// One entry per input role, sorted by `RoleID`.
    private(set) var mappings: [RigRoleMapping]
    /// The route requirement of every audio role with a valid channel count. The device document with
    /// `proposedRoutes` added and the routes in `routesWithoutRequirement`, `mismatchedRoutes` and
    /// `existingRoutes` removed passes `validate(roles: requirements)`. This is a sufficient condition:
    /// the lists name what that validation cannot accept, not routes the caller must delete. They may
    /// overlap, so remove their union.
    let requirements: [RoleID: RouteRoleRequirement]
    /// Existing `stale`/`deviceMissing` routes, sorted by `RouteID`. Removed for the validity claim
    /// on `requirements`: they are reported, never checked against their role. A stale route of an
    /// orphan role is also in `routesWithoutRequirement`.
    let existingRoutes: [RigExistingRouteReport]
    /// Existing routes (any binding) whose role is not in the input, sorted. A subset of
    /// `routesWithoutRequirement`.
    let orphanRoutes: [RouteID]
    /// Existing routes (any binding) whose role has no entry in `requirements`, sorted: routes of
    /// orphan roles, non-audio roles, roles with an invalid channel count and legacy (`nil` count)
    /// roles. `validate(roles: requirements)` would report each as an unknown role, so they are
    /// removed for the validity claim on `requirements`. Many are valid, confirmed routes (legacy
    /// already-routed, non-audio and orphan roles) that the caller may keep; the list may overlap
    /// `existingRoutes` and `mismatchedRoutes`.
    let routesWithoutRequirement: [RouteID]
    /// Devices that are missing or stale and therefore offer no candidates, sorted by `DeviceID`.
    let absentDevices: [DeviceID]
    /// The device document's route IDs, which no proposed route may reuse.
    private let documentRouteIDs: Set<RouteID>

    /// Every proposed route, in role order. Each binding is `.proposed`, with no evidence.
    var proposedRoutes: [AudioRoute] {
        mappings.compactMap { if case .proposed(let route, _) = $0.outcome { route } else { nil } }
    }

    /// Roles that cannot be offered any route, sorted.
    var unmapped: [RoleID] {
        mappings.compactMap { if case .unmapped = $0.outcome { $0.role } else { nil } }
    }

    /// Roles with several candidates awaiting the caller's choice, sorted.
    var awaitingChoice: [RoleID] {
        mappings.compactMap { if case .awaitingChoice = $0.outcome { $0.role } else { nil } }
    }

    /// Non-audio roles skipped as out of scope, sorted.
    var skipped: [RoleID] {
        mappings.compactMap { if case .skipped = $0.outcome { $0.role } else { nil } }
    }

    /// Roles whose existing routes no longer fit them, sorted.
    var mismatched: [RoleID] {
        mappings.compactMap { if case .mismatchedRoute = $0.outcome { $0.role } else { nil } }
    }

    /// The existing routes that no longer fit their role (every `.mismatchedRoute` entry), sorted.
    /// Removed for the validity claim on `requirements`; the caller removes or replaces them. A
    /// mismatched route of a `nil`-count role is also in `routesWithoutRequirement`.
    var mismatchedRoutes: [RouteID] {
        mappings.flatMap { mapping -> [RouteID] in
            if case .mismatchedRoute(let routes) = mapping.outcome { routes } else { [] }
        }.sorted()
    }

    private init(mappings: [RigRoleMapping], requirements: [RoleID: RouteRoleRequirement],
                 existingRoutes: [RigExistingRouteReport], orphanRoutes: [RouteID],
                 routesWithoutRequirement: [RouteID], absentDevices: [DeviceID], documentRouteIDs: Set<RouteID>) {
        self.mappings = mappings
        self.requirements = requirements
        self.existingRoutes = existingRoutes
        self.orphanRoutes = orphanRoutes
        self.routesWithoutRequirement = routesWithoutRequirement
        self.absentDevices = absentDevices
        self.documentRouteIDs = documentRouteIDs
    }

    /// Builds the proposal. The result depends only on the inputs' contents, not their order.
    static func make(
        roles: [ProjectRole], devices document: DeviceCapabilityDocument
    ) throws(RigMappingRefusal) -> RigMappingProposal {
        guard roles.count <= RigMappingLimits.roles else {
            throw .tooManyRoles(count: roles.count, maximum: RigMappingLimits.roles)
        }
        var seen = Set<RoleID>()
        for role in roles where !seen.insert(role.id).inserted { throw .duplicateRole(role.id) }
        do { try document.validate() } catch { throw .invalidDevices(String(describing: error)) }

        let eligible = RigRouteCandidates.eligibleDevices(document.devices)
        var routedRoles: [RoleID: [AudioRoute]] = [:]
        for route in document.routes where route.binding == .confirmed || route.binding == .proposed {
            routedRoles[route.role, default: []].append(route)
        }
        let layouts = Dictionary(uniqueKeysWithValues: document.devices.map { ($0.id, $0.layout) })
        var ids = RigRouteIDAllocator(used: Set(document.routes.map(\.id)))
        // `document.validate()` bounds the routes by the limit, so the budget is never negative.
        var budget = DeviceCapabilityLimits.routes - document.routes.count
        var requirements: [RoleID: RouteRoleRequirement] = [:]
        var mappings: [RigRoleMapping] = []
        for role in roles.sorted(by: { $0.id < $1.id }) {
            let outcome: RigRoleOutcome
            let direction = RigRoleRequirements.direction(of: role.direction)
            switch RigRoleRequirements.requirement(for: role) {
            case .notAudio(let signal):
                outcome = .skipped(signal)
            case .unmappable(.invalidChannelCount(let count)):
                outcome = .unmapped(.invalidChannelCount(count))
            case .unmappable(let reason):
                outcome = Self.existingOutcome(routedRoles[role.id], direction: direction, requirement: nil,
                                               layouts: layouts) ?? .unmapped(reason)
            case .audio(let requirement):
                requirements[role.id] = requirement
                if let routed = Self.existingOutcome(routedRoles[role.id], direction: direction,
                                                     requirement: requirement, layouts: layouts) {
                    outcome = routed
                } else {
                    let found = RigRouteCandidates.candidates(for: role.id, requirement: requirement, on: eligible)
                    outcome = Self.outcome(for: found, ids: &ids, budget: &budget)
                }
            }
            mappings.append(RigRoleMapping(role: role.id, outcome: outcome))
        }
        return RigMappingProposal(
            mappings: mappings, requirements: requirements,
            existingRoutes: Self.reports(document.routes),
            orphanRoutes: document.routes.filter { !seen.contains($0.role) }.map(\.id).sorted(),
            routesWithoutRequirement: document.routes.filter { requirements[$0.role] == nil }.map(\.id).sorted(),
            absentDevices: document.devices.filter { $0.presence != .present }.map(\.id).sorted(),
            documentRouteIDs: Set(document.routes.map(\.id))
        )
    }

    /// Binds one offered candidate of a role awaiting a choice to a `.proposed` route with the
    /// caller's ID. Returns the updated proposal; the receiver is unchanged.
    func choosing(_ candidate: RigRouteCandidate, id: RouteID) throws(RigMappingRefusal) -> RigMappingProposal {
        guard let index = mappings.firstIndex(where: { $0.role == candidate.role }) else {
            throw .unknownRole(candidate.role)
        }
        guard case .awaitingChoice(let offered) = mappings[index].outcome,
              offered.candidates.contains(candidate) else {
            throw .candidateNotOffered(candidate)
        }
        let proposed = proposedRoutes
        guard documentRouteIDs.count + proposed.count < DeviceCapabilityLimits.routes else {
            throw .routeCapacityExhausted(limit: DeviceCapabilityLimits.routes)
        }
        guard !documentRouteIDs.contains(id), !proposed.contains(where: { $0.id == id }) else {
            throw .routeIDInUse(id)
        }
        var updated = self
        updated.mappings[index] = RigRoleMapping(
            role: candidate.role, outcome: .proposed(Self.route(for: candidate, id: id), from: candidate)
        )
        return updated
    }

    /// The outcome for a role with existing confirmed or proposed routes, or `nil` when it has none.
    /// With a known requirement every route must pass `validate(layout:role:)`; with an unconfirmed
    /// channel count only the direction can be checked.
    private static func existingOutcome(
        _ routes: [AudioRoute]?, direction: RouteDirection, requirement: RouteRoleRequirement?,
        layouts: [DeviceID: ChannelLayout?]
    ) -> RigRoleOutcome? {
        guard let routes else { return nil }
        let mismatched = routes.filter { route in
            guard let requirement else { return route.direction != direction }
            return (try? route.validate(layout: layouts[route.device] ?? nil, role: requirement)) == nil
        }
        guard mismatched.isEmpty else { return .mismatchedRoute(mismatched.map(\.id).sorted()) }
        return .alreadyRouted(routes.map(\.id).sorted())
    }

    private static func outcome(
        for found: RigRoleCandidates, ids: inout RigRouteIDAllocator, budget: inout Int
    ) -> RigRoleOutcome {
        switch found.candidates.count {
        case 0:
            return .unmapped(.noCompatibleBlock)
        case 1:
            guard budget > 0 else { return .unmapped(.routeCapacityExhausted(limit: DeviceCapabilityLimits.routes)) }
            budget -= 1
            let candidate = found.candidates[0]
            return .proposed(route(for: candidate, id: ids.next(for: candidate.role)), from: candidate)
        default:
            // Nothing is reserved for a choice; with no budget left at all, no choice could succeed.
            guard budget > 0 else { return .unmapped(.routeCapacityExhausted(limit: DeviceCapabilityLimits.routes)) }
            return .awaitingChoice(found)
        }
    }

    private static func route(for candidate: RigRouteCandidate, id: RouteID) -> AudioRoute {
        AudioRoute(id: id, role: candidate.role, device: candidate.device, direction: candidate.direction,
                   channels: candidate.channels, binding: .proposed)
    }

    /// Test-only: the IDs `make` would derive for `roles` (in the given order) over the document IDs
    /// `used`, and how many candidate IDs the allocator built to find them.
    static func routeIDsForTesting(
        for roles: [RoleID], avoiding used: Set<RouteID>
    ) -> (ids: [RouteID], attempts: Int) {
        var allocator = RigRouteIDAllocator(used: used)
        let ids = roles.map { allocator.next(for: $0) }
        return (ids, allocator.attempts)
    }

    private static func reports(_ routes: [AudioRoute]) -> [RigExistingRouteReport] {
        routes.compactMap { route -> RigExistingRouteReport? in
            let state: RigExistingRouteState
            switch route.binding {
            case .stale: state = .stale
            case .deviceMissing: state = .deviceMissing
            case .proposed, .confirmed: return nil
            }
            return RigExistingRouteReport(route: route.id, role: route.role, device: route.device, state: state)
        }.sorted { $0.route < $1.route }
    }
}

/// Derives `route.proposed.<role>` IDs for one proposal. Each stem remembers its next suffix, so
/// roles that share a shortened stem resume where the previous one stopped instead of rescanning
/// from `.2`. Any used ID is skipped at most twice (as some stem's `.n` and as a stem itself), so
/// deriving `r` IDs over `d` document IDs costs at most `r + 2 * (r + d)` attempts.
private struct RigRouteIDAllocator {
    private var used: Set<RouteID>
    private var nextSuffix: [String: Int] = [:]
    /// Candidate IDs built so far, for the test-only cost check.
    private(set) var attempts = 0

    init(used: Set<RouteID>) {
        self.used = used
    }

    mutating func next(for role: RoleID) -> RouteID {
        let stem = String((RigMappingProposal.routeIDPrefix + role.rawValue).prefix(RouteID.maximumLength - 8))
        let start = nextSuffix[stem, default: 1]
        // The `used` check stays as a backstop: suffixes taken by document IDs are skipped.
        for suffix in start...(start + used.count) {
            attempts += 1
            if let id = RouteID(rawValue: suffix == 1 ? stem : "\(stem).\(suffix)"), used.insert(id).inserted {
                nextSuffix[stem] = suffix + 1
                return id
            }
        }
        preconditionFailure("A route ID among \(used.count + 1) suffixes is always unused")
    }
}
