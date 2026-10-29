import Foundation
import Testing
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import FluxKlang

@MainActor
@Suite(.serialized)
struct AssistantSourceResolutionRegressionTests {
    @Test(arguments: ["Help me route Synth through Echo to speakers.", "How do I connect Synth to speakers?",
                      "Help me to route Synth to speakers.", "How to connect Synth to speakers?"])
    func savedSourcesRemainInspectableButQuestionsCannotCreateDrafts(_ question: String) async throws {
        let synth = Equipment(name: "Synth")
        var context = AssistantBackendFixture.context(equipment: [synth], inputs: [
            .init(connector: 7, equipmentID: synth.id, outputPort: 0)
        ])
        context.effects = [Effect(name: "Echo")]
        #expect(AssistantSourceResolver.resolve(question, context: context).equipmentIDs == [synth.id])
        let request = AssistantGenerationRequest(question: question, recentMessages: [], summary: "", context: context)
        #expect(AssistantDraftIntent.wiringRequest(from: request)?.sourceInstrumentIDs == [synth.id])
        let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
        let provider = AssistantBackendGenerator()
        let generator = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: provider)
        for try await _ in generator.stream(request) {}
        #expect(coordinator.pendingStudioDraft == nil)
        #expect(provider.calls == 1)
    }

    @Test func coordinatedSourceClausesReachPreflightWithoutDroppingTheSecondSource() async throws {
        let synth = Equipment(name: "Synth")
        let bass = Equipment(name: "Bass")
        let context = AssistantBackendFixture.context(equipment: [synth, bass])
        let question = "Route Synth to speakers and Bass to speakers."
        #expect(AssistantSourceResolver.resolve(question, context: context).equipmentIDs == [synth.id, bass.id])
        let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
        let provider = AssistantBackendGenerator()
        let generator = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: provider)
        for try await _ in generator.stream(
            .init(question: question, recentMessages: [], summary: "", context: context)) {}
        #expect(coordinator.pendingStudioDraft == nil)
        #expect(provider.calls == 0)
    }

    @Test(arguments: ["don't use Bass", "don’t use Bass", "without Bass"])
    func fullQuestionExclusionsSurvivePositiveSourceScoping(_ exclusion: String) async throws {
        let synth = Equipment(name: "Synth")
        let bass = Equipment(name: "Bass")
        var context = AssistantBackendFixture.context(equipment: [synth, bass])
        context.effects = [Effect(name: "Echo")]
        let question = "Route Synth and Bass through Echo to speakers, \(exclusion)."
        let resolution = AssistantSourceResolver.resolve(question, context: context)
        #expect(resolution.equipmentIDs == [synth.id])
        let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
        let provider = AssistantBackendGenerator()
        let generator = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: provider)
        for try await _ in generator.stream(
            .init(question: question, recentMessages: [], summary: "", context: context)) {}
        #expect(coordinator.pendingStudioDraft == nil)
        #expect(provider.calls == 0)
    }

    @Test(arguments: ["channel 7 and channel 8", "channel7 and channel8",
                      "LOCAL input 7 and LOCAL input 8", "LOCALinput7 and LOCALinput8",
                      "channel7 and channel999999999999999999999999",
                      "LOCALinput7 and LOCALinput999999999999999999999999"])
    func explicitIdentitiesNeverPublishOnlyTheObservedSubset(_ identities: String) async throws {
        let synth = Equipment(name: "Synth")
        let bass = Equipment(name: "Bass")
        for scenario in 0...4 {
            var values: [String: WingValue] = [
                WingAddress.name(.channel, 7): .string("Lead"),
                WingAddress.channelSourceGroup(7): .string("LCL"),
                WingAddress.channelSourceIndex(7): .int(7),
                WingAddress.inputName(7): .string("Lead"),
                WingAddress.name(.channel, 8): .string(scenario == 0 ? "" : "Pad"),
                WingAddress.channelSourceGroup(8): .string(scenario == 2 ? "USB" : "LCL"),
                WingAddress.channelSourceIndex(8): .int(8),
                WingAddress.inputName(8): .string(scenario == 0 ? "" : "Pad")
            ]
            if scenario == 1 {
                values[WingAddress.name(.channel, 8)] = nil
                values[WingAddress.inputName(8)] = nil
            }
            var inputs = [StudioInputConnection(connector: 7, equipmentID: synth.id, outputPort: 0)]
            if scenario != 2 { inputs.append(.init(connector: 8, equipmentID: bass.id, outputPort: 0)) }
            let context = AssistantBackendFixture.observe(values,
                context: AssistantBackendFixture.context(equipment: [synth, bass], inputs: inputs),
                age: scenario == 3 ? 31 : 0, status: scenario == 4 ? .disconnected : .observed)
            let question = "route \(identities) to speakers"
            let resolution = AssistantSourceResolver.resolve(question, context: context)
            #expect(resolution.equipmentIDs.isEmpty)
            #expect(resolution.references.isEmpty)
            #expect(resolution.clarification != nil)
            let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
            let provider = AssistantBackendGenerator()
            let generator = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: provider)
            for try await _ in generator.stream(
                .init(question: question, recentMessages: [], summary: "", context: context)) {}
            #expect(coordinator.pendingStudioDraft == nil)
            #expect(provider.calls == 0)
        }
    }

    @Test(arguments: ["channel", "LOCAL input"])
    func usableExplicitIdentitiesIncludeAllSourcesUnlessExplicitlyExcluded(_ kind: String) async throws {
        let synth = Equipment(name: "Synth")
        let bass = Equipment(name: "Bass")
        let context = AssistantBackendFixture.observe([
            WingAddress.name(.channel, 7): .string("Lead"),
            WingAddress.channelSourceGroup(7): .string("LCL"),
            WingAddress.channelSourceIndex(7): .int(7),
            WingAddress.inputName(7): .string("Lead"),
            WingAddress.name(.channel, 8): .string("Pad"),
            WingAddress.channelSourceGroup(8): .string("LCL"),
            WingAddress.channelSourceIndex(8): .int(8),
            WingAddress.inputName(8): .string("Pad")
        ], context: AssistantBackendFixture.context(equipment: [synth, bass], inputs: [
            .init(connector: 7, equipmentID: synth.id, outputPort: 0),
            .init(connector: 8, equipmentID: bass.id, outputPort: 0)
        ]))
        for excluded in [false, true] {
            let question = "route \(kind) 7 and \(kind) 8 to speakers"
                + (excluded ? ", don't use \(kind) 8" : "")
            let resolution = AssistantSourceResolver.resolve(question, context: context)
            #expect(resolution.equipmentIDs == (excluded ? [synth.id] : [synth.id, bass.id]))
            #expect(resolution.references.count == (excluded ? 1 : 2))
            let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
            let provider = AssistantBackendGenerator()
            let generator = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: provider)
            for try await _ in generator.stream(
                .init(question: question, recentMessages: [], summary: "", context: context)) {}
            #expect(coordinator.pendingStudioDraft == nil)
            #expect(provider.calls == 0)
        }
    }

    @Test func explicitDraftToolResolutionCanUseLiveAliasWithoutBroadInformationalClarification() {
        let synth = Equipment(name: "Synth")
        let context = AssistantBackendFixture.observe([WingAddress.inputName(7): .string("Lead")],
            context: AssistantBackendFixture.context(equipment: [synth], inputs: [
                .init(connector: 7, equipmentID: synth.id, outputPort: 0)
            ]))
        let question = "What EQ is on Lead?"
        let informational = AssistantSourceResolver.resolve(question, context: context)
        #expect(informational.equipmentIDs.isEmpty)
        #expect(informational.clarification == nil)
        let tool = AssistantSourceResolver.resolve(question, context: context, requiresSourceIntent: false)
        #expect(tool.equipmentIDs == [synth.id])
        #expect(tool.references.count == 1)
    }

    #if canImport(FoundationModels)
    @Test(arguments: ["Help me route Synth to speakers.", "How do I connect Synth to speakers?",
                      "Help me route Lead to speakers.", "What EQ is on Lead?"])
    func retiredFoundationDraftToolCannotMutateFromSavedOrLiveMentions(_ question: String) async throws {
        let synth = Equipment(name: "Synth")
        let context = AssistantBackendFixture.observe([WingAddress.inputName(7): .string("Lead")],
            context: AssistantBackendFixture.context(equipment: [synth], inputs: [
                .init(connector: 7, equipmentID: synth.id, outputPort: 0)
            ]))
        let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
        let tool = AssistantDraftFoundationTool(question: question, context: context,
                                               coordinator: coordinator, authorizer: .model)
        _ = try await tool.call(arguments: AssistantDraftArguments(sourceNames: ["Synth"],
            effectNames: [], destination: "Final Mix"))
        #expect(coordinator.pendingStudioDraft == nil)
    }
    #endif

    @Test func helpPhrasingDoesNotBypassTrueSavedLiveAmbiguity() {
        let synth = Equipment(name: "Synth")
        let context = AssistantBackendFixture.observe([
            WingAddress.name(.channel, 8): .string("Synth"),
            WingAddress.channelSourceGroup(8): .string("USB"),
            WingAddress.channelSourceIndex(8): .int(3)
        ], context: AssistantBackendFixture.context(equipment: [synth]))
        for question in ["Help me route Synth to speakers.", "How do I connect Synth to speakers?"] {
            #expect(AssistantSourceResolver.resolve(question, context: context).clarification != nil)
            #expect(AssistantDraftIntent.wiringRequest(from: .init(question: question,
                recentMessages: [], summary: "", context: context)) == nil)
        }
    }

    @Test(arguments: ["route Synth and LOCAL input 9 to speakers", "route Lead and channel 8 to speakers"])
    func mixedNamedAndExplicitSourcesClarifyWithoutCreatingPartialDraft(_ question: String) async throws {
        let synth = Equipment(name: "Synth")
        let other = Equipment(name: "Other")
        let context = AssistantBackendFixture.observe([
            WingAddress.inputName(7): .string("Lead"),
            WingAddress.inputName(9): .string("Other"),
            WingAddress.name(.channel, 8): .string("Other"),
            WingAddress.channelSourceGroup(8): .string("LCL"),
            WingAddress.channelSourceIndex(8): .int(9)
        ], context: AssistantBackendFixture.context(equipment: [synth, other], inputs: [
            .init(connector: 7, equipmentID: synth.id, outputPort: 0),
            .init(connector: 9, equipmentID: other.id, outputPort: 0)
        ]))
        let resolution = AssistantSourceResolver.resolve(question, context: context)
        #expect(resolution.clarification?.contains("mixed named sources") == true)
        #expect(resolution.equipmentIDs.isEmpty)
        let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
        let provider = AssistantBackendGenerator()
        let generator = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: provider)
        for try await _ in generator.stream(
            .init(question: question, recentMessages: [], summary: "", context: context)) {}
        #expect(coordinator.pendingStudioDraft == nil)
        #expect(provider.calls == 0)
        #expect(AssistantSourceResolver.resolve("route Synth without LOCAL input 9 to speakers",
            context: context).equipmentIDs == [synth.id])
        #expect(AssistantSourceResolver.resolve("route LOCAL input 7 and LOCAL input 9 to speakers",
            context: context).equipmentIDs == [synth.id, other.id])
    }

    @Test(arguments: [false, true])
    func preflightCannotResolveLiveAliasesWithoutApplePreparation(retry: Bool) async throws {
        let synth = Equipment(name: "Synth")
        let context = AssistantBackendFixture.observe([WingAddress.inputName(7): .string("Lead")],
            context: AssistantBackendFixture.context(equipment: [synth], inputs: [
                .init(connector: 7, equipmentID: synth.id, outputPort: 0)
            ]))
        let route = "Route Lead to speakers."
        let request = AssistantGenerationRequest(question: retry ? "It is connected now, try again." : route,
            recentMessages: retry ? [.init(role: .user, text: route)] : [], summary: "", context: context)
        let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
        let provider = AssistantBackendGenerator()
        let generator = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: provider)
        for try await _ in generator.stream(request) {}
        #expect(coordinator.pendingStudioDraft == nil)
        #expect(provider.calls == 0)
    }

    @Test(arguments: [false, true])
    func preflightRejectsConflictingLiveAliasInCurrentOrHistoricalRoute(retry: Bool) async throws {
        let synth = Equipment(name: "Synth")
        let context = AssistantBackendFixture.observe([
            WingAddress.name(.channel, 8): .string("Synth"),
            WingAddress.channelSourceGroup(8): .string("USB"),
            WingAddress.channelSourceIndex(8): .int(3)
        ], context: AssistantBackendFixture.context(equipment: [synth]))
        let route = "Route Synth to speakers."
        let request = AssistantGenerationRequest(question: retry ? "It is connected now, try again." : route,
            recentMessages: retry ? [.init(role: .user, text: route)] : [], summary: "", context: context)
        let coordinator = AssistantCoordinator(draftStore: AssistantBackendDraftStore())
        let provider = AssistantBackendGenerator()
        let generator = AssistantDraftPreflightGenerator(coordinator: coordinator, downstream: provider)
        for try await _ in generator.stream(request) {}
        #expect(coordinator.pendingStudioDraft == nil)
        #expect(provider.calls == 0)
    }

    @Test func metadataPollingDuringListenVerificationCannotEraseConfirmationsOrRetryPatchWrites() async throws {
        let transport = AssistantRecordingWingTransport()
        let wing = WingController(transport: transport)
        await wing.connect(host: "192.0.2.10")
        let group = WingAddress.channelSourceGroup(40)
        let index = WingAddress.channelSourceIndex(40)
        let settings = WingSource(group: .local, index: 19).settings(forChannel: 40)
        await transport.pauseVerificationQuery(group)
        let apply = Task { await wing.applyAndVerify(settings) }
        try await AssistantBackendFixture.waitAsync { await transport.queryWaiting }
        await transport.releaseQueries()
        try await AssistantBackendFixture.wait {
            wing.confirmedValues[group] == .string("LCL") && wing.confirmedValues[index] == .int(19)
        }
        // Metadata GETs now receive no replies. They must retain the successful
        // verification replies instead of clearing them and provoking a retry.
        await transport.configure(answers: false)
        let before = await transport.queries.filter { $0 == group }.count
        wing.liveObservations.start(controller: wing, interval: .milliseconds(10))
        try await AssistantBackendFixture.waitAsync {
            await transport.queries.filter { $0 == group }.count > before
        }
        #expect(wing.confirmedValues[group] == .string("LCL"))
        #expect(wing.confirmedValues[index] == .int(19))
        let verification = await apply.value
        #expect(verification.state == .verified)
        #expect(wing.transportWriteCount == settings.count)
        #expect(await transport.writes == settings)
        await wing.disconnect()
    }
}
