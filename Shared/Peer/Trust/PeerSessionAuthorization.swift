//
//  PeerSessionAuthorization.swift
//  FluxKlang
//
//  Binds a transport-authenticated peer identity and a #93 negotiated session
//  to the host's trust record, and gates peer commands (#94 P1). The binding
//  never widens a grant: a session below the paired protocol version is a
//  downgrade and refuses, and negotiated capabilities only narrow (no
//  `control` means no command grants, no `status` means no status read;
//  `telemetry` adds nothing).
//

/// The effective grants of one trusted peer on one negotiated connection.
struct PeerAuthorizedSession: Hashable, Sendable {
    let identity: PeerIdentityFingerprint
    let role: PeerRole
    let negotiated: PeerNegotiatedSession
    let hostEpoch: HostEpoch
    let connectionEpoch: ConnectionEpoch
    let permission: PermissionFingerprint
    /// Grants narrowed by the negotiated capabilities.
    let commands: Set<PeerCommandGrant>
    let readsStatus: Bool

    /// Exact pair membership; never a prefix, group or class-only match.
    func permits(_ controlClass: ControlClass, _ scope: CommandScope) -> Bool {
        commands.contains(PeerCommandGrant(controlClass: controlClass, scope: scope))
    }

    /// The #62 admission context for this connection. Its scope and class sets
    /// are a cross product, so peers must go through `PeerGrantGate`, which
    /// checks the exact pair first.
    func admissionContext(revisions: CommandRevisions, catalog: ParameterCatalog,
                          ceiling: Double? = nil) -> AdmissionContext {
        AdmissionContext(
            hostEpoch: hostEpoch, connectionEpoch: connectionEpoch, revisions: revisions, permission: permission,
            allowedScopes: Set(commands.map(\.scope)), allowedClasses: Set(commands.map(\.controlClass)),
            catalog: catalog, ceiling: ceiling
        )
    }
}

extension PeerTrustStore {
    /// The #93 acceptor availability for a transport-authenticated identity.
    /// Unknown and revoked identities are denied before any hello is answered.
    func availability(for identity: PeerIdentityFingerprint) -> PeerAcceptorAvailability {
        !isRevoked(identity) && record(for: identity) != nil ? .available : .denied
    }

    /// Binds `identity` (from the authenticated transport, never from peer
    /// payloads) to `session`. `connection` and `host` are host-issued.
    func bind(_ identity: PeerIdentityFingerprint, session: PeerNegotiatedSession, connection: ConnectionID,
              host: HostEpoch) throws(PeerTrustError) -> PeerAuthorizedSession {
        guard !isRevoked(identity) else { throw .revoked }
        guard let record = record(for: identity) else { throw .unknownIdentity }
        guard session.hostEpoch == host.generation else { throw .hostEpochMismatch }
        guard session.protocolVersion >= record.protocolFloor else {
            throw .versionDowngrade(floor: record.protocolFloor, negotiated: session.protocolVersion)
        }
        let control = session.capabilities.contains(.control)
        return PeerAuthorizedSession(
            identity: identity, role: record.role, negotiated: session, hostEpoch: host,
            connectionEpoch: ConnectionEpoch(connection: connection, host: host.host,
                                             generation: session.connectionEpoch),
            permission: record.permissionFingerprint, commands: control ? record.grants.commands : [],
            readsStatus: record.grants.reads.contains(.statusRead) && session.capabilities.contains(.status)
        )
    }
}

/// Admits a paired peer's command candidate.
enum PeerGrantGate {
    /// The host state a peer command is admitted against.
    struct HostState: Sendable {
        let revisions: CommandRevisions
        let catalog: ParameterCatalog
        let lifecycle: EngineLifecycle
        var ceiling: Double?
    }

    /// Re-binds against the current store (so revocation and grant changes take
    /// effect at once), then checks the exact (class, scope) pair, and only then
    /// delegates to `HostCommandGate` unchanged. Revoked or unknown peers are
    /// denied; a changed record yields `permissionChanged` through admission.
    static func admit(_ intent: CommandIntent, from session: PeerAuthorizedSession, trust: PeerTrustStore,
                      host: HostState) -> HostCommandDecision {
        let current: PeerAuthorizedSession
        do {
            current = try trust.bind(session.identity, session: session.negotiated,
                                     connection: session.connectionEpoch.connection, host: session.hostEpoch)
        } catch { return .refused(.rejected(.permissionDenied)) }
        guard current.permits(intent.commandClass, intent.operation.scope) else {
            return .refused(.rejected(.scopeDenied))
        }
        let admission = current.admissionContext(revisions: host.revisions, catalog: host.catalog,
                                                 ceiling: host.ceiling)
        return HostCommandGate.admit(intent, admission: admission, lifecycle: host.lifecycle)
    }
}
