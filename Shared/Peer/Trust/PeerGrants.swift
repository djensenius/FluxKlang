//
//  PeerGrants.swift
//  FluxKlang
//
//  Scoped grants for a paired peer (#94). A grant is an exact
//  (control class, command scope) pair: there is no prefix or group matching
//  (group grants are deferred), an unknown scope is simply not granted, and an
//  empty set grants nothing. Every grant must fit the role's ceiling, and
//  Panic/Safe Mute (`.safety`) are never granted to a paired peer.
//

/// The explicit role a host chooses when it approves a pairing. Host and
/// assistant are not pairable roles. A role is never inferred from the peer's
/// request or form factor.
enum PeerRole: String, Hashable, Sendable, CaseIterable {
    /// Live parameter control (`live.set`) of exactly the granted parameters, plus status.
    case remoteController
    /// Status only (`status.read`); no commands.
    case observer

    /// Whether `grant` is inside this role's ceiling. Safety is outside every ceiling.
    func permits(_ grant: PeerCommandGrant) -> Bool {
        switch self {
        case .remoteController:
            guard grant.controlClass == .live, case .parameter = grant.scope else { return false }
            return true
        case .observer:
            return false
        }
    }
}

/// One exact command grant. `scope` is compared with `CommandScope` equality.
struct PeerCommandGrant: Hashable, Sendable {
    let controlClass: ControlClass
    let scope: CommandScope

    /// A canonical token for hashing; it never leaves the host in this form.
    var canonicalToken: String {
        let scopeToken = switch scope {
        case .parameter(let id): "parameter:" + id.rawValue
        case .route(let id): "route:" + id.rawValue
        case .patch(let id): "patch:" + id.rawValue
        case .action(let id): "action:" + id.rawValue
        case .draft(let id): "draft:" + id.rawValue
        case .transport: "transport"
        case .safety: "safety"
        }
        return controlClass.rawValue + "|" + scopeToken
    }

    var isSafety: Bool { controlClass == .safety || scope == .safety }
}

/// Read-only grants. P1 has exactly one.
enum PeerReadGrant: String, Hashable, Sendable, CaseIterable {
    /// Status projection; effective only when the session negotiated `status`.
    case statusRead = "status.read"
}

/// A validated grant set for one role.
struct PeerGrantSet: Hashable, Sendable {
    static let maximumCommandGrants = 64

    let role: PeerRole
    let commands: Set<PeerCommandGrant>
    let reads: Set<PeerReadGrant>

    /// - A remote controller needs at least one command grant; use `observer` for none.
    /// - An observer's only grant is `status.read`.
    init(role: PeerRole, commands: Set<PeerCommandGrant>, reads: Set<PeerReadGrant>) throws(PeerTrustError) {
        guard commands.count <= Self.maximumCommandGrants else { throw .tooManyGrants(commands.count) }
        guard !commands.contains(where: \.isSafety) else { throw .safetyNotGrantable }
        guard commands.allSatisfy(role.permits) else { throw .grantOutsideRole(role) }
        switch role {
        case .remoteController:
            guard !commands.isEmpty else { throw .noCommandGrants }
        case .observer:
            guard reads == [.statusRead] else { throw .observerRequiresStatusRead }
        }
        self.role = role
        self.commands = commands
        self.reads = reads
    }

    /// Exact pair membership; never a prefix, group or class-only match.
    func permits(_ controlClass: ControlClass, _ scope: CommandScope) -> Bool {
        commands.contains(PeerCommandGrant(controlClass: controlClass, scope: scope))
    }
}
