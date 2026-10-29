//
//  StudioGraphTests.swift
//  FluxKlangTests
//

import CoreGraphics
import Foundation
import Testing
@testable import FluxKlang

struct StudioGraphTests {
    @Test func feedbackCycleIsAnErrorAndProducesNoSettings() {
        let firstEffect = StudioNode(kind: .effect(UUID()), title: "Delay")
        let secondEffect = StudioNode(kind: .effect(UUID()), title: "Reverb")
        let endpoint = StudioEndpoint(name: "Main Speakers", destination: .finalMix)
        let endpointNode = StudioNode(kind: .endpoint(endpoint.id), title: endpoint.name)
        var graph = StudioGraph(nodes: [firstEffect, secondEffect, endpointNode])
        graph.connect(from: output(firstEffect), to: input(secondEffect))
        graph.connect(from: output(secondEffect), to: input(firstEffect))
        graph.connect(from: output(secondEffect), to: input(endpointNode))

        let compiled = StudioSignalCompiler.compile(StudioCompilationInput(
            graph: graph,
            endpoints: [endpoint],
            effects: [],
            connections: GlobalStudioConnections(),
            equipment: [],
            speakers: []
        ))

        #expect(compiled.hasErrors)
        #expect(compiled.routingPlan.appliableEdgeIDs.isEmpty)
        #expect(compiled.settings.isEmpty)
    }

    private func output(_ node: StudioNode) -> StudioPortRef {
        StudioPortRef(nodeID: node.id, side: .output, port: 0)
    }

    private func input(_ node: StudioNode) -> StudioPortRef {
        StudioPortRef(nodeID: node.id, side: .input, port: 0)
    }

    @Test func studioGraphAllowsFreeFanOutAndFanIn() {
        let synthA = StudioNode(kind: .instrument(UUID()), title: "OP-XY")
        let synthB = StudioNode(kind: .instrument(UUID()), title: "OP-1 Field")
        let reverb = StudioNode(kind: .effect(UUID()), title: "Microcosm")
        let endpoint = StudioNode(kind: .endpoint(UUID()), title: "Space Wash")

        var graph = StudioGraph(nodes: [synthA, synthB, reverb, endpoint])
        graph.connect(from: output(synthA), to: input(endpoint))
        graph.connect(from: output(synthA), to: input(reverb))
        graph.connect(from: output(synthB), to: input(reverb))
        graph.connect(from: output(reverb), to: input(endpoint))
        graph.connect(from: output(reverb), to: input(endpoint))

        // Fan-out from synthA and fan-in to both the effect and endpoint survive;
        // the exact duplicate reverb -> endpoint wire is ignored.
        #expect(graph.edges.count == 4)
        #expect(graph.edges.filter { $0.from.nodeID == synthA.id }.count == 2)
        #expect(graph.edges.filter { $0.to.nodeID == reverb.id }.count == 2)
        #expect(graph.edges.filter { $0.to.nodeID == endpoint.id }.count == 2)
    }

    @Test func plannerFindsDryAndWetEndpointBranches() {
        let synth = StudioNode(kind: .instrument(UUID()), title: "OP-XY")
        let delay = StudioNode(kind: .effect(UUID()), title: "Delay")
        let dry = StudioEndpoint(name: "OP-XY Dry", destination: .finalMix)
        let wet = StudioEndpoint(name: "OP-XY Delay Space", destination: .space)
        let dryNode = StudioNode(kind: .endpoint(dry.id), title: dry.name)
        let wetNode = StudioNode(kind: .endpoint(wet.id), title: wet.name)

        var graph = StudioGraph(nodes: [synth, delay, dryNode, wetNode])
        graph.connect(from: output(synth), to: input(dryNode))
        graph.connect(from: output(synth), to: input(delay))
        graph.connect(from: output(delay), to: input(wetNode))

        let plan = StudioRoutingPlanner.plan(for: graph, endpoints: [dry, wet])
        let dryPlan = plan.endpointPlans.first { $0.endpoint.id == dry.id }
        let wetPlan = plan.endpointPlans.first { $0.endpoint.id == wet.id }

        #expect(plan.issues.isEmpty)
        #expect(plan.appliableEdgeIDs == Set(graph.edges.map(\.id)))
        #expect(dryPlan?.sourceNodeIDs == [synth.id])
        #expect(wetPlan?.sourceNodeIDs == [synth.id])
        #expect(wetPlan?.endpoint.destination == .space)
    }

