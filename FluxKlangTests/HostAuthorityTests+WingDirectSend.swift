import Foundation
import Testing
@testable import FluxKlang

private let projectA = AuthorityBench.projectA
private let liveParameter = ParameterID(validated: "parameter.live")
private let console = "192.0.2.10"
private let mute = WingSetting(address: WingAddress.mute(.channel, 3), value: .int(1))

private func nextEpoch() throws -> HostEpoch {
    HostEpoch(host: AuthorityBench.host, generation: try Generation.initial.next())
}

/// Admits a running-set `.set` of `liveParameter` (as in `HostAuthorityTests+DirectWrite.swift`).
private func admission() throws -> AdmissionContext {
    let descriptor = try ParameterDescriptor(.init(
        id: liveParameter, unit: .normalized, lower: 0, upper: 1, defaultValue: 0.5, ceiling: 0.8, curve: .linear,
        ramp: ParameterRamp(.init(kind: .linear, minimumMilliseconds: 10, maximumMilliseconds: 100)),
        controlClass: .live, verification: .reported
    ))
    return AdmissionContext(hostEpoch: AuthorityBench.hostEpoch, connectionEpoch: nil, revisions: CommandRevisions(),
                            permission: AuthorityBench.permission, allowedScopes: [.parameter(liveParameter)],
                            allowedClasses: Set(ControlClass.allCases), catalog: try ParameterCatalog([descriptor]))
}

private func intent() throws -> CommandIntent {
    try CommandIntent(.init(
        id: CommandID(validated: "command.wing"), commandClass: .live, origin: .human,
        hostEpoch: AuthorityBench.hostEpoch, connectionEpoch: nil, revisions: CommandRevisions(),
        operation: .set(liveParameter, ParameterValue(value: 0.5, unit: .normalized)),
        permission: AuthorityBench.permission
    ))
}

private func grant(_ authority: HostAuthority) async throws -> DirectWriteAuthorization {
    let ticket = try #require(try await authority.admitDirect(try intent(), admission: try admission(),
                                                              project: projectA, window: AuthorityBench.windowA).get())
    return try await authority.authorizeDirectSend(ticket).get()
}

/// Why `grant` now refuses; its body must never run. Use only once the grant is spent or revoked.
private func refusal(of grant: DirectWriteAuthorization) -> DirectWriteRefusal? {
    do {
        try grant.consume { Issue.record("A spent or revoked grant ran its send") }
    } catch let refusal as DirectWriteRefusal {
        return refusal
    } catch {
        Issue.record("Unexpected error \(error)")
    }
    return nil
}

/// No socket. Records direct SETs and legacy SETs; GETs are dropped. Its session
/// check mirrors `WingTransport.sendDirect`.
private actor DirectSendRecordingTransport: WingTransporting {
    nonisolated let incoming = AsyncStream<WingIncoming> { $0.finish() }
    private(set) var sessionID: UUID?
    private(set) var peerHosts: Set<String> = []
    private(set) var directCalls = 0
    private(set) var directWrites: [WingSetting] = []
    private(set) var legacyWrites: [WingSetting] = []

    func start(remoteHost: String, localPort: UInt16?, broadcast: Bool) {
        sessionID = UUID()
        peerHosts = [remoteHost]
    }

    /// A transport restart the controller has not observed.
    func restart() { sessionID = UUID() }

    func stop() {
        sessionID = nil
        peerHosts = []
    }

    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) {
        if let value { legacyWrites.append(WingSetting(address: address, value: value)) }
    }

    func sendDirect(_ setting: WingSetting, sessionID: UUID, authorization: DirectWriteAuthorization) throws {
        directCalls += 1
        try authorization.consume {
            guard self.sessionID == sessionID else { throw WingTransportError.notAuthorized }
            directWrites.append(setting)
        }
    }
}

/// No socket and no direct path: `sendDirect` is the protocol default.
private actor DefaultDirectSendTransport: WingTransporting {
    nonisolated let incoming = AsyncStream<WingIncoming> { $0.finish() }
    private(set) var sends = 0

    func start(remoteHost: String, localPort: UInt16?, broadcast: Bool) {}
    func stop() {}
    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) { sends += 1 }
}

/// No socket. `sendDirect` spends the grant and records the write, then holds its
/// return until `release()`, so a test can change the controller session mid-send.
private actor GatedDirectSendTransport: WingTransporting {
    nonisolated let incoming = AsyncStream<WingIncoming> { $0.finish() }
    private(set) var sessionID: UUID?
    private(set) var directWrites: [WingSetting] = []
    private var held: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    func start(remoteHost: String, localPort: UInt16?, broadcast: Bool) { sessionID = UUID() }
    func stop() { sessionID = nil }
    func send(_ address: String, _ value: WingValue?, to host: String?, port: UInt16?) {}

    func sendDirect(_ setting: WingSetting, sessionID: UUID,
                    authorization: DirectWriteAuthorization) async throws {
        try authorization.consume {
            guard self.sessionID == sessionID else { throw WingTransportError.notAuthorized }
            directWrites.append(setting)
        }
        await withCheckedContinuation { continuation in
            held = continuation
            holdWaiters.forEach { $0.resume() }
            holdWaiters.removeAll()
        }
    }

    func waitUntilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }

    func release() {
        held?.resume()
        held = nil
    }
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

        @Test func aLiveChangeRevokesTheGrantBeforeTheSend() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport)
            let issued = try await grant(authority)
            await authority.updateLive(try AuthorityBench.liveState(epoch: try nextEpoch()))

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

        @Test func aGrantSendsAtMostOnce() async throws {
            let authority = try await AuthorityBench.makeAuthority()
            let transport = DirectSendRecordingTransport()
            let (controller, session) = try await connected(transport)
            let issued = try await grant(authority)
            let other = WingSetting(address: WingAddress.mute(.channel, 4), value: .int(1))

            #expect(await controller.setDirect(mute, session: session, authorization: issued))
            #expect(await controller.setDirect(other, session: session, authorization: issued) == false)
            #expect(await transport.directCalls == 2)
            #expect(await transport.directWrites == [mute])
            #expect(controller.values[other.address] == nil)
            #expect(refusal(of: issued) == .notOutstanding)
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
