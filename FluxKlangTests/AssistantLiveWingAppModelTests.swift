import Foundation
import Testing
@testable import FluxKlang

@MainActor
@Suite(.serialized)
struct AssistantLiveWingAppModelTests {
    private struct Fixture {
        let model: AppModel
        let transport: AssistantRecordingWingTransport
        let gear: Equipment
    }

    private func fixture() async throws -> Fixture {
        let transport = AssistantRecordingWingTransport()
        let wing = WingController(transport: transport)
        let model = AppModel(assistant: AssistantCoordinator(draftStore: AssistantBackendDraftStore()), wing: wing)
        let gear = try #require(model.equipment.items.first)
        _ = model.environments.addEnvironment(named: "Live Alias Test")
        try await model.studioConnections.replaceHome(StudioHomeConnections(inputs: gear.outputs.indices.map {
            StudioInputConnection(connector: 7 + $0, equipmentID: gear.id, outputPort: $0)
        }), equipment: model.equipment.items)
        await transport.put(WingAddress.inputName(7), .string("Fixture Alias"))
        await wing.connect(host: "192.0.2.10")
        await transport.emit(WingAddress.inputName(7), .string("Fixture Alias"))
        try await AssistantBackendFixture.wait { wing.confirmedValues[WingAddress.inputName(7)] != nil }
        return Fixture(model: model, transport: transport, gear: gear)
    }

    private func buildAliasDraft(_ model: AppModel, gear: Equipment) async throws {
        let context = model.assistantToolContext()
        let resolution = AssistantSourceResolver.resolve("route Fixture Alias to speakers", context: context)
        #expect(resolution.equipmentIDs == [gear.id])
        #expect(resolution.references.count == 1)
        var request = StudioWiringRequest(sourceInstrumentIDs: [gear.id])
        request.liveReferences = resolution.references
        _ = await model.assistant.perform(.buildStudioDraft(request), context: context)
    }

    @Test func liveScribblesNeverChangeSavedEffectiveOrCompiledStudioRouting() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        let transport = fixture.transport
        let saved = model.studioConnections.connections
        let effective = model.studioConnectionsForCurrentWing().effectiveHome
        let compiled = model.studioCompiledRouting()
        for (connector, name) in [(7, "Other Gear R"), (19, "New Gear L"), (20, "New Gear R")] {
            await transport.emit(WingAddress.inputName(connector), .string(name))
        }
        try await AssistantBackendFixture.wait {
            model.wing.confirmedValues[WingAddress.inputName(20)] == .string("New Gear R")
        }
        _ = model.assistantToolContext()
        #expect(model.studioConnections.connections == saved)
        #expect(model.studioConnectionsForCurrentWing().effectiveHome == effective)
        #expect(model.studioCompiledRouting() == compiled)
        #expect(model.wing.transportWriteCount == 0)
        #expect(await transport.writes.isEmpty)
        await model.wing.disconnect()
    }

    @Test func staleAliasDraftIsRefreshedBeforeAcceptanceWithoutHardwareWrites() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        let transport = fixture.transport
        try await buildAliasDraft(model, gear: fixture.gear)
        var stale = model.assistantToolContext()
        stale.liveWing = AssistantLiveWingContext.project(
            model.wing.confirmedSnapshot(now: Date().addingTimeInterval(31)),
            equipment: model.equipment.items, connections: stale.effectiveConnections)
        _ = await model.assistant.perform(.validatePendingStudioDraft, context: stale)
        #expect(model.assistant.pendingStudioDraft?.validation.contains { $0.code == "live-alias-changed" } == true)
        let before = await transport.queries.filter { $0 == WingAddress.inputName(7) }.count
        let result = await model.acceptPendingAssistantDraft()
        #expect(result != nil)
        #expect(await transport.queries.filter { $0 == WingAddress.inputName(7) }.count > before)
        #expect(model.wing.transportWriteCount == 0)
        #expect(await transport.writes.isEmpty)
        await model.wing.disconnect()
    }

    @Test func changedDisconnectedOrUnconfirmedAliasAcceptancePreservesGraphAndHomeWithoutWrites() async throws {
        for scenario in 0...2 {
            let fixture = try await fixture()
            let model = fixture.model
            let transport = fixture.transport
            try await buildAliasDraft(model, gear: fixture.gear)
            let graph = model.environments.activeStudioGraph
            let home = model.studioConnections.connections
            switch scenario {
            case 0: await transport.put(WingAddress.inputName(7), .string("Renamed"))
            case 1: await model.wing.disconnect()
            default: await transport.configure(answers: false)
            }
            #expect(await model.acceptPendingAssistantDraft() == nil)
            #expect(model.environments.activeStudioGraph == graph)
            #expect(model.studioConnections.connections == home)
            #expect(model.wing.transportWriteCount == 0)
            #expect(await transport.writes.isEmpty)
            await model.wing.disconnect()
        }
    }
}
