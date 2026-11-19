import Foundation
import Testing
@testable import FluxKlang

private let console = "192.0.2.10"

extension HostAuthorityTests {
    /// AU7b: `WingApplyTicketBudget` caps the tickets one gated apply may mint.
    /// Fakes only; nothing reaches a socket.
    @MainActor
    struct WingApplyMinterBudget {
        private func connected(_ transport: EchoingDirectTransport) async throws -> (WingController, UUID) {
            let controller = WingController(transport: transport, mode: .live)
            await controller.connect(host: console)
            return (controller, try #require(controller.sessionID))
        }

        @Test(arguments: [
            (0, 0, 0), (0, 1, 2), (1, 0, 3), (0, 256, 2), (0, 257, 4), (256, 1, 5), (32, 964, 10)
        ])
        func limitFollowsTheChunkCounts(_ safety: Int, _ remaining: Int, _ expected: Int) {
            #expect(WingApplyTicketBudget.limit(safetyCount: safety, remainingCount: remaining) == expected)
            #expect(WingApplyBench.drain(WingApplyTicketBudget(limit: expected)) == expected)
        }

        @Test func theBudgetUsesTheControllersOwnSplit() async throws {
            let (controller, _) = try await connected(EchoingDirectTransport())
            let settings = try WingApplyBench.settings(300)
            let duplicated = settings + settings[..<10]
            let outside = try #require(WingApplyBench.settings(400).last)

            #expect(WingApplyBench.drain(controller.directApplyBudget(duplicated)) == 4)
            let safety = Array(settings[..<5]) + [outside]
            #expect(controller.directApplyPlan(duplicated, safetySettings: safety).safety.count == 5)
            #expect(controller.directApplyPlan(duplicated, safetySettings: safety).remaining.count == 295)
            #expect(WingApplyBench.drain(controller.directApplyBudget(duplicated, safetySettings: safety)) == 6)
            #expect(WingApplyBench.drain(controller.directApplyBudget([])) == 0)
            await controller.disconnect()
        }

        @Test func takeStopsAtExactlyTheLimit() async {
            let budget = WingApplyTicketBudget(limit: 50)
            let successes = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<200 { group.addTask { budget.take() } }
                var taken = 0
                for await success in group where success { taken += 1 }
                return taken
            }
            #expect(successes == 50)
            #expect(!budget.take())
            #expect(!budget.take())
            #expect(!WingApplyTicketBudget(limit: 0).take())
            #expect(!WingApplyTicketBudget(limit: -3).take())
        }

        /// A budget of 1, and one chunk short of a phase, stop the apply at the next mint.
        @Test(arguments: [(300, 1), (513, 2)])
        func anExhaustedBudgetStopsTheApply(_ count: Int, _ limit: Int) async throws {
            let authority = try await WingApplyBench.authority()
            let minter = RecordingApplyMinter(try WingApplyBench.minter(authority,
                                                                         budget: WingApplyTicketBudget(limit: limit)))
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let settings = try WingApplyBench.settings(count)

            let result = await controller.applyAndVerify(settings, session: session, minting: minter)
            #expect(result.state == .failed)
            #expect(result.confirmedCount == 0)
            let mints = await minter.mints
            #expect(mints.count == limit + 1)
            let expected: [DirectWriteRefusal?] = Array(repeating: nil, count: limit) + [.tooManyOutstanding]
            #expect(mints.map(\.refusal) == expected)
            #expect(await transport.directWrites == Array(settings[..<(256 * limit)]))
            #expect(await transport.legacyWrites.isEmpty)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(await authority.outstandingDirectWriteCount() == 0)
            await controller.disconnect()
        }
    }

    /// AU8c-2: `StudioApplyRoute`, Studio Apply's route to the WING. Demo Mode alone is ungated
    /// and never touches the owner; a real session applies only through the gated overload with a
    /// production minter, and every refusal sends nothing on either path. A real owner and
    /// authority; an echoing transport, no socket.
    @MainActor
    struct StudioApplyRouting {
        /// Four route-admitted settings; the first two are the safety ones.
        private static func plan() throws -> (settings: [WingSetting], safety: [WingSetting]) {
            let settings = try WingApplyBench.settings(4)
            return (settings, Array(settings.prefix(2)))
        }

