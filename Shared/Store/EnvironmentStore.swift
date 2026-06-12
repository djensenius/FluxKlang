//
//  EnvironmentStore.swift
//  FluxKlang
//
//  Owns the user's environments — named, switchable routing setups — and which
//  one is active. Each environment carries its outboard effects, spatial
//  placements, and its own drag-and-drop canvas graph. Persisted to disk (and
//  mirrored to iCloud) so a performer's per-song rigs survive across launches and
//  devices. On first run it migrates any legacy single effects list
//  (`effects.json`) into a "Default" environment and folds the old single global
//  canvas (`chain.json`) into the active environment's graph.
//

import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class EnvironmentStore {
    private(set) var environments: [RoutingEnvironment] = []
    private(set) var activeID: RoutingEnvironment.ID?

    private let fileName = "environments.json"
    private let legacyFileName = "effects.json"
    private let legacyChainFileName = "chain.json"
    private var loaded = false
    /// Whether the one-time fold of the old global `chain.json` into the active
    /// environment's graph has happened. Persisted so it runs at most once.
    private var migratedChain = false

    private struct Persisted: Codable, Sendable {
        var environments: [RoutingEnvironment]
        var activeID: RoutingEnvironment.ID?
        var migratedChain: Bool?
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
            migratedChain = saved.migratedChain ?? false
        } else if let legacy = await JSONFileStore.shared.load([Effect].self, from: legacyFileName) {
            let migrated = RoutingEnvironment(name: "Default", effects: legacy)
            environments = [migrated]
            activeID = migrated.id
            persist()
        }
        normalizeActive()
        await migrateLegacyChainIfNeeded()
    }

    /// One-time fold of the old single global `chain.json` into the active
    /// environment's graph, so the per-environment canvas inherits whatever the
    /// user had wired before environments owned their own graphs. Runs only when
    /// the active environment has no graph yet, so it never clobbers newer work.
    private func migrateLegacyChainIfNeeded() async {
        guard !migratedChain else { return }
        if let legacy = await JSONFileStore.shared.load(ChainGraph.self, from: legacyChainFileName),
           !legacy.nodes.isEmpty,
           let index = activeIndex(),
           environments[index].graph.nodes.isEmpty {
            environments[index].graph = legacy
        }
        migratedChain = true
        persist()
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

    // MARK: - Active-environment spatial placement

    /// The saved placement of a voice in the active environment, if positioned.
    func placement(for voiceID: String) -> VoicePlacement? {
        active?.placements[voiceID]
    }

    /// Positions a voice in the active environment, creating its placement on
    /// first move so it begins contributing surround sends.
    func setVoicePosition(_ voiceID: String, to position: CGPoint) {
        mutateEnvironment { environment in
            var placement = environment.placements[voiceID] ?? VoicePlacement()
            placement.position = Self.clamp(position)
            environment.placements[voiceID] = placement
        }
    }

    /// Sets a voice's stereo spread in the active environment.
    func setVoiceWidth(_ voiceID: String, to width: Double) {
        mutateEnvironment { environment in
            var placement = environment.placements[voiceID] ?? VoicePlacement()
            placement.width = min(max(width, 0), 1)
            environment.placements[voiceID] = placement
        }
    }

    /// Removes a voice's placement, so it no longer contributes surround sends.
    func clearPlacement(_ voiceID: String) {
        mutateEnvironment { $0.placements[voiceID] = nil }
    }

    // MARK: - Active-environment canvas graph

    /// The active environment's signal-chain graph (empty if there is none yet).
    var activeGraph: ChainGraph { active?.graph ?? ChainGraph() }

    /// The WING settings implied by the active environment's canvas wiring.
    func chainWingSettings() -> [WingSetting] { active?.graph.wingSettings() ?? [] }

    func addChainNode(_ node: ChainNode) {
        mutateGraph { $0.addNode(node) }
    }

    func moveChainNode(_ id: ChainNode.ID, to position: CGPoint) {
        mutateGraph { $0.moveNode(id, to: position) }
    }

    func removeChainNode(_ id: ChainNode.ID) {
        mutateGraph { $0.removeNode(id) }
    }

    func connectChain(from origin: ChainPortRef, to destination: ChainPortRef) {
        mutateGraph { $0.connect(from: origin, to: destination) }
    }

    func removeChainEdge(_ id: ChainEdge.ID) {
        mutateGraph { $0.removeEdge(id) }
    }

    // MARK: - Active-environment effect overlay

    /// The canvas positions of the active environment's effect-overlay nodes.
    var activeEffectLayout: [String: CGPoint] { active?.effectLayout ?? [:] }

    /// Replaces the active environment's effects wholesale. Used by the canvas
    /// reconciler, which computes the new list from a dropped or deleted wire, so
    /// wiring on the canvas and ticking boxes in the list edit the same effects.
    func setActiveEffects(_ effects: [Effect]) {
        mutateEffects { $0 = effects }
    }

    /// Positions an effect-overlay node (an effect, an instrument source, or the
    /// Main) on the canvas.
    func setEffectNodePosition(_ key: String, to position: CGPoint) {
        mutateEnvironment { $0.effectLayout[key] = position }
    }

    /// Drops an instrument-source node on the canvas so it can be wired to an
    /// effect even before it feeds anything, placed below the sources already
    /// shown.
    func addEffectSourceNode(_ instrument: Equipment.ID) {
        let shown = EnvironmentChainCanvas.sourceInstruments(
            effects: activeEffects, layout: activeEffectLayout
        ).count
        setEffectNodePosition(
            EnvironmentChainCanvas.sourceKey(instrument),
            to: EnvironmentChainCanvas.defaultSourcePosition(index: shown)
        )
    }

    /// Forgets an effect-overlay node's saved position. For an unwired source
    /// node this also removes it from the canvas (its presence was the entry).
    func removeEffectLayoutEntry(_ key: String) {
        mutateEnvironment { $0.effectLayout[key] = nil }
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

    /// Guarantees there is an active environment (so wiring on the canvas always
    /// has somewhere to live), then runs `transform` on its graph and persists.
    private func mutateGraph(_ transform: (inout ChainGraph) -> Void) {
        ensureEnvironment()
        guard let index = activeIndex() else { return }
        transform(&environments[index].graph)
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
        let snapshot = Persisted(environments: environments, activeID: activeID, migratedChain: migratedChain)
        Task { await JSONFileStore.shared.save(snapshot, to: fileName) }
    }

    private static func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}
