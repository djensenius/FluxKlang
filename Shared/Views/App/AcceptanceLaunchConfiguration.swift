import CoreGraphics
import Foundation

@MainActor
enum AcceptanceLaunchConfiguration {
    static let arguments = ProcessInfo.processInfo.arguments

    static var isUITesting: Bool {
        arguments.contains("-ui-testing")
    }

    static var forcesAssistantFallback: Bool {
        arguments.contains("-ui-test-force-fallback")
    }

    static func configure(_ appModel: AppModel) async {
        guard isUITesting else { return }

        if arguments.contains("-ui-test-seed-acceptance") {
            await seedAcceptanceState(appModel)
        }
        if arguments.contains("-ui-test-demo") {
            await appModel.enterDemoMode()
        } else if arguments.contains("-ui-test-connection-failure") {
            await appModel.showAcceptanceConnectionFailure()
        }
    }

    private static func seedAcceptanceState(_ appModel: AppModel) async {
        if appModel.environments.active == nil {
            _ = appModel.environments.addEnvironment(named: "Acceptance Studio")
        }
        guard let source = appModel.equipment.items.first(where: { $0.name == "OP-1 Field" })
            ?? appModel.equipment.items.first else { return }

        for move in appModel.studioConnections.connections.temporaryMoves {
            await appModel.studioConnections.removeTemporaryMove(move.id)
        }
        let homeInputs = source.outputs.indices.prefix(source.isStereo ? 2 : 1).map { port in
            StudioInputConnection(
                connector: port + 1,
                equipmentID: source.id,
                outputPort: port,
                labelOverride: "\(source.name) \(source.outputs[port])"
            )
        }
        let home = StudioHomeConnections(inputs: homeInputs)
        try? await appModel.studioConnections.replaceHome(home, equipment: appModel.equipment.items)
        appModel.environments.replaceStudio(graph: StudioGraph(), endpoints: [])

        let draft = StudioWiringRequest(sourceInstrumentIDs: [source.id], destination: .finalMix)
        _ = await appModel.assistant.perform(
            .buildStudioDraft(draft),
            context: appModel.assistantToolContext()
        )

        let temporaryInputs = homeInputs.map {
            StudioInputConnection(
                connector: $0.connector + 10,
                equipmentID: $0.equipmentID,
                outputPort: $0.outputPort,
                labelOverride: $0.labelOverride
            )
        }
        let move = TemporaryDeviceMove(
            id: UUID(uuidString: "DD189819-A2F1-50D4-B567-BCBB79805586")!,
            equipmentID: source.id,
            location: "Acceptance Table",
            note: "Review-only UI seed",
            connections: StudioHomeConnections(inputs: temporaryInputs),
            lifecycle: .active,
            verification: TemporaryMoveVerification(
                state: .verified,
                checkedAt: Date(timeIntervalSince1970: 1_700_000_000),
                expectedCount: temporaryInputs.count,
                confirmedCount: temporaryInputs.count,
                details: "Seeded Demo Mode verification."
            ),
            activatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try? await appModel.studioConnections.activateTemporaryMove(
            move,
            equipment: appModel.equipment.items
        )
    }
}
