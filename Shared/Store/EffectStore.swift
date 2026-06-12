//
//  EffectStore.swift
//  FluxKlang
//
//  Owns the user's effects: outboard processors wired into the WING that
//  instruments can be sent to. Persisted to disk (and mirrored to iCloud) so the
//  user's "these effects get these instruments" setup survives across launches.
//  Effect order is meaningful — it drives the automatic bus/return allocation in
//  `EffectRouting` — so reordering is supported.
//

import Foundation
import Observation

@MainActor
@Observable
final class EffectStore {
    private(set) var effects: [Effect] = []

    private let fileName = "effects.json"
    private var loaded = false

    func load() async {
        guard !loaded else { return }
        loaded = true
        if let saved = await JSONFileStore.shared.load([Effect].self, from: fileName) {
            effects = saved
        }
    }

    /// Re-reads the persisted effects, picking up changes synced from iCloud.
    func reload() async {
        loaded = false
        await load()
    }

    func effect(_ id: Effect.ID) -> Effect? {
        effects.first { $0.id == id }
    }

    func add(_ effect: Effect) {
        effects.append(effect.normalizingJacks())
        persist()
    }

    func update(_ effect: Effect) {
        guard let index = effects.firstIndex(where: { $0.id == effect.id }) else { return }
        effects[index] = effect.normalizingJacks()
        persist()
    }

    func remove(at offsets: IndexSet) {
        effects.remove(atOffsets: offsets)
        persist()
    }

    func remove(_ effect: Effect) {
        effects.removeAll { $0.id == effect.id }
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        effects.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        let snapshot = effects
        Task { await JSONFileStore.shared.save(snapshot, to: fileName) }
    }
}
