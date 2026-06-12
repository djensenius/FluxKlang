//
//  RoutingEnvironment.swift
//  FluxKlang
//
//  A named, switchable routing setup — think "this song's rig". An environment
//  bundles the outboard effects and how instruments feed them, so a band or
//  soloist can flip between whole configurations with one tap and let FluxKlang
//  push all the WING bus/return/patch plumbing. Effects within an environment
//  may run in parallel or be chained in series (see `EffectRouting`).
//

import Foundation

struct RoutingEnvironment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// The outboard effects in this environment. Order is meaningful: it drives
    /// the automatic bus/return allocation in `EffectRouting`.
    var effects: [Effect]

    init(id: UUID = UUID(), name: String, effects: [Effect] = []) {
        self.id = id
        self.name = name
        self.effects = effects
    }

    /// A deep copy under a new identity, with fresh effect IDs so the duplicate's
    /// internal serial-chain links keep pointing inside the copy rather than at
    /// the original's effects.
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
        return RoutingEnvironment(name: newName, effects: copies)
    }
}
