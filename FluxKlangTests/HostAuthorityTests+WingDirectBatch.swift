import Foundation
import Testing
@testable import FluxKlang

private let console = "192.0.2.10"
private let first = WingSetting(address: WingAddress.mute(.channel, 3), value: .int(1))
private let second = WingSetting(address: WingAddress.mute(.channel, 4), value: .int(1))
private let third = WingSetting(address: WingAddress.mute(.channel, 5), value: .int(0))
private let batch = [first, second, third]

private func grant(_ authority: HostAuthority, _ settings: [WingSetting] = batch) async throws
    -> DirectWriteAuthorization {
    try await DirectSendBench.grant(authority, settings: settings)
}

/// Why `grant` now refuses `setting`; use only once the grant is spent or revoked.
private func refusal(of grant: DirectWriteAuthorization, _ setting: WingSetting = first) -> DirectWriteRefusal? {
    DirectSendBench.refusal(of: grant, target: setting.address)
}

extension HostAuthorityTests {
    /// AU4: `WingController.applyDirect` sends a batch under one bound grant, in
    /// caller order, stopping and spending the grant at the first refusal. Fakes
    /// only; nothing reaches a socket.
    @MainActor
    struct WingDirectBatch {
        private func connected(
            _ transport: some WingTransporting, mode: WingMode = .live
        ) async throws -> (WingController, UUID) {
            let controller = WingController(transport: transport, mode: mode)
            await controller.connect(host: console)
            return (controller, try #require(controller.sessionID))
        }

        @Test func aBatchSendsEveryBoundSettingInOrder() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport)
            // The binding is unordered; the caller's order is kept.
            let issued = try await grant(authority, [third, first, second])

            let outcome = await controller.applyDirect(batch, session: session, authorization: issued)
            #expect(outcome == DirectApplyOutcome(sent: batch))
            #expect(await transport.directWrites == batch)
            #expect(batch.allSatisfy { controller.values[$0.address] == $0.value })
            #expect(controller.transportWriteCount == 3)
            #expect(!issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(refusal(of: issued) == .notOutstanding)

