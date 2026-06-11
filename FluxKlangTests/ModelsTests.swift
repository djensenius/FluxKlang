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

    @Test func standardLayoutDerivesFromGearRig() {
        let layout = FaderLayout.standard
        // Each gear device (16 stereo + 2 mono) becomes one strip, plus the main.
        #expect(layout.strips.count == Equipment.seededLibrary.count + 1)
        #expect(layout.strips.first?.node == .channel(1))
        #expect(layout.strips.first?.rightNode == .channel(2))
        #expect(layout.strips.first?.isStereo == true)
        #expect(layout.strips.last?.node == .main(1))
        #expect(layout.contains(.channel(8)))   // TP-7 right channel
        #expect(layout.contains(.channel(33)))  // MicroFreak (mono)
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

    @Test func onlyMicroFreakAndLyraAreMono() {
        let library = Equipment.seededLibrary
        let mono = library.filter { !$0.isStereo }.map(\.name).sorted()
        #expect(mono == ["Arturia MicroFreak", "SOMA Lyra-8"])
        #expect(library.first { $0.name == "OP-XY" }?.isStereo == true)
        #expect(library.first { $0.name == "Hologram Microcosm" }?.isStereo == true)
    }

    @Test func channelAssignmentsLayOutStereoAsConsecutivePairs() {
        let assignments = Equipment.channelAssignments()
        #expect(assignments.count == Equipment.seededLibrary.count)
        // First device (OP-1 Field) is stereo on channels 1 & 2.
        #expect(assignments.first?.leftChannel == 1)
        #expect(assignments.first?.rightChannel == 2)
        #expect(assignments.first?.isStereo == true)
        // 16 stereo devices (32 channels) then 2 mono → channels 33 and 34.
        #expect(assignments.last?.leftChannel == 34)
        #expect(assignments.last?.isStereo == false)
        // Channels are contiguous with no gaps or overlaps.
        var expected = 1
        for assignment in assignments {
            #expect(assignment.leftChannel == expected)
            expected += assignment.isStereo ? 2 : 1
        }
        #expect(expected == 35)
    }

    @Test func equipmentDecodesLegacyJSONWithoutStereoFlag() throws {
        let decoder = JSONDecoder()
        let stereoData = Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","inputs":[],"outputs":["L","R"]}"#.utf8
        )
        let monoData = Data(
            #"{"id":"00000000-0000-0000-0000-000000000002","name":"Legacy","inputs":[],"outputs":["Out"]}"#.utf8
        )
        #expect(try decoder.decode(Equipment.self, from: stereoData).isStereo == true)
        #expect(try decoder.decode(Equipment.self, from: monoData).isStereo == false)
    }

    @Test func faderStripStereoCodableRoundTrip() throws {
        let stereo = FaderStrip(node: .channel(1), rightNode: .channel(2), customLabel: "OP-1 Field")
        let decoded = try roundTrip(stereo)
        #expect(decoded.isStereo)
        #expect(decoded.rightNode == .channel(2))
        #expect(decoded.customLabel == "OP-1 Field")
        #expect(try roundTrip(FaderStrip(node: .channel(33))).isStereo == false)
    }
}
