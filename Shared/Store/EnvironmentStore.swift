//
//  EnvironmentStore.swift
//  FluxKlang
//
//  Owns the user's environments — named, switchable routing setups — and which
//  one is active. Persisted to disk (and mirrored to iCloud) so a performer's
//  per-song rigs survive across launches and devices. On first run it migrates
//  any legacy single effects list (`effects.json`) into a "Default" environment.
//

import Foundation
import Observation

@MainActor
@Observable
final class EnvironmentStore {
    private(set) var environments: [RoutingEnvironment] = []
    private(set) var activeID: RoutingEnvironment.ID?

    private let fileName = "environments.json"
    private let legacyFileName = "effects.json"
    private var loaded = false

    private struct Persisted: Codable, Sendable {
        var environments: [RoutingEnvironment]
        var activeID: RoutingEnvironment.ID?
    }

    // MARK: - Active environment

    /// The active environment, falling back to the first if the stored id is
    /// stale or unset.
    var active: RoutingEnvironment? {
        if let activeID, let match = environments.first(where: { $0.id == activeID }) {
            return match
        }
        return environments.first
    }

    /// The effects belonging to the active environment.
    var activeEffects: [Effect] { active?.effects ?? [] }

    // MARK: - Loading

    func load() async {
        guard !loaded else { return }
        loaded = true
        if let saved = await JSONFileStore.shared.load(Persisted.self, from: fileName) {
            environments = saved.environments
            activeID = saved.activeID
        } else if let legacy = await JSONFileStore.shared.load([Effect].self, from: legacyFileName) {
            let migrated = RoutingEnvironment(name: "Default", effects: legacy)
            environments = [migrated]
            activeID = migrated.id
            persist()
        }
        normalizeActive()
    }

    /// Re-reads the persisted environments, picking up changes synced from iCloud.
    func reload() async {
        loaded = false
        await load()
    }

    // MARK: - RoutingEnvironment CRUD

    @discardableResult
    func addEnvironment(named name: String) -> RoutingEnvironment.ID {
        let environment = RoutingEnvironment(name: name)
        environments.append(environment)
        activeID = environment.id
        persist()
        return environment.id
    }

    func renameActive(to name: String) {
        mutateEnvironment { $0.name = name }
    }

    @discardableResult
    func duplicateActive() -> RoutingEnvironment.ID? {
        guard let current = active else { return nil }
        let copy = current.duplicated(named: "\(current.name) Copy")
        environments.append(copy)
        activeID = copy.id
        persist()
        return copy.id
    }

    func removeActive() {
        guard let current = active else { return }
        environments.removeAll { $0.id == current.id }
        activeID = environments.first?.id
        persist()
    }

    func remove(_ id: RoutingEnvironment.ID) {
        environments.removeAll { $0.id == id }
        if activeID == id { activeID = environments.first?.id }
        persist()
    }

    func setActive(_ id: RoutingEnvironment.ID) {
        guard environments.contains(where: { $0.id == id }) else { return }
        activeID = id
        persist()
    }

    // MARK: - Active-environment effect CRUD

    func effect(_ id: Effect.ID) -> Effect? {
        active?.effects.first { $0.id == id }
    }

    func add(_ effect: Effect) {
        mutateEffects { $0.append(effect.normalizingJacks()) }
    }

    func update(_ effect: Effect) {
        mutateEffects { effects in
            guard let index = effects.firstIndex(where: { $0.id == effect.id }) else { return }
            effects[index] = effect.normalizingJacks()
        }
    }

    func remove(at offsets: IndexSet) {
        mutateEffects { $0.remove(atOffsets: offsets) }
    }

    func remove(_ effect: Effect) {
        mutateEffects { effects in
            effects.removeAll { $0.id == effect.id }
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        mutateEffects { $0.move(fromOffsets: source, toOffset: destination) }
    }

    // MARK: - Internals

    /// Guarantees there is an active environment, creating a "Default" one when
    /// the store is empty, then runs `transform` on the active environment's
    /// effects and persists.
    private func mutateEffects(_ transform: (inout [Effect]) -> Void) {
        ensureEnvironment()
        guard let index = activeIndex() else { return }
        transform(&environments[index].effects)
        persist()
    }

    /// Runs `transform` on the active environment itself (e.g. to rename it).
    private func mutateEnvironment(_ transform: (inout RoutingEnvironment) -> Void) {
        guard let index = activeIndex() else { return }
        transform(&environments[index])
        persist()
    }

    private func activeIndex() -> Int? {
        guard let id = active?.id else { return nil }
        return environments.firstIndex { $0.id == id }
    }

    /// Creates a starter environment if none exist, so the UI always has an
    /// active environment to edit.
    private func ensureEnvironment() {
        guard environments.isEmpty else { return }
        let environment = RoutingEnvironment(name: "Default")
        environments = [environment]
        activeID = environment.id
    }

    /// Points `activeID` at a real environment after loading.
    private func normalizeActive() {
        if let activeID, environments.contains(where: { $0.id == activeID }) { return }
        activeID = environments.first?.id
    }

    private func persist() {
        let snapshot = Persisted(environments: environments, activeID: activeID)
        Task { await JSONFileStore.shared.save(snapshot, to: fileName) }
    }
}
