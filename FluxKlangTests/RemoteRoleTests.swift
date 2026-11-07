import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// RR1 (#96): the remote-controller role machine, lease release/refusal and the capability guard.
/// Topic files are `extension RemoteRoleTests` (+Transitions, +Lease, +Guard, +RawInput).
struct RemoteRoleTests {
    static let hostA = HostID(validated: "host.a")
    static let hostB = HostID(validated: "host.b")
    static let projectP = ProjectID(validated: "project.p")
    static let projectQ = ProjectID(validated: "project.q")
    static let windowW = WindowID(validated: "window.w")
    static let windowX = WindowID(validated: "window.x")

    static let idle = LocalEngineContext(lease: nil, lifecycle: .stopped)

    static func session(_ host: HostID = hostA, grant: PeerRole = .remoteController) -> RemoteSession {
        RemoteSession(host: host, grant: grant)
    }

    static func context(lease: EngineLeaseSnapshot?, _ lifecycle: EngineLifecycle = .stopped) -> LocalEngineContext {
        LocalEngineContext(lease: lease, lifecycle: lifecycle)
    }

    /// Reaches `kind` only through legal events from `standalone`, as production code must.
    static func role(
        _ kind: RemoteRoleKind, host: HostID = hostA, grant: PeerRole = .remoteController
    ) throws -> RemoteRole {
        var role = RemoteRole()
        guard kind != .standalone else { return role }
        try role.advance(.enterRemote(session(host, grant: grant), releasing: nil), local: idle)
        if kind == .hostLost { try role.advance(.hostLost(host), local: idle) }
        return role
    }

    /// One event of every kind, valid payloads for host A, used by the table and property tests.
    static func events(host: HostID = hostA, other: HostID = hostB) -> [RemoteRoleEvent] {
        [
            .enterRemote(session(host), releasing: nil), .leaveRemote, .hostLost(host), .hostReturned(host),
            .explicitPromotion(
                confirmation: PromotionConfirmation(lostHost: host), project: projectP, window: windowW
            )
        ]
    }

    static func acquire(
        _ registry: inout EngineLeaseRegistry, project: ProjectID = projectP, window: WindowID = windowW
    ) throws -> EngineLeaseSnapshot {
        try registry.acquire(project: project, window: window).snapshot
    }

    /// Records every call; the guard must leave these empty in a remote role.
    final class EngineDouble: EngineWriting {
        private(set) var calls: [String] = []
        func writeEngine(_ write: String) { calls.append(write) }
    }

    final class ConsoleDouble: ConsoleWriting {
        private(set) var calls: [String] = []
        func writeConsole(_ write: String) { calls.append(write) }
    }

    final class MIDIDouble: MIDIWriting {
        private(set) var calls: [UInt8] = []
        func sendMIDI(_ message: UInt8) { calls.append(message) }
    }
}
