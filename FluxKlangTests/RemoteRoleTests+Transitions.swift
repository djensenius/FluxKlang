import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RemoteRoleTests {
    @Test func standaloneEnterRemoteBecomesRemoteControllerWithOneBeginStep() throws {
        let entered = try RemoteRole().apply(
            .enterRemote(Self.session(), releasing: nil), local: Self.idle
        )
        #expect(entered.role.phase == .remoteController(Self.session()))
        #expect(entered.role.kind == .remoteController)
        #expect(entered.plan == [.beginRemoteControl(Self.session())])
    }

    @Test func leaveRemoteReturnsBothRemoteStatesToStandaloneWithAnEndStep() throws {
        for kind in [RemoteRoleKind.remoteController, .hostLost] {
            let left = try Self.role(kind).apply(.leaveRemote, local: Self.idle)
            #expect(left.role == RemoteRole())
            #expect(left.plan == [.endRemoteControl(Self.hostA)])
        }
    }

    @Test func hostLostMovesRemoteControllerToHostLostKeepingTheSession() throws {
        let lost = try Self.role(.remoteController).apply(.hostLost(Self.hostA), local: Self.idle)
        #expect(lost.role.phase == .hostLost(Self.session()))
        #expect(lost.plan == [.markHostUnavailable(Self.hostA)])
    }

    @Test func hostReturnedResumesTheSameSessionFromHostLost() throws {
        let back = try Self.role(.hostLost).apply(.hostReturned(Self.hostA), local: Self.idle)
        #expect(back.role.phase == .remoteController(Self.session()))
        #expect(back.plan == [.resumeRemoteControl(Self.hostA)])
    }

    @Test func everyIllegalStateEventPairIsRefusedWithItsKinds() throws {
        let illegal: [(RemoteRoleKind, RemoteRoleEventKind)] = [
            (.standalone, .leaveRemote), (.standalone, .hostLost), (.standalone, .hostReturned),
            (.standalone, .explicitPromotion), (.remoteController, .enterRemote),
            (.remoteController, .hostReturned), (.remoteController, .explicitPromotion),
            (.hostLost, .enterRemote), (.hostLost, .hostLost)
        ]
        for (kind, eventKind) in illegal {
            let event = try #require(Self.events().first { $0.kind == eventKind })
            let role = try Self.role(kind)
            #expect(throws: RemoteRoleRefusal.illegalTransition(from: kind, event: eventKind)) {
                try role.apply(event, local: Self.idle)
            }
        }
    }

    @Test func theGridHasFifteenCellsOfWhichSixAreLegal() throws {
        var legal = 0
        var cells = 0
        for kind in RemoteRoleKind.allCases {
            for event in Self.events() {
                cells += 1
                if (try? Self.role(kind).apply(event, local: Self.idle)) != nil { legal += 1 }
            }
        }
        #expect(cells == 15)
        #expect(legal == 6)
    }

    @Test func everyRefusedEventLeavesTheRoleUnchangedThroughAdvance() throws {
        var refusals = 0
        for kind in RemoteRoleKind.allCases {
            for event in Self.events() + [.hostLost(Self.hostB), .hostReturned(Self.hostB)] {
                var role = try Self.role(kind)
                let before = role
                do { try role.advance(event, local: Self.idle) } catch {
                    refusals += 1
                    #expect(role == before)
                }
            }
        }
        #expect(refusals == 15)
    }

    @Test func hostLostEventForAnotherHostIsAHostMismatchAndChangesNothing() throws {
        var role = try Self.role(.remoteController)
        let before = role
        #expect(throws: RemoteRoleRefusal.hostMismatch(expected: Self.hostA, found: Self.hostB)) {
            try role.advance(.hostLost(Self.hostB), local: Self.idle)
        }
        #expect(role == before)
    }

    @Test func hostReturnedForAnotherHostIsAHostMismatchAndChangesNothing() throws {
        var role = try Self.role(.hostLost)
        let before = role
        #expect(throws: RemoteRoleRefusal.hostMismatch(expected: Self.hostA, found: Self.hostB)) {
            try role.advance(.hostReturned(Self.hostB), local: Self.idle)
        }
        #expect(role == before)
    }

    @Test func aSecondHostLostWhileHostLostIsIllegalNotIdempotent() throws {
        let role = try Self.role(.hostLost)
        #expect(throws: RemoteRoleRefusal.illegalTransition(from: .hostLost, event: .hostLost)) {
            try role.apply(.hostLost(Self.hostA), local: Self.idle)
        }
    }

    @Test func theObserverGrantIsKeptThroughHostLossAndReturn() throws {
        var role = try Self.role(.remoteController, grant: .observer)
        #expect(role.session?.grant == .observer)
        try role.advance(.hostLost(Self.hostA), local: Self.idle)
        #expect(role.session == Self.session(grant: .observer))
        try role.advance(.hostReturned(Self.hostA), local: Self.idle)
        #expect(role.phase == .remoteController(Self.session(grant: .observer)))
    }

    @Test func switchingHostsRequiresLeavingFirst() throws {
        var role = try Self.role(.remoteController)
        let other = Self.session(Self.hostB)
        #expect(throws: RemoteRoleRefusal.illegalTransition(from: .remoteController, event: .enterRemote)) {
            try role.advance(.enterRemote(other, releasing: nil), local: Self.idle)
        }
        #expect(role.session?.host == Self.hostA)
        try role.advance(.leaveRemote, local: Self.idle)
        try role.advance(.enterRemote(other, releasing: nil), local: Self.idle)
        #expect(role.session == other)
    }

    @Test func onlyTheStandaloneRoleIsHostCapable() throws {
        for kind in RemoteRoleKind.allCases {
            #expect(try Self.role(kind).isHostCapable == (kind == .standalone))
        }
        #expect(RemoteRole().session == nil)
    }

    @Test func advanceReturnsTheSamePlanAndRoleAsApply() throws {
        var role = RemoteRole()
        let event = RemoteRoleEvent.enterRemote(Self.session(), releasing: nil)
        let applied = try role.apply(event, local: Self.idle)
        let plan = try role.advance(event, local: Self.idle)
        #expect(plan == applied.plan)
        #expect(role == applied.role)
    }

    @Test func aRoundTripThroughLossAndReturnThenLeaveEndsStandalone() throws {
        var role = RemoteRole()
        var plans: [[RemoteRoleStep]] = []
        for event in [
            RemoteRoleEvent.enterRemote(Self.session(), releasing: nil), .hostLost(Self.hostA),
            .hostReturned(Self.hostA), .leaveRemote
        ] {
            plans.append(try role.advance(event, local: Self.idle))
        }
        #expect(role == RemoteRole())
        #expect(plans == [
            [.beginRemoteControl(Self.session())], [.markHostUnavailable(Self.hostA)],
            [.resumeRemoteControl(Self.hostA)], [.endRemoteControl(Self.hostA)]
        ])
    }
}
