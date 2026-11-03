import Foundation
import Testing
@testable import FluxKlang

@MainActor
struct AssistantRoutingChatTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLUXKLANG_QUALIFY_APPLE_ROUTING"] == "1"))
    func optInNativeOwnerAndPriorMonoQualification() async throws {
        let interpreter = FoundationModelActionInterpreter.forLiveTesting(.routing)
        #expect(await interpreter.availability() == .available)
        let routing = try await interpreter.interpret(.init(text: AssistantRoutingFixture.text))
        #expect(routing == .routing(AssistantRoutingFixture.intent))
        print("Native owner interpretation: \(routing)")
        if case .routing(let intent) = routing {
            let fixture = AssistantRoutingFixture()
            let draft = try fixture.prepared(intent: intent)
            let refreshed = StudioWiringAdvisor.revalidate(draft, equipment: fixture.equipment,
                effects: [fixture.effect], connections: fixture.connections,
                currentGraph: StudioGraph(), currentEnvironmentID: nil)
            let merged = StudioPatchDraftMerger.merge(refreshed, into: StudioGraph(), endpoints: [],
                equipment: fixture.equipment, effects: [fixture.effect])
            fixture.checkPaths(graph: merged.graph, endpoints: merged.endpoints)
        }
        for text in ["turn down the volume of my Astrolab", "add my mother-32 and turn the volume to 50%"] {
            let result = try await interpreter.interpret(.init(text: text))
            print("Native mono interpretation: \(text): \(result)")
            guard case .proposal(let proposal) = result else {
                Issue.record("Expected mono proposal: \(result)")
                continue
            }
            if text.contains("mother") {
                #expect(proposal.targetMention == "mother-32")
                #expect(proposal.action == .setFaderPercent)
                #expect(proposal.amount == 50)
                #expect(proposal.addToStudio)
            } else {
                #expect(proposal.targetMention == "Astrolab")
                #expect(proposal.action == .lower)
                #expect(proposal.amount == nil)
            }
        }
    }
}
