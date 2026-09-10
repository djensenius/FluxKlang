//
//  StudioConnectionEditing.swift
//  FluxKlang
//
//  Presentation and safe mutation helpers for the global Home connection map.
//

import Foundation

enum StudioConnectionAssignmentError: LocalizedError, Equatable {
    case invalidInputConnector(Int)
    case invalidOutputConnector(Int)
    case missingEquipment
    case invalidEquipmentOutput
    case invalidEquipmentInput
    case equipmentOutputInUse(String, String, Int)
    case equipmentInputInUse(String, String, Int)
    case temporaryMoveConflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputConnector(let connector):
            return "WING input \(connector) is outside 1...24."
        case .invalidOutputConnector(let connector):
            return "WING output \(connector) is outside 1...8."
        case .missingEquipment:
            return "The selected equipment no longer exists."
        case .invalidEquipmentOutput:
            return "The selected equipment output no longer exists."
        case .invalidEquipmentInput:
            return "The selected equipment input no longer exists."
        case .equipmentOutputInUse(let equipment, let port, let connector):
            return "\(equipment) · \(port) is already assigned to WING input \(connector)."
        case .equipmentInputInUse(let equipment, let port, let connector):
            return "\(equipment) · \(port) is already assigned to WING output \(connector)."
        case .temporaryMoveConflict(let message):
            return "Return affected equipment Home before changing this assignment. \(message)"
        }
    }
}

extension StudioHomeConnections {
    func input(_ connector: Int) -> StudioInputConnection? {
        inputs.first { $0.connector == connector }
    }

    func output(_ connector: Int) -> StudioOutputConnection? {
        outputs.first { $0.connector == connector }
    }

    func inputFriendlyName(
        _ connector: Int,
        equipment: [Equipment],
        liveScribble: String? = nil
    ) -> String? {
        if let connection = input(connector) {
            return connection.label(equipment: equipment)
        }
        let scribble = liveScribble?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return scribble.isEmpty ? nil : scribble
    }

    func outputFriendlyName(_ connector: Int, equipment: [Equipment]) -> String? {
        output(connector)?.label(equipment: equipment)
    }

    func inputDisplayName(
        _ connector: Int,
        equipment: [Equipment],
        liveScribble: String? = nil
    ) -> String {
        connectorDisplayName(
            kind: "Input",
            connector: connector,
            friendlyName: inputFriendlyName(connector, equipment: equipment, liveScribble: liveScribble)
        )
    }

    func outputDisplayName(_ connector: Int, equipment: [Equipment]) -> String {
        connectorDisplayName(
            kind: "Output",
            connector: connector,
            friendlyName: outputFriendlyName(connector, equipment: equipment)
        )
    }

    mutating func setInput(
        _ connection: StudioInputConnection?,
        connector: Int,
        equipment: [Equipment]
    ) throws {
        guard Self.inputRange.contains(connector) else {
            throw StudioConnectionAssignmentError.invalidInputConnector(connector)
        }
        guard var connection else {
            inputs.removeAll { $0.connector == connector }
            return
        }
        connection.connector = connector
        guard let device = equipment.first(where: { $0.id == connection.equipmentID }) else {
            throw StudioConnectionAssignmentError.missingEquipment
        }
        guard device.outputs.indices.contains(connection.outputPort) else {
            throw StudioConnectionAssignmentError.invalidEquipmentOutput
        }
        if let existing = inputs.first(where: {
            $0.connector != connector
                && $0.equipmentID == connection.equipmentID
                && $0.outputPort == connection.outputPort
        }) {
            throw StudioConnectionAssignmentError.equipmentOutputInUse(
                device.name,
                device.outputs[connection.outputPort],
                existing.connector
            )
        }
        inputs.removeAll { $0.connector == connector }
        inputs.append(connection)
        inputs.sort { $0.connector < $1.connector }
    }

    mutating func setOutput(
        _ connection: StudioOutputConnection?,
        connector: Int,
        equipment: [Equipment]
    ) throws {
        guard Self.outputRange.contains(connector) else {
            throw StudioConnectionAssignmentError.invalidOutputConnector(connector)
        }
        guard var connection else {
            outputs.removeAll { $0.connector == connector }
            return
        }
        connection.connector = connector
        guard let device = equipment.first(where: { $0.id == connection.equipmentID }) else {
            throw StudioConnectionAssignmentError.missingEquipment
        }
        guard device.inputs.indices.contains(connection.inputPort) else {
            throw StudioConnectionAssignmentError.invalidEquipmentInput
        }
        if let existing = outputs.first(where: {
            $0.connector != connector
                && $0.equipmentID == connection.equipmentID
                && $0.inputPort == connection.inputPort
        }) {
            throw StudioConnectionAssignmentError.equipmentInputInUse(
                device.name,
                device.inputs[connection.inputPort],
                existing.connector
            )
        }
        outputs.removeAll { $0.connector == connector }
        outputs.append(connection)
        outputs.sort { $0.connector < $1.connector }
    }

    private func connectorDisplayName(kind: String, connector: Int, friendlyName: String?) -> String {
        guard let friendlyName else { return "\(kind) \(connector)" }
        return "\(kind) \(connector) · \(friendlyName)"
    }
}
