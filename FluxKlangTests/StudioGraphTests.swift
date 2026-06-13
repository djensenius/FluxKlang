//
//  StudioGraphTests.swift
//  FluxKlangTests
//

import CoreGraphics
import Foundation
import Testing
@testable import FluxKlang

struct StudioGraphTests {
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
        #expect(resourcePlan.allocations.map(\.controlNode) == [.bus(5), .bus(6)])
        #expect(!resourcePlan.allocations.map(\.controlNode.index).contains(1))
        #expect(!resourcePlan.allocations.map(\.controlNode.index).contains(16))
        #expect(!resourcePlan.allocations.map(\.controlNode.index).contains(15))
    }

    @Test func endpointAllocatorNamesAndRoutesFinalMixStems() {
        let endpoint = StudioEndpoint(name: "Very Long Endpoint Name", destination: .finalMix)
        let allocation = StudioEndpointAllocation(endpoint: endpoint, endpointNodeID: UUID(), controlNode: .bus(5))

        let settings = StudioResourceAllocator.settings(for: allocation)

        #expect(settings.contains {
            $0.address == WingAddress.name(.bus, 5) && $0.value == .string("Very Long En")
        })
        #expect(settings.contains {
            $0.address == WingAddress.mainOn(.bus, 5, toMain: 1) && $0.value == .int(1)
        })
    }

    @Test func signalCompilerRoutesDryAndWetBranchesToEndpointStems() {
        let synth = Equipment(name: "OP-XY", isStereo: true)
        let effect = Effect(
            name: "Reverb",
            isStereo: true,
            sendOutputs: [7, 8],
            returnInputs: [9, 10],
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

        let compiled = StudioSignalCompiler.compile(
            graph: graph,
            endpoints: [dry, wet],
            effects: [effect],
            assignments: Equipment.channelAssignments(from: [synth]),
            speakers: SpeakerArray.standardQuad.speakers
        )
        let valueByAddress = Dictionary(
            compiled.settings.map { ($0.address, $0.value) },
            uniquingKeysWith: { _, last in last }
        )

        #expect(!compiled.hasErrors)
        // Speaker buses 1...4 and effect buses 16/15 are reserved, so endpoint
        // stems allocate buses 5 and 6.
        #expect(valueByAddress[WingAddress.sendOn(.channel, 1, toBus: 5)] == .int(1))
        #expect(valueByAddress[WingAddress.sendOn(.channel, 2, toBus: 5)] == .int(1))
        #expect(valueByAddress[WingAddress.mainOn(.bus, 5, toMain: 1)] == .int(1))
        // The instrument feeds the effect bus pair.
        #expect(valueByAddress[WingAddress.sendOn(.channel, 1, toBus: 16)] == .int(1))
        #expect(valueByAddress[WingAddress.sendOn(.channel, 2, toBus: 15)] == .int(1))
        // The effect is patched out/back and its return feeds the Space endpoint.
        #expect(valueByAddress[WingAddress.outputSourceIndex(7)] == .int(16))
        #expect(valueByAddress[WingAddress.channelSourceIndex(40)] == .int(9))
        #expect(valueByAddress[WingAddress.sendOn(.channel, 40, toBus: 6)] == .int(1))
        #expect(valueByAddress[WingAddress.sendOn(.channel, 39, toBus: 6)] == .int(1))
        // The placed Space control then sends its generated bus stem to speakers.
        #expect(valueByAddress[WingAddress.sendOn(.bus, 6, toBus: 1)] == .int(1))
        #expect(valueByAddress[WingAddress.sendOn(.bus, 6, toBus: 4)] == .int(1))
    }
}
