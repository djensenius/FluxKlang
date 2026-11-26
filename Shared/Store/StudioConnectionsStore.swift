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
        var confirmedOutputDefaultsVersion: Int?
    }

    private let fileStore: JSONFileStore
    private let fileName: String
    private let outputDefaults: StudioOutputDefaults?
    private var loaded = false
    private var confirmedOutputDefaultsVersion = 0
    /// Saved environments are held (#943). While set, Home is neither initialized, migrated nor written;
    /// mutations, including temporary moves, are refused and current connections are retained. Cleared by
    /// the next `load`/`reload` after recovery.
    private(set) var isHeldForEnvironments = false

    init(
        fileStore: JSONFileStore = .shared,
        fileName: String = "studio-connections.json",
        outputDefaults: StudioOutputDefaults? = .bundled()
    ) {
        self.fileStore = fileStore
        self.fileName = fileName
        self.outputDefaults = outputDefaults
    }

    func load(
        equipment: [Equipment],
        environments: [RoutingEnvironment],
        activeID: RoutingEnvironment.ID?
    ) async {
        guard !loaded else { return }
        loaded = true
        isHeldForEnvironments = false
        if let saved = await fileStore.load(Persisted.self, from: fileName) {
            connections = saved.connections
            confirmedOutputDefaultsVersion = saved.confirmedOutputDefaultsVersion ?? 0
            let initialized = saved.initialized ?? !saved.connections.isEmpty
            if !initialized, saved.connections.isEmpty {
                connections = .migratingLegacy(
                    environments: environments,
                    activeID: activeID,
                    equipment: equipment
                )
            }
        } else {
            connections = .migratingLegacy(
                environments: environments,
                activeID: activeID,
                equipment: equipment
            )
        }
        connections.home.removeOutOfRangeLegacyInputs()
        if let outputDefaults,
           confirmedOutputDefaultsVersion < outputDefaults.version {
            connections.home.applyConfirmedOutputDefaults(outputDefaults, equipment: equipment)
            confirmedOutputDefaultsVersion = outputDefaults.version
        }
        await persist()
    }

    func reload(
        equipment: [Equipment],
        environments: [RoutingEnvironment],
        activeID: RoutingEnvironment.ID?
    ) async {
        loaded = false
        await load(equipment: equipment, environments: environments, activeID: activeID)
    }

    /// Called instead of `load`/`reload` while environments are held, at startup or after a later reload.
    func holdForUnavailableEnvironments() {
        isHeldForEnvironments = true
    }

    func replaceHome(_ home: StudioHomeConnections, equipment: [Equipment]) async throws {
        try refuseWhileHeld()
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
        try refuseWhileHeld()
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
        bank: WingOutputConnectorBank = .local,
        equipment: [Equipment]
    ) async throws {
        try refuseWhileHeld()
        var home = connections.home
        try home.setOutput(connection, connector: connector, bank: bank, equipment: equipment)
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
        try refuseWhileHeld()
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
        try refuseWhileHeld()
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
        guard !isHeldForEnvironments,
              let index = connections.temporaryMoves.firstIndex(where: { $0.id == move.id }) else { return }
        connections.temporaryMoves[index] = move
        await persist()
    }

    func removeTemporaryMove(_ id: TemporaryDeviceMove.ID) async {
        guard !isHeldForEnvironments else { return }
        connections.temporaryMoves.removeAll { $0.id == id }
        await persist()
    }

    private func refuseWhileHeld() throws {
        if isHeldForEnvironments { throw StudioConnectionAssignmentError.environmentsUnavailable }
    }

    private func validateTemporaryMoves(
        in candidate: GlobalStudioConnections,
        equipment: [Equipment]
    ) throws {
        guard !candidate.temporaryMoves.isEmpty else { return }
        for move in candidate.temporaryMoves where move.lifecycle.isEffective {
            let homeInputPorts = Set(candidate.home.inputs.filter {
                $0.equipmentID == move.equipmentID
            }.map(\.outputPort))
            let moveInputPorts = Set(move.connections.inputs.map(\.outputPort))
            let homeOutputPorts = Set(candidate.home.outputs.filter {
                $0.equipmentID == move.equipmentID
            }.compactMap(\.inputPort))
            let moveOutputPorts = Set(move.connections.outputs.compactMap(\.inputPort))
            guard homeInputPorts == moveInputPorts, homeOutputPorts == moveOutputPorts else {
                let equipmentName = equipment.first { $0.id == move.equipmentID }?.name
                    ?? "Moved equipment"
                throw StudioConnectionAssignmentError.temporaryMoveConflict(
                    "\(equipmentName)'s Home cable set changed."
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
        guard !isHeldForEnvironments else { return }
        await fileStore.save(
            Persisted(
                connections: connections,
                initialized: true,
                confirmedOutputDefaultsVersion: confirmedOutputDefaultsVersion
            ),
            to: fileName
        )
    }
}
