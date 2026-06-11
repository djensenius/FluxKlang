//
//  ChainGraph.swift
//  FluxKlang
//
//  The persistable signal-chain graph for the drag-and-drop builder: nodes
//  (user equipment and WING endpoints), their canvas positions, and the edges
//  (wires) between their ports.
//

import CoreGraphics
import Foundation

/// What a chain node represents.
enum ChainNodeKind: Codable, Hashable, Sendable {
    case equipment(UUID)
    case wingInput(Int)
    case wingChannel(Int)
    case wingBus(Int)
    case wingMain(Int)
    case wingOutput(Int)

    var isWing: Bool {
        if case .equipment = self { return false }
        return true
    }
}

/// A node placed on the chain canvas.
struct ChainNode: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: ChainNodeKind
    var title: String
    var position: CGPoint

    init(id: UUID = UUID(), kind: ChainNodeKind, title: String, position: CGPoint) {
        self.id = id
        self.kind = kind
        self.title = title
        self.position = position
    }
}

/// Which side of a node a port sits on.
enum ChainPortSide: String, Codable, Hashable, Sendable {
    case input
    case output
}

/// A reference to a specific port on a node.
struct ChainPortRef: Codable, Hashable, Sendable {
    var nodeID: UUID
    var side: ChainPortSide
    var port: Int
}

/// A wire connecting an output port to an input port.
struct ChainEdge: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var from: ChainPortRef
    var to: ChainPortRef

    init(id: UUID = UUID(), from: ChainPortRef, to: ChainPortRef) {
        self.id = id
        self.from = from
        self.to = to
    }
}

/// The full chain: nodes plus the wires between them.
struct ChainGraph: Codable, Sendable {
    var nodes: [ChainNode]
    var edges: [ChainEdge]

    init(nodes: [ChainNode] = [], edges: [ChainEdge] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    func node(_ id: UUID) -> ChainNode? {
        nodes.first { $0.id == id }
    }
}
