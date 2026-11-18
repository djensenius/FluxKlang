//
//  FluxKlangTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

@Suite(.productionAccessAudit)
struct FluxKlangTests {
    @Test(arguments: [AssistantRecordingWingTransport.BindingRead.session, .peers])
    @MainActor func obsoleteBindingReadCannotOverwriteReplacement(_ read: AssistantRecordingWingTransport.BindingRead)
    async throws {
        let transport = AssistantRecordingWingTransport()
        let controller = WingController(transport: transport)
        await transport.pauseBindingRead(read)
        let obsolete = Task { await controller.connect(host: "192.0.2.10") }
        do {
            try await AssistantBackendFixture.waitAsync { await transport.bindingReadWaiting }
            let oldTransportSession = await transport.sessionID
            await controller.disconnect()
            await controller.connect(host: "192.0.2.11")
            let current = controller.sessionID
            await transport.releaseBindingRead()
            await obsolete.value
            #expect(controller.connection.isConnected)
            #expect(controller.sessionID == current)
            #expect(controller.host == "192.0.2.11")
            await transport.emit("/binding/probe", .int(1), session: oldTransportSession)
            await transport.emit("/binding/probe", .int(2), host: "192.0.2.11")
            try await AssistantBackendFixture.wait { controller.confirmedValues["/binding/probe"] == .int(2) }
            #expect(await transport.stopCount == 1)
            #expect(await transport.writes.isEmpty)
        } catch {
            obsolete.cancel()
            await transport.releaseBindingRead()
            await obsolete.value
            await controller.disconnect()
            throw error
        }
        await controller.disconnect()
    }

    @Test @MainActor func cancelledSuspendedConnectionStopsAndCanRetry() async throws {
        let transport = AssistantRecordingWingTransport()
        let controller = WingController(transport: transport)
        await transport.pauseStart()
        let connection = Task { await controller.connect(host: "192.0.2.10") }
        do {
            try await AssistantBackendFixture.waitAsync { await transport.startWaiting }
            connection.cancel()
            await transport.releaseStart()
            await connection.value
            #expect(controller.connection == .disconnected)
            #expect(controller.sessionID == nil)
            #expect(controller.host == nil)
            #expect(await transport.sessionID == nil)
            #expect(await transport.stopCount == 1)
            await controller.connect(host: "192.0.2.10")
            #expect(controller.connection.isConnected)
            #expect(controller.sessionID != nil)
            #expect(await transport.writes.isEmpty)
        } catch {
            connection.cancel()
            await transport.releaseStart()
            await connection.value
            await controller.disconnect()
            throw error
        }
        await controller.disconnect()
    }

    @Test @MainActor func cancelledObsoleteConnectionNeverStopsTheReplacementAttempt() async throws {
        let transport = AssistantRecordingWingTransport()
        let controller = WingController(transport: transport)
        await transport.pauseStart()
        let obsolete = Task { await controller.connect(host: "192.0.2.10") }
        do {
            try await AssistantBackendFixture.waitAsync { await transport.startWaiting }
            obsolete.cancel()
            await controller.disconnect()
            await controller.connect(host: "192.0.2.10")
            let current = controller.sessionID
            await transport.releaseStart()
            await obsolete.value
            #expect(controller.connection.isConnected)
            #expect(controller.sessionID == current)
            #expect(await transport.sessionID != nil)
            #expect(await transport.stopCount == 1)
            #expect(await transport.writes.isEmpty)
        } catch {
            obsolete.cancel()
            await transport.releaseStart()
            await obsolete.value
            await controller.disconnect()
            throw error
        }
        await controller.disconnect()
    }

    /// Bounded (2 s) wait reported as a Bool so a missing reply fails an expectation, not a throw.
    @MainActor private static func arrives(_ condition: @MainActor () -> Bool) async -> Bool {
        (try? await AssistantBackendFixture.wait(condition)) != nil
    }

