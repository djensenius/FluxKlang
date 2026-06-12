//
//  ChainGeometry.swift
//  FluxKlang
//
//  Pure layout math for the chain canvas: how many ports a node has, how big it
//  is, and where each port anchor sits in canvas coordinates. Kept separate from
//  the views so the node cards and the wire layer agree on geometry.
//

import CoreGraphics
import Foundation

/// The input/output port labels for a node.
struct ChainPorts {
    var inputs: [String]
    var outputs: [String]
}

enum ChainGeometry {
    static let nodeWidth: CGFloat = 156
    static let headerHeight: CGFloat = 34
    static let portSpacing: CGFloat = 28
    static let footerPadding: CGFloat = 10
    static let portHitRadius: CGFloat = 26

    /// The ports for a node, resolving equipment ports from the library.
    static func ports(for node: ChainNode, equipment: [Equipment]) -> ChainPorts {
        switch node.kind {
        case .equipment(let id):
            let item = equipment.first { $0.id == id }
            return ChainPorts(inputs: item?.inputs ?? [], outputs: item?.outputs ?? ["Out"])
        case .wingInput:
            return ChainPorts(inputs: [], outputs: ["Out"])
        case .wingChannel:
            return ChainPorts(inputs: ["In"], outputs: ["Out"])
        case .wingBus:
            return ChainPorts(inputs: ["In"], outputs: ["Out"])
        case .wingMain:
            return ChainPorts(inputs: ["In"], outputs: ["Out"])
        case .wingOutput:
            return ChainPorts(inputs: ["In"], outputs: [])
        case .effect:
            return ChainPorts(inputs: ["In"], outputs: ["Out"])
        case .effectSource:
            return ChainPorts(inputs: [], outputs: ["Out"])
        case .effectMain:
            return ChainPorts(inputs: ["In"], outputs: [])
        }
    }

    /// Node size derived from its busiest side.
    static func size(inputs: Int, outputs: Int) -> CGSize {
        let rows = max(inputs, outputs, 1)
        return CGSize(width: nodeWidth, height: headerHeight + CGFloat(rows) * portSpacing + footerPadding)
    }

    /// The canvas-space anchor for a port. `node.position` is the node centre.
    static func anchor(
        node: ChainNode,
        side: ChainPortSide,
        port: Int,
        inputs: Int,
        outputs: Int
    ) -> CGPoint {
        let size = size(inputs: inputs, outputs: outputs)
        let count = side == .input ? inputs : outputs
        let edgeX = node.position.x + (side == .input ? -size.width / 2 : size.width / 2)
        let top = node.position.y - size.height / 2 + headerHeight
        let usableRows = max(count, 1)
        let yPos = top + (size.height - headerHeight - footerPadding) * (CGFloat(port) + 0.5) / CGFloat(usableRows)
        return CGPoint(x: edgeX, y: yPos)
    }

    /// All input-port anchors in a graph, for hit-testing a dropped wire.
    static func inputAnchors(in graph: ChainGraph, equipment: [Equipment]) -> [(ref: ChainPortRef, point: CGPoint)] {
        var result: [(ChainPortRef, CGPoint)] = []
        for node in graph.nodes {
            let ports = ports(for: node, equipment: equipment)
            for index in ports.inputs.indices {
                let point = anchor(
                    node: node,
                    side: .input,
                    port: index,
                    inputs: ports.inputs.count,
                    outputs: ports.outputs.count
                )
                result.append((ChainPortRef(nodeID: node.id, side: .input, port: index), point))
            }
        }
        return result
    }
}
