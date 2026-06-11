//
//  WireLayer.swift
//  FluxKlang
//
//  Draws the chain's connections as bezier wires in a single Canvas, plus the
//  in-progress wire while the user is dragging from a port. Non-interactive: the
//  ports themselves handle hit-testing.
//

import SwiftUI

struct WireLayer: View {
    let graph: ChainGraph
    let equipment: [Equipment]
    let size: CGSize
    var tempWire: (from: CGPoint, to: CGPoint)?

    var body: some View {
        Canvas { context, _ in
            for edge in graph.edges {
                guard let start = anchor(edge.from), let end = anchor(edge.to) else { continue }
                context.stroke(path(from: start, to: end), with: .color(.secondary), lineWidth: 2)
            }
            if let temp = tempWire {
                context.stroke(
                    path(from: temp.from, to: temp.to),
                    with: .color(.accentColor),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func anchor(_ ref: ChainPortRef) -> CGPoint? {
        guard let node = graph.node(ref.nodeID) else { return nil }
        let ports = ChainGeometry.ports(for: node, equipment: equipment)
        return ChainGeometry.anchor(
            node: node,
            side: ref.side,
            port: ref.port,
            inputs: ports.inputs.count,
            outputs: ports.outputs.count
        )
    }

    private func path(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let curve = max(40, abs(end.x - start.x) * 0.5)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + curve, y: start.y),
            control2: CGPoint(x: end.x - curve, y: end.y)
        )
        return path
    }
}
