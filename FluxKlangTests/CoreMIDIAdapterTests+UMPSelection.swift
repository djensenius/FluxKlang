import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CoreMIDIAdapterTests {
    @Test func backendConfigurationPreservesOldMapsAndRequiredValidation() throws {
        let bundled = try #require(LaunchControlXLConfiguration.bundled())
        #expect(bundled.version == 1)
        #expect(bundled.inputBackend == .legacyBytes)
        var customized = bundled
        customized.mode = .control
        customized.mapping.faderCCs = [77, 78]
        customized.mapping.sourceNameContains = ["My custom surface"]
        #expect(LaunchControlXLConfiguration(
            version: 1, mode: .control, mapping: customized.mapping
        ).inputBackend == .legacyBytes)
        let data = try JSONEncoder().encode(customized)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func decode(_ object: [String: Any]) throws -> LaunchControlXLConfiguration {
            try JSONDecoder().decode(
                LaunchControlXLConfiguration.self, from: JSONSerialization.data(withJSONObject: object)
            )
        }
        for value: Any? in [nil, NSNull(), "unknown-future-backend", "legacyBytes"] {
            var old = object
            old["inputBackend"] = value
            #expect(try decode(old) == customized, "fallback must preserve the user's mapping and mode")
        }
        for backend in LaunchControlXLInputBackend.allCases {
            var selected = customized
            selected.inputBackend = backend
            #expect(try JSONDecoder().decode(
                LaunchControlXLConfiguration.self, from: JSONEncoder().encode(selected)
            ) == selected)
        }
        for value: Any in [1, true, [], ["unexpected": "object"]] {
            var wrong = object
            wrong["inputBackend"] = value
            #expect(throws: DecodingError.self) { try decode(wrong) }
        }
        for key in ["version", "mode", "mapping"] {
            var missing = object
            missing[key] = nil
            #expect(throws: DecodingError.self) { try decode(missing) }
            missing[key] = NSNull()
            #expect(throws: DecodingError.self) { try decode(missing) }
            missing[key] = ["not": "the required type"]
            #expect(throws: DecodingError.self) { try decode(missing) }
        }
    }

    @MainActor
    @Test func byteOnlyCompatibilityNeverSilentlyStartsExperimentalInput() {
        let input = RecordingLaunchControlXLInput()
        var reports: [[MIDIConnectedSource]] = []
        input.start(
            backend: .experimentalMIDI1UMP, sourceNameContains: Self.surface, onPackets: { _ in },
            onSourcesChanged: { reports.append($0) }
        )
        #expect(input.starts.isEmpty)
        #expect(reports == [[]])
        input.start(
            backend: .legacyBytes, sourceNameContains: Self.surface, onPackets: { _ in },
            onSourcesChanged: { reports.append($0) }
        )
        #expect(input.starts == [Self.surface])
    }

    @MainActor
    @Test func selectionPersistsAndRestartsByteUMPByteOnOneInput() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = ProtocolInput()
        var made = 0
        let controller = fixture.controller(makeMIDIInput: { made += 1; return input })
        var actions: [LaunchControlXLAction] = []
        controller.setActionHandler { actions.append($0) }
        await controller.load()
        input.send(.bytes([[0xBF, 5]]))
        let old = try #require(input.starts.last)
        let staleSource = try Self.connected(99, "stale", fingerprint: nil)
        input.duringStop = {
            old.report([staleSource])
            #expect(controller.status == .waiting, "generation must be invalidated before calling old stop")
            old.deliver(MIDIPacketBatch(packets: [[0xBF, 6, 127]]))
        }
        await controller.setInputBackend(.experimentalMIDI1UMP)
        input.duringStop = nil
        #expect(controller.status == .waiting)
        #expect(controller.unresolvedSourceNames.isEmpty)
        #expect(controller.lastAction == nil, "old delivery during stop must not update reports or actions")
        input.send(.midi1UMP([[0x2FBF_057F]]))
        await controller.dispatchPendingActions()
        #expect(actions == [.fader(slot: 0, value: 1)])
        let saved = await fixture.store.load(LaunchControlXLConfiguration.self, from: "launch-control-xl.json")
        #expect(saved?.inputBackend == .experimentalMIDI1UMP)
        #expect(saved?.mapping == fixture.configuration.mapping)
        #expect(saved?.mode == .control)
        await controller.setInputBackend(.legacyBytes)
        old.deliver(MIDIPacketBatch(packets: [[0xBF, 6, 127]]))
        old.report([try Self.connected(98, "old report", fingerprint: nil)])
        input.send(.bytes([[127]]))
        await controller.dispatchPendingActions()
        #expect(actions.count == 1)
        input.send(.bytes([[0xBF, 6, 127]]))
        await controller.dispatchPendingActions()
        #expect(actions == [.fader(slot: 0, value: 1), .fader(slot: 1, value: 1)])
        #expect(input.starts.map(\.backend) == [.legacyBytes, .experimentalMIDI1UMP, .legacyBytes])
        #expect(input.events == ["start", "stop", "start", "stop", "start"])
        #expect(made == 1)
        let legacy = await fixture.store.load(LaunchControlXLConfiguration.self, from: "launch-control-xl.json")
        #expect(legacy?.inputBackend == .legacyBytes)
        #expect(legacy?.mapping == fixture.configuration.mapping)
        await controller.setMode(.disabled)
        await controller.setInputBackend(.experimentalMIDI1UMP)
        await controller.setInputBackend(.legacyBytes)
        #expect(input.starts.count == 3)
        #expect(controller.status == .disabled)
        await controller.setMode(.control)
        #expect(made == 1)
        #expect(input.starts.last?.backend == .legacyBytes)
        await controller.setMode(.disabled)
    }

    @MainActor
    @Test(arguments: [false, true])
    func backendAndModeRestartBeforePersistenceCanSuspend(changeMode: Bool) async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let store = fixture.store
        let input = ProtocolInput()
        let controller = LaunchControlXLController(
            fileStore: store, defaultConfiguration: fixture.configuration, makeMIDIInput: { input }
        )
        await controller.load()
        let gate = AdmissionGate()
        let blocker = Task.detached { await store.save(StoreHold(gate: gate), to: "held.json") }
        guard gate.wait(gate.entered) else {
            gate.release.signal()
            await blocker.value
            return
        }
        let change = Task {
            if changeMode {
                await controller.setMode(.monitor)
            } else {
                await controller.setInputBackend(.experimentalMIDI1UMP)
            }
        }
        #expect(await Self.eventually { input.starts.count == 2 })
        #expect(input.events == ["start", "stop", "start"])
        gate.release.signal()
        await blocker.value
        await change.value
        await controller.setMode(.disabled)
    }

    @MainActor
    @Test func rapidSelectionsDoNotRestartAgainWhenOlderPersistenceReturns() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let store = fixture.store
        let input = ProtocolInput()
        let controller = LaunchControlXLController(
            fileStore: store, defaultConfiguration: fixture.configuration, makeMIDIInput: { input }
        )
        await controller.load()
        let gate = AdmissionGate()
        let blocker = Task.detached { await store.save(StoreHold(gate: gate), to: "held.json") }
        guard gate.wait(gate.entered) else {
            gate.release.signal()
            await blocker.value
            return
        }
        let first = Task { await controller.setInputBackend(.experimentalMIDI1UMP) }
        #expect(await Self.eventually { input.starts.count == 2 })
        let second = Task { await controller.setInputBackend(.legacyBytes) }
        #expect(await Self.eventually { input.starts.count == 3 })
        let disabled = Task { await controller.setMode(.disabled) }
        #expect(await Self.eventually { controller.status == .disabled })
        let final = Task { await controller.setInputBackend(.experimentalMIDI1UMP) }
        #expect(await Self.eventually { controller.configuration.inputBackend == .experimentalMIDI1UMP })
        gate.release.signal()
        await blocker.value
        await first.value
        await second.value
        await disabled.value
        await final.value
        #expect(input.starts.map(\.backend) == [.legacyBytes, .experimentalMIDI1UMP, .legacyBytes])
        #expect(controller.status == .disabled)
        #expect(controller.configuration.inputBackend == .experimentalMIDI1UMP)
    }

    @MainActor
    @Test func pendingActionsAndOldReportsCannotCrossSuspendedHandlerAndBackendChanges() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = ProtocolInput()
        let controller = fixture.controller(makeMIDIInput: { input })
        var actions: [LaunchControlXLAction] = []
        var gate: CheckedContinuation<Void, Never>?
        var finished = false
        controller.setActionHandler { action in
            actions.append(action)
            if actions.count == 1 {
                await withCheckedContinuation { gate = $0 }
                finished = true
            }
        }
        await controller.load()
        let old = try #require(input.starts.last)
        input.send(.bytes([[0xBF, 5, 127], [0xBF, 6, 127]]))
        guard await Self.eventually({ gate != nil }) else {
            gate?.resume()
            await controller.setMode(.disabled)
            return
        }
        await controller.setInputBackend(.experimentalMIDI1UMP)
        old.deliver(MIDIPacketBatch(packets: [[0xBF, 7, 127]]))
        old.report([])
        input.send(.midi1UMP([[0x20BF_087F]]))
        gate?.resume()
        #expect(await Self.eventually { finished && actions.count >= 2 })
        #expect(actions == [.fader(slot: 0, value: 1), .fader(slot: 3, value: 1)])
        #expect(controller.lastAction == .fader(slot: 3, value: 1))
        #expect(controller.status == .waiting)
        await controller.setMode(.disabled)
    }

    @MainActor
    @Test func umpGeneratedControlsAreImmediateOrderedAndMonitorOnlyObserves() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = ProtocolInput()
        var configuration = fixture.configuration
        configuration.inputBackend = .experimentalMIDI1UMP
        let controller = LaunchControlXLController(
            fileStore: fixture.store, defaultConfiguration: configuration, makeMIDIInput: { input }
        )
        var actions: [LaunchControlXLAction] = []
        controller.setActionHandler { actions.append($0) }
        await controller.load()
        input.send(.midi1UMP([[0x2FBF_057F, 0x21BF_1400, 0x20BF_257F, 0x20BF_2D7F, 0x20BF_2D00,
                              0x20BF_667F, 0x20BF_677F]]))
        await controller.dispatchPendingActions()
        #expect(actions == [
            .fader(slot: 0, value: 1), .panOrBalance(slot: 7, value: -1), .select(slot: 0),
            .toggleMute(slot: 0), .moveBank(1), .moveBank(-1)
        ])
        await controller.setMode(.monitor)
        input.send(.midi1UMP([[0x20BF_067F]]))
        await controller.dispatchPendingActions()
        #expect(actions.count == 6)
        #expect(controller.lastAction == .fader(slot: 1, value: 1))
        await controller.setMode(.disabled)

        configuration.mapping.faderCCs = [6, 38, 98, 99, 100, 101]
        let paired = LaunchControlXLController(
            fileStore: fixture.store, fileName: "paired.json",
            defaultConfiguration: configuration, makeMIDIInput: { input }
        )
        paired.setActionHandler { actions.append($0) }
        await paired.load()
        for (slot, controller) in [UInt32(6), 38, 98, 99, 100, 101].enumerated() {
            let before = actions.count
            input.send(.midi1UMP([[0x20BF_007F | controller << 8]]))
            await paired.dispatchPendingActions()
            #expect(actions.count == before + 1)
            #expect(actions.last == .fader(slot: slot, value: 1))
        }
        await paired.setMode(.disabled)
    }

    @MainActor
    @Test func unexpectedFormatDropsAndResetsAllSourcesBeforeUnknownTokenRouting() async throws {
        let fixture = try LaunchControlXLFixture(mode: .control)
        defer { fixture.cleanUp() }
        let input = ProtocolInput()
        let controller = fixture.controller(makeMIDIInput: { input })
        var actions: [LaunchControlXLAction] = []
        controller.setActionHandler { actions.append($0) }
        await controller.load()
        let resolved = try Self.connected(1, "A", fingerprint: 1)
        let shared = try Self.connected(2, "B", fingerprint: nil)
        input.starts.last?.report([resolved, shared])
        input.send(.bytes([[0xBF, 5]]), token: 1)
        input.send(.bytes([[0xBF, 6]]), token: 2)
        input.starts.last?.deliver(MIDIPacketBatch(
            payload: .midi1UMP([[0x20BF_077F]]), source: try Self.token(99)
        ))
        input.send(.bytes([[127]]), token: 1)
        input.send(.bytes([[127]]), token: 2)
        await controller.dispatchPendingActions()
        #expect(actions.isEmpty)
        await controller.setInputBackend(.experimentalMIDI1UMP)
        input.starts.last?.deliver(MIDIPacketBatch(packets: [[0xBF, 5, 127]]))
        input.send(.midi1UMP([[0x20BF_067F]]))
        await controller.dispatchPendingActions()
        #expect(actions == [.fader(slot: 1, value: 1)])
        await controller.setMode(.disabled)
    }
}

