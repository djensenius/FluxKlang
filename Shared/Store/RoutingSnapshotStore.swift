//
//  RoutingSnapshotStore.swift
//  FluxKlang
//
//  Owns named "routing snapshots" — the Flock PATCH-style capture of the whole
//  patchbay (channel input patches + physical output source patches) that can be
//  recalled instantly. Kept separate from mixer presets so a snapshot recalls
//  only routing, never fader levels or mutes. Persisted (and iCloud-synced) via
//  the shared JSON store, reusing the `Preset` value type.
//

import Foundation
import Observation

@MainActor
@Observable
final class RoutingSnapshotStore {
    private(set) var snapshots: [Preset] = []

    private let fileName = "routing_snapshots.json"
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
            snapshots = saved
        }
    }

    /// Re-reads the persisted snapshots, picking up changes synced from iCloud.
    func reload() async {
        loaded = false
        await load()
    }

    func add(_ snapshot: Preset) {
        snapshots.append(snapshot)
        persist()
    }

    func update(_ snapshot: Preset) {
        guard let index = snapshots.firstIndex(where: { $0.id == snapshot.id }) else { return }
        snapshots[index] = snapshot
        persist()
    }

    func remove(at offsets: IndexSet) {
        snapshots.remove(atOffsets: offsets)
        persist()
    }

    func remove(_ snapshot: Preset) {
        snapshots.removeAll { $0.id == snapshot.id }
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
        let snapshot = snapshots
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
