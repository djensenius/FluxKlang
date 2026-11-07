//
//  RemoteRoleRefusal.swift
//  FluxKlang
//
//  Typed refusals of the remote-controller role machine (#96, RR1). A refusal
//  never changes the role, the lease registry or any sink.
//

/// The role a device is in, without its payload. Used by refusals and tables.
enum RemoteRoleKind: Hashable, Sendable, CaseIterable {
    case standalone
    case remoteController
    case hostLost
}

/// The event, without its payload. Used by refusals and tables.
enum RemoteRoleEventKind: Hashable, Sendable, CaseIterable {
    case enterRemote
    case leaveRemote
    case hostLost
    case hostReturned
    case explicitPromotion
}

/// Why `RemoteRole.apply` refused an event. Checks run in the order documented on
/// `RemoteRole.apply`; the first defect wins.
enum RemoteRoleRefusal: Error, Hashable, Sendable {
    /// The (state, event) pair is not in the transition table.
    case illegalTransition(from: RemoteRoleKind, event: RemoteRoleEventKind)
    /// A host-loss or host-return event names a host other than the controlled one.
    case hostMismatch(expected: HostID, found: HostID)
    /// This device holds the local engine lease; release it explicitly first (or pass its token).
    case localLeaseHeld(ProjectID)
    /// The release token is not the held lease's token: released, replaced, foreign, or no lease is held.
    case staleLeaseToken
    /// The local engine may be rendering or preparing; entering remote never stops a show.
    case showRunning(EngineLifecycle)
    /// Unresolved recovery keeps outputs muted; remote mode is not entered over it.
    case engineRecovering
    /// Promotion carries no explicit confirmation.
    case promotionNotConfirmed
    /// The confirmation names another host than the lost one.
    case confirmationMismatch(expected: HostID, found: HostID)
}

/// Why the capability guard refused a capability.
enum RemoteCapabilityRefusal: Error, Hashable, Sendable {
    /// There is no remote relationship, so there is nowhere to send a peer UI command.
    case noRemoteSession
    /// The controlled host went away; commands are not sent until it returns.
    case hostLost
    /// The session's grant is `observer`: status only.
    case observerHasNoCommands
    /// A remote controller never writes to the local engine, a console or MIDI.
    case noLocalWriteInRemoteRole
    /// Raw notes and clocks are never peer UI commands and are not local input in a remote role.
    case rawInputIsNotAPeerCommand
}
