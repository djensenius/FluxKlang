//
//  RemoteRoleTransition.swift
//  FluxKlang
//
//  Events, plan steps and the local-engine gates of the remote-controller role
//  machine (#96, RR1). Values only: the model reads no clock, socket or OS state
//  and never calls `EngineLeaseRegistry`; the caller performs the plan.
//

/// The controlled host and the role the host granted. The grant comes from the
/// host's trust record (`PeerAuthorizedSession.role`), never from the peer's request.
struct RemoteSession: Hashable, Sendable {
    let host: HostID
    /// `.observer` is status-only; there is no separate observer state.
    let grant: PeerRole
}

/// The caller's explicit confirmation that this device may take over after `lostHost` went away.
struct PromotionConfirmation: Hashable, Sendable {
    let lostHost: HostID
}

/// The local engine as the caller observes it when it submits an event.
struct LocalEngineContext: Hashable, Sendable {
    /// The registry's current snapshot; nil when no project of this process holds the lease.
    let lease: EngineLeaseSnapshot?
    let lifecycle: EngineLifecycle
}

/// An explicit request to change role. Roles are never inferred.
enum RemoteRoleEvent: Hashable, Sendable {
    /// `releasing` is the token of the held lease to release first; nil when no lease is held.
    case enterRemote(RemoteSession, releasing: EngineLeaseToken?)
    case leaveRemote
    case hostLost(HostID)
    case hostReturned(HostID)
    /// The only path to a host-capable role. A request for the registry, not an activation.
    case explicitPromotion(confirmation: PromotionConfirmation?, project: ProjectID, window: WindowID)

    var kind: RemoteRoleEventKind {
        switch self {
        case .enterRemote: .enterRemote
        case .leaveRemote: .leaveRemote
        case .hostLost: .hostLost
        case .hostReturned: .hostReturned
        case .explicitPromotion: .explicitPromotion
        }
    }
}

/// What the coordinator would do, in plan order. There is deliberately no step that
/// stops a show, panics or safe-mutes, and none that opens an audio or console session.
enum RemoteRoleStep: Hashable, Sendable {
    /// Call `EngineLeaseRegistry.release(expected:)` with this token and apply the context change.
    case releaseEngineLease(EngineLeaseToken)
    case beginRemoteControl(RemoteSession)
    case endRemoteControl(HostID)
    case markHostUnavailable(HostID)
    case resumeRemoteControl(HostID)
    /// A request to `EngineLeaseRegistry.acquire`; the registry decides.
    case requestEngineLease(project: ProjectID, window: WindowID)
}

/// The role after a legal event and the ordered plan for the caller.
struct RemoteRoleTransition: Hashable, Sendable {
    let role: RemoteRole
    let plan: [RemoteRoleStep]
}

extension LocalEngineContext {
    /// The entry gate. Order, first defect wins: held lease without a token, stale token,
    /// lifecycle. Returns the release steps to prepend to the plan (empty or one).
    func entryRelease(_ releasing: EngineLeaseToken?) throws(RemoteRoleRefusal) -> [RemoteRoleStep] {
        var steps: [RemoteRoleStep] = []
        switch (lease, releasing) {
        case (nil, nil):
            break
        case (let held?, nil):
            throw .localLeaseHeld(held.project)
        case (nil, _?):
            throw .staleLeaseToken
        case (let held?, let token?):
            guard held.token == token else { throw .staleLeaseToken }
            steps = [.releaseEngineLease(token)]
        }
        switch lifecycle {
        case .stopped: break
        case .recovering: throw .engineRecovering
        case .preparing, .running, .degraded, .heldByOther: throw .showRunning(lifecycle)
        }
        return steps
    }

    /// The promotion gate. Order, first defect wins: confirmation present, confirmation names
    /// the lost host, no lease held. The lifecycle is not consulted: the plan only requests a lease.
    func checkPromotion(
        _ confirmation: PromotionConfirmation?, lostHost: HostID
    ) throws(RemoteRoleRefusal) {
        guard let confirmation else { throw .promotionNotConfirmed }
        guard confirmation.lostHost == lostHost else {
            throw .confirmationMismatch(expected: lostHost, found: confirmation.lostHost)
        }
        if let held = lease { throw .localLeaseHeld(held.project) }
    }
}
