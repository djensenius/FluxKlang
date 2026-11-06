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
//  Per role, in this precedence: a non-audio role is skipped (out of scope);
//  an audio role without a valid channel count is unmapped; a role with an
//  existing confirmed or proposed route is left alone; otherwise exactly one
//  candidate yields a proposed route, more than one awaits the caller's choice
//  (nothing is auto-picked), and none leaves the role unmapped.
//
//  Existing `stale` and `deviceMissing` routes are reported, never reused:
//  their IDs, bindings and evidence are not carried into any proposal.
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
    /// The role already has confirmed or proposed routes (sorted by ID); nothing more is proposed.
    case alreadyRouted([RouteID])
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
    /// The route requirement of every audio role with a valid channel count, for `validate(roles:)`.
    let requirements: [RoleID: RouteRoleRequirement]
    /// Existing `stale`/`deviceMissing` routes, sorted by `RouteID`.
    let existingRoutes: [RigExistingRouteReport]
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

    private init(mappings: [RigRoleMapping], requirements: [RoleID: RouteRoleRequirement],
                 existingRoutes: [RigExistingRouteReport], absentDevices: [DeviceID], documentRouteIDs: Set<RouteID>) {
        self.mappings = mappings
        self.requirements = requirements
        self.existingRoutes = existingRoutes
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
        var routedRoles: [RoleID: [RouteID]] = [:]
        for route in document.routes where route.binding == .confirmed || route.binding == .proposed {
            routedRoles[route.role, default: []].append(route.id)
        }
        var usedIDs = Set(document.routes.map(\.id))
        var requirements: [RoleID: RouteRoleRequirement] = [:]
        var mappings: [RigRoleMapping] = []
        for role in roles.sorted(by: { $0.id < $1.id }) {
            let outcome: RigRoleOutcome
            switch RigRoleRequirements.requirement(for: role) {
            case .notAudio(let signal):
                outcome = .skipped(signal)
            case .unmappable(let reason):
                outcome = .unmapped(reason)
            case .audio(let requirement):
                requirements[role.id] = requirement
                if let routed = routedRoles[role.id] {
                    outcome = .alreadyRouted(routed.sorted())
                } else {
                    let found = RigRouteCandidates.candidates(for: role.id, requirement: requirement, on: eligible)
                    outcome = Self.outcome(for: found, usedIDs: &usedIDs)
                }
            }
            mappings.append(RigRoleMapping(role: role.id, outcome: outcome))
        }
        return RigMappingProposal(
            mappings: mappings, requirements: requirements,
            existingRoutes: Self.reports(document.routes),
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
        guard !documentRouteIDs.contains(id), !proposedRoutes.contains(where: { $0.id == id }) else {
            throw .routeIDInUse(id)
        }
        var updated = self
        updated.mappings[index] = RigRoleMapping(
            role: candidate.role, outcome: .proposed(Self.route(for: candidate, id: id), from: candidate)
        )
        return updated
    }

    private static func outcome(for found: RigRoleCandidates, usedIDs: inout Set<RouteID>) -> RigRoleOutcome {
        switch found.candidates.count {
        case 0:
            return .unmapped(.noCompatibleBlock)
        case 1:
            let candidate = found.candidates[0]
            let id = routeID(for: candidate.role, avoiding: usedIDs)
            usedIDs.insert(id)
            return .proposed(route(for: candidate, id: id), from: candidate)
        default:
            return .awaitingChoice(found)
        }
    }

    private static func route(for candidate: RigRouteCandidate, id: RouteID) -> AudioRoute {
        AudioRoute(id: id, role: candidate.role, device: candidate.device, direction: candidate.direction,
                   channels: candidate.channels, binding: .proposed)
    }

    /// `route.proposed.<role>`, shortened to leave room for a `.<n>` suffix; the first unused
    /// of the stem, `stem.2`, `stem.3`, … is chosen.
    static func routeID(for role: RoleID, avoiding used: Set<RouteID>) -> RouteID {
        let stem = String((routeIDPrefix + role.rawValue).prefix(RouteID.maximumLength - 8))
        for suffix in 1...(used.count + 1) {
            if let id = RouteID(rawValue: suffix == 1 ? stem : "\(stem).\(suffix)"), !used.contains(id) {
                return id
            }
        }
        preconditionFailure("A route ID among \(used.count + 1) suffixes is always unused")
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
