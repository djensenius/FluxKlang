//
//  StartupHardwareIsolationTests.swift
//  FluxKlangTests
//
//  Proves test-host startup selects inert hardware services, construction is
//  lazy, and Launch Control XL monitoring still works through an injected input.
//

import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct StartupHardwareIsolationTests {
    @Test func testHostSelectionNeverBuildsOrInvokesProductionFactories() {
        let spy = HardwareFactorySpy()
        let selected = HardwareServiceFactories.select(
            isTesting: true,
            production: { Issue.record("Test selection built production factories"); return spy.factories }()
        )

        #expect(AppPersistence.isTesting)
        #expect(selected.makeLaunchControlXLInput() is InertLaunchControlXLInput)
        #expect(HardwareServiceFactories.current.makeLaunchControlXLInput() is InertLaunchControlXLInput)
        #expect(spy.inputsMade == 0)
    }

    @Test func productionSelectionStillUsesProductionFactories() {
        let spy = HardwareFactorySpy()
        let selected = HardwareServiceFactories.select(isTesting: false, production: spy.factories)

        #expect(selected.makeLaunchControlXLInput() === spy.input)
        #expect(spy.inputsMade == 1)
    }

    @Test func appModelWiresInjectedFactoriesLazilyIntoLaunchControlXLStartup() async throws {
        let fixture = try LaunchControlXLFixture(mode: .monitor)
        defer { fixture.cleanUp() }
        await fixture.seed()
        let spy = HardwareFactorySpy()
        let wing = WingController.preview()
        let writesBefore = wing.transportWriteCount
        let model = AppModel(wing: wing, hardware: spy.factories, launchControlXLStore: fixture.store)
        #expect(spy.inputsMade == 0, "Construction must not create a MIDI input")

        await model.loadLaunchControlXL()

        #expect(model.launchControlXL.configuration.mode == .monitor)
        #expect(spy.inputsMade == 1)
        #expect(spy.input.starts == [fixture.configuration.mapping.sourceNameContains])
        #expect(model.launchControlXL.status == .waiting)

        let fader = MIDIControlChange(channel: 16, controller: 5, value: 127)
        spy.input.send([fader])
        try await waitUntil { model.launchControlXL.lastAction != nil }
        // Awaiting receive directly lets any (regressed) dispatch finish before the write check.
        await model.launchControlXL.receive([fader])

        #expect(model.launchControlXL.lastAction == .fader(slot: 0, value: 1))
        #expect(model.wing === wing, "Startup must not replace the WING controller")
        #expect(wing.transportWriteCount == writesBefore, "Monitor mode must not write to the WING")
    }

    @Test func disabledLoadNeverCreatesMIDIInputAndRestartsReuseOneInput() async throws {
        let fixture = try LaunchControlXLFixture(mode: .disabled)
        defer { fixture.cleanUp() }
        let spy = HardwareFactorySpy()
        let controller = fixture.controller(makeMIDIInput: spy.factories.makeLaunchControlXLInput)

        await controller.load()
        #expect(spy.inputsMade == 0)
        #expect(controller.status == .disabled)

        await controller.setMode(.monitor)
        await controller.setMode(.disabled)
        await controller.setMode(.monitor)

        #expect(spy.inputsMade == 1)
        #expect(spy.input.starts.count == 2)
        #expect(spy.input.stops == 2)
        #expect(controller.status == .waiting)
    }

    @Test func injectedInputStillDrivesMonitorWithoutDispatching() async throws {
        let fixture = try LaunchControlXLFixture(mode: .monitor)
        defer { fixture.cleanUp() }
        let spy = HardwareFactorySpy()
        let controller = fixture.controller(makeMIDIInput: spy.factories.makeLaunchControlXLInput)
        var dispatched: [LaunchControlXLAction] = []
        controller.setActionHandler { dispatched.append($0) }

        await controller.load()
        #expect(spy.inputsMade == 1)
        #expect(spy.input.starts == [fixture.configuration.mapping.sourceNameContains])
        #expect(controller.status == .waiting)

        spy.input.reportSources(["Launch Control XL"])
        #expect(controller.status == .connected(["Launch Control XL"]))

        spy.input.send([MIDIControlChange(channel: 16, controller: 5, value: 127)])
        try await waitUntil { controller.lastAction != nil }

        #expect(controller.lastAction == .fader(slot: 0, value: 1))
        #expect(dispatched.isEmpty)
    }
}

@MainActor
private final class HardwareFactorySpy {
    let input = RecordingLaunchControlXLInput()
    private(set) var inputsMade = 0

    var factories: HardwareServiceFactories {
        HardwareServiceFactories { [self] in
            inputsMade += 1
            return input
        }
    }
}

@MainActor
private final class RecordingLaunchControlXLInput: LaunchControlXLInput {
    private(set) var starts: [[String]] = []
    private(set) var stops = 0
    private var onMessages: (([MIDIControlChange]) -> Void)?
    private var onSourcesChanged: (([String]) -> Void)?

    func start(
        sourceNameContains: [String],
        onMessages: @escaping ([MIDIControlChange]) -> Void,
        onSourcesChanged: @escaping ([String]) -> Void
    ) {
        starts.append(sourceNameContains)
        self.onMessages = onMessages
        self.onSourcesChanged = onSourcesChanged
    }

    func stop() {
        stops += 1
        onSourcesChanged?([])
    }

    func reportSources(_ names: [String]) {
        onSourcesChanged?(names)
    }

    func send(_ messages: [MIDIControlChange]) {
        onMessages?(messages)
    }
}

private struct LaunchControlXLFixture {
    let directory = URL.temporaryDirectory.appendingPathComponent("lcxl-\(UUID().uuidString)", isDirectory: true)
    let configuration: LaunchControlXLConfiguration

    var store: JSONFileStore { JSONFileStore(directory: directory, cloud: nil) }

    init(mode: LaunchControlXLMode) throws {
        var configuration = try #require(LaunchControlXLConfiguration.bundled())
        configuration.mode = mode
        self.configuration = configuration
    }

    /// Saves the fixture mode where `AppModel`'s controller loads it, overriding the bundled default.
    func seed() async {
        await store.save(configuration, to: "launch-control-xl.json")
    }

    @MainActor
    func controller(
        makeMIDIInput: @escaping @MainActor () -> any LaunchControlXLInput
    ) -> LaunchControlXLController {
        LaunchControlXLController(
            fileStore: store,
            defaultConfiguration: configuration,
            makeMIDIInput: makeMIDIInput
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
