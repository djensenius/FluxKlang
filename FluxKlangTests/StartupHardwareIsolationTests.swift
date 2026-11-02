//
//  StartupHardwareIsolationTests.swift
//  FluxKlangTests
//
//  Proves test-host startup selects inert hardware services, construction is
//  lazy, and Launch Control XL monitoring still works through an injected input.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@MainActor
struct StartupHardwareIsolationTests {
    @Test func isolatedMIDIConstructionIsPassive() throws {
        try requireIsolatedStartupProcess()
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
        try requireIsolatedStartupProcess()
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
        try requireIsolatedStartupProcess()
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

    @Test func testHostSelectionNeverBuildsOrInvokesProductionFactories() throws {
        try requireIsolatedStartupProcess()
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

    @Test func omittedWingMakerAndDefaultControllerAreInert() async throws {
        try requireIsolatedStartupProcess()
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
                await controller.disconnect()
                continue
            }
            #expect(controller.values.isEmpty)
            #expect(controller.confirmedValues.isEmpty)
            await controller.disconnect()
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

    @Test func appModelDefaultDisconnectAndFailureUseInjectedWingFactory() async throws {
        let owners = try StartupAppModelFixture()
        defer { owners.cleanUp() }
        let spy = WingFactorySpy()
        let model = owners.makeModel(hardware: spy.factories)
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
        await owners.finish(model)
    }

    @Test(.timeLimit(.minutes(1)))
    func monitorLoadAndControllerReplacementAwaitOwnedTransportStop() async throws {
        let owners = try StartupAppModelFixture()
        defer { owners.cleanUp() }
        let fixture = try LaunchControlXLFixture(mode: .monitor)
        defer { fixture.cleanUp() }
        var configuration = fixture.configuration
        configuration.mapping.sourceNameContains = ["Synthetic LCXL \(UUID().uuidString)"]
        await fixture.store.save(configuration, to: "launch-control-xl.json")
        let data = try Data(contentsOf: fixture.directory.appendingPathComponent("launch-control-xl.json"))
        #expect(try JSONDecoder().decode(LaunchControlXLConfiguration.self, from: data) == configuration)
        let reloaded = await fixture.store.load(LaunchControlXLConfiguration.self, from: "launch-control-xl.json")
        #expect(reloaded == configuration)

        let spy = HardwareFactorySpy()
        let wingSpy = StartupWingTransportSpy()
        var hardware = spy.factories
        hardware.makeWingTransport = wingSpy.makeTransport
        let model = owners.makeModel(hardware: hardware, launchControlXLStore: fixture.store)
        let initial = model.wing
        #expect(spy.inputsMade == 0)
        #expect(wingSpy.transports.count == 1)

        await model.loadLaunchControlXL()
        #expect(model.wing === initial)
        #expect(model.launchControlXL.configuration == configuration)
        #expect(model.launchControlXL.status == .waiting)
        #expect(spy.inputsMade == 1)
        #expect(spy.input.starts == [configuration.mapping.sourceNameContains])

        for showsFailure in [false, true] {
            let previous = model.wing
            let previousCount = wingSpy.transports.count
            guard let transport = wingSpy.transports.last else {
                Issue.record("The injected factory must retain each controller's transport")
                break
            }
            let replacement = Task { @MainActor in
                if showsFailure {
                    await model.showAcceptanceConnectionFailure()
                } else {
                    await model.disconnect()
                }
            }
            let entered = await transport.waitForStopEntry()
            #expect(entered, "Replacement must enter the old transport's stop")
            #expect(model.wing === previous)
            #expect(wingSpy.transports.count == previousCount)
            #expect(await transport.stopsStarted == 1)
            #expect(await transport.stopsCompleted == 0)
            await transport.releaseStop()
            await replacement.value
            #expect(await transport.stopsCompleted == 1)
            #expect(model.wing !== previous)
            #expect(wingSpy.transports.count == previousCount + 1)
            #expect(model.wing.mode == .live)
            #expect(model.wing.connection == (showsFailure
                ? .failed(reason: "Acceptance test: WING unavailable") : .disconnected))
            #expect(model.wing.values.isEmpty && model.wing.confirmedValues.isEmpty)
            #expect(previous.transportWriteCount == 0 && model.wing.transportWriteCount == 0)
            #expect(spy.inputsMade == 1)
            #expect(spy.input.starts == [configuration.mapping.sourceNameContains])
        }

        #expect(wingSpy.transports.count == 3)
        for transport in wingSpy.transports {
            await transport.releaseStop()
            #expect(await transport.starts == 0)
            #expect(await transport.sends == 0)
        }
        await model.launchControlXL.setMode(.disabled)
        #expect(model.launchControlXL.status == .disabled)
        #expect(spy.input.stops == 1)
        await model.wing.disconnect()
        await model.awaitDomainScheduledSaveSnapshots()
        await model.awaitSiriEntityIndexingSnapshot()
        #expect(wingSpy.transports.count == 3, "Cleanup must not replace the final controller")
    }

