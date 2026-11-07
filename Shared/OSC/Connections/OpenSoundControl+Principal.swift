//
//  OpenSoundControl+Principal.swift
//  FluxKlang
//
//  The principal that OSC intake acts as (#89, O2b). It is live-only: its
//  allowed classes are exactly `[.live]`, its grants are exact
//  (class, scope) pairs over parameter, action and transport scopes, and every
//  command it forms must have `.controller` origin. The exact pair is checked
//  before `HostCommandGate.admit` runs unchanged, so the gate never sees a
//  scope-by-class cross product (the precedent is `PeerGrantGate`). Host and
//  connection epochs and the permission fingerprint are injected by the host,
//  never minted here, and the principal keeps no peer key, address or session.
//

extension OpenSoundControl {
    /// One exact grant: `scope` under `controlClass`. There is no prefix, group or class-only matching.
    struct PrincipalGrant: Sendable, Hashable {
        let controlClass: ControlClass
        let scope: CommandScope
    }

    /// Every typed refusal of principal construction. A refused call changes nothing.
    enum PrincipalRefusal: Error, Sendable, Hashable {
        /// The permission fingerprint is not well formed (1 through 256 UTF-8 bytes).
        case malformedPermission
        /// The connection epoch belongs to a different host than the host epoch.
        case connectionEpochForOtherHost
        case noGrants
        case tooManyGrants(count: Int, limit: Int)
        /// A grant under any class other than `.live`.
        case classNotAllowed(ControlClass)
        /// Route, patch, draft and safety (panic, safe mute) scopes are never grantable to OSC.
        case scopeNotGrantable(CommandScope)
        case duplicateGrant(PrincipalGrant)
    }

    /// The live-only authority of OSC intake. Validated once; private storage afterwards.
    struct Principal: Sendable, Hashable {
        static let maximumGrants = 256
        /// Exactly the live class. Structural, hazardous, safety and proposal commands are never admitted.
        static let allowedClasses: Set<ControlClass> = [.live]
        /// OSC peers are controllers: a command with any other origin is refused.
        static let origin = CommandOrigin.controller

        private(set) var hostEpoch: HostEpoch
        private(set) var connectionEpoch: ConnectionEpoch
        private(set) var permission: PermissionFingerprint
        /// Held as a set, so grant order never matters.
        private(set) var grants: Set<PrincipalGrant>

        /// Validation order: permission, connection host, grant count, then each grant in array order
        /// (class, scope, duplicate). `grants` holds 1 through `maximumGrants` entries.
        init(
            hostEpoch: HostEpoch, connectionEpoch: ConnectionEpoch, permission: PermissionFingerprint,
            grants: [PrincipalGrant]
        ) throws(PrincipalRefusal) {
            guard permission.isWellFormed else { throw .malformedPermission }
            guard connectionEpoch.host == hostEpoch.host else { throw .connectionEpochForOtherHost }
            guard !grants.isEmpty else { throw .noGrants }
            guard grants.count <= Self.maximumGrants else {
                throw .tooManyGrants(count: grants.count, limit: Self.maximumGrants)
            }
            var granted: Set<PrincipalGrant> = []
            for grant in grants {
                guard Self.allowedClasses.contains(grant.controlClass) else {
                    throw .classNotAllowed(grant.controlClass)
                }
                guard Self.isGrantable(grant.scope) else { throw .scopeNotGrantable(grant.scope) }
                guard granted.insert(grant).inserted else { throw .duplicateGrant(grant) }
            }
            self.hostEpoch = hostEpoch
            self.connectionEpoch = connectionEpoch
            self.permission = permission
            self.grants = granted
        }

        /// Exact pair membership; never a prefix, group, class-only or scope-only match.
        func permits(_ controlClass: ControlClass, _ scope: CommandScope) -> Bool {
            grants.contains(PrincipalGrant(controlClass: controlClass, scope: scope))
        }

        /// The #62 admission context. Every grant is `.live`, so `[.live]` over the granted scopes describes the
        /// grants exactly, and the raw gate admits no pair this principal does not grant. The raw gate does not
        /// check the `.controller` origin, and it words a non-live class on a granted scope as `permissionDenied`
        /// where `admit` says `scopeDenied`; `admit` is the entry point that checks both.
        func admissionContext(
            revisions: CommandRevisions, catalog: ParameterCatalog, ceiling: Double? = nil
        ) -> AdmissionContext {
            AdmissionContext(
                hostEpoch: hostEpoch, connectionEpoch: connectionEpoch, revisions: revisions,
                permission: permission, allowedScopes: Set(grants.map(\.scope)),
                allowedClasses: Self.allowedClasses, catalog: catalog, ceiling: ceiling
            )
        }

        /// Origin first (anything but `.controller` is `permissionDenied`), then the exact (class, scope)
        /// pair (`scopeDenied`), and only then `HostCommandGate.admit` unchanged: stale epochs, a changed
        /// permission or revision, parameter checks and the lifecycle keep their own reasons.
        func admit(
            _ intent: CommandIntent, revisions: CommandRevisions, catalog: ParameterCatalog,
            lifecycle: EngineLifecycle, ceiling: Double? = nil
        ) -> HostCommandDecision {
            guard intent.origin == Self.origin else { return .refused(.rejected(.permissionDenied)) }
            guard permits(intent.commandClass, intent.operation.scope) else {
                return .refused(.rejected(.scopeDenied))
            }
            let admission = admissionContext(revisions: revisions, catalog: catalog, ceiling: ceiling)
            return HostCommandGate.admit(intent, admission: admission, lifecycle: lifecycle)
        }

        private static func isGrantable(_ scope: CommandScope) -> Bool {
            switch scope {
            case .parameter, .action, .transport: true
            case .route, .patch, .draft, .safety: false
            }
        }
    }
}