    @Test @MainActor func reconnectOnTheSameTransportStillReceivesReplies() async throws {
        let transport = AssistantRecordingWingTransport()
        let controller = WingController(transport: transport)
        await controller.connect(host: "192.0.2.10")
        await transport.emit("/reconnect/probe", .int(1))
        let first = await Self.arrives { controller.confirmedValues["/reconnect/probe"] == .int(1) }
        #expect(first)
        await controller.disconnect()
        await controller.connect(host: "192.0.2.10")
        let session = try #require(await transport.sessionID)
        await transport.emit("/reconnect/probe", .int(2), session: session)
        let renewed = await Self.arrives { controller.confirmedValues["/reconnect/probe"] == .int(2) }
        #expect(renewed, "the second session on the same transport must still ingest replies")
        #expect(transport.incomingReadCount == 1, "one listener spans both sessions")
        await controller.disconnect()
    }

    @Test @MainActor func staleSessionReplyAfterReconnectIsIgnored() async throws {
        let transport = AssistantRecordingWingTransport()
        let controller = WingController(transport: transport)
        await controller.connect(host: "192.0.2.10")
        let stale = try #require(await transport.sessionID)
        await controller.disconnect()
        await controller.connect(host: "192.0.2.10")
        let current = try #require(await transport.sessionID)
        #expect(current != stale)
        await transport.emit("/reconnect/stale", .int(1), session: stale)
        await transport.emit("/reconnect/fence", .int(2), session: current)
        let fenced = await Self.arrives { controller.confirmedValues["/reconnect/fence"] == .int(2) }
        #expect(fenced)
        #expect(controller.confirmedValues["/reconnect/stale"] == nil, "stale transport session is dropped")
        await controller.disconnect()
    }

    /// Demo replies carry no transport session, so only the connected-state guard drops a reply
    /// that the single listener drains while a reconnect is still suspended in `start`.
    @Test @MainActor func demoReplyWhileReconnectingIsIgnored() async throws {
        let transport = AssistantRecordingWingTransport()
        let controller = WingController(transport: transport, mode: .demo)
        await controller.connect(host: "demo")
        await controller.disconnect()
        await transport.pauseStart()
        let reconnect = Task { await controller.connect(host: "demo") }
        do {
            try await AssistantBackendFixture.waitAsync { await transport.startWaiting }
            #expect(controller.connection == .connecting)
            await transport.emit("/reconnect/early", .int(1))
            await Task.yield()
            await transport.releaseStart()
            await reconnect.value
            await transport.emit("/reconnect/fence", .int(2))
            let fenced = await Self.arrives { controller.confirmedValues["/reconnect/fence"] == .int(2) }
            #expect(fenced)
            #expect(controller.confirmedValues["/reconnect/early"] == nil, "no ingest before connected")
        } catch {
            await transport.releaseStart()
            await reconnect.value
            await controller.disconnect()
            throw error
        }
        await controller.disconnect()
    }

    @Test @MainActor func demoReconnectStillReceivesEchoes() async throws {
        let controller = WingController.demo()
        let mute = WingAddress.mute(.channel, 1)
        await controller.connectDemo()
        let seeded = await Self.arrives { controller.confirmedValues[mute] == .int(0) }
        #expect(seeded)
        await controller.disconnect()
        await controller.connectDemo()
        await controller.setMute(.channel, 1, muted: true)
        let echoed = await Self.arrives { controller.confirmedValues[mute] == .int(1) }
        #expect(echoed, "demo echo after reconnect must be ingested")
        await controller.disconnect()
    }

    @Test @MainActor func controllerStartsDisconnected() {
        let controller = WingController()
        #expect(controller.connection == .disconnected)
        #expect(controller.connection.isConnected == false)
        #expect(controller.port == WingNetwork.defaultPort)
        #expect(controller.host == nil)
        #expect(controller.values.isEmpty)
    }
}
