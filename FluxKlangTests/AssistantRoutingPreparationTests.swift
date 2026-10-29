import Foundation
import Testing
@testable import FluxKlang

struct AssistantRoutingFixture {
    static let text = "I want to use Osmose and Solar on mains, with Solar going through evil pet, "
        + "and I'd like my OP-XY going out the desktop speakers"
    static let intent = AssistantRoutingIntent(branches: [
        .init(source: "Osmose", destination: "mains", destinationEvidence: "Osmose and Solar on mains"),
        .init(source: "Solar", effects: ["evil pet"], destination: "mains",
              destinationEvidence: "Osmose and Solar on mains", processingEvidence: "Solar going through evil pet"),
        .init(source: "OP-XY", destination: "desktop speakers",
              destinationEvidence: "OP-XY going out the desktop speakers")
    ])
    let osmose: Equipment
    let solar: Equipment
    let opxy: Equipment
    let evil: Equipment
    var equipment: [Equipment] { [osmose, solar, opxy, evil] }
    var effect: Effect { Effect(id: evil.id, name: "Evil Pet", equipmentID: evil.id) }
    let connections: GlobalStudioConnections
    init() {
        let library = Equipment.seededLibrary
        osmose = library.first { $0.name.contains("Osmose") }
            ?? Equipment(name: "Expressive E Osmose", outputs: ["L", "R"], isStereo: true)
        solar = library.first { $0.name.localizedCaseInsensitiveContains("solar") }
            ?? Equipment(name: "Elta Solar 42F", outputs: ["L", "R"], isStereo: true)
        opxy = library.first { $0.name == "OP-XY" }
            ?? Equipment(name: "OP-XY", outputs: ["L", "R"], isStereo: true)
        evil = library.first { $0.name.localizedCaseInsensitiveContains("evil pet") }
            ?? Equipment(name: "Endorphin.es Evil Pet", inputs: ["L", "R"], outputs: ["L", "R"], isStereo: true)
        let devices = [osmose, solar, opxy, evil]
        connections = GlobalStudioConnections(home: .init(inputs: devices.enumerated().flatMap { index, device in
            device.outputs.indices.map { .init(connector: index * 2 + $0 + 1, equipmentID: device.id, outputPort: $0) }
        }, outputs: [
            .init(connector: 3, equipmentID: evil.id, inputPort: 0),
            .init(connector: 4, equipmentID: evil.id, inputPort: 1),
            .init(connector: 5, destinationName: "Desk Speakers L"),
            .init(connector: 6, destinationName: "Desk Speakers R"),
            .init(connector: 7, destinationName: "Main Speakers L"),
            .init(connector: 8, destinationName: "Main Speakers R")
        ]))
    }
    var context: AssistantToolContext {
        AssistantToolContext(currentScreen: .assistant,
            connection: .init(status: .disconnected, detail: nil, isDemo: false), equipment: equipment,
            homeConnections: connections.home, effectiveConnections: connections.effectiveHome, activeMoves: [],
            environments: [], activeEnvironmentID: nil, presets: [], resources: [], validationIssues: [],
            graph: StudioGraph(), endpoints: [], effects: [effect], globalConnections: connections)
    }
    func prepared(text: String = Self.text, intent: AssistantRoutingIntent = Self.intent,
                  context: AssistantToolContext? = nil) throws -> StudioPatchDraft {
        let result = AssistantRoutingPreparation.prepare(text: text, intent: intent, context: context ?? self.context)
        guard case .prepared(let draft) = result else { throw RoutingTestError.notPrepared }
        return draft
    }
    func rejects(text: String = Self.text, intent: AssistantRoutingIntent = Self.intent,
                 context: AssistantToolContext? = nil) -> Bool {
        if case .clarification = AssistantRoutingPreparation.prepare(
            text: text, intent: intent, context: context ?? self.context) { return true }
        return false
    }
    func checkPaths(graph: StudioGraph, endpoints: [StudioEndpoint]) {
        func node(_ kind: StudioNodeKind) -> UUID? { graph.nodes.first { $0.kind == kind }?.id }
        func destinations(_ source: StudioNodeKind) -> Set<StudioNodeKind> {
            Set(graph.edges.filter { $0.from.nodeID == node(source) }.compactMap { edge in
                graph.nodes.first { $0.id == edge.to.nodeID }?.kind
            })
        }
        let main = endpoints.first { $0.destination == .finalMix }
        let desk = endpoints.first { $0.destination == .custom }
        #expect(endpoints.count == 2)
        #expect(destinations(.instrument(osmose.id)) == Set(main.map { [.endpoint($0.id)] } ?? []))
        #expect(destinations(.instrument(solar.id)) == [.effect(effect.id)])
        #expect(destinations(.effect(effect.id)) == Set(main.map { [.endpoint($0.id)] } ?? []))
        #expect(destinations(.instrument(opxy.id)) == Set(desk.map { [.endpoint($0.id)] } ?? []))
        #expect(desk?.outputConnectors == [.init(index: 5), .init(index: 6)])
        #expect(graph.edges.count == 4)
    }
}

