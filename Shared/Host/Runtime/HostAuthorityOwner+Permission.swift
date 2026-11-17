//
//  HostAuthorityOwner+Permission.swift
//  FluxKlang
//
//  The owner's live permission (#62 AU8a, host-authority-sources.md decision 2)
//  and the admission provider a `WingApplyGrantMinter` reads on every mint.
//

import Foundation

/// The local user's role, granted only by an explicit gesture (decision 2).
enum HostUserRole: String, Hashable, Sendable {
    case host
}

enum HostGrantRefusal: Error, Hashable, Sendable {
    /// The grant revision would wrap; the grant is refused and nothing changes.
    case revisionExhausted
}

extension HostAuthorityOwner {
    /// What an intent carries while nothing is granted: a context with a nil permission
    /// refuses it first, and no grant mints it (grants are `"hp1."` + 64 hex digits).
    static let ungranted = PermissionFingerprint(rawValue: "hp1.ungranted")

    /// `"hp1."` + 64 lowercase hex digits of `PeerTrustDigest.sha256(domain:
    /// "fluxklang.host.permission.v1", [role raw value, u64be(revision)])`.
    static func fingerprint(_ role: HostUserRole, revision: UInt64) -> PermissionFingerprint {
        let digest = PeerTrustDigest.sha256(domain: "fluxklang.host.permission.v1",
                                            [Array(role.rawValue.utf8), PeerTrustDigest.bigEndian(revision)])
        return PermissionFingerprint(rawValue: "hp1." + PeerTrustDigest.hex(digest))
    }

    /// The provider for a `WingApplyGrantMinter`: re-reads the owner on every mint.
    nonisolated var provider: WingApplyGrantMinter.Provider {
        { [self] in await admission() }
    }

    /// The live epoch and permission, admitting exactly the apply route, once the
    /// Studio project is open. Nothing is cached.
    func admission() async -> WingApplyAdmission? {
        _ = await opened.value
        return Self.admission(epoch: hostEpoch, permission: permission)
    }

    /// A `.structural` `.human` `.bind(applyRoute)` intent and a context allowing only
    /// `.route(applyRoute)`; nil (minted as `.staleLive`) if the intent is invalid.
    static func admission(epoch: HostEpoch, permission: PermissionFingerprint?) -> WingApplyAdmission? {
        let route = WingDirectSendScope.applyRoute
        let context = AdmissionContext(hostEpoch: epoch, connectionEpoch: nil, revisions: CommandRevisions(),
                                       permission: permission, allowedScopes: [.route(route)],
                                       allowedClasses: [.structural], catalog: .wing)
        guard let intent = try? CommandIntent(.init(
            id: CommandID(uuid: UUID()), commandClass: .structural, origin: .human, hostEpoch: epoch,
            connectionEpoch: nil, revisions: CommandRevisions(), operation: .bind(route),
            permission: permission ?? ungranted
        )) else { return nil }
        return WingApplyAdmission(intent: intent, admission: context)
    }
}
