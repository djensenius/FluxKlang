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

    func replaceHome(_ home: StudioHomeConnections, equipment: [Equipment]) async throws {
        var candidate = connections
        candidate.home = home
        try validateTemporaryMoves(in: candidate, equipment: equipment)
        connections = candidate
        await persist()
    }

    func setInput(
        _ connection: StudioInputConnection?,
        connector: Int,
        equipment: [Equipment]
    ) async throws {
        var home = connections.home
        try home.setInput(connection, connector: connector, equipment: equipment)
        var candidate = connections
        candidate.home = home
        try validateTemporaryMoves(in: candidate, equipment: equipment)
        connections = candidate
        await persist()
    }

    func setOutput(
        _ connection: StudioOutputConnection?,
        connector: Int,
        equipment: [Equipment]
    ) async throws {
        var home = connections.home
        try home.setOutput(connection, connector: connector, equipment: equipment)
        var candidate = connections
        candidate.home = home
        try validateTemporaryMoves(in: candidate, equipment: equipment)
        connections = candidate
        await persist()
    }

    func activateTemporaryMove(
        _ move: TemporaryDeviceMove,
        equipment: [Equipment]
    ) async throws {
        try TemporaryMoveAllocator.validate(
            move,
            home: connections.home,
            equipment: equipment,
            existingMoves: connections.temporaryMoves
        )
        connections.temporaryMoves.removeAll { $0.id == move.id || $0.equipmentID == move.equipmentID }
        connections.temporaryMoves.append(move)
        await persist()
    }

    func reserveTemporaryMove(
        _ move: TemporaryDeviceMove,
        equipment: [Equipment]
    ) async throws {
        try TemporaryMoveAllocator.validate(
            move,
            home: connections.home,
            equipment: equipment,
            existingMoves: connections.temporaryMoves
        )
        connections.temporaryMoves.removeAll { $0.id == move.id || $0.equipmentID == move.equipmentID }
        connections.temporaryMoves.append(move.preparingApply())
        await persist()
    }

    func updateTemporaryMove(_ move: TemporaryDeviceMove) async {
        guard let index = connections.temporaryMoves.firstIndex(where: { $0.id == move.id }) else { return }
        connections.temporaryMoves[index] = move
        await persist()
    }

    func removeTemporaryMove(_ id: TemporaryDeviceMove.ID) async {
        connections.temporaryMoves.removeAll { $0.id == id }
        await persist()
    }

    private func validateTemporaryMoves(
        in candidate: GlobalStudioConnections,
        equipment: [Equipment]
    ) throws {
        guard !candidate.temporaryMoves.isEmpty else { return }
        for move in candidate.temporaryMoves {
            let homeInputPorts = Set(candidate.home.inputs.filter {
                $0.equipmentID == move.equipmentID
            }.map(\.outputPort))
            let moveInputPorts = Set(move.connections.inputs.map(\.outputPort))
            let homeOutputPorts = Set(candidate.home.outputs.filter {
                $0.equipmentID == move.equipmentID
            }.map(\.inputPort))
            let moveOutputPorts = Set(move.connections.outputs.map(\.inputPort))
            guard homeInputPorts == moveInputPorts, homeOutputPorts == moveOutputPorts else {
                throw StudioConnectionAssignmentError.temporaryMoveConflict(
                    "The moved equipment's Home cable set changed."
                )
            }
            do {
                try TemporaryMoveAllocator.validate(
                    move,
                    home: candidate.home,
                    equipment: equipment,
                    existingMoves: candidate.temporaryMoves
                )
            } catch {
                throw StudioConnectionAssignmentError.temporaryMoveConflict(error.localizedDescription)
            }
        }
        if let issue = StudioPhysicalResolver(
            connections: candidate.effectiveHome,
            equipment: equipment
        ).structuralIssues().first {
            throw StudioConnectionAssignmentError.temporaryMoveConflict(issue.message)
        }
    }

    private func persist() async {
        await fileStore.save(Persisted(connections: connections, initialized: true), to: fileName)
    }
}
