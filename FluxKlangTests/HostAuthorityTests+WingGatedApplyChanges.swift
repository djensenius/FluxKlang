import Foundation
import Testing
@testable import FluxKlang

private let console = "192.0.2.10"
private let safeMute = WingSetting(address: WingAddress.mute(.channel, 1), value: .int(1))
private let safeFader = WingSetting(address: WingAddress.fader(.channel, 1), value: .float(0.25))
private let sourceGroup = WingSetting(address: WingAddress.channelSourceGroup(1), value: .string("LCL"))
private let sourceIndex = WingSetting(address: WingAddress.channelSourceIndex(1), value: .int(3))
private let otherMute = WingSetting(address: WingAddress.mute(.channel, 2), value: .int(0))
private let safety = [safeMute, safeFader]
private let routing = [sourceGroup, sourceIndex]

/// One gated apply whose first send phase is `phase`: the settings, its safety
/// subset, the entry a test drops once, and the verdict text when it fails.
private struct ReplacedApply {
    let phase: WingDirectApplyPhase
    let retry: WingDirectApplyPhase
    let settings: [WingSetting]
    let safetySettings: [WingSetting]
    let dropped: WingSetting
    let details: String

    init(_ phase: WingDirectApplyPhase) {
        self.phase = phase
        if phase == .safety {
            (retry, settings, safetySettings, dropped) = (.safetyRetry, safety + routing, safety, safeFader)
            details = "Safe endpoint levels could not be confirmed. Routing was not sent."
        } else {
            (retry, settings, safetySettings, dropped) = (.retry, routing, [], sourceIndex)
            details = "The WING session changed during the apply. Nothing was confirmed."
        }
    }

    /// Direct writes the first phase makes, before its verification starts.
    var firstWrites: Int { phase == .safety ? safety.count : routing.count }
}

extension HostAuthorityTests {
    /// AU6: what the grant-gated `WingController.applyAndVerify` does when the
    /// WING session or its confirmations change while an apply is in flight. A
    /// replacement session's replies never verify the apply, and a retry chunk
    /// sends only its own still-pending settings. Fakes only; no socket.
    @MainActor
    struct WingGatedApplyChanges {
        private func connected(_ transport: EchoingDirectTransport) async throws -> (WingController, UUID) {
            let controller = WingController(transport: transport, mode: .live)
            await controller.connect(host: console)
            return (controller, try #require(controller.sessionID))
        }

        /// Waits until `controller` has confirmed every value of `settings`.
        private static func confirmed(_ settings: [WingSetting], by controller: WingController) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline,
                  !settings.allSatisfy({ controller.confirmedValues[$0.address] == $0.value }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        /// Reconnects `controller`, then has the replacement session confirm `replies`.
        private static func replaceSession(of controller: WingController, on transport: EchoingDirectTransport,
                                           confirming replies: [WingSetting]) async {
            await controller.disconnect()
            await controller.connect(host: console)
            await transport.confirm(replies)
            await confirmed(replies, by: controller)
            #expect(replies.allSatisfy { controller.confirmedValues[$0.address] == $0.value })
        }

        /// The session is replaced during the first verification delay. Whether the
        /// replacement confirms every value (nothing pending) or not, the apply fails
        /// with nothing confirmed, and the retry phase mints no grant for the dead session.
        @Test(arguments: [(WingDirectApplyPhase.safety, false), (.safety, true),
                          (.remaining, false), (.remaining, true)])
        func aSessionReplacedDuringTheFirstVerificationFailsTheApply(
            _ phase: WingDirectApplyPhase, _ leavesPending: Bool
        ) async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let apply = ReplacedApply(phase)
            if leavesPending { await transport.drop(apply.dropped.address, times: 1) }
            let replies = apply.settings.filter { !leavesPending || $0 != apply.dropped }
            await transport.replaceSession(afterWrites: apply.firstWrites) {
                await Self.replaceSession(of: controller, on: transport, confirming: replies)
            }

            let result = await controller.applyAndVerify(apply.settings, safetySettings: apply.safetySettings,
                                                         session: session, minting: minter)
            #expect(controller.sessionID != session)
            #expect(result.state == .failed)
            #expect(result.confirmedCount == 0)
            #expect(result.details == apply.details)
            #expect(await minter.phases == [phase])
            #expect(await transport.directCalls == apply.firstWrites)
            #expect(await minter.grants.allSatisfy { !$0.isArmed })
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }

        /// The session is replaced during the final verification, after the retry
        /// sent, and the replacement confirms every value: still nothing is confirmed.
        @Test(arguments: [WingDirectApplyPhase.safety, .remaining])
        func aSessionReplacedDuringTheFinalVerificationFailsTheApply(_ phase: WingDirectApplyPhase) async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let apply = ReplacedApply(phase)
            await transport.drop(apply.dropped.address, times: 1)
            await transport.replaceSession(afterWrites: apply.firstWrites + 1) {
                await Self.replaceSession(of: controller, on: transport, confirming: apply.settings)
            }

            let result = await controller.applyAndVerify(apply.settings, safetySettings: apply.safetySettings,
                                                         session: session, minting: minter)
            #expect(controller.sessionID != session)
            #expect(result.state == .failed)
            #expect(result.confirmedCount == 0)
            #expect(result.details == apply.details)
            #expect(await minter.phases == [phase, apply.retry])
            #expect(await transport.directCalls == apply.firstWrites + 1)
            #expect(await minter.grants.allSatisfy { !$0.isArmed })
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }

