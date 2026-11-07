//
//  RemoteRole.swift
//  FluxKlang
//
//  The remote-controller role machine (#96, RR1, host-remote-roles.md). A device
//  is standalone, controlling a named host, or has lost that host. Only explicit
//  events change the role; a lost host is never promoted automatically and OS
//  exclusivity is never assumed. Pure: the result is a role plus an ordered plan.
//
//  state \ event        enterRemote     leaveRemote     hostLost(h)       hostReturned(h)    explicitPromotion
//  standalone           gate            illegal         illegal           illegal            illegal
//  remoteController(s)  illegal         standalone      hostLost(s)*      illegal            illegal
//  hostLost(s)          illegal         standalone      illegal           remoteController*  gate -> standalone
//
//  * only when h == s.host, otherwise `hostMismatch`. `gate` is `LocalEngineContext.entryRelease` for
//  enterRemote and `checkPromotion` for explicitPromotion. An illegal pair is `illegalTransition`.
//

/// The role of this device. Remote states exist only as the result of `apply`/`advance` on a legal event.
struct RemoteRole: Hashable, Sendable {
    enum Phase: Hashable, Sendable {
        case standalone
        case remoteController(RemoteSession)
        /// The relationship is kept (the same session), but nothing is sent and nothing is promoted.
        case hostLost(RemoteSession)
    }

    private(set) var phase: Phase

    /// A standalone device: no remote relationship. This is the only host-capable role.
    init() {
        phase = .standalone
    }

    private init(phase: Phase) {
        self.phase = phase
    }

    var kind: RemoteRoleKind {
        switch phase {
        case .standalone: .standalone
        case .remoteController: .remoteController
        case .hostLost: .hostLost
        }
    }

    var session: RemoteSession? {
        switch phase {
        case .standalone: nil
        case .remoteController(let session), .hostLost(let session): session
        }
    }

    /// Whether this role may own the local engine. Only `standalone`; never inferred from a loss.
    var isHostCapable: Bool { kind == .standalone }

    /// The role and plan after `event`, or a typed refusal. Non-mutating: a refusal changes nothing.
    /// Check order: the (state, event) pair, then the host named by the event, then the gate.
    func apply(
        _ event: RemoteRoleEvent, local: LocalEngineContext
    ) throws(RemoteRoleRefusal) -> RemoteRoleTransition {
        switch (phase, event) {
        case (.standalone, .enterRemote(let session, let releasing)):
            let release = try local.entryRelease(releasing)
            return Self.transition(.remoteController(session), release + [.beginRemoteControl(session)])
        case (.remoteController(let session), .hostLost(let host)):
            try Self.require(host, equals: session.host)
            return Self.transition(.hostLost(session), [.markHostUnavailable(host)])
        case (.hostLost(let session), .hostReturned(let host)):
            try Self.require(host, equals: session.host)
            return Self.transition(.remoteController(session), [.resumeRemoteControl(host)])
        case (.remoteController(let session), .leaveRemote), (.hostLost(let session), .leaveRemote):
            return Self.transition(.standalone, [.endRemoteControl(session.host)])
        case (.hostLost(let session), .explicitPromotion(let confirmation, let project, let window)):
            try local.checkPromotion(confirmation, lostHost: session.host)
            return Self.transition(
                .standalone, [.endRemoteControl(session.host), .requestEngineLease(project: project, window: window)]
            )
        case (.standalone, .leaveRemote), (.standalone, .hostLost), (.standalone, .hostReturned),
             (.standalone, .explicitPromotion), (.remoteController, .enterRemote),
             (.remoteController, .hostReturned), (.remoteController, .explicitPromotion),
             (.hostLost, .enterRemote), (.hostLost, .hostLost):
            throw .illegalTransition(from: kind, event: event.kind)
        }
    }

    /// Applies `event` in place and returns the plan. On a refusal the role is left exactly as it was.
    @discardableResult
    mutating func advance(
        _ event: RemoteRoleEvent, local: LocalEngineContext
    ) throws(RemoteRoleRefusal) -> [RemoteRoleStep] {
        let result = try apply(event, local: local)
        self = result.role
        return result.plan
    }

    private static func transition(_ phase: Phase, _ plan: [RemoteRoleStep]) -> RemoteRoleTransition {
        RemoteRoleTransition(role: RemoteRole(phase: phase), plan: plan)
    }

    private static func require(_ found: HostID, equals expected: HostID) throws(RemoteRoleRefusal) {
        guard found == expected else { throw .hostMismatch(expected: expected, found: found) }
    }
}
