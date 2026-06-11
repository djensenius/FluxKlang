//
//  PresetStore.swift
//  FluxKlang
//
//  Owns named snapshots of WING settings (routing + fader levels) that can be
//  recalled with one tap.
//

import Foundation
import Observation

@MainActor
@Observable
final class PresetStore {
    private(set) var presets: [Preset] = []

    private let fileName = "presets.json"
    private var loaded = false

    func load() async {
        guard !loaded else { return }
        loaded = true
        if let saved = await JSONFileStore.shared.load([Preset].self, from: fileName) {
            presets = saved
        }
    }

    /// Re-reads the persisted presets, picking up changes synced from iCloud.
    func reload() async {
        loaded = false
        await load()
    }

    func add(_ preset: Preset) {
        presets.append(preset)
        persist()
    }

    func update(_ preset: Preset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        persist()
    }

    func remove(at offsets: IndexSet) {
        presets.remove(atOffsets: offsets)
        persist()
    }

    func remove(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        let snapshot = presets
        Task { await JSONFileStore.shared.save(snapshot, to: fileName) }
    }
}
