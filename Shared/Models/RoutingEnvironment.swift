//
//  RoutingEnvironment.swift
//  FluxKlang
//
//  A named, switchable routing setup — think "this song's rig". An environment
//  bundles the outboard effects and how instruments feed them, plus its own
//  drag-and-drop canvas (`ChainGraph`), so a band or soloist can flip between
//  whole configurations with one tap and let FluxKlang push all the WING
//  bus/return/patch plumbing. Effects within an environment may run in parallel
//  or be chained in series (see `EffectRouting`).
//

import CoreGraphics
import Foundation

/// Where a derived voice sits in the spatial field. Saved per environment and
/// keyed by the voice's stable id (see `EnvironmentVoice`), so switching
/// environments recalls every placement.
struct VoicePlacement: Codable, Hashable, Sendable {
    /// Normalised position in `0...1` on both axes.
    var position: CGPoint
    /// Stereo spread in `0...1` (ignored for mono voices).
    var width: Double

    init(position: CGPoint = CGPoint(x: 0.5, y: 0.5), width: Double = 0.5) {
        self.position = position
        self.width = width
    }
}

struct RoutingEnvironment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// The outboard effects in this environment. Order is meaningful: it drives
    /// the automatic bus/return allocation in `EffectRouting`.
    var effects: [Effect]
    /// Spatial placement of derived voices, keyed by voice id. Voices without an
    /// entry are unplaced and contribute no surround sends until positioned.
    var placements: [String: VoicePlacement]
    /// The drag-and-drop signal-chain graph for this environment: nodes (gear and
    /// WING endpoints) and the wires between them. Each environment owns its own
    /// canvas, so switching environments swaps the whole patch.
    var graph: ChainGraph
    /// Canvas positions for the environment's effect overlay — the effect,
    /// instrument-source, and Main nodes that author `effects` visually. Keyed by
    /// stable node id (see `EnvironmentChainCanvas`). A key's mere presence also
    /// places an as-yet-unwired source node on the canvas. Pure UI state: it never
    /// affects the routing the environment pushes to the console.
    var effectLayout: [String: CGPoint]

    init(
        id: UUID = UUID(),
        name: String,
        effects: [Effect] = [],
        placements: [String: VoicePlacement] = [:],
        graph: ChainGraph = ChainGraph(),
        effectLayout: [String: CGPoint] = [:]
    ) {
        self.id = id
        self.name = name
        self.effects = effects
        self.placements = placements
        self.graph = graph
        self.effectLayout = effectLayout
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, effects, placements, graph, effectLayout
    }

    // Keeps environments.json files saved before spatial placement (and the
    // per-environment canvas) existed loadable: a missing `placements` map,
    // `graph`, or `effectLayout` decodes as empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        effects = try container.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        placements = try container.decodeIfPresent([String: VoicePlacement].self, forKey: .placements) ?? [:]
        graph = try container.decodeIfPresent(ChainGraph.self, forKey: .graph) ?? ChainGraph()
        effectLayout = try container.decodeIfPresent([String: CGPoint].self, forKey: .effectLayout) ?? [:]
    }

    /// A deep copy under a new identity, with fresh effect IDs so the duplicate's
    /// internal serial-chain links keep pointing inside the copy rather than at
    /// the original's effects. Effect-return placements and effect-node layout
    /// entries are remapped onto the new effect IDs; source placements (keyed by
    /// equipment) carry over unchanged. The canvas graph is copied verbatim — its
    /// nodes reference gear and WING endpoints, not effects, so it needs no
    /// remapping.
    func duplicated(named newName: String) -> RoutingEnvironment {
        var remap: [Effect.ID: Effect.ID] = [:]
        for effect in effects {
            remap[effect.id] = UUID()
        }
        let copies = effects.map { effect -> Effect in
            var copy = effect
            copy.id = remap[effect.id] ?? UUID()
            if let destination = effect.destinationEffectID {
                copy.destinationEffectID = remap[destination]
            }
            return copy
        }
        var copiedPlacements: [String: VoicePlacement] = [:]
        for (key, placement) in placements {
            copiedPlacements[EnvironmentVoice.remap(voiceID: key, effects: remap)] = placement
        }
        var copiedLayout: [String: CGPoint] = [:]
        for (key, point) in effectLayout {
            copiedLayout[EnvironmentChainCanvas.remap(nodeKey: key, effects: remap)] = point
        }
        return RoutingEnvironment(
            name: newName,
            effects: copies,
            placements: copiedPlacements,
            graph: graph,
            effectLayout: copiedLayout
        )
    }
}
