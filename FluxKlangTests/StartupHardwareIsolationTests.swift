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

    @Test func appModelConstructionInvokesNoHardwareFactories() {
        let spy = HardwareFactorySpy()

        let model = AppModel(wing: .preview(), hardware: spy.factories)

        #expect(spy.inputsMade == 0)
        #expect(model.launchControlXL.status == .disabled)
    }

    @Test func appModelStartupInTestConfigurationInvokesNoProductionFactories() async {
        let spy = HardwareFactorySpy()
        let wing = WingController.preview()
        let hardware = HardwareServiceFactories.select(
            isTesting: AppPersistence.isTesting,
            production: spy.factories
        )
        let model = AppModel(
            assistant: AssistantCoordinator(draftStore: AssistantBackendDraftStore()),
            wing: wing,
            hardware: hardware
        )
        let writesBefore = wing.transportWriteCount

        await model.loadStores()

        #expect(spy.inputsMade == 0)
        #expect(spy.input.starts.isEmpty)
        #expect(model.wing === wing, "Startup must not reconnect to a live WING")
        #expect(wing.transportWriteCount == writesBefore)
        if case .connected = model.launchControlXL.status {
            Issue.record("Inert input must not report connected MIDI sources")
        }
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

    init(mode: LaunchControlXLMode) throws {
        var configuration = try #require(LaunchControlXLConfiguration.bundled())
        configuration.mode = mode
        self.configuration = configuration
    }

    @MainActor
    func controller(
        makeMIDIInput: @escaping @MainActor () -> any LaunchControlXLInput
    ) -> LaunchControlXLController {
        LaunchControlXLController(
            fileStore: JSONFileStore(directory: directory, cloud: nil),
            defaultConfiguration: configuration,
            makeMIDIInput: makeMIDIInput
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
