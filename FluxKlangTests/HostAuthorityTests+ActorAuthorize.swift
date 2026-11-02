import Testing
@testable import FluxKlang

private typealias Bench = AuthorityBench

/// Windows that do not render project A when it authorizes.
enum NonRenderingWindow: CaseIterable, Sendable { case noLease, detachedWindow, otherHolder }

/// Why a commit of an authorized plan is refused.
enum CommitRefusalCase: CaseIterable, Sendable {
    case noLease, otherHolder, staleLive, staleLease, reusedAuthorization, replacedAuthorization, fullQueue
}

extension HostAuthorityTests {
    /// Gesture authorization from a rendering window, and commit refusals (H5c-1).
    struct ActorAuthorize {
        @Test(arguments: [CommandOrigin.assistant, .controller])
        func gestureOriginNotRequestOriginAuthorizes(_ origin: CommandOrigin) async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.review(authority, &engine)
            let before = await authority.snapshot()
            // The request's origin is `.human`; only the gesture's origin counts.
            let refused = await authority.authorize(project: Bench.projectA, gesture: Bench.gesture(origin: origin))
            #expect(Bench.refusal(refused) == .activation(.rejected(.originCannotActivate(origin))))
            #expect(await authority.snapshot() == before)
            _ = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            #expect(await authority.snapshot().authorizedWindows == [Bench.projectA: Bench.windowA])
        }

        @Test(arguments: NonRenderingWindow.allCases)
        func nonRenderingWindowCannotAuthorize(_ window: NonRenderingWindow) async throws {
            let authority = try await Bench.makeAuthority(holding: window == .detachedWindow ? Bench.windowA : nil)
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.review(authority, &engine)
            let gesture: ActivationGesture
            let role: WindowRenderRole
            switch window {
            case .noLease:
                (gesture, role) = (Bench.gesture(), .stopped)
            case .detachedWindow:
                _ = try await authority.attach(Bench.windowA2, project: Bench.projectA).get()
                _ = try await authority.detach(Bench.windowA2).get()
                (gesture, role) = (Bench.gesture(Bench.windowA2), .editAndPrepareOnly(heldBy: Bench.projectA))
            case .otherHolder:
                _ = try await authority.acquire(project: Bench.projectB, window: Bench.windowB).get()
                (gesture, role) = (Bench.gesture(), .editAndPrepareOnly(heldBy: Bench.projectB))
            }
            let before = await authority.snapshot()
            let refused = await authority.authorize(project: Bench.projectA, gesture: gesture)
            #expect(Bench.refusal(refused) == .windowCannotAuthorize(role))
            #expect(await authority.snapshot() == before)
        }

        @Test(arguments: CommitRefusalCase.allCases)
        func commitRefusalsQueueNothing(_ refusalCase: CommitRefusalCase) async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.review(authority, &engine)
            let authorization = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            let expected = try await prepare(refusalCase, authority, authorization)
            let before = await authority.snapshot()
            let refused = await authority.commit(project: Bench.projectA, authorization: authorization)
            #expect(Bench.refusal(refused) == expected)
            #expect(await authority.snapshot() == before)
        }

        @Test func commitWhileRecoveringIsRefused() async throws {
            let authority = try await Bench.makeAuthority(lifecycleA: .recovering)
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.review(authority, &engine)
            let authorization = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            let before = await authority.snapshot()
            let refused = await authority.commit(project: Bench.projectA, authorization: authorization)
            #expect(Bench.refusal(refused) == .lifecycleRejectsChanges(.recovering))
            #expect(await authority.snapshot() == before && before.queue.pending.isEmpty)
        }

        @Test func commitRefusesWhenAuthorizingWindowStopsRendering() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.review(authority, &engine)
            _ = try await authority.attach(Bench.windowA2, project: Bench.projectA).get()
            let stale = try await authority.authorize(project: Bench.projectA,
                                                      gesture: Bench.gesture(Bench.windowA2)).get()
            // A still holds the lease, but the authorizing window left it.
            _ = try await authority.detach(Bench.windowA2).get()
            let before = await authority.snapshot()
            let refused = await authority.commit(project: Bench.projectA, authorization: stale)
            #expect(Bench.refusal(refused) == .windowCannotAuthorize(.editAndPrepareOnly(heldBy: Bench.projectA)))
            #expect(await authority.snapshot() == before)
            let fresh = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            try await authority.commit(project: Bench.projectA, authorization: fresh).get()
        }

        @Test func authorizedWindowIsPerProjectAndCleared() async throws {
            let authority = try await Bench.makeAuthority()
            var engine = try ScriptedActivationEngine()
            _ = try await Bench.review(authority, &engine)
            _ = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            #expect(await authority.snapshot().authorizedWindows == [Bench.projectA: Bench.windowA])
            try await authority.cancel(project: Bench.projectA).get()
            #expect(await authority.snapshot().authorizedWindows.isEmpty)

            _ = try await Bench.review(authority, &engine)
            let authA = try await authority.authorize(project: Bench.projectA, gesture: Bench.gesture()).get()
            _ = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
            _ = try await Bench.review(authority, &engine, project: Bench.projectB)
            let authB = try await authority.authorize(project: Bench.projectB,
                                                      gesture: Bench.gesture(Bench.windowB)).get()
            let both = await authority.snapshot()
            #expect(both.authorizedWindows == [Bench.projectA: Bench.windowA, Bench.projectB: Bench.windowB])
            // A's own record is checked, not B's: A's window no longer renders.
            let refusedA = await authority.commit(project: Bench.projectA, authorization: authA)
            #expect(Bench.refusal(refusedA) == .windowCannotAuthorize(.editAndPrepareOnly(heldBy: Bench.projectB)))
            #expect(await authority.snapshot() == both)
            // B's commit consumes only B's record.
            try await authority.commit(project: Bench.projectB, authorization: authB).get()
            #expect(await authority.snapshot().authorizedWindows == [Bench.projectA: Bench.windowA])
        }

        /// Sets up `refusalCase` after A authorized from window A; returns the expected refusal.
        private func prepare(_ refusalCase: CommitRefusalCase, _ authority: HostAuthority,
                             _ authorization: ActivationAuthorization) async throws -> HostAuthorityRefusal {
            let projectA = Bench.projectA
            switch refusalCase {
            case .noLease:
                try await authority.release(project: projectA).get()
                return .windowCannotAuthorize(.stopped)
            case .otherHolder:
                _ = try await authority.transfer(to: Bench.projectB, window: Bench.windowB).get()
                return .windowCannotAuthorize(.editAndPrepareOnly(heldBy: Bench.projectB))
            case .staleLive:
                let next = HostEpoch(host: Bench.host, generation: try Generation.initial.next())
                await authority.updateLive(try Bench.liveState(epoch: next))
                return .activation(.staleContext)
            case .staleLease:
                try await authority.release(project: projectA).get()
                _ = try await authority.acquire(project: projectA, window: Bench.windowA).get()
                return .activation(.staleContext)
            case .reusedAuthorization:
                try await authority.commit(project: projectA, authorization: authorization).get()
                return .activation(.authorizationInvalid(.noneOutstanding))
            case .replacedAuthorization:
                _ = try await authority.authorize(project: projectA, gesture: Bench.gesture()).get()
                return .activation(.authorizationInvalid(.notOutstanding))
            case .fullQueue:
                try await Bench.fillQueue(authority)
                return .queueFull
            }
        }
    }
}
