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
    private var loaded = false

    func load() async {
        guard !loaded else { return }
        loaded = true
        if let saved = await JSONFileStore.shared.load([Equipment].self, from: fileName) {
            items = saved
        }
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

    private func persist() {
        let snapshot = items
        Task { await JSONFileStore.shared.save(snapshot, to: fileName) }
    }
}