enum RoutingTestError: Error { case notPrepared, model }

struct AssistantRoutingPreparationTests {
    @Test func ownerRequestBuildRevalidateAndMergeRetainsExactlyThreePaths() throws {
        let fixture = AssistantRoutingFixture()
        let draft = try fixture.prepared()
        #expect(!draft.hasErrors)
        #expect(draft.request.additionalRoutes.count == 2)
        #expect(draft.applicationMode == .append)
        #expect(!draft.request.additionalRoutes[0].includesDrySignal)
        #expect(draft.cableInstructions.contains { $0.instruction.value.contains("LCL 5 feeds Desk Speakers L") })
        let refreshed = StudioWiringAdvisor.revalidate(draft, equipment: fixture.equipment,
            effects: [fixture.effect], connections: fixture.connections,
            currentGraph: StudioGraph(), currentEnvironmentID: nil)
        #expect(refreshed.id == draft.id)
        #expect(refreshed.createdAt == draft.createdAt)
        #expect(refreshed.liveReferences == draft.liveReferences)
        #expect(refreshed.outputReferences == draft.outputReferences)
        #expect(!refreshed.hasErrors)
        let merged = StudioPatchDraftMerger.merge(refreshed, into: StudioGraph(), endpoints: [],
                                                 equipment: fixture.equipment, effects: [fixture.effect])
        fixture.checkPaths(graph: merged.graph, endpoints: merged.endpoints)
        let restored = try JSONDecoder().decode(StudioPatchDraft.self, from: JSONEncoder().encode(draft))
        #expect(restored == draft)
    }

