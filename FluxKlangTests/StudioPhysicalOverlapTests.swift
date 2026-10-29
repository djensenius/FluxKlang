import Foundation
import Testing
@testable import FluxKlang

struct StudioPhysicalOverlapTests {
    // Changes 0/5 are disjoint, including equal output indices on different banks.
    // Changes 1/2 overlap one send/return leg; 3/4 reverse the overlapping pairs.
    // Change 6 overlaps sends within AES50-A. All four mono/stereo combinations are covered.
    @Test(arguments: 0...3, 0...6)
    func independentEffectsRejectPhysicalOverlapAtEveryStage(stereoMode: Int, change: Int) {
        let sources = ["Source A", "Source B"].map { Equipment(name: $0, outputs: ["Out"]) }
        let devices = ["Effect A", "Effect B"].map {
            Equipment(name: $0, inputs: ["L", "R"], outputs: ["L", "R"], isStereo: true)
        }
        let effects = devices.enumerated().map { index, device in
            Effect(name: device.name, equipmentID: device.id,
                   isStereo: index == 0 ? stereoMode % 2 == 1 : stereoMode / 2 == 1)
        }
        let equipment = sources + devices
        var connections = GlobalStudioConnections(home: .init(
            inputs: sources.enumerated().map { .init(connector: 19 + $0.offset,
                                                     equipmentID: $0.element.id, outputPort: 0) },
            outputs: [.init(connector: 7, destinationName: "Main Speakers L"),
                      .init(connector: 8, destinationName: "Main Speakers R")]))
        for (index, effect) in effects.enumerated() {
            for port in 0..<(effect.isStereo ? 2 : 1) {
                connections.home.inputs.append(.init(connector: 11 + index * 2 + port,
                                                      equipmentID: devices[index].id, outputPort: port))
                connections.home.outputs.append(.init(connector: 1 + index * 2 + port,
                                                       equipmentID: devices[index].id, inputPort: port))
            }
        }
        let request = StudioWiringRequest(
            sourceInstrumentIDs: [sources[0].id], effectChainIDs: [effects[0].id],
            additionalRoutes: [.init(sourceInstrumentIDs: [sources[1].id],
                                     effectChainIDs: [effects[1].id], destination: .finalMix)])
        let build = { (connections: GlobalStudioConnections) in
            StudioWiringAdvisor.build(request: request, equipment: equipment, effects: effects,
                                      connections: connections, currentGraph: StudioGraph())
        }
        let draft = build(connections)
        #expect(!draft.hasErrors)
        let accepted = StudioPatchDraftMerger.merge(
            draft, into: StudioGraph(), endpoints: [], equipment: equipment, effects: effects)
        let compile = { (connections: GlobalStudioConnections) in
            StudioSignalCompiler.compile(.init(
                graph: accepted.graph, endpoints: accepted.endpoints, effects: effects,
                connections: connections, equipment: equipment, speakers: []))
        }
        #expect(!compile(connections).hasErrors)
        #expect(!compile(connections).settings.isEmpty)
        changeOutputs(&connections.home.outputs, devices: devices, stereo: effects[1].isStereo, change: change)
        for index in connections.home.inputs.indices
        where connections.home.inputs[index].equipmentID == devices[1].id {
            let port = connections.home.inputs[index].outputPort
            if change == 2, port == 0 { connections.home.inputs[index].connector = 11 }
            if change == 4 { connections.home.inputs[index].connector = effects[1].isStereo ? 12 - port : 11 }
        }
        let rejects = (1...4).contains(change) || change == 6
        let refreshed = StudioWiringAdvisor.revalidate(
            draft, equipment: equipment, effects: effects, connections: connections,
            currentGraph: StudioGraph(), currentEnvironmentID: nil)
        #expect(build(connections).hasErrors == rejects)
        #expect(refreshed.hasErrors == rejects)
        #expect(refreshed.id == draft.id)
        let compiled = compile(connections)
        #expect(compiled.hasErrors == rejects)
        #expect(compiled.settings.isEmpty == rejects)
        if rejects {
            #expect(compiled.issues.contains {
                if case .physicalConnection = $0.kind { return $0.severity == .error }
                return false
            })
        }
    }

    private func changeOutputs(
        _ outputs: inout [StudioOutputConnection], devices: [Equipment], stereo: Bool, change: Int
    ) {
        for index in outputs.indices {
            if change == 6, outputs[index].equipmentID == devices[0].id {
                outputs[index].bank = .aes50A
            }
            guard outputs[index].equipmentID == devices[1].id else { continue }
            let port = outputs[index].inputPort ?? 0
            if change == 1, port == 0 { outputs[index].connector = 1 }
            if change == 3 { outputs[index].connector = stereo ? 2 - port : 1 }
            if change == 5 || change == 6 {
                outputs[index].connector = 1 + port
                outputs[index].bank = .aes50A
            }
        }
    }
}
