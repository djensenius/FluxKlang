//
//  DemoModeTests.swift
//  FluxKlangTests
//
//  Exercises Demo Mode end to end: the controller connects to the in-memory
//  simulator, ingests the seeded console, reflects fader changes, and tears down.
//

import Testing
@testable import FluxKlang

@MainActor
struct DemoModeTests {
    @Test func demoConnectsAndSeedsConsole() async throws {
        let controller = WingController.demo()
        #expect(controller.isDemo)

        await controller.connectDemo()
        #expect(controller.connection.isConnected)

        try await waitUntil {
            controller.name(.channel, 1) != nil
                && controller.name(.main, 1) != nil
                && controller.faderPosition(.channel, 10) != nil
        }
        #expect(controller.name(.channel, 1) == "OP-1 Field L")
        #expect(controller.name(.main, 1) == "Main LR")
        #expect(controller.faderPosition(.channel, 10) != nil)

        await controller.disconnect()
        #expect(!controller.connection.isConnected)
    }

    @Test func demoReflectsFaderAndMuteChanges() async throws {
        let controller = WingController.demo()
        await controller.connectDemo()
        // Use a channel outside the ambient-motion range so the assertion is stable.
        await controller.setFader(.channel, 10, position: 0.5)
        try await waitUntil { controller.faderPosition(.channel, 10) == 0.5 }
        #expect(controller.faderPosition(.channel, 10) == 0.5)

        await controller.setMute(.channel, 10, muted: true)
        try await waitUntil { controller.isMuted(.channel, 10) == true }
        #expect(controller.isMuted(.channel, 10) == true)

        await controller.disconnect()
    }

    @Test func stereoPairFaderAndMuteDriveBothChannels() async throws {
        let controller = WingController.demo()
        await controller.connectDemo()
        // Channels 9 & 10 are outside the ambient-motion range, so the assertions
        // stay stable. position 0.5 with balance 0.25 → L 0.375, R 0.625.
        let left = WingNodeRef.channel(9)
        let right = WingNodeRef.channel(10)
        await controller.setFaderPair(left, right, position: 0.5, balance: 0.25)
        try await waitUntil {
            controller.faderPosition(.channel, 9) == 0.375
                && controller.faderPosition(.channel, 10) == 0.625
        }
        #expect(controller.faderPosition(.channel, 9) == 0.375)
        #expect(controller.faderPosition(.channel, 10) == 0.625)

        await controller.setMutePair(left, right, muted: true)
        try await waitUntil {
            controller.isMuted(.channel, 9) == true && controller.isMuted(.channel, 10) == true
        }
        #expect(controller.isMuted(.channel, 9) == true)
        #expect(controller.isMuted(.channel, 10) == true)

        await controller.disconnect()
    }
}
