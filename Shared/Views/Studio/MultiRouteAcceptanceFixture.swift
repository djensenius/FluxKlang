#if DEBUG
import SwiftUI

@MainActor
enum MultiRouteAcceptanceFixture {
    static func seed(_ appModel: AppModel, arguments: [String]) async throws {
        guard AcceptanceLaunchConfiguration.isMultiRouteUITesting, AppPersistence.isTesting,
              AppPersistence.defaultCloud == nil, appModel.isDemo else {
            throw FixtureError.requiresUITestingDemo
        }
        let devices = try fixtureEquipment(in: appModel)
        let osmose = devices[0]
        let solar = devices[1]
        let opxy = devices[2]
        let evilPet = devices[3]
        _ = appModel.environments.addEnvironment(named: "Multi-route UI Acceptance")
        let effect = Effect(
            id: UUID(uuidString: "57FEC185-E5B0-58A1-B299-25861E4AB52A")!,
            name: evilPet.name,
            equipmentID: evilPet.id,
            sendOutputs: [3, 4],
            returnInputs: [7, 8]
        )
        appModel.environments.add(effect)
        for move in appModel.studioConnections.connections.temporaryMoves {
            await appModel.studioConnections.removeTemporaryMove(move.id)
        }
        var home = physicalHome(devices)
        let priorSource = Equipment(
            id: UUID(uuidString: "B6326F55-CA48-4975-9EE8-1E567931D128")!,
            name: "Preserved Synth", outputs: ["Out"])
        if arguments.contains("-ui-test-multi-route-prior") {
            appModel.equipment.add(priorSource)
            home.inputs.append(.init(connector: 9, equipmentID: priorSource.id, outputPort: 0))
        }
        try await appModel.studioConnections.replaceHome(home, equipment: appModel.equipment.items)
        if arguments.contains("-ui-test-multi-route-prior") {
            try seedPriorGraph(appModel, source: priorSource)
        }
        let direct = "\(osmose.name) to mains"
        let processed = "\(solar.name) through \(evilPet.name) to mains"
        let desktop = "\(opxy.name) to desktop speakers"
        let dry = arguments.contains("-ui-test-multi-route-dry-parallel")
            ? "\(solar.name) dry and wet in parallel" : ""
        let replace = arguments.contains("-ui-test-multi-route-replace") ? "replace the entire setup" : ""
        let text = [direct, processed, desktop, dry, replace].filter { !$0.isEmpty }.joined(separator: ", ")
        let intent = AssistantRoutingIntent(branches: [
            .init(source: osmose.name, destination: "mains", destinationEvidence: direct),
            .init(source: solar.name, effects: [evilPet.name], destination: "mains",
                  destinationEvidence: processed, processingEvidence: processed,
                  includesDrySignal: !dry.isEmpty, dryEvidence: dry),
            .init(source: opxy.name, destination: "desktop speakers", destinationEvidence: desktop)
        ], replacesSetup: !replace.isEmpty, modeEvidence: replace)
        let context = appModel.assistantToolContext()
        guard case .prepared(let draft) = AssistantRoutingPreparation.prepare(
            text: text, intent: intent, context: context
        ) else { throw FixtureError.invalidPhysicalDraft("Typed fixture preparation failed.") }
        guard await appModel.assistant.commitPreparedRouting(
            draft, expectedPending: appModel.assistant.pendingStudioDraft,
            preparedContext: context, currentContext: context
        ) else {
            throw FixtureError.invalidPhysicalDraft("Coordinator did not stage the prepared Studio draft.")
        }
        try requireValid(draft)
        guard appModel.wing.transportWriteCount == 0 else { throw FixtureError.unexpectedTransportWrite }
        appModel.section = .studio
    }

    private static func fixtureEquipment(in appModel: AppModel) throws -> [Equipment] {
        let names = ["Expressive E Osmose", "Elta SOLAR 42F", "OP-XY", "Endorphin.es EviL Pet"]
        let library = Equipment.seededLibrary + Equipment.confirmedLiveAdditions
        return try names.map { name in
            guard let canonical = library.first(where: { $0.name == name }) else {
                throw FixtureError.missingEquipment(name)
            }
            // Fixed port descriptions are UI-test configuration, not live rig inference.
            if appModel.equipment.item(canonical.id) == nil {
                appModel.equipment.add(canonical)
            } else {
                appModel.equipment.update(canonical)
            }
            return canonical
        }
    }

    private static func physicalHome(_ devices: [Equipment]) -> StudioHomeConnections {
        let inputs = devices.enumerated().flatMap { index, device in
            device.outputs.indices.map { port in
                StudioInputConnection(
                    connector: index * 2 + port + 1,
                    equipmentID: device.id,
                    outputPort: port
                )
            }
        }
        let evilPet = devices[3]
        return StudioHomeConnections(inputs: inputs, outputs: [
            StudioOutputConnection(connector: 1, destinationName: "Desk Speakers L"),
            StudioOutputConnection(connector: 2, destinationName: "Desk Speakers R"),
            StudioOutputConnection(connector: 3, equipmentID: evilPet.id, inputPort: 0),
            StudioOutputConnection(connector: 4, equipmentID: evilPet.id, inputPort: 1),
            StudioOutputConnection(connector: 7, destinationName: "Main Speakers L"),
            StudioOutputConnection(connector: 8, destinationName: "Main Speakers R")
        ])
    }

    private static func seedPriorGraph(_ appModel: AppModel, source: Equipment) throws {
        let prior = StudioWiringAdvisor.build(
            request: StudioWiringRequest(sourceInstrumentIDs: [source.id], destination: .finalMix),
            equipment: appModel.equipment.items,
            effects: appModel.environments.activeEffects,
            connections: appModel.studioConnections.connections,
            currentGraph: StudioGraph(),
            environmentID: appModel.environments.activeID
        )
        try requireValid(prior)
        let merged = StudioPatchDraftMerger.merge(
            prior, into: StudioGraph(), endpoints: [],
            equipment: appModel.equipment.items, effects: appModel.environments.activeEffects
        )
        appModel.environments.replaceStudio(graph: merged.graph, endpoints: merged.endpoints)
    }

    private static func requireValid(_ draft: StudioPatchDraft) throws {
        guard draft.hasErrors else { return }
        throw FixtureError.invalidPhysicalDraft(
            draft.validation.filter { $0.severity == .error }.map(\.message).joined(separator: "; ")
        )
    }

    private enum FixtureError: Error {
        case requiresUITestingDemo
        case missingEquipment(String)
        case invalidPhysicalDraft(String)
        case unexpectedTransportWrite
    }
}

/// Observation only: this UI-test surface cannot send or apply any WING values.
struct MultiRouteAcceptanceDiagnosticsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Text("Demo fixture · no live WING transport")
            .accessibilityIdentifier("assistant.multiRoute.fixtureMode")
        Text("Transport SET attempts: \(appModel.wing.transportWriteCount)")
            .accessibilityIdentifier("assistant.multiRoute.transportWriteCount")
        let graph = appModel.environments.activeStudioGraph
        Text("Current local graph: \(graph.nodes.count) nodes · \(graph.edges.count) wires")
            .accessibilityIdentifier("assistant.multiRoute.localGraph")
    }
}
#endif
