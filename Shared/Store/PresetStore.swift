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
    private let injectedStore: JSONFileStore?
    private var loaded = false
    @ObservationIgnored private var saveTail: Task<Void, Never>?

    init(store: JSONFileStore? = nil) {
        injectedStore = store
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        let store = injectedStore ?? JSONFileStore.shared
        if let saved = await store.load([Preset].self, from: fileName) {
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

    /// Awaits the tail captured when this MainActor method begins, including its predecessors.
    /// Does not await later producers, establish all-producer quiescence, coalesce concurrent
    /// loads, or guarantee durable persistence success: JSON saves are best-effort.
    /// Cancelling the waiter does not cancel the save chain.
    func awaitScheduledSavesSnapshot() async {
        let tail = saveTail
        await tail?.value
    }

    private func persist() {
        let snapshot = presets
        let fileName = fileName
        let injectedStore = injectedStore
        let previousTail = saveTail
        saveTail = Task {
            await previousTail?.value
            let store = injectedStore ?? JSONFileStore.shared
            await store.save(snapshot, to: fileName)
        }
    }
}