        /// While the retry chunk's mint is suspended, one bound setting is confirmed
        /// and a confirmed setting outside the chunk becomes pending again. Only the
        /// chunk's still-pending setting is sent; the unbound one is neither sent nor
        /// a transport failure, and the grant's unspent target is relinquished.
        @Test func confirmationsChangingDuringARetryMintSendOnlyBoundPendingSettings() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let minter = GatedApplyMinter(authority)
            let transport = EchoingDirectTransport()
            let (controller, session) = try await connected(transport)
            let settings = routing + [otherMute]
            let changedMute = WingSetting(address: otherMute.address, value: .int(1))
            for setting in routing { await transport.drop(setting.address, times: 1) }
            await minter.after(.retry, mint: 0) {
                #expect(controller.confirmedValues[otherMute.address] == otherMute.value)
                await transport.confirm([sourceGroup, changedMute])
                await Self.confirmed([sourceGroup, changedMute], by: controller)
                #expect(controller.confirmedValues[changedMute.address] == changedMute.value)
            }

            let result = await controller.applyAndVerify(settings, session: session, minting: minter)
            #expect(result.state == .partiallyVerified)
            #expect(result.confirmedCount == 2)
            let mints = await minter.mints
            #expect(mints.map(\.phase) == [.remaining, .retry])
            #expect(mints.map(\.orderedTargets) == [settings.map { DirectSendTarget($0.address) },
                                                    routing.map { DirectSendTarget($0.address) }])
            #expect(await transport.directCalls == 4)
            #expect(await transport.directWrites == settings + [sourceIndex])
            let grants = await minter.grants
            #expect(grants.count == 2)
            #expect(grants.allSatisfy { !$0.isArmed })
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }
    }
}

/// Why an AU8d state re-read must not verify.
enum WingRereadRefusal: CaseIterable, Sendable {
    case missing, olderThanRequest, otherSession, demo, disconnect, reconnect, cancelled
}

extension HostAuthorityTests {
    /// AU8d: `WingController.verifyReread(session:)`, the state re-read that verifies a live connect. It sends
    /// paced GETs only and succeeds only when every observed address answered after the request, on that
    /// session, within the deadline. Fakes only; no socket.
    @MainActor
    struct WingStateReread {
        private static let addresses = WingLiveObservations.addresses

        /// A connected controller whose connect-time GETs are stalled, then the transport armed.
        private func connected(_ transport: RereadTransport, mode: WingMode = .live) async throws -> WingController {
            let controller = WingController(transport: transport, mode: mode)
            await controller.connect(host: console)
            try #require(controller.connection.isConnected)
            try await Self.until { await transport.stalled >= 2 }
            return controller
        }

        @Test func everyObservedAddressAnsweredFreshlyThroughPacedGetsVerifies() async throws {
            let transport = RereadTransport(observed: Self.addresses)
            let controller = try await connected(transport)
            let session = try #require(controller.sessionID)
            await transport.arm()
            #expect(await controller.verifyReread(session: session))
            let gets = await transport.gets
            #expect(Self.addresses.count == 144)
            try #require(gets.count == Self.addresses.count)
            #expect(gets.map(\.address) == Self.addresses.sorted())
            #expect(await transport.sets.isEmpty)
            let size = WingNetwork.bulkRefreshBatchSize
            for boundary in stride(from: size, to: gets.count, by: size) {
                #expect(gets[boundary - 1].at.duration(to: gets[boundary].at) >= WingNetwork.bulkRefreshBatchDelay)
            }
            await controller.disconnect()
            await transport.finish()
        }

        /// Polls `condition` for up to 5 s.
        private static func until(_ condition: @MainActor () async -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline, await !condition() { try await Task.sleep(for: .milliseconds(5)) }
        }

        @Test(arguments: WingRereadRefusal.allCases)
        func anIncompleteStaleOrForeignRereadNeverVerifies(_ refusal: WingRereadRefusal) async throws {
            let transport = RereadTransport(observed: Self.addresses)
            let controller = try await connected(transport, mode: refusal == .demo ? .demo : .live)
            let session = try #require(controller.sessionID)
            let last = try #require(Self.addresses.sorted().last)
            switch refusal {
            case .missing: await transport.silence(last)
            case .olderThanRequest:
                await transport.answer(Self.addresses)
                try await Self.until { Self.addresses.allSatisfy { controller.confirmedReceivedAt[$0] != nil } }
                try #require(Self.addresses.allSatisfy { controller.confirmedReceivedAt[$0] != nil })
                await transport.silence(last)
            case .disconnect, .reconnect, .cancelled: await transport.hold(at: last)
            case .otherSession, .demo: break
            }
            await transport.arm()
            let read = Task { await controller.verifyReread(session: refusal == .otherSession ? UUID() : session) }
            if [.disconnect, .reconnect, .cancelled].contains(refusal) {
                try await Self.until { await transport.held }
                #expect(await transport.held)
                switch refusal {
                case .disconnect: await controller.disconnect()
                case .reconnect: await controller.connect(host: console)
                default: read.cancel()
                }
            }
            #expect(await read.value == false)
            if refusal == .demo || refusal == .otherSession { #expect(await transport.gets.isEmpty) }
            #expect(await transport.sets.isEmpty)
            await controller.disconnect()
            await transport.finish()
        }
    }
}