            // A batch shorter than its binding still spends the rest.
            let wider = try await grant(authority)
            #expect(await controller.applyDirect([second], session: session, authorization: wider)
                == DirectApplyOutcome(sent: [second]))
            #expect(!wider.isArmed)
            #expect(refusal(of: wider, third) == .notOutstanding)
            await controller.disconnect()
        }

        @Test func aSettingOutsideTheBindingIsNotSent() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport)
            let issued = try await grant(authority, [first, third])

            let outcome = await controller.applyDirect(batch, session: session, authorization: issued)
            #expect(outcome == DirectApplyOutcome(sent: [first], failed: second, unsent: [third]))
            #expect(await transport.directCalls == 2)
            #expect(await transport.directWrites == [first])
            #expect(controller.values[second.address] == nil)
            #expect(controller.values[third.address] == nil)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(refusal(of: issued, third) == .notGranted)
            await controller.disconnect()
        }

        @Test func aLiveChangeMidBatchStopsAndReportsPartial() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = GatedDirectSendTransport()
            let (controller, session) = try await connected(transport)
            let issued = try await grant(authority)

            let applying = Task { await controller.applyDirect(batch, session: session, authorization: issued) }
            await transport.waitUntilHeld()
            await authority.updateLive(try AuthorityBench.liveState(epoch: try DirectSendBench.nextEpoch()))
            await transport.release()

            #expect(await applying.value == DirectApplyOutcome(sent: [first], failed: second, unsent: [third]))
            #expect(await transport.directWrites == [first])
            #expect(controller.values[first.address] == first.value)
            #expect(controller.values[second.address] == nil)
            #expect(controller.values[third.address] == nil)
            #expect(refusal(of: issued, third) == .staleLive)
            await controller.disconnect()
        }

        /// The controller session changes while the first entry is in flight: its
        /// value is not recorded, the next entry is refused by the controller's
        /// per-entry check (the new transport session would accept it), and the
        /// grant is spent.
        @Test func aSessionChangeMidBatchStopsAndSpends() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = GatedDirectSendTransport()
            let (controller, session) = try await connected(transport)
            let issued = try await grant(authority)

            let applying = Task { await controller.applyDirect(batch, session: session, authorization: issued) }
            await transport.waitUntilHeld()
            await controller.disconnect()
            await controller.connect(host: console)
            #expect(controller.sessionID != session)
            await transport.release()

            #expect(await applying.value == DirectApplyOutcome(sent: [first], failed: second, unsent: [third]))
            #expect(await transport.directWrites == [first])
            #expect(batch.allSatisfy { controller.values[$0.address] == nil })
            #expect(!issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(refusal(of: issued, second) == .notOutstanding)
            await controller.disconnect()
        }

        /// The task is cancelled while the first entry is in flight: that entry
        /// completes, the next is refused by the controller's per-entry check, and
        /// the grant is spent.
        @Test func aCancellationMidBatchStopsAndSpends() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = GatedDirectSendTransport()
            let (controller, session) = try await connected(transport)
            let issued = try await grant(authority)

            let applying = Task { await controller.applyDirect(batch, session: session, authorization: issued) }
            await transport.waitUntilHeld()
            applying.cancel()
            await transport.release()

            #expect(await applying.value == DirectApplyOutcome(sent: [first], failed: second, unsent: [third]))
            #expect(await transport.directWrites == [first])
            #expect(controller.values[first.address] == first.value)
            #expect(controller.values[second.address] == nil)
            #expect(controller.values[third.address] == nil)
            #expect(!issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(refusal(of: issued, second) == .notOutstanding)
            await controller.disconnect()
        }

        @Test(arguments: WingDirectSendRefusal.allCases)
        func aControllerRefusalSpendsTheWholeBatch(_ reason: WingDirectSendRefusal) async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport, mode: reason == .demo ? .demo : .live)
            let issued = try await grant(authority)

            let outcome: DirectApplyOutcome
            switch reason {
            case .disconnected:
                await controller.disconnect()
                outcome = await controller.applyDirect(batch, session: session, authorization: issued)
            case .wrongSession:
                outcome = await controller.applyDirect(batch, session: UUID(), authorization: issued)
            case .demo:
                outcome = await controller.applyDirect(batch, session: session, authorization: issued)
            case .cancelled:
                // The task cannot start before this main-actor test suspends, so it starts cancelled.
                let task = Task { await controller.applyDirect(batch, session: session, authorization: issued) }
                task.cancel()
                outcome = await task.value
            }

            #expect(outcome == DirectApplyOutcome(failed: first, unsent: [second, third]))
            #expect(await transport.directCalls == 0)
            #expect(controller.transportWriteCount == 0)
            #expect(batch.allSatisfy { controller.values[$0.address] == nil })
            #expect(!issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(refusal(of: issued, third) == .notOutstanding)
            await controller.disconnect()
        }

        @Test func aTransportFailureStopsAndRelinquishes() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport)
            await transport.fail(second.address)
            let issued = try await grant(authority)

            let outcome = await controller.applyDirect(batch, session: session, authorization: issued)
            #expect(outcome == DirectApplyOutcome(sent: [first], failed: second, unsent: [third]))
            #expect(await transport.directCalls == 2)
            #expect(await transport.directWrites == [first])
            #expect(controller.values[first.address] == first.value)
            #expect(controller.values[second.address] == nil)
            #expect(controller.values[third.address] == nil)
            #expect(!issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(refusal(of: issued, third) == .notOutstanding)
            await controller.disconnect()
        }

        /// The real transport is never started. A bound target reaches the session
        /// check inside `consume` (`.notAuthorized`, the target spent); an unbound
        /// one is refused by the grant first. Neither calls the socket.
        @Test func anUnstartedRealTransportRefusesABoundGrantWithoutIO() async throws {
            try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
            let authority = try await AuthorityBench.makeAuthority()
            let audit = ProductionAccessAudit()
            let real = WingTransport(mirroring: audit)
            let transport: any WingTransporting = real
            let issued = try await grant(authority, [first, second])
            let narrow = try await grant(authority, [first])

            await #expect(throws: WingTransportError.notAuthorized) {
                try await transport.sendDirect(first, sessionID: UUID(), authorization: issued)
            }
            #expect(issued.isArmed)
            await #expect(throws: WingTransportError.notAuthorized) {
                try await real.sendDirect(second, sessionID: UUID(), authorization: issued)
            }
            #expect(!issued.isArmed)
            #expect(refusal(of: issued) == .notOutstanding)
            await #expect(throws: DirectWriteRefusal.notGranted) {
                try await real.sendDirect(third, sessionID: UUID(), authorization: narrow)
            }
            #expect(refusal(of: narrow) == .notGranted)
            #expect(await authority.outstandingDirectSendCount() == 0)
            let snapshot = audit.snapshot()
            #expect(snapshot.count(.passiveConstruction, for: .wingTransport) == 1)
            #expect(snapshot.count(.attempted, for: .wingTransport) == 0)
            #expect(snapshot.count(.apiEntered, for: .wingTransport) == 0)
        }
    }
}
