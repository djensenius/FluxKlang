//
//  StudioConnectionsStore.swift
//  FluxKlang
//
//  Persists the single global Home wiring map. On first initialization only, it
//  conservatively imports the first meaningful legacy per-environment setup.
//

import Foundation
import Observation

@MainActor
@Observable
final class StudioConnectionsStore {
    private(set) var connections = GlobalStudioConnections()

    struct Persisted: Codable, Sendable {
        var connections: GlobalStudioConnections
        var initialized: Bool?
    }

    private let fileStore: JSONFileStore
    private let fileName: String
    private var loaded = false

    init(
        fileStore: JSONFileStore = .shared,
        fileName: String = "studio-connections.json"
    ) {
        self.fileStore = fileStore
        self.fileName = fileName
    }

    func load(
        equipment: [Equipment],
        environments: [RoutingEnvironment],
        activeID: RoutingEnvironment.ID?
    ) async {
        guard !loaded else { return }
        loaded = true
        if let saved = await fileStore.load(Persisted.self, from: fileName) {
            connections = saved.connections
            let initialized = saved.initialized ?? !saved.connections.isEmpty
            if !initialized, saved.connections.isEmpty {
                connections = .migratingLegacy(
                    environments: environments,
                    activeID: activeID,
                    equipment: equipment
                )
                await persist()
            }
        } else {
            connections = .migratingLegacy(
                environments: environments,
                activeID: activeID,
                equipment: equipment
            )
            await persist()
        }
    }

    func reload(
        equipment: [Equipment],
        environments: [RoutingEnvironment],
        activeID: RoutingEnvironment.ID?
    ) async {
        loaded = false
        await load(equipment: equipment, environments: environments, activeID: activeID)
    }

    func replaceHome(_ home: StudioHomeConnections) async {
        connections.home = home
        await persist()
    }

    private func persist() async {
        await fileStore.save(Persisted(connections: connections, initialized: true), to: fileName)
    }
}