        /// A connected controller of `mode` and a fresh owner whose roots are open, granted unless
        /// `granted` is false, connected to the controller's session unless `session` replaces it.
        private func makeBench(_ mode: WingMode = .live, granted: Bool = true, session: UUID? = nil,
                               checkpoint: (@Sendable (HostAuthorityOwner.Checkpoint) async -> Void)? = nil)
        async throws -> RouteBench {
            let transport = EchoingDirectTransport()
            let controller = WingController(transport: transport, mode: mode)
            await controller.connect(host: console)
            let owner = try HostAuthorityOwner(host: OwnerBench.host, checkpoint: checkpoint)
            await OwnerBench.openRoots(owner)
            if granted { _ = try await owner.grant(.host).get() }
            let controllerSession = try #require(controller.sessionID)
            await owner.connected(session: session ?? controllerSession)
            return RouteBench(controller: controller, transport: transport, owner: owner)
        }

        private func apply(_ bench: RouteBench, owner: HostAuthorityOwner?,
                           window: WindowID? = OwnerBench.windowOne) async throws -> WingApplyVerification {
            let (settings, safety) = try Self.plan()
            return await StudioApplyRoute.apply(settings, safetySettings: safety, on: bench.controller,
                                                owner: owner, window: window)
        }

        /// `result` is `refusal`'s failed verdict, and nothing reached the transport on either path.
        private func expectRefused(_ result: WingApplyVerification, _ refusal: StudioApplyRoute.Refusal,
                                   _ bench: RouteBench) async throws {
            let (settings, _) = try Self.plan()
            #expect(result == WingApplyVerification(state: .failed, settings: settings, confirmedCount: 0,
                                                    details: refusal.details))
            #expect(await bench.transport.directCalls == 0)
            #expect(await bench.transport.legacyWrites.isEmpty)
        }

        /// With or without an owner and window, Demo Mode applies ungated (the transport answers its
        /// reads). A granted owner of the demo session, whose root is open, is left untouched: no lease.
        @Test(arguments: [true, false])
        func demoModeStaysUngatedAndNeverTouchesTheOwner(_ withOwner: Bool) async throws {
            let bench = try await makeBench(.demo)
            let (settings, _) = try Self.plan()
            await bench.transport.confirm(settings)
            let before = await bench.owner.authority.snapshot()
            let result = try await apply(bench, owner: withOwner ? bench.owner : nil,
                                         window: withOwner ? OwnerBench.windowOne : nil)
            #expect(result.state == .verified)
            #expect(Set(await bench.transport.legacyWrites.map(\.address)) == Set(settings.map(\.address)))
            #expect(await bench.transport.directCalls == 0)
            let after = await bench.owner.authority.snapshot()
            #expect(after == before)
            #expect(after.lease == nil)
            await bench.controller.disconnect()
        }

        /// A granted, open, connected root renders and verifies through direct writes only, and
        /// applies again with a fresh minter.
        @Test func aGrantedOpenRootAppliesThroughTheGate() async throws {
            let bench = try await makeBench()
            let (settings, _) = try Self.plan()
            for round in 1...2 {
                let result = try await apply(bench, owner: bench.owner)
                #expect(result.state == .verified)
                #expect(result.confirmedCount == settings.count)
                let sent = Array(Array(repeating: settings, count: round).joined())
                #expect(await bench.transport.directWrites == sent)
            }
            #expect(await bench.transport.legacyWrites.isEmpty)
            #expect(await bench.owner.authority.snapshot().lease?.windows == [OwnerBench.windowOne])
            #expect(await bench.owner.authority.outstandingDirectSendCount() == 0)
            #expect(await bench.owner.authority.outstandingDirectWriteCount() == 0)
            await bench.controller.disconnect()
        }

        /// Without a grant the apply is refused before `beginApply`: the window claims no lease.
        @Test func anUngrantedApplySendsNothingAndClaimsNoLease() async throws {
            let bench = try await makeBench(granted: false)
            try await expectRefused(try await apply(bench, owner: bench.owner), .notGranted, bench)
            #expect(await bench.owner.permission == nil)
            #expect(await bench.owner.authority.snapshot().lease == nil)
            await bench.controller.disconnect()
        }

        @Test(arguments: [(false, true), (true, false), (false, false)])
        func aMissingOwnerOrWindowSendsNothing(_ hasOwner: Bool, _ hasWindow: Bool) async throws {
            let bench = try await makeBench()
            let result = try await apply(bench, owner: hasOwner ? bench.owner : nil,
                                         window: hasWindow ? OwnerBench.windowOne : nil)
            try await expectRefused(result, hasOwner ? .noWindow : .noOwner, bench)
            #expect(await bench.owner.authority.snapshot().lease == nil)
            await bench.controller.disconnect()
        }

        @Test func aClosedWindowIsRefused() async throws {
            let bench = try await makeBench()
            await bench.owner.windowClosed(OwnerBench.windowOne)
            try await expectRefused(try await apply(bench, owner: bench.owner), .apply(.windowClosed), bench)
            #expect(await bench.owner.authority.snapshot().lease == nil)
            await bench.controller.disconnect()
        }

        @Test func anotherRenderingWindowRefusesTheApply() async throws {
            let bench = try await makeBench()
            _ = try await bench.owner.beginApply(window: OwnerBench.windowTwo).get()
            try await expectRefused(try await apply(bench, owner: bench.owner), .apply(.otherWindowRenders), bench)
            #expect(await bench.owner.authority.snapshot().lease?.windows == [OwnerBench.windowTwo])
            await bench.controller.disconnect()
        }

        /// `beginApply` succeeds on the owner's session (the window now renders), but that is not the
        /// controller's session, so no minter is built and nothing is sent.
        @Test func aSessionMismatchSendsNothing() async throws {
            let bench = try await makeBench(session: UUID())
            try await expectRefused(try await apply(bench, owner: bench.owner), .sessionMismatch, bench)
            #expect(await bench.owner.session != bench.controller.sessionID)
            #expect(await bench.owner.authority.snapshot().lease?.windows == [OwnerBench.windowOne])
            #expect(await bench.owner.authority.outstandingDirectWriteCount() == 0)
            await bench.controller.disconnect()
        }

        /// A planned disconnect leaves the owner without a session: `.noSession`, nothing sent.
        @Test func aDisconnectedLiveSessionIsRefused() async throws {
            let bench = try await makeBench()
            await bench.controller.disconnect()
            _ = try await bench.owner.disconnected().get()
            try await expectRefused(try await apply(bench, owner: bench.owner), .apply(.noSession), bench)
            #expect(await bench.owner.authority.snapshot().lease == nil)
        }

        /// The grant is revoked once the window renders, before the first mint: the mint is refused
        /// and the apply fails with nothing confirmed. It never falls back to the ungated path.
        @Test func aGrantRevokedBeforeTheMintNeverFallsBack() async throws {
            let revoker = RevokeAtLeaseReady()
            let bench = try await makeBench(checkpoint: { await revoker.visit($0) })
            await revoker.arm(bench.owner)
            let (settings, _) = try Self.plan()
            let result = try await apply(bench, owner: bench.owner)
            #expect(result == WingApplyVerification(
                state: .failed, settings: settings, confirmedCount: 0,
                details: "Safe endpoint levels could not be confirmed. Routing was not sent."
            ))
            #expect(await revoker.revoked)
            #expect(await bench.owner.permission == nil)
            #expect(await bench.transport.directCalls == 0)
            #expect(await bench.transport.legacyWrites.isEmpty)
            #expect(await bench.owner.authority.snapshot().lease?.windows == [OwnerBench.windowOne])
            #expect(await bench.owner.authority.outstandingDirectSendCount() == 0)
            #expect(await bench.owner.authority.outstandingDirectWriteCount() == 0)
            await bench.controller.disconnect()
        }
    }
}

/// One Studio apply route's controller, its echoing transport and the owner.
@MainActor
private struct RouteBench {
    let controller: WingController
    let transport: EchoingDirectTransport
    let owner: HostAuthorityOwner
}

/// Once armed, revokes the owner's grant at its `.leaseReady` checkpoint: the apply's lease work
/// completes, and its first mint then reads no permission.
private actor RevokeAtLeaseReady {
    private var owner: HostAuthorityOwner?
    private(set) var revoked = false

    func arm(_ owner: HostAuthorityOwner) { self.owner = owner }

    func visit(_ point: HostAuthorityOwner.Checkpoint) async {
        guard point == .leaseReady, let owner else { return }
        self.owner = nil
        await owner.revoke()
        revoked = true
    }
}
