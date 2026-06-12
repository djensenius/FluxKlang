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

    init(
        id: UUID = UUID(),
        name: String,
        effects: [Effect] = [],
        placements: [String: VoicePlacement] = [:],
        graph: ChainGraph = ChainGraph()
    ) {
        self.id = id
        self.name = name
        self.effects = effects
        self.placements = placements
        self.graph = graph
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, effects, placements, graph
    }

    // Keeps environments.json files saved before spatial placement (and the
    // per-environment canvas) existed loadable: a missing `placements` map or
    // `graph` decodes as empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        effects = try container.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        placements = try container.decodeIfPresent([String: VoicePlacement].self, forKey: .placements) ?? [:]
        graph = try container.decodeIfPresent(ChainGraph.self, forKey: .graph) ?? ChainGraph()
    }

    /// A deep copy under a new identity, with fresh effect IDs so the duplicate's
    /// internal serial-chain links keep pointing inside the copy rather than at
    /// the original's effects. Effect-return placements are remapped onto the new
    /// effect IDs; source placements (keyed by equipment) carry over unchanged.
    /// The canvas graph is copied verbatim — its nodes reference gear and WING
    /// endpoints, not effects, so it needs no remapping.
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
        return RoutingEnvironment(name: newName, effects: copies, placements: copiedPlacements, graph: graph)
    }
}
