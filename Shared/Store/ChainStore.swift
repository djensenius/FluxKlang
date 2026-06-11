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

    /// Re-reads the persisted graph, picking up changes synced from iCloud.
    func reload() async {
        loaded = false
        await load()
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

    /// Connects an output port to an input port. WING channel inputs and physical
    /// WING outputs are 1:1 source patches, so a new wire replaces any existing one
    /// into them; all other destinations (gear inputs, summing buses, mains) allow
    /// fan-in — multiple sources can converge — but never exact-duplicate wires.
    /// No-op if the connection isn't output → input.
    func connect(from origin: ChainPortRef, to destination: ChainPortRef) {
        guard origin.side == .output, destination.side == .input else { return }
        if isSingleSourceDestination(destination) {
            graph.edges.removeAll { $0.to == destination }
        } else if graph.edges.contains(where: { $0.from == origin && $0.to == destination }) {
            return
        }
        graph.edges.append(ChainEdge(from: origin, to: destination))
        persist()
    }

    /// Whether a destination port accepts only one incoming wire. A WING channel
    /// input and a physical WING output are each a single hardware source patch
    /// (`/io/in` and `/io/out` respectively); everything else allows fan-in.
    private func isSingleSourceDestination(_ destination: ChainPortRef) -> Bool {
        switch graph.node(destination.nodeID)?.kind {
        case .wingChannel, .wingOutput: return true
        default: return false
        }
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
