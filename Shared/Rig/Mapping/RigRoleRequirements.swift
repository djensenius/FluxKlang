//
//  RigRoleRequirements.swift
//  FluxKlang
//
//  What a portable `ProjectRole` needs from a host-local audio route, in the
//  device contract's own vocabulary (`RouteRoleRequirement`). Only audio roles
//  are mapped; MIDI, control and clock roles are skipped explicitly (out of
//  scope for #100 RG1), never coerced into audio routes.
//

/// Why an audio role cannot be offered any route.
enum RigUnmappedReason: Hashable, Sendable {
    /// The role's channel count is not confirmed (`nil`), e.g. an adopted legacy role, and the
    /// role has no existing confirmed or proposed route.
    case unconfirmedChannelCount
    /// The role's channel count is outside `GraphPort.channelRange`.
    case invalidChannelCount(Int)
    /// No present device offers a contiguous block of the role's direction and channel count.
    case noCompatibleBlock
    /// Blocks fit (one or several), but the existing routes plus the proposals for roles that sort
    /// earlier already fill `DeviceCapabilityLimits.routes` (`limit`), so no route could be added.
    case routeCapacityExhausted(limit: Int)
}

/// How a role enters the mapping.
enum RigRoleRequirement: Hashable, Sendable {
    /// An audio role with a valid channel count, and what its route must satisfy.
    case audio(RouteRoleRequirement)
    /// An audio role that can never be routed as it stands.
    case unmappable(RigUnmappedReason)
    /// A non-audio role (MIDI, control, clock); out of scope and skipped explicitly.
    case notAudio(PortSignal)
}

/// Derives route requirements from portable roles.
enum RigRoleRequirements {
    /// The route direction for a role direction. Both are from the host's point of view:
    /// an input role (e.g. "Vocal Mic In") is fed by a device input channel.
    static func direction(of direction: PortDirection) -> RouteDirection {
        switch direction {
        case .input: .input
        case .output: .output
        }
    }

    /// The requirement for one role. Signal is checked first, so a non-audio role is skipped
    /// whatever its channel field says.
    static func requirement(for role: ProjectRole) -> RigRoleRequirement {
        guard role.signal == .audio else { return .notAudio(role.signal) }
        guard let channels = role.channels else { return .unmappable(.unconfirmedChannelCount) }
        guard GraphPort.channelRange.contains(channels) else { return .unmappable(.invalidChannelCount(channels)) }
        return .audio(RouteRoleRequirement(direction: direction(of: role.direction), channelCount: channels))
    }
}
