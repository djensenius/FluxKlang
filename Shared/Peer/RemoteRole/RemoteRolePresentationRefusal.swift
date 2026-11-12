//
//  RemoteRolePresentationRefusal.swift
//  FluxKlang
//
//  Typed refusals of the remote controller's role presentation (#96, REM1). A
//  refusal returns nothing and changes no role. Checks run in the order below;
//  the first defect wins.
//

/// Why `RemoteRolePresentation.make` refused its inputs.
enum RemoteRolePresentationRefusal: Error, Hashable, Sendable {
    /// The role has no remote session; only a remote or host-lost role is presented.
    case notRemote(RemoteRoleKind)
    /// The role controls `expected`, but the connection phase belongs to `found`.
    case hostMismatch(expected: HostID, found: HostID)
    /// The discard report belongs to another session than the connection phase.
    case reportSessionMismatch(StaleDependency)
}
