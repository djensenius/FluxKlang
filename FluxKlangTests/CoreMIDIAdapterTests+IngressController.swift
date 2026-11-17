import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CoreMIDIAdapterTests {
    @MainActor
    @Test func ingressGapOnUnknownTokenResetsResolvedAndLegacyControllerSources() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = RecordingLaunchControlXLInput()
        let controller = fixture.controller(makeMIDIInput: { input })
        var actions: [LaunchControlXLAction] = []
        controller.setActionHandler { actions.append($0) }
        await controller.load()
        input.reportConnected([
            try Self.connected(1, "resolved", fingerprint: 10),
            try Self.connected(2, "legacy", fingerprint: nil)
        ])
        let ingress = try MIDICallbackIngress(batches: 2)
        let delivery = MIDICallbackDelivery(automaticallyDrive: false)
        delivery.start(ingress, reconcile: {}, handler: try #require(input.onPackets))
        #expect(Self.send([[0xBF, 5]], to: ingress, token: 1))
        #expect(Self.send([[0xBF, 6]], to: ingress, token: 2))
        #expect(!Self.send([[0]], to: ingress, token: 1))
        delivery.tick()
        #expect(Self.send([[7]], to: ingress, token: 99))
        delivery.tick() // unknown route must not bypass the accompanying all-source reset
        #expect(Self.send([[127]], to: ingress, token: 1))
        #expect(Self.send([[127]], to: ingress, token: 2))
        delivery.tick()
        await controller.dispatchPendingActions()
        #expect(actions.isEmpty)
        #expect(Self.send([[0xBF, 5, 127]], to: ingress, token: 1))
        #expect(Self.send([[0xBF, 6, 127]], to: ingress, token: 2))
        delivery.tick()
        await controller.dispatchPendingActions()
        #expect(actions == [.fader(slot: 0, value: 1), .fader(slot: 1, value: 1)])
        delivery.stop()
        await controller.setMode(.disabled)
    }
}
