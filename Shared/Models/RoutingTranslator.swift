//
//  RoutingTranslator.swift
//  FluxKlang
//
//  Translates the WING-touching edges of a chain graph into concrete WING OSC
//  settings. Edges between two pieces of external gear are documentation-only
//  (physical patches the WING can't change); edges that touch WING endpoints
//  become source patches, sends and main assignments.
//

import Foundation

enum RoutingTranslator {
    /// All WING settings implied by a chain graph's WING-touching edges.
    static func settings(for graph: ChainGraph) -> [WingSetting] {
        var result: [WingSetting] = []
        for edge in graph.edges {
            guard let from = graph.node(edge.from.nodeID)?.kind,
                  let destination = graph.node(edge.to.nodeID)?.kind else { continue }
            result.append(contentsOf: translate(from: from, to: destination))
        }
        return result
    }

    private static func translate(from: ChainNodeKind, to destination: ChainNodeKind) -> [WingSetting] {
        switch (from, destination) {
        case let (.wingInput(source), .wingChannel(channel)):
            return [
                WingSetting(address: WingAddress.channelSourceGroup(channel), value: .int(0)),
                WingSetting(address: WingAddress.channelSourceIndex(channel), value: .int(Int32(source)))
            ]
        case let (.wingChannel(channel), .wingBus(bus)):
            return [WingSetting(address: WingAddress.sendOn(.channel, channel, toBus: bus), value: .int(1))]
        case let (.wingChannel(channel), .wingMain(main)):
            return [WingSetting(address: WingAddress.mainOn(.channel, channel, toMain: main), value: .int(1))]
        case let (.wingBus(bus), .wingMain(main)):
            return [WingSetting(address: WingAddress.mainOn(.bus, bus, toMain: main), value: .int(1))]
        default:
            return []
        }
    }
}
