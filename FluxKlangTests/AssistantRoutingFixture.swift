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
