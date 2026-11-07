import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RemoteRoleTests {
    private static let noLocalWrite = RemoteRoleDecision.refused(.noLocalWriteInRemoteRole)
    private static let rawRefused = RemoteRoleDecision.refused(.rawInputIsNotAPeerCommand)

    /// The expected decision of every capability, in `RemoteCapability.allCases` order, per role variant.
    private static func expectedRow(_ kind: RemoteRoleKind, grant: PeerRole) -> [RemoteRoleDecision] {
        switch (kind, grant) {
        case (.standalone, _):
            [.allowed, .allowed, .allowed, .refused(.noRemoteSession), .allowed, .allowed, .allowed]
        case (.remoteController, .remoteController):
            [noLocalWrite, noLocalWrite, noLocalWrite, .allowed, .allowed, rawRefused, rawRefused]
        case (.remoteController, .observer):
            [noLocalWrite, noLocalWrite, noLocalWrite, .refused(.observerHasNoCommands), .allowed,
             rawRefused, rawRefused]
        case (.hostLost, _):
            [noLocalWrite, noLocalWrite, noLocalWrite, .refused(.hostLost), .allowed, rawRefused, rawRefused]
        }
    }

    @Test func theFullCapabilityTableMatchesForEveryRoleVariant() throws {
        #expect(RemoteCapability.allCases == [
            .engineWrite, .consoleWrite, .midiOutput, .peerUICommand, .statusRead, .rawNoteInput, .clockInput
        ])
        let variants: [(RemoteRoleKind, PeerRole)] = [
            (.standalone, .remoteController), (.remoteController, .remoteController),
            (.remoteController, .observer), (.hostLost, .remoteController), (.hostLost, .observer)
        ]
        for (kind, grant) in variants {
            let role = try Self.role(kind, grant: grant)
            let row = RemoteCapability.allCases.map { RemoteRoleGuard.decide(role: role, capability: $0) }
            #expect(row == Self.expectedRow(kind, grant: grant))
        }
    }

    @Test func standaloneAllowsEveryLocalCapabilityAndRefusesOnlyPeerCommands() throws {
        let role = RemoteRole()
        let refused = RemoteCapability.allCases.filter {
            RemoteRoleGuard.decide(role: role, capability: $0) != .allowed
        }
        #expect(refused == [.peerUICommand])
    }

    @Test func inEveryRemoteRoleOnlyPeerCommandsAndStatusReadCanPass() throws {
        for kind in [RemoteRoleKind.remoteController, .hostLost] {
            for grant in PeerRole.allCases {
                let role = try Self.role(kind, grant: grant)
                let passing = RemoteCapability.allCases.filter {
                    RemoteRoleGuard.decide(role: role, capability: $0) == .allowed
                }
                let expected: [RemoteCapability] = kind == .remoteController && grant == .remoteController
                    ? [.peerUICommand, .statusRead] : [.statusRead]
                #expect(passing == expected)
            }
        }
    }

    @Test func rawNotesAndClocksAreRefusedAsInputInEveryRemoteRole() throws {
        for kind in [RemoteRoleKind.remoteController, .hostLost] {
            let role = try Self.role(kind)
            for capability in [RemoteCapability.rawNoteInput, .clockInput] {
                #expect(RemoteRoleGuard.decide(role: role, capability: capability) == Self.rawRefused)
            }
        }
    }

    @Test func doublesRecordZeroCallsInTheRemoteAndHostLostRoles() throws {
        for kind in [RemoteRoleKind.remoteController, .hostLost] {
            let role = try Self.role(kind)
            let engine = EngineDouble()
            let console = ConsoleDouble()
            let midi = MIDIDouble()
            #expect(throws: RemoteCapabilityRefusal.noLocalWriteInRemoteRole) {
                try RemoteRoleGuard.writeEngine("engine", role: role, to: engine)
            }
            #expect(throws: RemoteCapabilityRefusal.noLocalWriteInRemoteRole) {
                try RemoteRoleGuard.writeConsole("console", role: role, to: console)
            }
            #expect(throws: RemoteCapabilityRefusal.noLocalWriteInRemoteRole) {
                try RemoteRoleGuard.sendMIDI(0x90, role: role, to: midi)
            }
            #expect(engine.calls.isEmpty)
            #expect(console.calls.isEmpty)
            #expect(midi.calls.isEmpty)
        }
    }

    @Test func doublesRecordExactlyTheExpectedCallsInStandalone() throws {
        let role = RemoteRole()
        let engine = EngineDouble()
        let console = ConsoleDouble()
        let midi = MIDIDouble()
        try RemoteRoleGuard.writeEngine("e1", role: role, to: engine)
        try RemoteRoleGuard.writeEngine("e2", role: role, to: engine)
        try RemoteRoleGuard.writeConsole("c1", role: role, to: console)
        try RemoteRoleGuard.sendMIDI(0x90, role: role, to: midi)
        try RemoteRoleGuard.sendMIDI(0x80, role: role, to: midi)
        #expect(engine.calls == ["e1", "e2"])
        #expect(console.calls == ["c1"])
        #expect(midi.calls == [0x90, 0x80])
    }

    @Test func aRefusedPerformDoesNotRunTheActionAndAnAllowedOneReturnsItsValue() throws {
        var runs = 0
        let remote = try Self.role(.remoteController)
        #expect(throws: RemoteCapabilityRefusal.rawInputIsNotAPeerCommand) {
            try RemoteRoleGuard.perform(.rawNoteInput, role: remote) { runs += 1 }
        }
        #expect(runs == 0)
        let value = try RemoteRoleGuard.perform(.peerUICommand, role: remote) { runs += 1; return "sent" }
        #expect(value == "sent")
        #expect(runs == 1)
    }

    @Test func performThrowsTheSameTypedReasonTheGuardDecides() throws {
        for kind in RemoteRoleKind.allCases {
            let role = try Self.role(kind, grant: .observer)
            for capability in RemoteCapability.allCases {
                var ran = false
                let decision = RemoteRoleGuard.decide(role: role, capability: capability)
                do {
                    try RemoteRoleGuard.perform(capability, role: role) { ran = true }
                    #expect(decision == .allowed)
                    #expect(ran)
                } catch {
                    #expect(decision == .refused(error))
                    #expect(!ran)
                }
            }
        }
    }

    @Test func standaloneRefusesPeerCommandsAsNoRemoteSession() throws {
        #expect(RemoteRoleGuard.decide(role: RemoteRole(), capability: .peerUICommand) == .refused(.noRemoteSession))
    }

    @Test func anObserverReadsStatusButCannotSendCommandsWhileControllingOrAfterLoss() throws {
        let observing = try Self.role(.remoteController, grant: .observer)
        #expect(RemoteRoleGuard.decide(role: observing, capability: .statusRead) == .allowed)
        #expect(RemoteRoleGuard.decide(role: observing, capability: .peerUICommand) == .refused(.observerHasNoCommands))
        let lost = try Self.role(.hostLost, grant: .observer)
        #expect(RemoteRoleGuard.decide(role: lost, capability: .peerUICommand) == .refused(.hostLost))
    }

    @Test func theGuardFollowsTheRoleThroughATransitionSequence() throws {
        var role = RemoteRole()
        let engine = EngineDouble()
        try RemoteRoleGuard.writeEngine("before", role: role, to: engine)
        try role.advance(.enterRemote(Self.session(), releasing: nil), local: Self.idle)
        #expect(throws: RemoteCapabilityRefusal.noLocalWriteInRemoteRole) {
            try RemoteRoleGuard.writeEngine("remote", role: role, to: engine)
        }
        try role.advance(.hostLost(Self.hostA), local: Self.idle)
        #expect(throws: RemoteCapabilityRefusal.noLocalWriteInRemoteRole) {
            try RemoteRoleGuard.writeEngine("lost", role: role, to: engine)
        }
        try role.advance(.leaveRemote, local: Self.idle)
        try RemoteRoleGuard.writeEngine("after", role: role, to: engine)
        #expect(engine.calls == ["before", "after"])
    }
}
