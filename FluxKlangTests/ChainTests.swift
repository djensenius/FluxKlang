//
//  ChainTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

struct ChainTests {
    private struct Fixture {
        var graph: ChainGraph
        let inputA: ChainNode
        let inputB: ChainNode
        let channel: ChainNode
    }

    private func makeFixture() -> Fixture {
        var graph = ChainGraph()
        let inputA = ChainNode(kind: .wingInput(1), title: "Local 1", position: .zero)
        let inputB = ChainNode(kind: .wingInput(2), title: "Local 2", position: .zero)
        let channel = ChainNode(kind: .wingChannel(1), title: "Channel 1", position: .zero)
        graph.addNode(inputA)
        graph.addNode(inputB)
        graph.addNode(channel)
        return Fixture(graph: graph, inputA: inputA, inputB: inputB, channel: channel)
    }

    @Test func connectReplacesExistingWireIntoSameInput() {
        var fixture = makeFixture()
        let channelInput = ChainPortRef(nodeID: fixture.channel.id, side: .input, port: 0)
        fixture.graph.connect(from: ChainPortRef(nodeID: fixture.inputA.id, side: .output, port: 0), to: channelInput)
        fixture.graph.connect(from: ChainPortRef(nodeID: fixture.inputB.id, side: .output, port: 0), to: channelInput)
        #expect(fixture.graph.edges.count == 1)
        #expect(fixture.graph.edges.first?.from.nodeID == fixture.inputB.id)
    }

    @Test func connectAllowsFanInIntoSummingDestination() {
        var fixture = makeFixture()
        let bus = ChainNode(kind: .wingBus(1), title: "Bus 1", position: .zero)
        fixture.graph.addNode(bus)
        let busInput = ChainPortRef(nodeID: bus.id, side: .input, port: 0)
        fixture.graph.connect(from: ChainPortRef(nodeID: fixture.inputA.id, side: .output, port: 0), to: busInput)
        fixture.graph.connect(from: ChainPortRef(nodeID: fixture.inputB.id, side: .output, port: 0), to: busInput)
        // A bus sums its sources, so both wires survive (no replacement).
        #expect(fixture.graph.edges.count == 2)
    }

    @Test func connectIgnoresDuplicateWire() {
        var fixture = makeFixture()
        let bus = ChainNode(kind: .wingBus(1), title: "Bus 1", position: .zero)
        fixture.graph.addNode(bus)
        let origin = ChainPortRef(nodeID: fixture.inputA.id, side: .output, port: 0)
        let busInput = ChainPortRef(nodeID: bus.id, side: .input, port: 0)
        fixture.graph.connect(from: origin, to: busInput)
        fixture.graph.connect(from: origin, to: busInput)
        #expect(fixture.graph.edges.count == 1)
    }

    @Test func connectRejectsInputToOutput() {
        var fixture = makeFixture()
        // Swapped sides: not a valid output → input connection.
        fixture.graph.connect(
            from: ChainPortRef(nodeID: fixture.channel.id, side: .input, port: 0),
            to: ChainPortRef(nodeID: fixture.inputA.id, side: .output, port: 0)
        )
        #expect(fixture.graph.edges.isEmpty)
    }

    @Test func removeNodeDropsIncidentEdges() {
        var fixture = makeFixture()
        fixture.graph.connect(
            from: ChainPortRef(nodeID: fixture.inputA.id, side: .output, port: 0),
            to: ChainPortRef(nodeID: fixture.channel.id, side: .input, port: 0)
        )
        #expect(fixture.graph.edges.count == 1)
        fixture.graph.removeNode(fixture.channel.id)
        #expect(fixture.graph.edges.isEmpty)
        #expect(fixture.graph.nodes.count == 2)
    }