    @Test func reorderedClausesAndCapitalizationKeepSourceSpecificProcessing() throws {
        let fixture = AssistantRoutingFixture()
        let text = "OP-XY going out the Desktop Speakers, with Solar going through Evil Pet, "
            + "use Solar and Osmose on mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "OP-XY", destination: "Desktop Speakers",
                  destinationEvidence: "OP-XY going out the Desktop Speakers"),
            .init(source: "Solar", effects: ["Evil Pet"], destination: "mains",
                  destinationEvidence: "Solar and Osmose on mains", processingEvidence: "Solar going through Evil Pet"),
            .init(source: "Osmose", destination: "mains", destinationEvidence: "Solar and Osmose on mains")
        ])
        let draft = try fixture.prepared(text: text, intent: intent)
        fixture.checkPaths(
            graph: StudioGraph(nodes: draft.fragment.nodes.map(\.node), edges: draft.fragment.edges.map(\.edge)),
            endpoints: draft.fragment.endpoints)
    }

    @Test func unknownPartialDuplicateWrongScopeAndMixedMixerPlansFailAtomically() {
        let fixture = AssistantRoutingFixture()
        var intents: [AssistantRoutingIntent] = []
        var partial = AssistantRoutingFixture.intent
        partial.branches.removeLast()
        intents.append(partial)
        var unknown = AssistantRoutingFixture.intent
        unknown.branches[2].source = "Unknown"
        intents.append(unknown)
        var duplicate = AssistantRoutingFixture.intent
        duplicate.branches.append(duplicate.branches[0])
        intents.append(duplicate)
        var wrong = AssistantRoutingFixture.intent
        wrong.branches[0].effects = ["evil pet"]
        wrong.branches[0].processingEvidence = AssistantRoutingFixture.text
        intents.append(wrong)
        for intent in intents { #expect(fixture.rejects(intent: intent)) }
        #expect(fixture.rejects(text: AssistantRoutingFixture.text + " and Unknown on mains"))
        #expect(fixture.rejects(text: AssistantRoutingFixture.text + " and set Astrolab volume to 50%"))
        #expect(fixture.rejects(text: AssistantRoutingFixture.text + " and set Osmose volume to 50%"))
        #expect(fixture.rejects(text: AssistantRoutingFixture.text + " and put it through that"))
        let unknownEffect = "Solar through Unlisted to mains"
        #expect(fixture.rejects(text: unknownEffect, intent: .init(branches: [
            .init(source: "Solar", effects: ["Unlisted"], destination: "mains",
                  destinationEvidence: unknownEffect, processingEvidence: "Solar through Unlisted")
        ])))
    }

    @Test func destinationsResolveActualGroupsAndNeverFallBackToMainsForModifiedSpeakers() throws {
        let fixture = AssistantRoutingFixture()
        for alias in ["desk speakers", "desktop speakers", "DESK SPEAKERS"] {
            let result = try #require(AssistantRoutingOutputResolver.resolve(alias, in: fixture.connections.home))
            #expect(result.destination == .custom)
            #expect(result.reference.connectors == [.init(index: 5), .init(index: 6)])
        }
        for name in ["unknown speakers", "studio monitors", "basement desktop speakers"] {
            #expect(AssistantRoutingOutputResolver.resolve(name, in: fixture.connections.home) == nil)
        }
        var home = fixture.connections.home
        home.outputs.append(contentsOf: [
            .init(bank: .aes50A, connector: 1, destinationName: "Desktop Speakers L"),
            .init(bank: .aes50A, connector: 2, destinationName: "Desktop Speakers R")
        ])
        #expect(AssistantRoutingOutputResolver.resolve("desktop speakers", in: home) == nil)
        let reference = try #require(AssistantRoutingOutputResolver.resolve(
            "desktop speakers", in: fixture.connections.home)?.reference)
        #expect(!reference.isValid(in: home))
        home = fixture.connections.home
        home.outputs.removeAll { $0.connector == 6 }
        #expect(AssistantRoutingOutputResolver.resolve("desktop speakers", in: home) == nil)
    }

    @Test func missingEachPhysicalSourceEffectSendReturnAndOutputLegRejectsWholeRequest() {
        let fixture = AssistantRoutingFixture()
        for removedInput in 1...8 {
            var context = fixture.context
            context.globalConnections.home.inputs.removeAll { $0.connector == removedInput }
            context.effectiveConnections = context.globalConnections.effectiveHome
            #expect(fixture.rejects(context: context))
        }
        for removedOutput in 3...8 {
            var context = fixture.context
            context.globalConnections.home.outputs.removeAll { $0.connector == removedOutput }
            context.effectiveConnections = context.globalConnections.effectiveHome
            #expect(fixture.rejects(context: context))
        }
        var context = fixture.context
        context.equipment.append(Equipment(name: "Osmose"))
        #expect(fixture.rejects(context: context))
        context = fixture.context
        context.effects.append(Effect(name: "Evil Pet", equipmentID: fixture.evil.id))
        #expect(fixture.rejects(context: context))
        context = fixture.context
        context.effects[0].equipmentID = nil
        #expect(fixture.rejects(context: context))
        context = fixture.context
        context.effects.append(Effect(name: "Pet Alias", equipmentID: fixture.evil.id))
        var sharedDevice = AssistantRoutingFixture.intent
        sharedDevice.branches[0].effects = ["Pet Alias"]
        sharedDevice.branches[0].processingEvidence = "Osmose through Pet Alias"
        #expect(fixture.rejects(text: AssistantRoutingFixture.text + " and Osmose through Pet Alias",
                                intent: sharedDevice, context: context))
    }

    @Test func changedConfigurationAndEnvironmentRejectAtRevalidationWithoutLosingBranches() throws {
        let fixture = AssistantRoutingFixture()
        let draft = try fixture.prepared()
        var connections = fixture.connections
        connections.home.outputs[2].connector = 1
        connections.home.outputs[3].connector = 2
        let refreshed = StudioWiringAdvisor.revalidate(draft, equipment: fixture.equipment,
            effects: [fixture.effect], connections: connections,
            currentGraph: StudioGraph(), currentEnvironmentID: UUID())
        #expect(refreshed.validation.contains { $0.code == "destination-changed" })
        #expect(refreshed.validation.contains { $0.code == "environment-changed" })
        #expect(refreshed.request.additionalRoutes.count == 2)
        #expect(refreshed.fragment.edges.count == 4)
    }

    @Test func omittedRepeatedSourceDirectivesCannotHideBehindCoveredNamesOrBroadEvidence() {
        let fixture = AssistantRoutingFixture()
        let text = AssistantRoutingFixture.text + " and also Solar directly to desktop speakers"
        #expect(fixture.rejects(text: text))
        var broad = AssistantRoutingFixture.intent
        broad.branches[1].destinationEvidence = text
        broad.branches[1].processingEvidence = text
        #expect(fixture.rejects(text: text, intent: broad))
    }

    @Test func interveningSourceAndPhysicalEffectGraphUseInvalidatesPreparedDraft() throws {
        let fixture = AssistantRoutingFixture()
        let draft = try fixture.prepared()
        let direct = StudioWiringAdvisor.build(request: .init(sourceInstrumentIDs: [fixture.solar.id]),
            equipment: fixture.equipment, effects: [fixture.effect], connections: fixture.connections,
            currentGraph: StudioGraph())
        let directGraph = StudioGraph(nodes: direct.fragment.nodes.map(\.node),
                                      edges: direct.fragment.edges.map(\.edge))
        let effectGraph = StudioGraph(nodes: [.init(kind: .effect(fixture.effect.id), title: "Now in use")])
        for graph in [directGraph, effectGraph] {
            let refreshed = StudioWiringAdvisor.revalidate(draft, equipment: fixture.equipment,
                effects: [fixture.effect], connections: fixture.connections,
                currentGraph: graph, currentEnvironmentID: nil)
            #expect(refreshed.hasErrors)
            #expect(refreshed.validation.contains { $0.code == "routing-graph-changed" })
        }
    }

    @Test func reversedSpeakerNumberingPreservesSidesAndSideDriftInvalidatesReview() throws {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        context.globalConnections.home.outputs[2].connector = 6
        context.globalConnections.home.outputs[3].connector = 5
        context.effectiveConnections = context.globalConnections.effectiveHome
        let draft = try fixture.prepared(context: context)
        let desk = try #require(draft.fragment.endpoints.first { $0.destination == .custom })
        #expect(desk.outputConnectors == [.init(index: 6), .init(index: 5)])
        let graph = StudioGraph(nodes: draft.fragment.nodes.map(\.node), edges: draft.fragment.edges.map(\.edge))
        let compiled = StudioSignalCompiler.compile(.init(graph: graph, endpoints: draft.fragment.endpoints,
            effects: [fixture.effect], connections: context.globalConnections,
            equipment: fixture.equipment, speakers: []))
        #expect(!compiled.hasErrors)
        let allocation = try #require(compiled.resourcePlan.allocations.first { $0.endpoint.id == desk.id })
        let values = Dictionary(compiled.settings.map { ($0.address, $0.value) }, uniquingKeysWith: { _, last in last })
        #expect(values[WingAddress.outputSourceIndex(6)] == .int(Int32(allocation.controlNode.index)))
        let right = try #require(allocation.rightControlNode)
        #expect(values[WingAddress.outputSourceIndex(5)] == .int(Int32(right.index)))
        context.globalConnections.home.outputs[2].destinationName = "Desk Speakers R"
        context.globalConnections.home.outputs[3].destinationName = "Desk Speakers L"
        let refreshed = StudioWiringAdvisor.revalidate(draft, equipment: fixture.equipment,
            effects: [fixture.effect], connections: context.globalConnections,
            currentGraph: StudioGraph(), currentEnvironmentID: nil)
        #expect(refreshed.validation.contains { $0.code == "destination-changed" })
    }

    @Test func exactMainGroupAgreesWithCompilerAndMappingDriftFailsClosed() throws {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        context.globalConnections.home.outputs += [
            .init(connector: 1, destinationName: "Backup Main Speakers L"),
            .init(connector: 2, destinationName: "Backup Main Speakers R")
        ]
        context.effectiveConnections = context.globalConnections.effectiveHome
        let draft = try fixture.prepared(context: context)
        let graph = StudioGraph(nodes: draft.fragment.nodes.map(\.node), edges: draft.fragment.edges.map(\.edge))
        let compiled = StudioSignalCompiler.compile(.init(graph: graph, endpoints: draft.fragment.endpoints,
            effects: [fixture.effect], connections: context.globalConnections,
            equipment: fixture.equipment, speakers: []))
        #expect(!compiled.hasErrors)
        let values = Dictionary(compiled.settings.map { ($0.address, $0.value) }, uniquingKeysWith: { _, last in last })
        #expect(values[WingAddress.outputSourceGroup(7)] == .string("MAIN"))
        #expect(values[WingAddress.outputSourceIndex(7)] == .int(1))
        #expect(values[WingAddress.outputSourceIndex(8)] == .int(2))
        #expect(values[WingAddress.outputSourceGroup(1)] == nil)
        #expect(values[WingAddress.outputSourceGroup(2)] == nil)
        context.globalConnections.home.outputs[4].destinationName = "Main Speakers R"
        context.globalConnections.home.outputs[5].destinationName = "Main Speakers L"
        let drifted = StudioSignalCompiler.compile(.init(graph: graph, endpoints: draft.fragment.endpoints,
            effects: [fixture.effect], connections: context.globalConnections,
            equipment: fixture.equipment, speakers: []))
        #expect(drifted.hasErrors)
        #expect(drifted.settings.isEmpty)
    }

    @Test func onlyIsScopedAndExclusionsNeverBecomePositiveOrReplacement() throws {
        let fixture = AssistantRoutingFixture()
        let text = "only Solar going through evil pet to mains without Osmose"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains",
                  destinationEvidence: "Solar going through evil pet to mains",
                  processingEvidence: "Solar going through evil pet")
        ], excludedMentions: ["Osmose"], exclusionEvidence: ["without Osmose"])
        let draft = try fixture.prepared(text: text, intent: intent)
        #expect(draft.applicationMode == .append)
        #expect(draft.request.sourceInstrumentIDs == [fixture.solar.id])
        var replaced = intent
        replaced.replacesSetup = true
        replaced.modeEvidence = "only"
        #expect(fixture.rejects(text: text, intent: replaced))
        #expect(fixture.rejects(text: "don't use " + text, intent: intent))
        var positiveExcluded = intent
        positiveExcluded.excludedMentions = ["Solar"]
        positiveExcluded.exclusionEvidence = ["without Solar"]
        #expect(fixture.rejects(text: text + " without Solar", intent: positiveExcluded))
    }

    @Test func explicitDryWetIsSupportedButAmbiguousParallelAndSharedEffectsAreNot() throws {
        let fixture = AssistantRoutingFixture()
        let text = "Solar through evil pet to mains with Solar dry and wet in parallel"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet"], destination: "mains",
                  destinationEvidence: "Solar through evil pet to mains", processingEvidence: "Solar through evil pet",
                  includesDrySignal: true, dryEvidence: "Solar dry and wet in parallel")
        ])
        let draft = try fixture.prepared(text: text, intent: intent)
        #expect(draft.request.includesDrySignal)
        #expect(draft.fragment.edges.count == 3)
        var noDry = intent
        noDry.branches[0].includesDrySignal = false
        noDry.branches[0].dryEvidence = ""
        #expect(fixture.rejects(text: text, intent: noDry))
        var shared = AssistantRoutingFixture.intent
        shared.branches[0].effects = ["evil pet"]
        shared.branches[0].processingEvidence = "Osmose through evil pet"
        #expect(fixture.rejects(text: AssistantRoutingFixture.text + " and Osmose through evil pet", intent: shared))
        var context = fixture.context
        context.graph.addNode(.init(kind: .effect(fixture.effect.id), title: "Already shared"))
        #expect(fixture.rejects(context: context))
        context = fixture.context
        let existing = StudioPatchDraftMerger.merge(try fixture.prepared(), into: StudioGraph(), endpoints: [],
            equipment: fixture.equipment, effects: [fixture.effect])
        context.graph = existing.graph
        context.endpoints = existing.endpoints
        #expect(fixture.rejects(context: context))
    }

    @Test func liveAliasesAreExistingEquipmentReferencesAndStaleOrUnlinkedAliasesReject() throws {
        let fixture = AssistantRoutingFixture()
        let text = "route Lead to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Lead", destination: "mains", destinationEvidence: "Lead to mains")
        ])
        var context = fixture.context
        let now = Date()
        let snapshot = WingConfirmedSnapshot(status: .observed, sessionID: UUID(), capturedAt: now,
            values: [WingAddress.inputName(1): .string("Lead")], receivedAt: [WingAddress.inputName(1): now])
        context.liveWing = AssistantLiveWingContext.project(snapshot, equipment: context.equipment,
                                                            connections: context.effectiveConnections)
        let draft = try fixture.prepared(text: text, intent: intent, context: context)
        #expect(draft.request.sourceInstrumentIDs == [fixture.osmose.id])
        #expect(draft.liveReferences?.count == 1)
        #expect(context.equipment == fixture.equipment)
        context.liveWing.observations[0].isStale = true
        #expect(fixture.rejects(text: text, intent: intent, context: context))
        context.liveWing.observations[0].isStale = false
        context.liveWing.observations[0].equipmentID = nil
        #expect(fixture.rejects(text: text, intent: intent, context: context))
    }

    @Test func explicitSerialOrderIsRetainedAndUnclearOrParallelOrderClarifies() throws {
        let fixture = AssistantRoutingFixture()
        var context = fixture.context
        let echoDevice = Equipment(name: "Echo", inputs: ["In"], outputs: ["Out"])
        let echo = Effect(name: "Echo", equipmentID: echoDevice.id, isStereo: false)
        context.equipment.append(echoDevice)
        context.effects.append(echo)
        context.globalConnections.home.inputs.append(.init(connector: 9, equipmentID: echoDevice.id, outputPort: 0))
        context.globalConnections.home.outputs.append(.init(connector: 1, equipmentID: echoDevice.id, inputPort: 0))
        context.effectiveConnections = context.globalConnections.effectiveHome
        let text = "Solar through evil pet then Echo to mains"
        let intent = AssistantRoutingIntent(branches: [
            .init(source: "Solar", effects: ["evil pet", "Echo"], destination: "mains",
                  destinationEvidence: text, processingEvidence: "Solar through evil pet then Echo")
        ])
        let draft = try fixture.prepared(text: text, intent: intent, context: context)
        #expect(draft.request.effectChainIDs == [fixture.effect.id, echo.id])
        var unclear = intent
        unclear.branches[0].processingEvidence = "Solar through evil pet and Echo"
        unclear.branches[0].destinationEvidence = "Solar through evil pet and Echo to mains"
        #expect(fixture.rejects(text: "Solar through evil pet and Echo to mains", intent: unclear, context: context))
        #expect(fixture.rejects(text: text + " in parallel", intent: intent, context: context))
    }

    @Test func oldStoredRequestDecodesWithoutNewMetadata() throws {
        let fixture = AssistantRoutingFixture()
        let data = Data("""
            {"sourceInstrumentIDs":["\(fixture.osmose.id)"],"effectChainIDs":[],"destination":"finalMix"}
            """.utf8)
        let request = try JSONDecoder().decode(StudioPatchRequest.self, from: data)
        #expect(request.additionalRoutes.isEmpty)
        #expect(!request.includesDrySignal)
    }

    @Test func ownershipFenceCoversNamedOutputAdditionsWithoutStealingPriorMonoExample() {
        #expect(AssistantRoutingOwnership.owns("add Osmose to PA"))
        #expect(AssistantRoutingOwnership.owns("Osmose to the studio speaker"))
        #expect(AssistantRoutingOwnership.owns("make Solar feed Evil Pet"))
        #expect(AssistantRoutingOwnership.owns("include Osmose on PA and set Astrolab to 50%"))
        #expect(!AssistantRoutingOwnership.owns("add my mother-32 and turn the volume to 50%"))
        #expect(!AssistantRoutingOwnership.owns("turn down the volume of my Astrolab"))
        #expect(!AssistantRoutingOwnership.owns("How do I route Solar to speakers?"))
    }

    @Test func evidenceAndArrayBoundsCannotBeBypassedByInjectedInterpretations() {
        let fixture = AssistantRoutingFixture()
        var intent = AssistantRoutingFixture.intent
        intent.branches[1].processingEvidence = "Solar through evil pet"
        #expect(fixture.rejects(intent: intent))
        intent = AssistantRoutingFixture.intent
        intent.branches = Array(repeating: intent.branches[0], count: 9)
        #expect(fixture.rejects(intent: intent))
        #expect(fixture.rejects(text: String(repeating: " ", count: 2_001) + AssistantRoutingFixture.text))
    }
}
