import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct AssistantRoutingNameEvidenceTests {
    @Test(arguments: [false, true], [false, true])
    func savedNamesWithoutInitialLiveMatchesAreRechecked(excluded: Bool, atCommit: Bool) async throws {
        let fixture = AssistantRoutingFixture()
        let session = UUID()
        let context = AssistantBackendFixture.observe([:], context: fixture.context, session: session)
        let text = "route Osmose to mains" + (excluded ? " without Solar" : "")
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Osmose", destination: "mains", destinationEvidence: "Osmose to mains")
        ], excludedMentions: excluded ? ["Solar"] : [], exclusionEvidence: excluded ? ["without Solar"] : [])
        let prepared = try fixture.prepared(text: text, intent: intent, context: context)
        let draft = try JSONDecoder().decode(StudioPatchDraft.self, from: JSONEncoder().encode(prepared))
        #expect(draft.liveReferences?.isEmpty == true)
        let changed = AssistantBackendFixture.observe([
            WingAddress.inputName(excluded ? 1 : 3): .string(excluded ? "Solar" : "Osmose")
        ], context: context, session: session)
        let coordinator = AssistantCoordinator(draftStore: RoutingTestDraftStore())
        if atCommit {
            #expect(!(await coordinator.commitPreparedRouting(draft, expectedPending: nil,
                preparedContext: context, currentContext: changed)))
            #expect(coordinator.pendingStudioDraft == nil)
        } else {
            #expect(await coordinator.commitPreparedRouting(draft, expectedPending: nil,
                preparedContext: context, currentContext: context))
            let result = await coordinator.perform(.validatePendingStudioDraft, context: changed)
            guard case .pendingDraft(let refreshed?) = result else {
                Issue.record("Expected a revalidated draft")
                return
            }
            #expect(refreshed.hasErrors)
        }
    }

    @Test(arguments: [false, true])
    func configuredOrLiveOperatorNamesCannotDisappearFromSourceCoverage(live: Bool) {
        let fixture = AssistantRoutingFixture()
        let dry = Equipment(name: live ? "First Synth" : "Dry")
        let wet = Equipment(name: live ? "Second Synth" : "Wet")
        var context = fixture.context
        context.equipment += [dry, wet]
        context.globalConnections.home.inputs += [
            .init(connector: 9, equipmentID: dry.id, outputPort: 0),
            .init(connector: 10, equipmentID: wet.id, outputPort: 0)
        ]
        context.effectiveConnections = context.globalConnections.effectiveHome
        if live {
            context = AssistantBackendFixture.observe([
                WingAddress.inputName(9): .string("Dry"), WingAddress.inputName(10): .string("Wet")
            ], context: context)
        }
        let text = "route Solar and Dry and Wet through evil pet to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains", destinationEvidence: text,
                  processingEvidence: "Solar and Dry and Wet through evil pet", includesDrySignal: true,
                  dryEvidence: "Solar and Dry and Wet through evil pet")
        ])
        #expect(fixture.rejects(text: text, intent: intent, context: context))
    }

    @Test func destinationTraversalCannotMoveAfterTheRequestedEffect() {
        let text = "route Solar through mains then into evil pet"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains",
                  destinationEvidence: "Solar through mains",
                  processingEvidence: "Solar through mains then into evil pet")
        ])
        #expect(AssistantRoutingFixture().rejects(text: text, intent: intent))
    }
}
