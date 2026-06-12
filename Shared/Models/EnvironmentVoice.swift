//
//  EnvironmentVoice.swift
//  FluxKlang
//
//  Derives the placeable "voices" of an environment from its routing graph. A
//  voice is something you can position in space, and the set of voices is NOT
//  simply one-per-instrument: because an outboard effect sums its inputs, its
//  return is a single (stereo) voice carrying every source that feeds it — so
//  two synths sharing a reverb become one movable voice, not two. Voices are
//  therefore:
//    • dry source voices — each instrument that feeds an effect, on its own
//      channel(s); always independently placeable, and
//    • effect-return voices — each effect whose wet returns to the main, carrying
//      the union of every source that reaches it (directly or up a serial chain).
//  Effects that fold into a downstream effect are not separate voices; their wet
//  is part of the downstream return.
//

import CoreGraphics
import Foundation

/// A positionable element of an environment, derived from its routing graph.
struct EnvironmentVoice: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// An instrument's own (dry) signal.
        case source
        /// An effect's processed return, summing every source that feeds it.
        case effectReturn
    }

    var id: String
    var kind: Kind
    /// The voice's primary label (instrument or effect name).
    var name: String
    /// Names of the instruments this voice carries. One for a dry source; one or
    /// more for an effect return (more than one means a shared effect).
    var sourceNames: [String]
    /// The WING channel(s) carrying this voice.
    var channels: [Int]
    var isStereo: Bool

    /// Whether this voice bundles more than one instrument (a shared effect),
    /// whose members therefore can't be placed independently.
    var isShared: Bool { kind == .effectReturn && sourceNames.count > 1 }

    /// A short description of the instruments carried, e.g. "Moog + Juno".
    var sourcesLabel: String { sourceNames.joined(separator: " + ") }

    /// Builds a `SpatialSource` for this voice at `position`/`width`, reusing the
    /// shared stereo-spread and panning math. Returns nil if the voice has no
    /// channels (e.g. a capacity-exhausted effect with no return).
    func spatialSource(position: CGPoint, width: Double) -> SpatialSource? {
        guard let first = channels.first else { return nil }
        let stereo = isStereo && channels.count > 1
        return SpatialSource(
            name: name,
            mode: stereo ? .stereo : .mono,
            left: .channel(first),
            right: stereo ? .channel(channels[1]) : nil,
            position: position,
            width: width
        )
    }
}

extension EnvironmentVoice {
    /// Prefix tagging a dry-source voice id (followed by the equipment UUID).
    static let sourcePrefix = "source:"
    /// Prefix tagging an effect-return voice id (followed by the effect UUID).
    static let returnPrefix = "return:"

    static func sourceID(_ equipment: Equipment.ID) -> String { sourcePrefix + equipment.uuidString }
    static func returnID(_ effect: Effect.ID) -> String { returnPrefix + effect.uuidString }

    /// Rewrites a return-voice id onto a new effect id using `remap`; source ids
    /// (and anything unrecognised) pass through unchanged. Used when an
    /// environment is duplicated and its effects get fresh identities.
    static func remap(voiceID: String, effects remap: [Effect.ID: Effect.ID]) -> String {
        guard voiceID.hasPrefix(returnPrefix),
              let oldID = UUID(uuidString: String(voiceID.dropFirst(returnPrefix.count))),
              let newID = remap[oldID] else {
            return voiceID
        }
        return returnID(newID)
    }
}

/// A voice paired with its placement in the spatial field. `isPlaced` is false
/// for voices the user hasn't positioned yet — they sit at the default centre
/// and contribute no surround sends until moved.
struct PlacedVoice: Identifiable, Hashable, Sendable {
    var voice: EnvironmentVoice
    var position: CGPoint
    var width: Double
    var isPlaced: Bool

    var id: String { voice.id }
}

enum EnvironmentVoices {
    /// The placeable voices of `environment`, given the channel rig.
    static func voices(
        for environment: RoutingEnvironment,
        assignments: [Equipment.ChannelAssignment]
    ) -> [EnvironmentVoice] {
        let effects = environment.effects
        let allocations = EffectRouting.allocations(for: effects)
        let effectsByID = Dictionary(effects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let assignmentByInstrument = Dictionary(
            assignments.map { ($0.equipment.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        func hasBus(_ id: Effect.ID) -> Bool { !(allocations[id]?.buses.isEmpty ?? true) }

        // The downstream effect a routed effect folds into, mirroring the
        // routing engine's rules (cyclic or capacity-exhausted targets fall back
        // to the main, making this effect a voice root).
        func foldTarget(_ effect: Effect) -> Effect.ID? {
            guard let target = EffectRouting.resolvedDestination(for: effect, effectsByID: effectsByID),
                  hasBus(target.id) else { return nil }
            return target.id
        }

        func root(of effect: Effect) -> Effect.ID {
            var current = effect
            var steps = 0
            while let next = foldTarget(current), let node = effectsByID[next], steps <= effects.count {
                current = node
                steps += 1
            }
            return current.id
        }

        // Accumulate which sources reach each main-returning root.
        var sourcesByRoot: [Effect.ID: Set<Equipment.ID>] = [:]
        for effect in effects where hasBus(effect.id) {
            sourcesByRoot[root(of: effect), default: []].formUnion(effect.sourceInstruments)
        }

        var voices: [EnvironmentVoice] = []

        // Dry source voices: every instrument feeding an effect, in channel order.
        let inPlay = Set(effects.flatMap { $0.sourceInstruments })
        let dryAssignments = inPlay
            .compactMap { assignmentByInstrument[$0] }
            .sorted { $0.leftChannel < $1.leftChannel }
        for assignment in dryAssignments {
            var channels = [assignment.leftChannel]
            if let right = assignment.rightChannel { channels.append(right) }
            voices.append(EnvironmentVoice(
                id: EnvironmentVoice.sourceID(assignment.equipment.id),
                kind: .source,
                name: assignment.equipment.name,
                sourceNames: [assignment.equipment.name],
                channels: channels,
                isStereo: assignment.isStereo
            ))
        }

        // Effect-return voices: each routed effect that returns to the main,
        // carrying the union of every source that reaches it. Effect order is
        // preserved so the preview matches the effect list.
        func names(_ ids: Set<Equipment.ID>) -> [String] {
            ids.compactMap { assignmentByInstrument[$0]?.equipment.name }.sorted()
        }
        for effect in effects where hasBus(effect.id) && foldTarget(effect) == nil {
            let members = sourcesByRoot[effect.id] ?? Set(effect.sourceInstruments)
            voices.append(EnvironmentVoice(
                id: EnvironmentVoice.returnID(effect.id),
                kind: .effectReturn,
                name: effect.name,
                sourceNames: names(members),
                channels: allocations[effect.id]?.returnChannels ?? [],
                isStereo: effect.isStereo
            ))
        }
        return voices
    }
}