    @Test func plannerAllowsUnfinishedBranchesButDoesNotApplyThem() {
        let synth = StudioNode(kind: .instrument(UUID()), title: "MicroFreak")
        let delay = StudioNode(kind: .effect(UUID()), title: "Delay")
        let dry = StudioEndpoint(name: "MicroFreak Dry", destination: .finalMix)
        let dryNode = StudioNode(kind: .endpoint(dry.id), title: dry.name)

        var graph = StudioGraph(nodes: [synth, delay, dryNode])
        graph.connect(from: output(synth), to: input(dryNode))
        graph.connect(from: output(synth), to: input(delay))

        let plan = StudioRoutingPlanner.plan(for: graph, endpoints: [dry])

        #expect(plan.hasWarnings)
        #expect(!plan.hasErrors)
        #expect(plan.appliableEdgeIDs == Set(graph.edges.prefix(1).map(\.id)))
        #expect(plan.issues.contains {
            if case .unfinishedBranch(let nodeID) = $0.kind {
                return nodeID == delay.id
            }
            return false
        })
    }

    @Test func studioEndpointCodableRoundTripPreservesControlsAndPlacement() throws {
        let endpoint = StudioEndpoint(
            name: "Rear Texture",
            destination: .space,
            controls: [.volume, .mute, .metering],
            colorName: "purple",
            placement: VoicePlacement(position: CGPoint(x: 0.25, y: 0.75), width: 0.8)
        )

        let data = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(StudioEndpoint.self, from: data)

        #expect(decoded == endpoint)
        #expect(decoded.controls.contains(.metering))
        #expect(decoded.placement?.position == CGPoint(x: 0.25, y: 0.75))
    }

    @Test func routingEnvironmentCarriesSemanticStudioGraph() throws {
        let endpoint = StudioEndpoint(name: "OP-XY Dry", destination: .finalMix)
        let endpointNode = StudioNode(kind: .endpoint(endpoint.id), title: endpoint.name)
        let setup = StudioSetup.inferredFromEquipment([Equipment(name: "OP-XY", isStereo: true)])
        let environment = RoutingEnvironment(
            name: "Sketch",
            studioGraph: StudioGraph(nodes: [endpointNode]),
            studioEndpoints: [endpoint],
            studioSetup: setup
        )

        let data = try JSONEncoder().encode(environment)
        let decoded = try JSONDecoder().decode(RoutingEnvironment.self, from: data)

        #expect(decoded.studioEndpoints == [endpoint])
        #expect(decoded.studioGraph.nodes.first?.kind == .endpoint(endpoint.id))
        #expect(decoded.studioSetup == setup)
    }

    @Test func setupInferenceStoresEquipmentOutputPatches() throws {
        let opxy = Equipment(name: "OP-XY", outputs: ["L", "R"], isStereo: true)
        let micro = Equipment(name: "MicroFreak", outputs: ["Out"], isStereo: false)

        let setup = StudioSetup.inferredFromEquipment([opxy, micro])
        let opxyProfile = setup.profile(for: .equipment(opxy.id))
        let microProfile = setup.profile(for: .equipment(micro.id))

        #expect(opxyProfile?.role == .instrument)
        #expect(opxyProfile?.patches.count == 2)
        #expect(microProfile?.patches.count == 1)
        #expect(opxyProfile?.patches[0].connector == .wingInput(WingSource(group: .local, index: 1)))
        #expect(opxyProfile?.patches[1].connector == .wingInput(WingSource(group: .local, index: 2)))
        #expect(microProfile?.patches[0].connector == .wingInput(WingSource(group: .local, index: 3)))

        let data = try JSONEncoder().encode(setup)
        #expect(try JSONDecoder().decode(StudioSetup.self, from: data) == setup)
    }

    @Test func endpointAllocatorAvoidsSpeakerAndEffectBuses() {
        let synth = StudioNode(kind: .instrument(UUID()), title: "OP-XY")
        let dry = StudioEndpoint(name: "OP-XY Dry", destination: .finalMix)
        let space = StudioEndpoint(name: "OP-XY Space", destination: .space)
        let dryNode = StudioNode(kind: .endpoint(dry.id), title: dry.name)
        let spaceNode = StudioNode(kind: .endpoint(space.id), title: space.name)
        var graph = StudioGraph(nodes: [synth, dryNode, spaceNode])
        graph.connect(from: output(synth), to: input(dryNode))
        graph.connect(from: output(synth), to: input(spaceNode))

        let effect = Effect(name: "Reverb", isStereo: true)
        let routingPlan = StudioRoutingPlanner.plan(for: graph, endpoints: [dry, space])
        let resourcePlan = StudioResourceAllocator.allocateEndpoints(
            for: routingPlan,
            effects: [effect],
            speakers: SpeakerArray.standardQuad.speakers
        )

        #expect(!resourcePlan.hasErrors)
        #expect(resourcePlan.allocations.map(\.controlNode) == [.bus(5), .bus(7)])
        #expect(resourcePlan.allocations.map(\.rightControlNode) == [.bus(6), .bus(8)])
        #expect(!resourcePlan.allocations.map(\.controlNode.index).contains(1))
        #expect(!resourcePlan.allocations.map(\.controlNode.index).contains(16))
        #expect(!resourcePlan.allocations.map(\.controlNode.index).contains(15))
    }

    @Test func endpointAllocatorNamesAndRoutesFinalMixStems() {
        let endpoint = StudioEndpoint(name: "Very Long Endpoint Name", destination: .finalMix)
        let allocation = StudioEndpointAllocation(
            endpoint: endpoint,
            endpointNodeID: UUID(),
            controlNode: .bus(5),
            rightControlNode: .bus(6)
        )

        let settings = StudioResourceAllocator.settings(for: allocation)

        #expect(settings.contains {
            $0.address == WingAddress.name(.bus, 5) && $0.value == .string("Very Long En")
        })
        #expect(settings.contains {
            $0.address == WingAddress.fader(.bus, 5)
                && $0.value == .float(FaderMath.position(
                    fromDecibels: StudioResourceAllocator.initialLevelDecibels
                ))
        })
        #expect(settings.contains {
            $0.address == WingAddress.mute(.bus, 5) && $0.value == .int(1)
        })
        #expect(settings.contains {
            $0.address == WingAddress.mute(.bus, 6) && $0.value == .int(1)
        })
        #expect(settings.contains {
            $0.address == WingAddress.fader(.bus, 6)
                && $0.value == .float(FaderMath.position(
                    fromDecibels: StudioResourceAllocator.initialLevelDecibels
                ))
        })
    }

    @Test func signalCompilerRoutesDryAndWetBranchesToEndpointStems() {
        let synth = Equipment(name: "OP-XY", outputs: ["Out L", "Out R"], isStereo: true)
        let effectEquipment = Equipment(
            name: "Reverb",
            inputs: ["In L", "In R"],
            outputs: ["Out L", "Out R"],
            isStereo: true
        )
        let effect = Effect(
            name: "Reverb",
            equipmentID: effectEquipment.id,
            isStereo: true,
            sendOutputs: [1, 2],
            returnInputs: [1, 2],
            sourceInstruments: []
        )
        let instrumentNode = StudioNode(kind: .instrument(synth.id), title: synth.name)
        let effectNode = StudioNode(kind: .effect(effect.id), title: effect.name)
        let dry = StudioEndpoint(name: "OP-XY Dry", destination: .finalMix)
        let wet = StudioEndpoint(
            name: "OP-XY Reverb Space",
            destination: .space,
            placement: VoicePlacement(position: CGPoint(x: 0.5, y: 0.5))
        )
        let dryNode = StudioNode(kind: .endpoint(dry.id), title: dry.name)
        let wetNode = StudioNode(kind: .endpoint(wet.id), title: wet.name)
        var graph = StudioGraph(nodes: [instrumentNode, effectNode, dryNode, wetNode])
        graph.connect(from: output(instrumentNode), to: input(dryNode))
        graph.connect(from: output(instrumentNode), to: input(effectNode))
        graph.connect(from: output(effectNode), to: input(wetNode))
        let connections = GlobalStudioConnections(home: StudioHomeConnections(
            inputs: [
                StudioInputConnection(connector: 11, equipmentID: synth.id, outputPort: 0),
                StudioInputConnection(connector: 12, equipmentID: synth.id, outputPort: 1),
                StudioInputConnection(connector: 21, equipmentID: effectEquipment.id, outputPort: 0),
                StudioInputConnection(connector: 22, equipmentID: effectEquipment.id, outputPort: 1)
            ],
            outputs: [
                StudioOutputConnection(connector: 1, destinationName: "Main Speakers L"),
                StudioOutputConnection(connector: 2, destinationName: "Main Speakers R"),
                StudioOutputConnection(connector: 7, equipmentID: effectEquipment.id, inputPort: 0),
                StudioOutputConnection(connector: 8, equipmentID: effectEquipment.id, inputPort: 1)
            ]
        ))

        let compiled = StudioSignalCompiler.compile(StudioCompilationInput(
            graph: graph,
            endpoints: [dry, wet],
            effects: [effect],
            connections: connections,
            equipment: [synth, effectEquipment],
            speakers: SpeakerArray.standardQuad.speakers
        ))
        let valueByAddress = Dictionary(
            compiled.settings.map { ($0.address, $0.value) },
            uniquingKeysWith: { _, last in last }
        )

        #expect(!compiled.hasErrors)
        // Speaker buses 1...4 and effect buses 16/15 are reserved, so endpoint
        // stems allocate stereo pairs 5/6 and 7/8.
        #expect(valueByAddress[WingAddress.sendOn(.channel, 11, toBus: 5)] == .int(1))
        #expect(valueByAddress[WingAddress.sendOn(.channel, 12, toBus: 6)] == .int(1))
        #expect(valueByAddress[WingAddress.fader(.channel, 11)] == nil)
        #expect(valueByAddress[WingAddress.mute(.channel, 11)] == nil)
        #expect(valueByAddress[WingAddress.mainOn(.channel, 11, toMain: 1)] == .int(0))
        #expect(valueByAddress[WingAddress.mainOn(.channel, 12, toMain: 1)] == .int(0))
        #expect(valueByAddress[WingAddress.channelSourceIndex(11)] == .int(11))
        #expect(valueByAddress[WingAddress.channelSourceIndex(12)] == .int(12))
        #expect(valueByAddress[WingAddress.mainOn(.bus, 5, toMain: 1)] == .int(1))
        #expect(valueByAddress[WingAddress.mainOn(.bus, 6, toMain: 2)] == .int(1))
        // The instrument feeds the effect bus pair.
        #expect(valueByAddress[WingAddress.sendOn(.channel, 11, toBus: 16)] == .int(1))
        #expect(valueByAddress[WingAddress.sendOn(.channel, 12, toBus: 15)] == .int(1))
        // The effect is patched out/back and its return feeds the Space endpoint.
        #expect(valueByAddress[WingAddress.outputSourceIndex(7)] == .int(16))
        #expect(valueByAddress[WingAddress.channelSourceIndex(40)] == .int(21))
        #expect(valueByAddress[WingAddress.sendOn(.channel, 40, toBus: 7)] == .int(1))
        #expect(valueByAddress[WingAddress.sendOn(.channel, 39, toBus: 8)] == .int(1))
        // The placed Space control then sends its generated bus stem to speakers.
        #expect(valueByAddress[WingAddress.sendOn(.bus, 7, toBus: 1)] == .int(1))
        #expect(valueByAddress[WingAddress.sendOn(.bus, 8, toBus: 4)] == .int(1))
    }

    @Test(arguments: 0...2, [false, true])
    func finalMixUsesConfiguredMainSpeakerOutputs(mapping: Int, reversed: Bool) {
        let synth = Equipment(name: "Synth", outputs: ["Out L", "Out R"], isStereo: true)
        let instrumentNode = StudioNode(kind: .instrument(synth.id), title: synth.name)
        let outputs = [WingOutputConnector(index: reversed ? 8 : 7), .init(index: reversed ? 7 : 8)]
        let endpoint = StudioEndpoint(name: "Main Speakers", destination: .finalMix,
                                      outputConnectors: mapping == 0 ? nil : (mapping == 1 ? [] : outputs))
        let endpointNode = StudioNode(kind: .endpoint(endpoint.id), title: endpoint.name)
        var graph = StudioGraph(nodes: [instrumentNode, endpointNode])
        graph.connect(from: output(instrumentNode), to: input(endpointNode))
        let connections = GlobalStudioConnections(home: StudioHomeConnections(
            inputs: [
                StudioInputConnection(connector: 19, equipmentID: synth.id, outputPort: 0),
                StudioInputConnection(connector: 20, equipmentID: synth.id, outputPort: 1)
            ],
            outputs: [
                StudioOutputConnection(connector: reversed ? 8 : 7, destinationName: "Main Speakers L"),
                StudioOutputConnection(connector: reversed ? 7 : 8, destinationName: "Main Speakers R")
            ]
        ))

        let compiled = StudioSignalCompiler.compile(StudioCompilationInput(
            graph: graph,
            endpoints: [endpoint],
            effects: [],
            connections: connections,
            equipment: [synth],
            speakers: SpeakerArray.standardQuad.speakers
        ))
        let values = Dictionary(compiled.settings.map { ($0.address, $0.value) }) { _, last in last }

        #expect(!compiled.hasErrors)
        #expect(values[WingAddress.outputSourceGroup(7)] == .string("MAIN"))
        #expect(values[WingAddress.outputSourceIndex(7)] == .int(reversed ? 2 : 1))
        #expect(values[WingAddress.outputSourceGroup(8)] == .string("MAIN"))
        #expect(values[WingAddress.outputSourceIndex(8)] == .int(reversed ? 1 : 2))
        #expect(values[WingAddress.mainOn(.bus, 5, toMain: 1)] == .int(1))
        #expect(values[WingAddress.mainOn(.bus, 6, toMain: 2)] == .int(1))
        #expect(values[WingAddress.mainLevel(.bus, 5, toMain: 1)] == .float(0))
        #expect(values[WingAddress.mainLevel(.bus, 6, toMain: 2)] == .float(0))
    }

    @Test func customDestinationPatchesStereoEndpointPairDirectlyToOutputs() {
        let synth = Equipment(name: "Synth", outputs: ["Out L", "Out R"], isStereo: true)
        let source = StudioNode(kind: .instrument(synth.id), title: synth.name)
        let endpoint = StudioEndpoint(
            name: "Desk Speakers",
            destination: .custom,
            outputConnectors: [
                WingOutputConnector(bank: .local, index: 1),
                WingOutputConnector(bank: .local, index: 2)
            ]
        )
        let destination = StudioNode(kind: .endpoint(endpoint.id), title: endpoint.name)
        var graph = StudioGraph(nodes: [source, destination])
        graph.connect(from: output(source), to: input(destination))
        let connections = GlobalStudioConnections(home: StudioHomeConnections(inputs: [
            StudioInputConnection(connector: 19, equipmentID: synth.id, outputPort: 0),
            StudioInputConnection(connector: 20, equipmentID: synth.id, outputPort: 1)
        ]))

        let compiled = StudioSignalCompiler.compile(StudioCompilationInput(
            graph: graph,
            endpoints: [endpoint],
            effects: [],
            connections: connections,
            equipment: [synth],
            speakers: SpeakerArray.standardQuad.speakers
        ))
        let values = Dictionary(compiled.settings.map { ($0.address, $0.value) }) { _, last in last }

        #expect(!compiled.hasErrors)
        #expect(values[WingAddress.outputSourceGroup(1)] == .string("BUS"))
        #expect(values[WingAddress.outputSourceIndex(1)] == .int(5))
        #expect(values[WingAddress.outputSourceGroup(2)] == .string("BUS"))
        #expect(values[WingAddress.outputSourceIndex(2)] == .int(6))
    }
}