    @Test func explicitWingAndPreviewConstructionDoNotBuildADefaultTransport() async throws {
        let owners = try StartupAppModelFixture()
        defer { owners.cleanUp() }
        let spy = WingFactorySpy()
        let wing = WingController(transport: InertWingTransport())
        let model = owners.makeModel(wing: wing, hardware: spy.factories)
        #expect(model.wing === wing)
        let previewWing = WingController.preview()
        let preview = owners.makeModel(wing: previewWing, hardware: spy.factories)
        #expect(preview.wing === previewWing)
        #expect(preview.isDemo && preview.isConnected)
        #expect(spy.ports.isEmpty, "An explicit controller must not create a throwaway default")
        let appPreview = AppModel.preview()
        #expect(appPreview.isDemo && appPreview.isConnected)
        #expect(!appPreview.wing.values.isEmpty)
        let activePreviewWing = appPreview.wing
        do {
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
        } catch {
            await owners.finish(model, preview, appPreview)
            throw error
        }
        await owners.finish(model, preview, appPreview)
    }

    @Test func appModelWiresInjectedFactoriesLazilyIntoLaunchControlXLStartup() async throws {
        let owners = try StartupAppModelFixture()
        defer { owners.cleanUp() }
        let fixture = try LaunchControlXLFixture(mode: .monitor)
        defer { fixture.cleanUp() }
        await fixture.seed()
        let spy = HardwareFactorySpy()
        let wing = WingController.preview()
        let writesBefore = wing.transportWriteCount
        let model = owners.makeModel(wing: wing, hardware: spy.factories, launchControlXLStore: fixture.store)
        #expect(spy.inputsMade == 0, "Construction must not create a MIDI input")

        await model.loadLaunchControlXL()

        #expect(model.launchControlXL.configuration.mode == .monitor)
        #expect(spy.inputsMade == 1)
        #expect(spy.input.starts == [fixture.configuration.mapping.sourceNameContains])
        #expect(model.launchControlXL.status == .waiting)

        let fader = MIDIControlChange(channel: 16, controller: 5, value: 127)
        spy.input.send([fader])
        do {
            try await waitUntil { model.launchControlXL.lastAction != nil }
        } catch {
            await owners.finish(model)
            throw error
        }
        // Awaiting receive directly lets any (regressed) dispatch finish before the write check.
        await model.launchControlXL.receive([fader])

        #expect(model.launchControlXL.lastAction == .fader(slot: 0, value: 1))
        #expect(model.wing === wing, "Startup must not replace the WING controller")
        #expect(wing.transportWriteCount == writesBefore, "Monitor mode must not write to the WING")
        await owners.finish(model)
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
        await controller.setMode(.disabled)
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
        do {
            try await waitUntil { controller.lastAction != nil }
        } catch {
            await controller.setMode(.disabled)
            throw error
        }

        #expect(controller.lastAction == .fader(slot: 0, value: 1))
        #expect(dispatched.isEmpty)
        await controller.setMode(.disabled)
    }
}