    @Test func translatesChannelToMainAssignment() {
        var fixture = makeFixture()
        let main = ChainNode(kind: .wingMain(1), title: "Main", position: .zero)
        fixture.graph.addNode(main)
        fixture.graph.connect(
            from: ChainPortRef(nodeID: fixture.inputA.id, side: .output, port: 0),
            to: ChainPortRef(nodeID: fixture.channel.id, side: .input, port: 0)
        )
        fixture.graph.connect(
            from: ChainPortRef(nodeID: fixture.channel.id, side: .output, port: 0),
            to: ChainPortRef(nodeID: main.id, side: .input, port: 0)
        )
        let addresses = Set(fixture.graph.wingSettings().map(\.address))
        #expect(addresses.contains(WingAddress.channelSourceGroup(1)))
        #expect(addresses.contains(WingAddress.mainOn(.channel, 1, toMain: 1)))
    }

    @Test func translatesMainToOutputPatch() {
        var graph = ChainGraph()
        let main = ChainNode(kind: .wingMain(1), title: "Main", position: .zero)
        let output = ChainNode(kind: .wingOutput(3), title: "Output 3", position: .zero)
        graph.addNode(main)
        graph.addNode(output)
        graph.connect(
            from: ChainPortRef(nodeID: main.id, side: .output, port: 0),
            to: ChainPortRef(nodeID: output.id, side: .input, port: 0)
        )
        // Wiring Main → a physical output patches the output's source — i.e. how
        // the chain "reaches the speakers".
        let settings = graph.wingSettings()
        #expect(settings.contains { $0.address == WingAddress.outputSourceGroup(3) && $0.value == .string("MAIN") })
        #expect(settings.contains { $0.address == WingAddress.outputSourceIndex(3) && $0.value == .int(1) })
    }

    @Test func translatesBusToOutputPatch() {
        var graph = ChainGraph()
        let bus = ChainNode(kind: .wingBus(2), title: "Bus 2", position: .zero)
        let output = ChainNode(kind: .wingOutput(5), title: "Output 5", position: .zero)
        graph.addNode(bus)
        graph.addNode(output)
        graph.connect(
            from: ChainPortRef(nodeID: bus.id, side: .output, port: 0),
            to: ChainPortRef(nodeID: output.id, side: .input, port: 0)
        )
        let settings = graph.wingSettings()
        #expect(settings.contains { $0.address == WingAddress.outputSourceGroup(5) && $0.value == .string("BUS") })
        #expect(settings.contains { $0.address == WingAddress.outputSourceIndex(5) && $0.value == .int(2) })
    }

    @Test func channelToOutputProducesNoPatch() {
        // A raw channel is not a valid WING output source group, so wiring a
        // channel straight to a physical output yields no OSC patch — the chain
        // must reach the speakers via a bus or main.
        var graph = ChainGraph()
        let channel = ChainNode(kind: .wingChannel(1), title: "Channel 1", position: .zero)
        let output = ChainNode(kind: .wingOutput(3), title: "Output 3", position: .zero)
        graph.addNode(channel)
        graph.addNode(output)
        graph.connect(
            from: ChainPortRef(nodeID: channel.id, side: .output, port: 0),
            to: ChainPortRef(nodeID: output.id, side: .input, port: 0)
        )
        let settings = graph.wingSettings()
        #expect(!settings.contains { $0.address == WingAddress.outputSourceGroup(3) })
        #expect(!settings.contains { $0.address == WingAddress.outputSourceIndex(3) })
    }

    @Test func connectReplacesExistingWireIntoSameOutput() {
        var graph = ChainGraph()
        let main = ChainNode(kind: .wingMain(1), title: "Main", position: .zero)
        let bus = ChainNode(kind: .wingBus(1), title: "Bus 1", position: .zero)
        let output = ChainNode(kind: .wingOutput(3), title: "Output 3", position: .zero)
        graph.addNode(main)
        graph.addNode(bus)
        graph.addNode(output)
        let outputInput = ChainPortRef(nodeID: output.id, side: .input, port: 0)
        graph.connect(from: ChainPortRef(nodeID: main.id, side: .output, port: 0), to: outputInput)
        graph.connect(from: ChainPortRef(nodeID: bus.id, side: .output, port: 0), to: outputInput)
        // A physical output is a single 1:1 source patch, so the second wire
        // replaces the first rather than producing an ambiguous fan-in.
        #expect(graph.edges.count == 1)
        #expect(graph.edges.first?.from.nodeID == bus.id)
    }
}
