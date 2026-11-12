//
//  RemoteRolePresentation.swift
//  FluxKlang
//
//  The remote controller's role-dependent presentation as a value (#96, REM1,
//  host-remote-roles.md): title, state, status text, whether inputs are enabled, the
//  discarded-changes notice, and the structure and safety lines. Pure: no view, I/O,
//  clock, session read or command. Nothing calls it yet.
//

/// What the remote shows for its connection to the host.
enum RemoteRolePresentationState: Hashable, Sendable {
    case connected
    case resyncing
    case disconnected
}

struct RemoteRolePresentation: Hashable, Sendable {
    let title: String
    let state: RemoteRolePresentationState
    /// nil while connected.
    let statusText: String?
    let inputsEnabled: Bool
    /// The discarded-changes notice; nil without a report or when it dropped nothing.
    let notice: String?
    /// nil for an observer.
    let structureText: String?
    let safetyText: String
    /// The connection epoch of the phase's session.
    let epoch: Int
    /// The name shown: the given one verbatim, or the host ID when it is nil or empty.
    let hostName: String

    private init(
        title: String, state: RemoteRolePresentationState, statusText: String?, inputsEnabled: Bool,
        notice: String?, structureText: String?, safetyText: String, epoch: Int, hostName: String
    ) {
        self.title = title
        self.state = state
        self.statusText = statusText
        self.inputsEnabled = inputsEnabled
        self.notice = notice
        self.structureText = structureText
        self.safetyText = safetyText
        self.epoch = epoch
        self.hostName = hostName
    }

    /// Refusals, first wins: the role is not remote, the phase is of another host, the report is of another
    /// session. A refusal returns nothing.
    static func make(
        role: RemoteRole, phase: PeerReconnectState.Phase, hostName: String?, discarded: PeerDiscardReport?
    ) throws(RemoteRolePresentationRefusal) -> RemoteRolePresentation {
        guard let remote = role.session else { throw .notRemote(role.kind) }
        let session = phase.session
        guard session.hostEpoch.host == remote.host else {
            throw .hostMismatch(expected: remote.host, found: session.hostEpoch.host)
        }
        if let discarded, let stale = session.staleDependency(
            host: discarded.session.hostEpoch, connection: discarded.session.connectionEpoch
        ) {
            throw .reportSessionMismatch(stale)
        }
        let name = hostName.flatMap { $0.utf8.isEmpty ? nil : $0 } ?? remote.host.rawValue
        let state = state(role: role, phase: phase)
        let isController = remote.grant == .remoteController
        let epoch = session.connectionEpoch.generation.value
        return RemoteRolePresentation(
            title: isController
                ? RemoteRoleText.controllerTitle(host: name, epoch: epoch) : RemoteRoleText.observerTitle(host: name),
            state: state,
            statusText: statusText(state),
            inputsEnabled: isController && state == .connected,
            notice: notice(discarded, state: state, host: name),
            structureText: isController ? RemoteRoleText.structure : nil,
            safetyText: isController ? RemoteRoleText.controllerSafety : RemoteRoleText.observerSafety,
            epoch: epoch,
            hostName: name
        )
    }

    private static func state(role: RemoteRole, phase: PeerReconnectState.Phase) -> RemoteRolePresentationState {
        if role.kind == .hostLost { return .disconnected }
        switch phase {
        case .disconnected: return .disconnected
        case .synced(_, awaitingResume: false): return .connected
        case .synced(_, awaitingResume: true), .resyncing, .connected: return .resyncing
        }
    }

    private static func statusText(_ state: RemoteRolePresentationState) -> String? {
        switch state {
        case .connected: nil
        case .resyncing: RemoteRoleText.resyncing
        case .disconnected: RemoteRoleText.disconnected
        }
    }

    private static func notice(
        _ report: PeerDiscardReport?, state: RemoteRolePresentationState, host name: String
    ) -> String? {
        guard let report, report.discardedCount > 0 else { return nil }
        return RemoteRoleText.discarded(count: report.discardedCount, host: name, valuesMatch: state == .connected)
    }
}

private extension PeerReconnectState.Phase {
    var session: PeerSyncSession {
        switch self {
        case .connected(let session), .synced(let session, _), .resyncing(let session), .disconnected(let session):
            session
        }
    }
}
