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
///
/// The first group are free-form patchbay nodes persisted in a `ChainGraph`
/// (user gear and raw WING endpoints). The `effect*` group are the higher-level
/// environment nodes shown on the same canvas — an outboard effect, an
/// instrument feeding effects, and the Main — derived from the environment's
/// `[Effect]` rather than stored in the graph, so they never get persisted here.
enum ChainNodeKind: Codable, Hashable, Sendable {
    case equipment(UUID)
    case wingInput(Int)
    case wingChannel(Int)
    case wingBus(Int)
    case wingMain(Int)
    case wingOutput(Int)
    /// An outboard effect (aux send) in the active environment.
    case effect(UUID)
    /// An instrument feeding one or more effects in the active environment.
    case effectSource(UUID)
    /// The Main bus, where effect returns land.
    case effectMain

    var isWing: Bool {
        if case .equipment = self { return false }
        return true
    }

    /// Whether this node belongs to the environment's effect overlay (derived
    /// from `[Effect]`) rather than the persisted free-form patchbay graph.
    var isEffectDomain: Bool {
        switch self {
        case .effect, .effectSource, .effectMain: return true
        default: return false
        }
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
struct ChainGraph: Codable, Hashable, Sendable {
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

// MARK: - Editing

extension ChainGraph {
    /// Adds a node to the canvas.
    mutating func addNode(_ node: ChainNode) {
        nodes.append(node)
    }

    /// Moves a node to a new canvas position.
    mutating func moveNode(_ id: UUID, to position: CGPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].position = position
    }

    /// Removes a node and every wire incident to it.
    mutating func removeNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.from.nodeID == id || $0.to.nodeID == id }
    }

    /// Connects an output port to an input port. WING channel inputs and physical
    /// WING outputs are 1:1 source patches, so a new wire replaces any existing one
    /// into them; all other destinations (gear inputs, summing buses, mains) allow
    /// fan-in — multiple sources can converge — but never exact-duplicate wires.
    /// No-op if the connection isn't output → input.
    mutating func connect(from origin: ChainPortRef, to destination: ChainPortRef) {
        guard origin.side == .output, destination.side == .input else { return }
        if isSingleSourceDestination(destination) {
            edges.removeAll { $0.to == destination }
        } else if edges.contains(where: { $0.from == origin && $0.to == destination }) {
            return
        }
        edges.append(ChainEdge(from: origin, to: destination))
    }

    /// Removes a single wire.
    mutating func removeEdge(_ id: UUID) {
        edges.removeAll { $0.id == id }
    }

    /// The WING settings implied by the current graph.
    func wingSettings() -> [WingSetting] {
        RoutingTranslator.settings(for: self)
    }

    /// Whether a destination port accepts only one incoming wire. A WING channel
    /// input and a physical WING output are each a single hardware source patch
    /// (`/io/in` and `/io/out` respectively); everything else allows fan-in.
    private func isSingleSourceDestination(_ destination: ChainPortRef) -> Bool {
        switch node(destination.nodeID)?.kind {
        case .wingChannel, .wingOutput: return true
        default: return false
        }
    }
}
