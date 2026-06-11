//
//  ModelsTests.swift
//  FluxKlangTests
//

import CoreGraphics
import Foundation
import Testing
@testable import FluxKlang

struct ModelsTests {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test func wingValueCodableRoundTrip() throws {
        #expect(try roundTrip(WingValue.float(0.75)) == .float(0.75))
        #expect(try roundTrip(WingValue.int(3)) == .int(3))
        #expect(try roundTrip(WingValue.string("Kick")) == .string("Kick"))
    }

    @Test func standardLayoutHasChannelsPlusMain() {
        let layout = FaderLayout.standard
        #expect(layout.strips.count == 17)
        #expect(layout.strips.first?.node == .channel(1))
        #expect(layout.strips.last?.node == .main(1))
        #expect(layout.contains(.channel(8)))
        #expect(!layout.contains(.bus(1)))
    }

    @Test func faderLayoutCodableRoundTrip() throws {
        let layout = FaderLayout.standard
        let decoded = try roundTrip(layout)
        #expect(decoded.strips.count == layout.strips.count)
        #expect(decoded.strips.first?.node == .channel(1))
    }

    @Test func presetCodableRoundTrip() throws {
        let preset = Preset(
            name: "Live Set",
            settings: [
                WingSetting(address: WingAddress.fader(.channel, 1), value: .float(0.75)),
                WingSetting(address: WingAddress.mute(.channel, 2), value: .int(1))
            ],
            wingScene: 4
        )
        #expect(try roundTrip(preset) == preset)
    }

    @Test func chainGraphCodableRoundTrip() throws {
        let input = ChainNode(kind: .wingInput(1), title: "Local 1", position: CGPoint(x: 10, y: 20))
        let channel = ChainNode(kind: .wingChannel(1), title: "Channel 1", position: CGPoint(x: 200, y: 20))
        let edge = ChainEdge(
            from: ChainPortRef(nodeID: input.id, side: .output, port: 0),
            to: ChainPortRef(nodeID: channel.id, side: .input, port: 0)
        )
        let graph = ChainGraph(nodes: [input, channel], edges: [edge])
        let decoded = try roundTrip(graph)
        #expect(decoded.nodes.count == 2)
        #expect(decoded.edges.count == 1)
        #expect(decoded.node(input.id)?.position == CGPoint(x: 10, y: 20))
    }

    @Test func routingTranslatorEmitsSourcePatchSendAndAssign() {
        let input = ChainNode(kind: .wingInput(5), title: "Local 5", position: .zero)
        let channel = ChainNode(kind: .wingChannel(1), title: "Channel 1", position: .zero)
        let bus = ChainNode(kind: .wingBus(2), title: "Bus 2", position: .zero)
        let main = ChainNode(kind: .wingMain(1), title: "Main", position: .zero)
        let synthA = ChainNode(kind: .equipment(UUID()), title: "OP-1", position: .zero)
        let synthB = ChainNode(kind: .equipment(UUID()), title: "TX-6", position: .zero)

        func port(_ node: ChainNode, _ side: ChainPortSide) -> ChainPortRef {
            ChainPortRef(nodeID: node.id, side: side, port: 0)
        }

        let graph = ChainGraph(
            nodes: [input, channel, bus, main, synthA, synthB],
            edges: [
                ChainEdge(from: port(input, .output), to: port(channel, .input)),
                ChainEdge(from: port(channel, .output), to: port(bus, .input)),
                ChainEdge(from: port(channel, .output), to: port(main, .input)),
                ChainEdge(from: port(bus, .output), to: port(main, .input)),
                ChainEdge(from: port(synthA, .output), to: port(synthB, .input))
            ]
        )

        let settings = RoutingTranslator.settings(for: graph)
        let addresses = Set(settings.map(\.address))

        #expect(addresses.contains(WingAddress.channelSourceGroup(1)))
        #expect(addresses.contains(WingAddress.channelSourceIndex(1)))
        #expect(addresses.contains(WingAddress.sendOn(.channel, 1, toBus: 2)))
        #expect(addresses.contains(WingAddress.mainOn(.channel, 1, toMain: 1)))
        #expect(addresses.contains(WingAddress.mainOn(.bus, 2, toMain: 1)))
        // Source patch contributes 2 settings; the three send/assign edges add
        // one each. The gear-to-gear edge contributes nothing.
        #expect(settings.count == 5)
    }

    @Test func equipmentLibraryIsSeeded() {
        #expect(!Equipment.seededLibrary.isEmpty)
        #expect(Equipment.seededLibrary.contains { $0.name == "OP-1 Field" })
    }
}
