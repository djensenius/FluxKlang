//
//  ChainStore.swift
//  FluxKlang
//
//  Owns the drag-and-drop signal-chain graph and persists node positions and
//  wires to disk.
//

import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class ChainStore {
    private(set) var graph = ChainGraph()

    private let fileName = "chain.json"
    private var loaded = false

    func load() async {
        guard !loaded else { return }
        loaded = true
        if let saved = await JSONFileStore.shared.load(ChainGraph.self, from: fileName) {
            graph = saved
        }
    }

    func addNode(_ node: ChainNode) {
        graph.nodes.append(node)
        persist()
    }

    func moveNode(_ id: UUID, to position: CGPoint) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        graph.nodes[index].position = position
        persist()
    }

    func removeNode(_ id: UUID) {
        graph.nodes.removeAll { $0.id == id }
        graph.edges.removeAll { $0.from.nodeID == id || $0.to.nodeID == id }
        persist()
    }

    /// Connects an output port to an input port, replacing any existing wire into
    /// the same destination port. No-op if the connection isn't output → input.
    func connect(from origin: ChainPortRef, to destination: ChainPortRef) {
        guard origin.side == .output, destination.side == .input else { return }
        graph.edges.removeAll { $0.to == destination }
        graph.edges.append(ChainEdge(from: origin, to: destination))
        persist()
    }

    func removeEdge(_ id: UUID) {
        graph.edges.removeAll { $0.id == id }
        persist()
    }

    /// The WING settings implied by the current graph.
    func wingSettings() -> [WingSetting] {
        RoutingTranslator.settings(for: graph)
    }

    private func persist() {
        let snapshot = graph
        Task { await JSONFileStore.shared.save(snapshot, to: fileName) }
    }
}
