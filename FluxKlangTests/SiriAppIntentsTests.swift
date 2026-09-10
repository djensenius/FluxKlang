import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct SiriAppIntentsTests {
    @Test func entityQueriesResolveStableIdentifiersAndFuzzySpeech() {
        let synth = Equipment(
            id: UUID(uuidString: "C024A205-2CB4-4D3C-A66A-A6AB87218D32")!,
            name: "Arturia MicroFreak"
        )
        let other = Equipment(name: "SOMA Cosmos")

        #expect(EquipmentEntityQuery.entities(for: [synth.id], in: [other, synth]).map(\.id) == [synth.id])
        #expect(EquipmentEntityQuery.entities(matching: "micro freak", in: [other, synth]).map(\.id) == [synth.id])
        let typoMatches = EquipmentEntityQuery.entities(
            matching: "Arturia MicroFrek",
            in: [other, synth]
        )
        #expect(typoMatches.map(\.id) == [synth.id])
        #expect(DestinationEntityQuery.entities(matching: "mix").map(\.destination) == [.finalMix])
        #expect(Equipment.seededLibrary.map(\.id) == Equipment.seededLibrary.map(\.id))
    }

    @Test func effectAndEnvironmentQueriesUseStoreIdentifiers() {
        let effect = Effect(name: "Hologram Microcosm")
        let environment = RoutingEnvironment(name: "Ambient Set", effects: [effect])

        #expect(EffectEntityQuery.entities(for: [effect.id], in: environment.effects).map(\.id) == [effect.id])
        #expect(EffectEntityQuery.entities(matching: "micro cosm", in: environment.effects).map(\.id) == [effect.id])
        #expect(
            EnvironmentEntityQuery.entities(matching: "ambent set", in: [environment]).map(\.id)
                == [environment.id]
        )
    }

    @Test func draftIntentPreservesEffectOrderPersistsAndOpensReviewWithoutWrites() async throws {
        let store = MemorySiriDraftStore()
        let coordinator = AssistantCoordinator(draftStore: store)
        let model = AppModel(assistant: coordinator, wing: .preview())
        let source = model.equipment.items[0]
        _ = model.environments.addEnvironment(named: "Siri Test")
        let first = Effect(name: "Delay")
        let second = Effect(name: "Reverb")
        model.environments.add(first)
        model.environments.add(second)
        try await model.studioConnections.replaceHome(
            StudioHomeConnections(inputs: [
                StudioInputConnection(connector: 1, equipmentID: source.id, outputPort: 0),
                StudioInputConnection(connector: 2, equipmentID: source.id, outputPort: 1)
            ]),
            equipment: model.equipment.items
        )
        let before = model.wing.values
        let writesBefore = model.wing.transportWriteCount

        let spoken = await SiriDraftStudioAction.execute(
            sourceGear: [EquipmentEntity(id: source.id, name: source.name)],
            effects: [
                EffectEntity(id: second.id, name: second.name),
                EffectEntity(id: first.id, name: first.name)
            ],
            destination: .space,
            model: model
        )

        let draft = try #require(coordinator.pendingStudioDraft)
        #expect(draft.request.sourceInstrumentIDs == [source.id])
        #expect(draft.request.effectChainIDs == [second.id, first.id])
        #expect(draft.request.destination == .space)
        #expect(await store.load()?.id == draft.id)
        #expect(spoken.contains("Drafted \(source.name)"))
        #expect(spoken.contains("Review"))
        #expect(model.section == .studio)
        #expect(coordinator.navigationTarget == .reviewPendingDraft)
        #expect(model.wing.values == before)
        #expect(model.wing.transportWriteCount == writesBefore)
    }

    @Test func draftIntentDropsMissingAndDuplicateParametersWithoutApplyingRouting() async throws {
        let coordinator = AssistantCoordinator(draftStore: MemorySiriDraftStore())
        let model = AppModel(assistant: coordinator, wing: .preview())
        let source = model.equipment.items[0]
        _ = model.environments.addEnvironment(named: "Siri Mapping")
        let effect = Effect(name: "Delay")
        model.environments.add(effect)
        let unknownID = UUID()
        let beforeGraph = model.environments.activeStudioGraph
        let beforeValues = model.wing.values
        let writesBefore = model.wing.transportWriteCount

        _ = await SiriDraftStudioAction.execute(
            sourceGear: [
                EquipmentEntity(id: source.id, name: source.name),
                EquipmentEntity(id: source.id, name: source.name),
                EquipmentEntity(id: unknownID, name: "Missing")
            ],
            effects: [
                EffectEntity(id: effect.id, name: effect.name),
                EffectEntity(id: effect.id, name: effect.name),
                EffectEntity(id: unknownID, name: "Missing")
            ],
            destination: .finalMix,
            model: model
        )

        let draft = try #require(coordinator.pendingStudioDraft)
        #expect(draft.request.sourceInstrumentIDs == [source.id])
        #expect(draft.request.effectChainIDs == [effect.id])
        #expect(model.environments.activeStudioGraph == beforeGraph)
        #expect(model.wing.values == beforeValues)
        #expect(model.wing.transportWriteCount == writesBefore)
    }

    @Test func spokenOutputReportsValidationAndBaselineQueriesRemainAvailable() {
        let draft = StudioPatchDraft(
            id: UUID(),
            createdAt: Date(),
            request: .init(
                environmentID: nil,
                sourceInstrumentIDs: [],
                effectChainIDs: [],
                destination: .finalMix
            ),
            fragment: StudioGraphFragment(nodes: [], edges: [], endpoints: []),
            cableInstructions: [],
            logicalRoutingSummary: [AssistantUntrustedText("Missing source → Mix")],
            validation: [
                StudioDraftValidationIssue(code: "missing", severity: .error, message: "Missing source")
            ]
        )

        #expect(SiriDraftStudioAction.spokenSummary(for: draft).contains("Review 1 issue"))
        #expect(DestinationEntityQuery.entities(for: [DestinationEntity.space.id]) == [.space])
    }
}

private actor MemorySiriDraftStore: PendingStudioPatchPersisting {
    private var draft: StudioPatchDraft?

    func load() -> StudioPatchDraft? { draft }
    func save(_ draft: StudioPatchDraft?) { self.draft = draft }
}
