//
//  StudioConnectionEditing.swift
//  FluxKlang
//
//  Presentation and safe mutation helpers for the global Home connection map.
//

import Foundation

extension StudioHomeConnections {
    mutating func removeOutOfRangeLegacyInputs() {
        inputs.removeAll { !Self.inputRange.contains($0.connector) }
    }
}

extension GlobalStudioConnections {
    /// Legacy name-driven preview retained for migration/regression callers only.
    /// Runtime Home, Studio compilation and assistant grounding must not use it.
    func reconcilingLiveInputNames(
        _ liveNames: [Int: String],
        equipment: [Equipment]
    ) -> GlobalStudioConnections {
        let matches = liveNames.compactMap { connector, label -> (Int, Equipment)? in
            guard StudioHomeConnections.inputRange.contains(connector) else { return nil }
            let candidates = equipment.filter { liveLabel(label, matches: $0.name) }
            guard candidates.count == 1 else { return nil }
            return (connector, candidates[0])
        }
        let grouped = Dictionary(grouping: matches, by: { $0.1.id })
        guard !grouped.isEmpty else { return self }

        var reconciled = self
        let matchedEquipmentIDs = Set(grouped.keys)
        let matchedConnectors = Set(matches.map(\.0))
        reconciled.home.inputs.removeAll {
            matchedEquipmentIDs.contains($0.equipmentID) || matchedConnectors.contains($0.connector)
        }
        for (equipmentID, entries) in grouped {
            guard let device = equipment.first(where: { $0.id == equipmentID }) else { continue }
            let connectors = entries.map(\.0).sorted().prefix(device.outputs.count)
            for (outputPort, connector) in connectors.enumerated() {
                let existing = home.inputs.first {
                    $0.equipmentID == equipmentID && $0.outputPort == outputPort
                }
                reconciled.home.inputs.append(StudioInputConnection(
                    id: existing?.id ?? UUID(),
                    connector: connector,
                    equipmentID: equipmentID,
                    outputPort: outputPort,
                    labelOverride: existing?.labelOverride
                ))
            }
        }
        reconciled.home.inputs.sort { ($0.connector, $0.outputPort) < ($1.connector, $1.outputPort) }
        return reconciled
    }

    private func liveLabel(_ label: String, matches equipmentName: String) -> Bool {
        let equipment = normalizedName(equipmentName)
        return liveLabelVariants(label).contains {
            !$0.isEmpty && (equipment == $0 || equipment.hasPrefix($0) || equipment.hasSuffix($0))
        }
    }

    private func liveLabelVariants(_ label: String) -> Set<String> {
        let tokens = label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var variants = Set([tokens.joined()])
        if let last = tokens.last, ["l", "r", "left", "right"].contains(last) {
            variants.insert(tokens.dropLast().joined())
        }
        return variants
    }

    private func normalizedName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

enum StudioConnectionAssignmentError: LocalizedError, Equatable {
    case invalidInputConnector(Int)
    case invalidOutputConnector(Int)
    case invalidBankOutputConnector(WingOutputConnectorBank, Int)
    case missingEquipment
    case invalidEquipmentOutput
    case invalidEquipmentInput
    case equipmentOutputInUse(String, String, Int)
    case equipmentInputInUse(String, String, WingOutputConnector)
    case temporaryMoveConflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputConnector(let connector):
            return "WING input \(connector) is outside 1...24."
        case .invalidOutputConnector(let connector):
            return "WING output \(connector) is outside 1...8."
        case .invalidBankOutputConnector(let bank, let connector):
            return "\(bank.label) output \(connector) is outside "
                + "\(bank.connectorRange.lowerBound)...\(bank.connectorRange.upperBound)."
        case .missingEquipment:
            return "The selected equipment no longer exists."
        case .invalidEquipmentOutput:
            return "The selected equipment output no longer exists. Reselect an available output."
        case .invalidEquipmentInput:
            return "The selected equipment input no longer exists. Reselect an available input."
        case .equipmentOutputInUse(let equipment, let port, let connector):
            return "\(equipment) · \(port) is already assigned to WING input \(connector)."
        case .equipmentInputInUse(let equipment, let port, let connector):
            return "\(equipment) · \(port) is already assigned to \(connector.label)."
        case .temporaryMoveConflict(let message):
            return "Return affected equipment Home before changing this assignment. \(message)"
        }
    }
}

extension StudioHomeConnections {
    func input(_ connector: Int) -> StudioInputConnection? {
        inputs.first { $0.connector == connector }
    }

    func output(
        _ connector: Int,
        bank: WingOutputConnectorBank = .local
    ) -> StudioOutputConnection? {
        outputs.first { $0.bank == bank && $0.connector == connector }
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

    func outputFriendlyName(
        _ connector: Int,
        bank: WingOutputConnectorBank = .local,
        equipment: [Equipment]
    ) -> String? {
        output(connector, bank: bank)?.label(equipment: equipment)
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

    func outputDisplayName(
        _ connector: Int,
        bank: WingOutputConnectorBank = .local,
        equipment: [Equipment]
    ) -> String {
        let output = WingOutputConnector(bank: bank, index: connector)
        return connectorDisplayName(
            kind: output.label,
            connector: connector,
            includeConnector: false,
            friendlyName: outputFriendlyName(connector, bank: bank, equipment: equipment)
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
        bank: WingOutputConnectorBank = .local,
        equipment: [Equipment]
    ) throws {
        guard bank.connectorRange.contains(connector) else {
            if bank == .local {
                throw StudioConnectionAssignmentError.invalidOutputConnector(connector)
            }
            throw StudioConnectionAssignmentError.invalidBankOutputConnector(bank, connector)
        }
        guard var connection else {
            outputs.removeAll { $0.bank == bank && $0.connector == connector }
            return
        }
        connection.bank = bank
        connection.connector = connector
        if let destinationName = connection.destinationName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !destinationName.isEmpty {
            connection.destinationName = destinationName
            connection.equipmentID = nil
            connection.inputPort = nil
            outputs.removeAll { $0.bank == bank && $0.connector == connector }
            outputs.append(connection)
            sortOutputs()
            return
        }
        guard let equipmentID = connection.equipmentID,
              let inputPort = connection.inputPort,
              let device = equipment.first(where: { $0.id == equipmentID }) else {
            throw StudioConnectionAssignmentError.missingEquipment
        }
        guard device.inputs.indices.contains(inputPort) else {
            throw StudioConnectionAssignmentError.invalidEquipmentInput
        }
        if let existing = outputs.first(where: {
            $0.outputConnector != connection.outputConnector
                && $0.equipmentID == equipmentID
                && $0.inputPort == inputPort
        }) {
            throw StudioConnectionAssignmentError.equipmentInputInUse(
                device.name,
                device.inputs[inputPort],
                existing.outputConnector
            )
        }
        outputs.removeAll { $0.bank == bank && $0.connector == connector }
        outputs.append(connection)
        sortOutputs()
    }

    private mutating func sortOutputs() {
        outputs.sort {
            ($0.bank.rawValue, $0.connector) < ($1.bank.rawValue, $1.connector)
        }
    }

    private func connectorDisplayName(
        kind: String,
        connector: Int,
        includeConnector: Bool = true,
        friendlyName: String?
    ) -> String {
        let connectorName = includeConnector ? "\(kind) \(connector)" : kind
        guard let friendlyName else { return connectorName }
        return "\(connectorName) · \(friendlyName)"
    }
}
