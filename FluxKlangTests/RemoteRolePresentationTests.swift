import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Builds roles, phases and discard reports for the remote role presentation suites (#96 REM1). Sessions and the
/// reconnect state come from `PeerReconnectFixture`; the host is `host.reconnect`, shown as "Host A".
enum RemoteRolePresentationFixture {
    static let host = PeerReconnectFixture.host
    static let otherHost = HostID(validated: "host.other")
    static let name = "Host A"

    static func session(host hostGeneration: Int = 7, connection: Int = 4) -> PeerSyncSession {
        PeerReconnectFixture.session(host: hostGeneration, connection: connection)
    }

    static func synced(host hostGeneration: Int = 7, connection: Int = 4, awaitingResume: Bool = false)
        -> PeerReconnectState.Phase {
        .synced(session(host: hostGeneration, connection: connection), awaitingResume: awaitingResume)
    }

    static func role(
        _ kind: RemoteRoleKind = .remoteController, host: HostID = host, grant: PeerRole = .remoteController
    ) throws -> RemoteRole {
        var role = RemoteRole()
        guard kind != .standalone else { return role }
        let idle = LocalEngineContext(lease: nil, lifecycle: .stopped)
        try role.advance(.enterRemote(RemoteSession(host: host, grant: grant), releasing: nil), local: idle)
        if kind == .hostLost { try role.advance(.hostLost(host), local: idle) }
        return role
    }

    /// A report of `count` dropped changes: connected at connection epoch 3, reconnected to epoch 4 of host epoch 7.
    static func report(discarding count: Int) throws -> PeerDiscardReport {
        let old = session(connection: 3)
        var state = PeerReconnectFixture.synced(old)
        for index in 0..<count {
            try state.enqueue(PeerReconnectFixture.intent("command.n\(index)", session: old))
        }
        _ = state.connectionLost(old)
        return try state.reconnect(to: session(connection: 4))
    }

    static func make(
        role: RemoteRole, phase: PeerReconnectState.Phase, name: String? = name, discarded: PeerDiscardReport? = nil
    ) throws -> RemoteRolePresentation {
        try RemoteRolePresentation.make(role: role, phase: phase, hostName: name, discarded: discarded)
    }
}

private typealias Fixture = RemoteRolePresentationFixture

/// The remote controller's role-dependent presentation (#96 REM1): title, state, texts, inputs and refusals. Every
/// expected text is typed by hand from host-remote-roles.md. Pure values only: no view, clock, store or I/O.
#if os(macOS)
@Suite("Remote role presentation", .productionAccessAudit)
#else
@Suite("Remote role presentation")
#endif
struct RemoteRolePresentationTests {
    @Test func theDocumentExampleIsTheConnectedController() throws {
        let value = try Fixture.make(role: Fixture.role(), phase: Fixture.synced())
        #expect(value.title == "Remote for Host A - epoch 4")
        #expect(value.state == .connected)
        #expect(value.statusText == nil)
        #expect(value.inputsEnabled)
        #expect(value.notice == nil)
        #expect(value.structureText == "Hosts edit structure")
        #expect(value.safetyText == "host only (#94 open)")
        #expect(value.epoch == 4)
        #expect(value.hostName == "Host A")
    }

    @Test func theEpochIsTheConnectionEpochNotTheHostEpoch() throws {
        let four = try Fixture.make(role: Fixture.role(), phase: Fixture.synced(host: 7, connection: 4))
        #expect(four.epoch == 4)
        #expect(four.title == "Remote for Host A - epoch 4")
        let nine = try Fixture.make(role: Fixture.role(), phase: Fixture.synced(host: 7, connection: 9))
        #expect(nine.epoch == 9)
        #expect(nine.title == "Remote for Host A - epoch 9")
    }

    @Test func resyncingPhasesDisableInputWithTheResyncingText() throws {
        let session = Fixture.session()
        let phases: [PeerReconnectState.Phase] = [
            .resyncing(session), .connected(session), .synced(session, awaitingResume: true)
        ]
        for phase in phases {
            let value = try Fixture.make(role: Fixture.role(), phase: phase)
            #expect(value.state == .resyncing)
            #expect(value.statusText == "Resyncing...")
            #expect(!value.inputsEnabled)
            #expect(value.title == "Remote for Host A - epoch 4")
        }
    }

    @Test func aDisconnectedPhaseSendsNothing() throws {
        let value = try Fixture.make(role: Fixture.role(), phase: .disconnected(Fixture.session()))
        #expect(value.state == .disconnected)
        #expect(value.statusText == "Disconnected; nothing will be sent")
        #expect(!value.inputsEnabled)
    }

    @Test func aHostLostRoleIsDisconnectedWhateverThePhaseSays() throws {
        let value = try Fixture.make(role: Fixture.role(.hostLost), phase: Fixture.synced())
        #expect(value.state == .disconnected)
        #expect(value.statusText == "Disconnected; nothing will be sent")
        #expect(!value.inputsEnabled)
        #expect(value.title == "Remote for Host A - epoch 4")
    }

    @Test func aHostLostRoleIsDisconnectedInEveryPhase() throws {
        let session = Fixture.session()
        let phases: [PeerReconnectState.Phase] = [
            .synced(session, awaitingResume: false), .synced(session, awaitingResume: true),
            .resyncing(session), .connected(session), .disconnected(session)
        ]
        let role = try Fixture.role(.hostLost)
        for phase in phases {
            let value = try Fixture.make(role: role, phase: phase)
            #expect(value.state == .disconnected)
            #expect(value.statusText == "Disconnected; nothing will be sent")
            #expect(!value.inputsEnabled)
        }
    }

    @Test func aControllerWithADisconnectedPhaseIsDisconnected() throws {
        let role = try Fixture.role(.remoteController)
        #expect(role.kind == .remoteController)
        let value = try Fixture.make(role: role, phase: .disconnected(Fixture.session(connection: 2)))
        #expect(value.state == .disconnected)
        #expect(value.title == "Remote for Host A - epoch 2")
    }

    @Test func anObserverWatchesAndNeverEnablesInput() throws {
        let observer = try Fixture.role(grant: .observer)
        let connected = try Fixture.make(role: observer, phase: Fixture.synced())
        #expect(connected.title == "Watching Host A")
        #expect(connected.state == .connected)
        #expect(!connected.inputsEnabled)
        #expect(connected.structureText == nil)
        #expect(connected.safetyText == "host only (#94)")
        #expect(connected.epoch == 4)
        #expect(connected.hostName == "Host A")
        #expect(connected.notice == nil)
        let resyncing = try Fixture.make(role: observer, phase: .resyncing(Fixture.session()))
        #expect(resyncing.statusText == "Resyncing...")
        #expect(!resyncing.inputsEnabled)
    }

    @Test func theHostNameIsVerbatimWithTheHostIDAsFallback() throws {
        let role = try Fixture.role()
        let expectedFallback = "Remote for host.reconnect - epoch 4"
        let missing = try Fixture.make(role: role, phase: Fixture.synced(), name: nil)
        #expect(missing.title == expectedFallback)
        #expect(missing.hostName == "host.reconnect")
        let empty = try Fixture.make(role: role, phase: Fixture.synced(), name: "")
        #expect(empty.title == expectedFallback)
        #expect(empty.hostName == "host.reconnect")
        let blank = try Fixture.make(role: role, phase: Fixture.synced(), name: "  ")
        #expect(blank.title == "Remote for    - epoch 4")
        #expect(blank.hostName == "  ")
    }

    @Test func refusalsNameTheFirstDefect() throws {
        #expect(throws: RemoteRolePresentationRefusal.notRemote(.standalone)) {
            try Fixture.make(role: Fixture.role(.standalone), phase: Fixture.synced())
        }
        let other = try Fixture.role(host: Fixture.otherHost)
        #expect(throws: RemoteRolePresentationRefusal.hostMismatch(expected: Fixture.otherHost, found: Fixture.host)) {
            try Fixture.make(role: other, phase: Fixture.synced())
        }
        let report = try Fixture.report(discarding: 1)
        #expect(throws: RemoteRolePresentationRefusal.reportSessionMismatch(.connectionEpoch)) {
            try Fixture.make(role: Fixture.role(), phase: Fixture.synced(connection: 9), discarded: report)
        }
        #expect(throws: RemoteRolePresentationRefusal.reportSessionMismatch(.hostEpoch)) {
            try Fixture.make(role: Fixture.role(), phase: Fixture.synced(host: 8), discarded: report)
        }
    }

    @Test func refusalOrderIsRoleThenHostThenReport() throws {
        let report = try Fixture.report(discarding: 1)
        let mismatched = Fixture.synced(connection: 9)
        #expect(throws: RemoteRolePresentationRefusal.notRemote(.standalone)) {
            try Fixture.make(role: Fixture.role(.standalone), phase: mismatched, discarded: report)
        }
        let other = try Fixture.role(host: Fixture.otherHost)
        #expect(throws: RemoteRolePresentationRefusal.hostMismatch(expected: Fixture.otherHost, found: Fixture.host)) {
            try Fixture.make(role: other, phase: mismatched, discarded: report)
        }
    }

    @Test func equalInputsGiveEqualValuesAndDifferentPhasesDiffer() throws {
        let role = try Fixture.role()
        let first = try Fixture.make(role: role, phase: Fixture.synced())
        let second = try Fixture.make(role: role, phase: Fixture.synced())
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
        let other = try Fixture.make(role: role, phase: .resyncing(Fixture.session()))
        #expect(first != other)
    }

    @Test func theFixedTextsAreTheDocumentsWording() {
        #expect(RemoteRoleText.resyncing == "Resyncing...")
        #expect(RemoteRoleText.disconnected == "Disconnected; nothing will be sent")
        #expect(RemoteRoleText.structure == "Hosts edit structure")
        #expect(RemoteRoleText.controllerSafety == "host only (#94 open)")
        #expect(RemoteRoleText.observerSafety == "host only (#94)")
        #expect(RemoteRoleText.controllerTitle(host: "Host A", epoch: 1) == "Remote for Host A - epoch 1")
        #expect(RemoteRoleText.observerTitle(host: "Host A") == "Watching Host A")
    }
}
