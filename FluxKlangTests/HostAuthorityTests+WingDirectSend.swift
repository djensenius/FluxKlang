import Foundation
import Testing
@testable import FluxKlang

private let console = "192.0.2.10"
private let mute = WingSetting(address: WingAddress.mute(.channel, 3), value: .int(1))

/// A grant binding `settings` (by default `mute` alone).
private func grant(_ authority: HostAuthority, settings: [WingSetting] = [mute]) async throws
    -> DirectWriteAuthorization {
    try await DirectSendBench.grant(authority, settings: settings)
}

/// Why `grant` now refuses `mute`; its body must never run. Use only once the grant is spent or revoked.
private func refusal(of grant: DirectWriteAuthorization) -> DirectWriteRefusal? {
    DirectSendBench.refusal(of: grant, target: mute.address)
}

extension HostAuthorityTests {
    /// Where `WingController.setDirect` refuses before reaching the transport.
    enum WingDirectSendRefusal: CaseIterable, Sendable {
        case disconnected, wrongSession, demo, cancelled
    }

    /// AU3: `WingController.setDirect` sends one SET inside a host-authority grant.
    /// Fakes only; nothing reaches a socket.
    @MainActor
    struct WingDirectSend {
        private func connected(
            _ transport: some WingTransporting, mode: WingMode = .live
        ) async throws -> (WingController, UUID) {
            let controller = WingController(transport: transport, mode: mode)
            await controller.connect(host: console)
            return (controller, try #require(controller.sessionID))
        }

        @Test func aFreshGrantSendsOnce() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport)
            let issued = try await grant(authority)

            #expect(await controller.setDirect(mute, session: session, authorization: issued))
            #expect(await transport.directWrites == [mute])
            #expect(await transport.legacyWrites.isEmpty)
            #expect(controller.values[mute.address] == mute.value)
            #expect(controller.transportWriteCount == 1)
            #expect(!issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(refusal(of: issued) == .notOutstanding)
            await controller.disconnect()
        }