extension StudioGraphTests {
    @Test(arguments: [false, true], 0...3)
    func acceptedDeskMappingIsRecheckedBeforeCompilation(reuse: Bool, change: Int) throws {
        let synth = Equipment(name: "Synth", outputs: ["Out"])
        var connections = GlobalStudioConnections(home: .init(
            inputs: [.init(connector: 19, equipmentID: synth.id, outputPort: 0)],
            outputs: [.init(connector: 5, destinationName: "Desk Speakers L"),
                      .init(connector: 6, destinationName: "Desk Speakers R")]
        ))
        let reference = try #require(AssistantRoutingOutputResolver.resolve(
            "desktop speakers", in: connections.home)?.reference)
        var draft = StudioWiringAdvisor.build(
            request: .init(sourceInstrumentIDs: [synth.id], destination: .custom,
                           outputConnectors: reference.connectors),
            equipment: [synth], effects: [], connections: connections, currentGraph: StudioGraph())
        if change != 3 { draft.outputReferences = [reference] }
        let legacy = StudioEndpoint(name: "Desk Speakers", destination: .custom,
                                    outputConnectors: reference.connectors)
        let graph = StudioGraph(nodes: reuse ? [.init(kind: .endpoint(legacy.id), title: legacy.name)] : [])
        let accepted = StudioPatchDraftMerger.merge(
            draft, into: graph, endpoints: reuse ? [legacy] : [], equipment: [synth], effects: [])
        #expect(!draft.hasErrors)
        #expect(accepted.endpoints.count == 1)
        #expect(accepted.endpoints.first?.outputReferences == (change == 3 ? nil : [reference]))
        if reuse { #expect(accepted.endpoints.first?.id == legacy.id) }
        if change == 1 || change == 3 {
            connections.home.outputs[0].connector = 7
            connections.home.outputs[1].connector = 8
        } else if change == 2 {
            connections.home.outputs[0].destinationName = "Desk Speakers R"
            connections.home.outputs[1].destinationName = "Desk Speakers L"
        }
        let persisted = try JSONDecoder().decode([StudioEndpoint].self, from: JSONEncoder().encode(accepted.endpoints))
        #expect(persisted == accepted.endpoints)
        let compiled = StudioSignalCompiler.compile(.init(
            graph: accepted.graph, endpoints: persisted, effects: [], connections: connections,
            equipment: [synth], speakers: []))
        let rejects = change == 1 || change == 2
        #expect(compiled.hasErrors == rejects)
        #expect(compiled.settings.isEmpty == rejects)
        if rejects {
            #expect(compiled.issues.contains {
                $0.severity == .error && $0.kind == .outputMappingChanged(persisted[0].id)
            })
        } else {
            let values = Dictionary(compiled.settings.map { ($0.address, $0.value) },
                                    uniquingKeysWith: { _, last in last })
            #expect(values[WingAddress.outputSourceGroup(5)] == .string("BUS"))
            #expect(values[WingAddress.outputSourceIndex(5)] == .int(1))
            #expect(values[WingAddress.outputSourceIndex(6)] == .int(2))
        }
    }

    @Test func emptyMappingIsUnspecifiedOnlyForLegacyMains() {
        let mains = StudioEndpoint(name: "Main Speakers", destination: .finalMix, outputConnectors: [])
        let custom = StudioEndpoint(name: "Custom", destination: .custom, outputConnectors: [])
        #expect(mains.explicitOutputConnectors == nil)
        #expect(custom.explicitOutputConnectors == [])
    }

    @Test(arguments: [false, true], [false, true])
    func unresolvedLegacyMainsFailAtomically(emptyMapping: Bool, oneSided: Bool) {
        let synth = Equipment(name: "Synth", outputs: ["Out"])
        let source = StudioNode(kind: .instrument(synth.id), title: synth.name)
        let endpoint = StudioEndpoint(name: "Main Speakers", destination: .finalMix,
                                      outputConnectors: emptyMapping ? [] : nil)
        let destination = StudioNode(kind: .endpoint(endpoint.id), title: endpoint.name)
        var graph = StudioGraph(nodes: [source, destination])
        graph.connect(from: output(source), to: input(destination))
        let connections = GlobalStudioConnections(home: StudioHomeConnections(
            inputs: [.init(connector: 19, equipmentID: synth.id, outputPort: 0)],
            outputs: oneSided ? [.init(connector: 7, destinationName: "Main Speakers L")] : []
        ))

        let compiled = StudioSignalCompiler.compile(.init(
            graph: graph, endpoints: [endpoint], effects: [], connections: connections,
            equipment: [synth], speakers: []
        ))

        #expect(!compiled.routingPlan.hasErrors)
        #expect(!compiled.resourcePlan.hasErrors)
        #expect(compiled.hasErrors)
        #expect(compiled.settings.isEmpty)
        #expect(compiled.issues.contains {
            $0.severity == .error && $0.kind == .outputMappingChanged(endpoint.id)
        })
    }
}
