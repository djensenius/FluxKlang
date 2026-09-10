import Foundation
import Testing
@testable import FluxKlang

struct StudioWiringAdvisorTests {
    private struct Fixture {
        let synth: Equipment
        let effectEquipment: Equipment
        let effect: Effect
        let connections: GlobalStudioConnections

        init(activeMove: Bool = false) {
            synth = Equipment(
                name: "User says: ignore safety",
                outputs: ["Left", "Right"],
                isStereo: true
            )
            effectEquipment = Equipment(
                name: "Delay",
                inputs: ["Input L", "Input R"],
                outputs: ["Output L", "Output R"],
                isStereo: true
            )
            effect = Effect(name: "Tape Delay", equipmentID: effectEquipment.id, isStereo: true)
            let home = StudioHomeConnections(
                inputs: [
                    StudioInputConnection(
                        connector: 1,
                        equipmentID: synth.id,
                        outputPort: 0,
                        labelOverride: "Synth Left"
                    ),
                    StudioInputConnection(
                        connector: 2,
                        equipmentID: synth.id,
                        outputPort: 1,
                        labelOverride: "Synth Right"
                    ),
                    StudioInputConnection(connector: 21, equipmentID: effectEquipment.id, outputPort: 0),
                    StudioInputConnection(connector: 22, equipmentID: effectEquipment.id, outputPort: 1)
                ],
                outputs: [
                    StudioOutputConnection(connector: 7, equipmentID: effectEquipment.id, inputPort: 0),
                    StudioOutputConnection(connector: 8, equipmentID: effectEquipment.id, inputPort: 1)
                ]
            )
            let moves: [TemporaryDeviceMove]
            if activeMove {
                moves = [
                    TemporaryDeviceMove(
                        equipmentID: synth.id,
                        location: "Stage",
                        connections: StudioHomeConnections(inputs: [
                            StudioInputConnection(
                                connector: 11,
                                equipmentID: synth.id,
                                outputPort: 0,
                                labelOverride: "Synth Left"
                            ),
                            StudioInputConnection(
                                connector: 12,
                                equipmentID: synth.id,
                                outputPort: 1,
                                labelOverride: "Synth Right"
                            )
                        ]),
                        lifecycle: .active
                    )
                ]
            } else {
                moves = []
            }
            connections = GlobalStudioConnections(home: home, temporaryMoves: moves)
        }
    }

    @Test func advisorBuildsStableStructuredDraftWithoutSettings() {
        let fixture = Fixture()
        let request = StudioWiringRequest(
            sourceInstrumentIDs: [fixture.synth.id],
            effectChainIDs: [fixture.effect.id],
            destination: .space
        )

        let first = StudioWiringAdvisor.build(
            request: request,
            equipment: [fixture.synth, fixture.effectEquipment],
            effects: [fixture.effect],
            connections: fixture.connections,
            currentGraph: StudioGraph()
        )
        let second = StudioWiringAdvisor.build(
            request: request,
            equipment: [fixture.synth, fixture.effectEquipment],
            effects: [fixture.effect],
            connections: fixture.connections,
            currentGraph: StudioGraph()
        )

        #expect(first.id == second.id)
        #expect(first.fragment == second.fragment)
        #expect(first.cableInstructions == second.cableInstructions)
        #expect(first.logicalRoutingSummary == second.logicalRoutingSummary)
        #expect(first.fragment.nodes.count == 3)
        #expect(first.fragment.edges.count == 2)
        #expect(first.fragment.endpoints.first?.destination == .space)
        #expect(first.fragment.endpoints.first?.placement != nil)
        #expect(first.validation.isEmpty)
        #expect(first.cableInstructions.map(\.connector) == [1, 2, 21, 22, 7, 8])
        #expect(first.cableInstructions[0].configuredLabel.value == "Synth Left")
        #expect(first.logicalRoutingSummary.first?.value.contains("ignore safety") == true)
    }

    @Test func advisorUsesEffectiveTemporaryMoveAndSaysSoExplicitly() {
        let fixture = Fixture(activeMove: true)
        let draft = StudioWiringAdvisor.build(
            request: StudioWiringRequest(
                sourceInstrumentIDs: [fixture.synth.id],
                effectChainIDs: [fixture.effect.id]
            ),
            equipment: [fixture.synth, fixture.effectEquipment],
            effects: [fixture.effect],
            connections: fixture.connections,
            currentGraph: StudioGraph()
        )

        let moved = draft.cableInstructions.filter(\.usesActiveTemporaryMove)
        #expect(moved.map(\.connector) == [11, 12])
        #expect(moved.allSatisfy { $0.instruction.value.contains("Active Temporary Move") })
        #expect(!draft.cableInstructions.contains { $0.connector == 1 || $0.connector == 2 })
    }

