//
//  PresetsTests.swift
//  FluxKlangTests
//
//  Verifies preset capture (snapshot) and recall (apply) against the demo
//  controller: snapshotting reads current values, and recalling pushes them back.
//

import Testing
@testable import FluxKlang

@MainActor
struct PresetsTests {
    @Test func snapshotCapturesCurrentValues() async throws {
        let controller = WingController.demo()
        await controller.connectDemo()
        await controller.setFader(.channel, 10, position: 0.42)
        try await waitUntil { controller.faderPosition(.channel, 10) == 0.42 }

        let snapshot = controller.snapshot(of: [WingAddress.fader(.channel, 10)])
        #expect(snapshot.count == 1)
        #expect(snapshot.first?.value == .float(0.42))
    }

    @Test func recallAppliesSavedSettings() async throws {
        let controller = WingController.demo()
        await controller.connectDemo()
        await controller.setFader(.channel, 10, position: 0.2)
        try await waitUntil { controller.faderPosition(.channel, 10) == 0.2 }

        let preset = Preset(
            name: "Test",
            settings: [WingSetting(address: WingAddress.fader(.channel, 10), value: .float(0.8))]
        )
        await controller.apply(preset.settings)
        #expect(controller.faderPosition(.channel, 10) == 0.8)
    }
}