extension CoreMIDIAdapterTests {
    struct ProtocolStart {
        let backend: LaunchControlXLInputBackend
        let deliver: @MainActor (MIDIPacketBatch) -> Void
        let report: ([MIDIConnectedSource]) -> Void
    }

    @MainActor
    final class ProtocolInput: LaunchControlXLInput {
        let delivery = MIDICallbackDelivery(automaticallyDrive: false)
        var ingress: MIDICallbackIngress?
        var starts: [ProtocolStart] = []
        var events: [String] = []
        var duringStop: (() -> Void)?

        func start(
            sourceNameContains: [String], onPackets: @escaping @MainActor (MIDIPacketBatch) -> Void,
            onSourcesChanged: @escaping ([MIDIConnectedSource]) -> Void
        ) {
            start(backend: .legacyBytes, sourceNameContains: sourceNameContains,
                  onPackets: onPackets, onSourcesChanged: onSourcesChanged)
        }

        func start(
            backend: LaunchControlXLInputBackend, sourceNameContains: [String],
            onPackets: @escaping @MainActor (MIDIPacketBatch) -> Void,
            onSourcesChanged: @escaping ([MIDIConnectedSource]) -> Void
        ) {
            events.append("start")
            starts.append(ProtocolStart(backend: backend, deliver: onPackets, report: onSourcesChanged))
            let ingress: MIDICallbackIngress
            do {
                ingress = try MIDICallbackIngress(format: backend.format)
            } catch {
                Issue.record(error)
                return
            }
            self.ingress = ingress
            delivery.start(ingress, reconcile: {}, handler: onPackets)
        }

        func stop() {
            events.append("stop")
            duringStop?()
            delivery.stop()
            ingress = nil
            starts.last?.report([])
        }

        func send(_ payload: MIDIPacketBatch.Payload, token: UInt = 0) {
            guard let ingress else { Issue.record("Input not started"); return }
            switch payload {
            case .bytes(let packets): #expect(CoreMIDIAdapterTests.send(packets, to: ingress, token: token))
            case .midi1UMP(let packets): #expect(EventList(packets).send(to: ingress, token: token))
            }
            delivery.tick()
        }
    }

    struct StoreHold: Encodable {
        let gate: AdmissionGate
        func encode(to encoder: any Encoder) throws {
            gate.hold()
            var container = encoder.singleValueContainer()
            try container.encode("owned persistence blocker")
        }
    }
}
