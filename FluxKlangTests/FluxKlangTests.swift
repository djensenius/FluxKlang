//
//  FluxKlangTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

struct FluxKlangTests {
    @Test(arguments: [AssistantRecordingWingTransport.BindingRead.session, .peers])
    @MainActor func obsoleteBindingReadCannotOverwriteReplacement(_ read: AssistantRecordingWingTransport.BindingRead)
    async throws {
        let transport = AssistantRecordingWingTransport()
        let controller = WingController(transport: transport)
        await transport.pauseBindingRead(read)
        let obsolete = Task { await controller.connect(host: "192.0.2.10") }
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
        await controller.disconnect()
    }

    @Test @MainActor func cancelledSuspendedConnectionStopsAndCanRetry() async throws {
        let transport = AssistantRecordingWingTransport()
        let controller = WingController(transport: transport)
        await transport.pauseStart()
        let connection = Task { await controller.connect(host: "192.0.2.10") }
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
        await controller.disconnect()
    }

    @Test @MainActor func cancelledObsoleteConnectionNeverStopsTheReplacementAttempt() async throws {
        let transport = AssistantRecordingWingTransport()
        let controller = WingController(transport: transport)
        await transport.pauseStart()
        let obsolete = Task { await controller.connect(host: "192.0.2.10") }
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