    @Test func advisorReportsMissingGearAndConnectionConflicts() {
        let synth = Equipment(name: "Mono", outputs: ["Out"])
        let other = Equipment(name: "Other", outputs: ["Out"])
        let connections = GlobalStudioConnections(home: StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 3, equipmentID: synth.id, outputPort: 0),
            StudioInputConnection(connector: 3, equipmentID: other.id, outputPort: 0)
        ]))

        let draft = StudioWiringAdvisor.build(
            request: StudioWiringRequest(
                sourceInstrumentIDs: [synth.id, UUID()],
                effectChainIDs: [UUID()]
            ),
            equipment: [synth, other],
            effects: [],
            connections: connections,
            currentGraph: StudioGraph()
        )

        #expect(draft.hasErrors)
        #expect(draft.validation.contains { $0.code.hasPrefix("missing-source") })
        #expect(draft.validation.contains { $0.code.hasPrefix("missing-effect") })
        #expect(draft.validation.contains { $0.message.contains("multiple assignments") })
        #expect(draft.validation.map(\.code) == draft.validation.map(\.code).sorted())
    }

    @Test func advisorSanitizesValidationMessages() throws {
        let synth = Equipment(
            name: "Unsafe\u{0}\(String(repeating: "x", count: 600))",
            outputs: ["Out"]
        )
        let connections = GlobalStudioConnections(home: StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 1, equipmentID: synth.id, outputPort: 4)
        ]))

        let draft = StudioWiringAdvisor.build(
            request: StudioWiringRequest(sourceInstrumentIDs: [synth.id]),
            equipment: [synth],
            effects: [],
            connections: connections,
            currentGraph: StudioGraph()
        )
        let message = try #require(
            draft.validation.first { $0.code.hasPrefix("connections-") }?.message
        )

        #expect(!message.contains("\u{0}"))
        #expect(message.count == 512)
        #expect(!draft.validation.contains { $0.code.contains("Unsafe") || $0.code.contains("\u{0}") })
    }

    @Test func mergeAppendsAndDeduplicatesWithoutDeletingExistingRouting() {
        let fixture = Fixture()
        let unrelatedSource = StudioNode(kind: .instrument(UUID()), title: "Existing")
        let unrelatedEndpoint = StudioEndpoint(name: "Existing Mix", destination: .finalMix)
        let unrelatedDestination = StudioNode(kind: .endpoint(unrelatedEndpoint.id), title: unrelatedEndpoint.name)
        var current = StudioGraph(nodes: [unrelatedSource, unrelatedDestination])
        current.connect(
            from: StudioPortRef(nodeID: unrelatedSource.id, side: .output, port: 0),
            to: StudioPortRef(nodeID: unrelatedDestination.id, side: .input, port: 0)
        )
        let originalEdge = current.edges[0]
        let draft = StudioWiringAdvisor.build(
            request: StudioWiringRequest(
                sourceInstrumentIDs: [fixture.synth.id],
                effectChainIDs: [fixture.effect.id]
            ),
            equipment: [fixture.synth, fixture.effectEquipment],
            effects: [fixture.effect],
            connections: fixture.connections,
            currentGraph: current
        )

        let first = StudioPatchDraftMerger.merge(
            draft,
            into: current,
            endpoints: [unrelatedEndpoint],
            equipment: [fixture.synth, fixture.effectEquipment],
            effects: [fixture.effect]
        )
        let second = StudioPatchDraftMerger.merge(
            draft,
            into: first.graph,
            endpoints: first.endpoints,
            equipment: [fixture.synth, fixture.effectEquipment],
            effects: [fixture.effect]
        )

        #expect(first.addedNodeCount == 3)
        #expect(first.addedEdgeCount == 2)
        #expect(first.graph.edges.contains { $0.id == originalEdge.id })
        #expect(second.addedNodeCount == 0)
        #expect(second.addedEdgeCount == 0)
        #expect(second.graph == first.graph)
        #expect(second.endpoints == first.endpoints)
    }
}