        /// Success comes from the outcome, not payload equality: NaN never equals itself.
        @Test func aNaNSettingThatSendsReportsSuccess() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport)
            let fader = WingSetting(address: WingAddress.fader(.channel, 3), value: .float(.nan))
            let issued = try await grant(authority, settings: [fader])

            #expect(await controller.setDirect(fader, session: session, authorization: issued))
            let writes = await transport.directWrites
            try #require(writes.count == 1)
            #expect(writes[0].address == fader.address)
            guard case .float(let sent) = writes[0].value else {
                Issue.record("Expected a float write, got \(writes[0].value)")
                return
            }
            #expect(sent.isNaN)
            #expect(await transport.directCalls == 1)
            #expect(!issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 0)
            await controller.disconnect()
        }

        @Test func aLiveChangeRevokesTheGrantBeforeTheSend() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport)
            let issued = try await grant(authority)
            await authority.updateLive(try AuthorityBench.liveState(epoch: try DirectSendBench.nextEpoch()))

            #expect(await controller.setDirect(mute, session: session, authorization: issued) == false)
            #expect(await transport.directCalls == 1)
            #expect(await transport.directWrites.isEmpty)
            #expect(controller.values[mute.address] == nil)
            #expect(refusal(of: issued) == .staleLive)
            await controller.disconnect()
        }

        @Test func aLeaseTransferRevokesTheGrantBeforeTheSend() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport)
            let issued = try await grant(authority)
            _ = try await authority.transfer(to: AuthorityBench.projectB, window: AuthorityBench.windowB).get()

            #expect(await controller.setDirect(mute, session: session, authorization: issued) == false)
            #expect(await transport.directCalls == 1)
            #expect(await transport.directWrites.isEmpty)
            #expect(controller.values[mute.address] == nil)
            #expect(refusal(of: issued) == .staleLease)
            await controller.disconnect()
        }

        /// Each bound target sends at most once: repeating `mute` is not granted and
        /// revokes the rest, so the still-bound `other` cannot send either.
        @Test func aGrantSendsAtMostOnce() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport)
            let other = WingSetting(address: WingAddress.mute(.channel, 4), value: .int(1))
            let issued = try await grant(authority, settings: [mute, other])

            #expect(await controller.sendDirectEntry(mute, session: session, authorization: issued))
            #expect(await controller.setDirect(mute, session: session, authorization: issued) == false)
            #expect(await controller.setDirect(other, session: session, authorization: issued) == false)
            #expect(await transport.directCalls == 3)
            #expect(await transport.directWrites == [mute])
            #expect(controller.values[other.address] == nil)
            #expect(refusal(of: issued) == .notGranted)
            await controller.disconnect()
        }

        /// R3: a refusal before the transport still spends the grant (stricter than
        /// `setConfirmedMixerValue`), so it never keeps a `directSendCapacity` slot.
        @Test(arguments: WingDirectSendRefusal.allCases)
        func aControllerRefusalSpendsTheGrant(_ reason: WingDirectSendRefusal) async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport, mode: reason == .demo ? .demo : .live)
            let issued = try await grant(authority)
            #expect(await authority.outstandingDirectSendCount() == 1)

            let sent: Bool
            switch reason {
            case .disconnected:
                await controller.disconnect()
                sent = await controller.setDirect(mute, session: session, authorization: issued)
            case .wrongSession:
                sent = await controller.setDirect(mute, session: UUID(), authorization: issued)
            case .demo:
                sent = await controller.setDirect(mute, session: session, authorization: issued)
            case .cancelled:
                // The task cannot start before this main-actor test suspends, so it starts cancelled.
                let task = Task { await controller.setDirect(mute, session: session, authorization: issued) }
                task.cancel()
                sent = await task.value
            }

            #expect(sent == false)
            #expect(await transport.directCalls == 0)
            #expect(controller.transportWriteCount == 0)
            #expect(!issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(refusal(of: issued) == .notOutstanding)
            await controller.disconnect()
        }

        @Test func aTransportSessionMismatchRefusesAndSpends() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport)
            let issued = try await grant(authority)
            await transport.restart()

            #expect(await controller.setDirect(mute, session: session, authorization: issued) == false)
            #expect(await transport.directCalls == 1)
            #expect(await transport.directWrites.isEmpty)
            #expect(controller.values[mute.address] == nil)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(refusal(of: issued) == .notOutstanding)
            await controller.disconnect()
        }

        /// The SET goes out under the grant, but the controller session changes before
        /// the transport returns, so the controller does not record the value.
        @Test func aSessionChangeDuringTheSendIsNotRecorded() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = GatedDirectSendTransport()
            let (controller, session) = try await connected(transport)
            let issued = try await grant(authority)

            let sending = Task { await controller.setDirect(mute, session: session, authorization: issued) }
            await transport.waitUntilHeld()
            await controller.disconnect()
            await controller.connect(host: console)
            #expect(controller.sessionID != session)
            await transport.release()

            #expect(await sending.value)
            #expect(await transport.directWrites == [mute])
            #expect(controller.values[mute.address] == nil)
            #expect(refusal(of: issued) == .notOutstanding)
            await controller.disconnect()
        }

        /// The real transport is never started: its session is nil, so the check
        /// inside `consume` refuses before any socket call. Called through the
        /// protocol, as `WingController` does, and on the concrete type: both must
        /// reach `WingTransport`'s own methods, not the refusing protocol defaults.
        @Test func anUnstartedRealTransportRefusesWithoutIO() async throws {
            try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
            let authority = try await AuthorityBench.makeAuthority()
            let audit = ProductionAccessAudit()
            let real = WingTransport(mirroring: audit)
            let transport: any WingTransporting = real
            let issued = try await grant(authority)
            let concrete = try await grant(authority)
            let mixer = WingMixerWriteAuthorization(deadline: .now.advanced(by: .seconds(1)))

            await #expect(throws: WingTransportError.notAuthorized) {
                try await transport.sendDirect(mute, sessionID: UUID(), authorization: issued)
            }
            await #expect(throws: WingTransportError.notAuthorized) {
                try await real.sendDirect(mute, sessionID: UUID(), authorization: concrete)
            }
            await #expect(throws: WingTransportError.notAuthorized) {
                try await real.sendMixerValue(WingNodeRef(kind: .channel, index: 3), value: .int(1), muted: true,
                                              sessionID: UUID(), authorization: mixer)
            }
            #expect(await transport.sessionID == nil)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(refusal(of: issued) == .notOutstanding)
            #expect(refusal(of: concrete) == .notOutstanding)
            #expect(mixer.wasConsumed)
            let snapshot = audit.snapshot()
            #expect(snapshot.count(.passiveConstruction, for: .wingTransport) == 1)
            #expect(snapshot.count(.attempted, for: .wingTransport) == 0)
            #expect(snapshot.count(.apiEntered, for: .wingTransport) == 0)
        }

        @Test func theDefaultSendDirectSpendsTheGrantWithoutSending() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DefaultDirectSendTransport()
            let recorded = try await grant(authority)
            let inert = try await grant(authority)

            await #expect(throws: WingTransportError.notStarted) {
                try await transport.sendDirect(mute, sessionID: UUID(), authorization: recorded)
            }
            await #expect(throws: WingTransportError.notStarted) {
                try await InertWingTransport().sendDirect(mute, sessionID: UUID(), authorization: inert)
            }
            #expect(await transport.sends == 0)
            #expect(await authority.outstandingDirectSendCount() == 0)
            #expect(refusal(of: recorded) == .notOutstanding)
            #expect(refusal(of: inert) == .notOutstanding)
        }

        @Test func legacyApplyNeedsNoGrantAndLeavesGrantsArmed() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport)
            let issued = try await grant(authority)

            #expect(await controller.apply([mute]))
            #expect(await transport.legacyWrites == [mute])
            #expect(await transport.directCalls == 0)
            #expect(controller.values[mute.address] == mute.value)
            #expect(issued.isArmed)
            #expect(await authority.outstandingDirectSendCount() == 1)
            // The legacy path neither spends nor needs the grant.
            #expect(await controller.setDirect(mute, session: session, authorization: issued))
            #expect(await transport.directWrites == [mute])
            await controller.disconnect()
        }
    }
}
