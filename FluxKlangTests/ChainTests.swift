//
//  ChainTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

@MainActor
struct ChainTests {
    private struct Fixture {
        let store: ChainStore
        let inputA: ChainNode
        let inputB: ChainNode
        let channel: ChainNode
    }

    private func makeFixture() -> Fixture {
        let store = ChainStore()
        let inputA = ChainNode(kind: .wingInput(1), title: "Local 1", position: .zero)
        let inputB = ChainNode(kind: .wingInput(2), title: "Local 2", position: .zero)
        let channel = ChainNode(kind: .wingChannel(1), title: "Channel 1", position: .zero)
        store.addNode(inputA)
        store.addNode(inputB)
        store.addNode(channel)
        return Fixture(store: store, inputA: inputA, inputB: inputB, channel: channel)
    }

    @Test func connectReplacesExistingWireIntoSameInput() {
        let fixture = makeFixture()
        let store = fixture.store
        let channelInput = ChainPortRef(nodeID: fixture.channel.id, side: .input, port: 0)
        store.connect(from: ChainPortRef(nodeID: fixture.inputA.id, side: .output, port: 0), to: channelInput)
        store.connect(from: ChainPortRef(nodeID: fixture.inputB.id, side: .output, port: 0), to: channelInput)
        #expect(store.graph.edges.count == 1)
        #expect(store.graph.edges.first?.from.nodeID == fixture.inputB.id)
    }

    @Test func connectRejectsInputToOutput() {
        let fixture = makeFixture()
        let store = fixture.store
        // Swapped sides: not a valid output → input connection.
        store.connect(
            from: ChainPortRef(nodeID: fixture.channel.id, side: .input, port: 0),
            to: ChainPortRef(nodeID: fixture.inputA.id, side: .output, port: 0)
        )
        #expect(store.graph.edges.isEmpty)
    }

    @Test func removeNodeDropsIncidentEdges() {
        let fixture = makeFixture()
        let store = fixture.store
        store.connect(
            from: ChainPortRef(nodeID: fixture.inputA.id, side: .output, port: 0),
            to: ChainPortRef(nodeID: fixture.channel.id, side: .input, port: 0)
        )
        #expect(store.graph.edges.count == 1)
        store.removeNode(fixture.channel.id)
        #expect(store.graph.edges.isEmpty)
        #expect(store.graph.nodes.count == 2)
    }

    @Test func translatesChannelToMainAssignment() {
        let fixture = makeFixture()
        let store = fixture.store
        let main = ChainNode(kind: .wingMain(1), title: "Main", position: .zero)
        store.addNode(main)
        store.connect(
            from: ChainPortRef(nodeID: fixture.inputA.id, side: .output, port: 0),
            to: ChainPortRef(nodeID: fixture.channel.id, side: .input, port: 0)
        )
        store.connect(
            from: ChainPortRef(nodeID: fixture.channel.id, side: .output, port: 0),
            to: ChainPortRef(nodeID: main.id, side: .input, port: 0)
        )
        let addresses = Set(store.wingSettings().map(\.address))
        #expect(addresses.contains(WingAddress.channelSourceGroup(1)))
        #expect(addresses.contains(WingAddress.mainOn(.channel, 1, toMain: 1)))
    }
}
