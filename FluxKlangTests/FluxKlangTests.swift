//
//  FluxKlangTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

struct FluxKlangTests {
    @Test @MainActor func controllerStartsDisconnected() {
        let controller = WingController()
        #expect(controller.connection == .disconnected)
        #expect(controller.connection.isConnected == false)
        #expect(controller.port == WingNetwork.defaultPort)
        #expect(controller.host == nil)
        #expect(controller.values.isEmpty)
    }
}
