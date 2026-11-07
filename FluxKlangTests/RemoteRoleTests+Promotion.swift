import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RemoteRoleTests {
    private static func promotion(
        _ lost: HostID? = hostA, project: ProjectID = projectQ, window: WindowID = windowX
    ) -> RemoteRoleEvent {
        .explicitPromotion(
            confirmation: lost.map(PromotionConfirmation.init(lostHost:)), project: project, window: window
        )
    }

    @Test func promotionFromHostLostPlansEndThenALeaseRequestAndNothingElse() throws {
        var role = try Self.role(.hostLost)
        let plan = try role.advance(Self.promotion(), local: Self.idle)
        let end = RemoteRoleStep.endRemoteControl(Self.hostA)
        #expect(plan == [end, .requestEngineLease(project: Self.projectQ, window: Self.windowX)])
        #expect(role == RemoteRole())
    }

    @Test func promotionWithoutAConfirmationIsRefusedAndStaysHostLost() throws {
        var role = try Self.role(.hostLost)
        let before = role
        #expect(throws: RemoteRoleRefusal.promotionNotConfirmed) {
            try role.advance(Self.promotion(nil), local: Self.idle)
        }
        #expect(role == before)
    }

    @Test func promotionConfirmingAnotherHostIsRefused() throws {
        var role = try Self.role(.hostLost)
        let before = role
        #expect(throws: RemoteRoleRefusal.confirmationMismatch(expected: Self.hostA, found: Self.hostB)) {
            try role.advance(Self.promotion(Self.hostB), local: Self.idle)
        }
        #expect(role == before)
    }

    @Test func promotionWithAHeldLeaseIsRefusedEvenWithAConfirmation() throws {
        var registry = EngineLeaseRegistry()
        let snapshot = try Self.acquire(&registry, project: Self.projectQ, window: Self.windowX)
        var role = try Self.role(.hostLost)
        let before = role
        #expect(throws: RemoteRoleRefusal.localLeaseHeld(Self.projectQ)) {
            try role.advance(Self.promotion(), local: Self.context(lease: snapshot))
        }
        #expect(role == before)
        #expect(registry.snapshot == snapshot)
    }

    @Test func promotionDefectsAreCheckedConfirmationThenHostThenLease() throws {
        var registry = EngineLeaseRegistry()
        let snapshot = try Self.acquire(&registry)
        let held = Self.context(lease: snapshot)
        let role = try Self.role(.hostLost)
        #expect(throws: RemoteRoleRefusal.promotionNotConfirmed) {
            try role.apply(Self.promotion(nil), local: held)
        }
        #expect(throws: RemoteRoleRefusal.confirmationMismatch(expected: Self.hostA, found: Self.hostB)) {
            try role.apply(Self.promotion(Self.hostB), local: held)
        }
    }

    @Test func promotionIsIllegalFromStandaloneAndRemoteControllerEvenWhenConfirmed() throws {
        for kind in [RemoteRoleKind.standalone, .remoteController] {
            let role = try Self.role(kind)
            #expect(throws: RemoteRoleRefusal.illegalTransition(from: kind, event: .explicitPromotion)) {
                try role.apply(Self.promotion(), local: Self.idle)
            }
        }
    }

    @Test func promotionDoesNotConsultTheLifecycleBecauseItOnlyRequestsALease() throws {
        let role = try Self.role(.hostLost)
        let result = try role.apply(Self.promotion(), local: Self.context(lease: nil, .recovering))
        #expect(result.plan.count == 2)
        #expect(result.role == RemoteRole())
    }

    @Test func walkingEveryEventSequenceNeverAutoPromotesNorStopsAndEmitsOnlySixPlanShapes() throws {
        let lease = try Self.heldSnapshot()
        let contexts = [Self.idle, Self.context(lease: nil, .running), Self.context(lease: lease)]
        let alphabet: [RemoteRoleEvent] = [
            .enterRemote(Self.session(), releasing: nil), .enterRemote(Self.session(), releasing: lease.token),
            .leaveRemote, .hostLost(Self.hostA), .hostLost(Self.hostB), .hostReturned(Self.hostA),
            .hostReturned(Self.hostB), Self.promotion(), Self.promotion(nil), Self.promotion(Self.hostB)
        ]
        var sequences = 0
        var transitions = 0
        var shapes: Set<String> = []
        for context in contexts {
            var frontier = [RemoteRole()]
            for _ in 0..<4 {
                var next: [RemoteRole] = []
                for role in frontier {
                    for event in alphabet {
                        sequences += 1
                        guard let result = try? role.apply(event, local: context) else { continue }
                        transitions += 1
                        next.append(result.role)
                        Self.assertSafe(from: role, event: event, result: result)
                        shapes.insert(Self.shape(result.plan))
                    }
                }
                frontier = next
            }
        }
        #expect(sequences > 0)
        #expect(transitions > 0)
        #expect(shapes == [
            "begin", "release,begin", "end", "markUnavailable", "resume", "end,request"
        ])
    }

    private static func heldSnapshot() throws -> EngineLeaseSnapshot {
        var registry = EngineLeaseRegistry()
        return try acquire(&registry)
    }

    private static func shape(_ plan: [RemoteRoleStep]) -> String {
        plan.map { step -> String in
            switch step {
            case .releaseEngineLease: "release"
            case .beginRemoteControl: "begin"
            case .endRemoteControl: "end"
            case .markHostUnavailable: "markUnavailable"
            case .resumeRemoteControl: "resume"
            case .requestEngineLease: "request"
            }
        }.joined(separator: ",")
    }

    private static func assertSafe(from role: RemoteRole, event: RemoteRoleEvent, result: RemoteRoleTransition) {
        if role.kind == .hostLost, result.role.isHostCapable {
            #expect(event.kind == .leaveRemote || event.kind == .explicitPromotion)
        }
        if event.kind == .hostLost || event.kind == .hostReturned { #expect(!result.role.isHostCapable) }
        for step in result.plan {
            switch step {
            case .requestEngineLease: #expect(event.kind == .explicitPromotion)
            case .releaseEngineLease: #expect(event.kind == .enterRemote)
            case .beginRemoteControl, .endRemoteControl, .markHostUnavailable, .resumeRemoteControl: break
            }
        }
    }
}
