//
//  EquipmentStore.swift
//  FluxKlang
//
//  Owns the user-editable equipment library used by the chain builder. Seeded
//  with the user's known gear on first run.
//

import Foundation
import Observation

@MainActor
@Observable
final class EquipmentStore {
    private(set) var items: [Equipment] = Equipment.seededLibrary

    private let fileName = "equipment.json"
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
        if let saved = await store.load([Equipment].self, from: fileName) {
            items = saved
        }
        mergeConfirmedLiveEquipment()
    }

    /// Re-reads the persisted library, picking up changes synced from iCloud.
    func reload() async {
        loaded = false
        await load()
    }

    func item(_ id: Equipment.ID) -> Equipment? {
        items.first { $0.id == id }
    }

    func add(_ equipment: Equipment) {
        items.append(equipment)
        persist()
    }

    func update(_ equipment: Equipment) {
        guard let index = items.firstIndex(where: { $0.id == equipment.id }) else { return }
        items[index] = equipment
        persist()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        persist()
    }

    func remove(_ equipment: Equipment) {
        items.removeAll { $0.id == equipment.id }
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
        let snapshot = items
        let fileName = fileName
        let injectedStore = injectedStore
        let previousTail = saveTail
        saveTail = Task {
            await previousTail?.value
            let store = injectedStore ?? JSONFileStore.shared
            await store.save(snapshot, to: fileName)
        }
    }

    private func mergeConfirmedLiveEquipment() {
        let existingNames = Set(items.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let additions = Equipment.confirmedLiveAdditions.filter { addition in
            !items.contains(where: { $0.id == addition.id })
                && !existingNames.contains(addition.name.lowercased())
        }
        guard !additions.isEmpty else { return }
        items.append(contentsOf: additions)
        persist()
    }
}
