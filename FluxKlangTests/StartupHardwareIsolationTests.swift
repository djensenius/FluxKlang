//
//  StartupHardwareIsolationTests.swift
//  FluxKlangTests
//
//  Proves test-host startup selects inert hardware services, construction is
//  lazy, and Launch Control XL monitoring still works through an injected input.
//

import Foundation
import Synchronization
import Testing
@testable import FluxKlang

@MainActor
struct StartupHardwareIsolationTests {
    @Test func isolatedMIDIConstructionIsPassive() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        let audit = ProductionAccessAudit()
        _ = CoreMIDIInput(mirroring: audit)
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.passiveConstruction, for: .midiInput) == 1)
        #expect(snapshot.count(.factoryEvaluated, for: .midiInput) == 0)
        #expect(snapshot.count(.attempted, for: .midiInput) == 0)
        #expect(snapshot.count(.denied, for: .midiInput) == 0)
        #expect(snapshot.count(.apiEntered, for: .midiInput) == 0)
    }

    @Test func isolatedMIDIRestartsRetainNoCallbacks() async throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        let audit = ProductionAccessAudit()
        let input = CoreMIDIInput(mirroring: audit)
        var callbackObjects: [NSObject] = []
        weak var callbackOwner: NSObject?
        func start() {
            let owner = NSObject()
            callbackOwner = owner
            input.start(sourceNameContains: ["Synthetic MIDI source"],
                        onMessages: { _ in callbackObjects.append(owner) },
                        onSourcesChanged: { _ in callbackObjects.append(owner) })
        }

        for _ in 0..<2 {
            start()
            #expect(callbackOwner == nil, "A denied start must not retain either callback")
        }
        input.stop()
        input.stop()
        start()
        #expect(callbackOwner == nil)
        input.stop()
        await Task.yield()
        #expect(callbackObjects.isEmpty)
        let snapshot = audit.snapshot()
        #expect(snapshot.count(.attempted, for: .midiInput) == 3)
        #expect(snapshot.count(.denied, for: .midiInput) == 3)
        #expect(snapshot.count(.apiEntered, for: .midiInput) == 0)
    }

    @Test func directProductionConstructorsAreDeniedBeforeEvaluation() throws {
        try #require(AppPersistence.isTesting, "Production-boundary tests require process-selected isolation")
        let audit = ProductionAccessAudit()
        let factories = HardwareServiceFactories.productionFactories(mirroring: audit)
        let before = audit.snapshot()
        for operation in ProductionAccessAudit.Operation.allCases {
            for event in ProductionAccessAudit.Event.allCases {
                #expect(before.count(event, for: operation) == 0, "A closure bundle is not a production attempt")
            }
        }

        #expect(factories.makeLaunchControlXLInput() is InertLaunchControlXLInput)
        #expect(factories.makePermissionProbe() is InertPermissionProbe)
        #expect(factories.makeWingTransport(WingNetwork.defaultPort, factories.localNetworkProbe) is InertWingTransport)
        let after = audit.snapshot()
        let constructors: [ProductionAccessAudit.Operation] = [.midiInput, .permissionProbe, .wingTransport]
        for operation in constructors {
            #expect(after.count(.attempted, for: operation) == 1)
            #expect(after.count(.denied, for: operation) == 1)
            #expect(after.count(.factoryEvaluated, for: operation) == 0)
            #expect(after.count(.passiveConstruction, for: operation) == 0)
            #expect(after.count(.apiEntered, for: operation) == 0)
        }
    }

    @Test func testHostSelectionNeverBuildsOrInvokesProductionFactories() {
        let spy = HardwareFactorySpy()
        let selected = HardwareServiceFactories.select(
            isTesting: true,
            production: { Issue.record("Test selection built production factories"); return spy.factories }()
        )

        #expect(AppPersistence.isTesting)
        #expect(selected.makeLaunchControlXLInput() is InertLaunchControlXLInput)
        #expect(HardwareServiceFactories.current.makeLaunchControlXLInput() is InertLaunchControlXLInput)
        #expect(selected.makeWingTransport(WingNetwork.defaultPort, selected.localNetworkProbe) is InertWingTransport)
        let current = HardwareServiceFactories.current
        #expect(current.makeWingTransport(WingNetwork.defaultPort, current.localNetworkProbe) is InertWingTransport)
        #expect(spy.inputsMade == 0)
        #expect(spy.wing.ports.isEmpty)
    }

    @Test func productionSelectionStillUsesProductionFactories() {
        let spy = HardwareFactorySpy()
        let selected = HardwareServiceFactories.select(isTesting: false, production: spy.factories)

        #expect(selected.makeLaunchControlXLInput() === spy.input)
        #expect(spy.inputsMade == 1)
        #expect(spy.wing.ports.isEmpty, "Selection must not eagerly build a transport")
        _ = selected.makeWingTransport(9000, selected.localNetworkProbe)
        #expect(spy.wing.ports == [9000])
    }

    @Test func omittedWingMakerAndDefaultControllerAreInert() async {
        let factories = HardwareServiceFactories(makeLaunchControlXLInput: { InertLaunchControlXLInput() })
        let transport = factories.makeWingTransport(WingNetwork.defaultPort, factories.localNetworkProbe)
        #expect(transport is InertWingTransport)
        for controller in [WingController(), WingController(hardware: factories)] {
            #expect(controller.mode == .live)
            #expect(controller.port == WingNetwork.defaultPort)
            #expect(controller.connection == .disconnected)
            await controller.connect(host: "must-not-resolve.invalid")
            guard case .failed = controller.connection else {
                Issue.record("An inert controller must refuse connection")
                continue
            }
            #expect(controller.values.isEmpty)
            #expect(controller.confirmedValues.isEmpty)
        }
    }

    @Test func inertTransportRefusesStartAndSendWithoutProducingData() async {
        let transport = InertWingTransport()
        await #expect(throws: WingTransportError.notStarted) {
            try await transport.start(remoteHost: "must-not-resolve.invalid", localPort: nil, broadcast: true)
        }
        await #expect(throws: WingTransportError.notStarted) {
            try await transport.send("/ch/1/fdr", .float(1))
        }
        await transport.stop()
        await transport.stop()
        #expect(await transport.sessionID == nil)
        #expect(await transport.peerHosts.isEmpty)
        var messages = transport.incoming.makeAsyncIterator()
        #expect(await messages.next() == nil)
    }

    @Test func controllerConstructionAndFailureUseInjectedWingFactory() {
        let spy = WingFactorySpy()
        let controller = WingController(port: 9000, hardware: spy.factories)
        #expect(controller.mode == .live)
        #expect(controller.port == 9000)
        #expect(controller.connection == .disconnected)
        let failure = WingController.acceptanceFailure(reason: "Unavailable", hardware: spy.factories)
        #expect(failure.mode == .live)
        #expect(failure.connection == .failed(reason: "Unavailable"))
        #expect(failure.values.isEmpty)
        #expect(spy.ports == [9000, WingNetwork.defaultPort])
    }

    @Test func appModelDefaultDisconnectAndFailureUseInjectedWingFactory() async {
        let spy = WingFactorySpy()
        let model = AppModel(hardware: spy.factories)
        let initial = model.wing
        #expect(spy.ports == [WingNetwork.defaultPort])
        #expect(initial.connection == .disconnected)

        await model.disconnect()
        #expect(model.wing !== initial)
        #expect(model.wing.connection == .disconnected)
        #expect(spy.ports.count == 2)

        await model.showAcceptanceConnectionFailure()
        #expect(model.wing.mode == .live)
        #expect(model.wing.connection == .failed(reason: "Acceptance test: WING unavailable"))
        #expect(spy.ports == Array(repeating: WingNetwork.defaultPort, count: 3))
    }

    @Test func explicitWingAndPreviewConstructionDoNotBuildADefaultTransport() async throws {
        let spy = WingFactorySpy()
        let wing = WingController(transport: InertWingTransport())
        let model = AppModel(wing: wing, hardware: spy.factories)
        #expect(model.wing === wing)
        let previewWing = WingController.preview()
        let preview = AppModel(wing: previewWing, hardware: spy.factories)
        #expect(preview.wing === previewWing)
        #expect(preview.isDemo && preview.isConnected)
        #expect(spy.ports.isEmpty, "An explicit controller must not create a throwaway default")
        let appPreview = AppModel.preview()
        #expect(appPreview.isDemo && appPreview.isConnected)
        #expect(!appPreview.wing.values.isEmpty)
        let activePreviewWing = appPreview.wing
        let actions = try #require(appPreview.assistantChat.actionPlanner as? AssistantActionController)
        #expect(actions === appPreview.assistantActions)
        #expect(actions.controller() === activePreviewWing)
        let mixer = try #require(appPreview.assistantChat.mixerExecutor)
        let refusal = await mixer.execute(.init(target: .main(1), operation: .mute(true)),
                                          sessionID: activePreviewWing.sessionID)
        #expect(refusal.hasPrefix("No changes:"))
        #expect(refusal.contains("not Demo Mode"))
        #expect(activePreviewWing.transportWriteCount == 0)

        await appPreview.disconnect()

        #expect(appPreview.wing !== activePreviewWing)
        #expect(appPreview.wing.mode == .live)
        #expect(appPreview.wing.connection == .disconnected)
        #expect(actions.controller() === appPreview.wing, "The existing action binding must follow replacement")
        #expect(appPreview.assistantChat.actionPlanner as? AssistantActionController === actions)
        #expect(activePreviewWing.transportWriteCount == 0)
        #expect(appPreview.wing.transportWriteCount == 0)
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
    let wing = WingFactorySpy()
    private(set) var inputsMade = 0

    var factories: HardwareServiceFactories {
        HardwareServiceFactories(makeLaunchControlXLInput: { [self] in
            inputsMade += 1
            return input
        }, makeWingTransport: wing.makeTransport)
    }
}

/// All state captured by the @Sendable WING factory is protected by the mutex.
private final class WingFactorySpy: Sendable {
    private let recordedPorts = Mutex<[UInt16]>([])
    var ports: [UInt16] { recordedPorts.withLock { $0 } }

    @MainActor var factories: HardwareServiceFactories {
        var factories = HardwareServiceFactories.inert
        factories.makeWingTransport = makeTransport
        return factories
    }

    func makeTransport(port: UInt16, probe: @escaping LocalNetworkProbe.Check) -> any WingTransporting {
        recordedPorts.withLock { $0.append(port) }
        return InertWingTransport()
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
