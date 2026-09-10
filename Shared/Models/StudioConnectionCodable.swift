//
//  StudioConnectionCodable.swift
//  FluxKlang
//

import Foundation

extension StudioInputConnection {
    private enum CodingKeys: String, CodingKey {
        case id, connector, equipmentID, outputPort, labelOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        connector = try container.decode(Int.self, forKey: .connector)
        equipmentID = try container.decode(Equipment.ID.self, forKey: .equipmentID)
        outputPort = try container.decode(Int.self, forKey: .outputPort)
        labelOverride = try container.decodeIfPresent(String.self, forKey: .labelOverride)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(connector, forKey: .connector)
        try container.encode(equipmentID, forKey: .equipmentID)
        try container.encode(outputPort, forKey: .outputPort)
        try container.encodeIfPresent(labelOverride, forKey: .labelOverride)
    }
}

extension StudioOutputConnection {
    private enum CodingKeys: String, CodingKey {
        case id, connector, equipmentID, inputPort, labelOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        connector = try container.decode(Int.self, forKey: .connector)
        equipmentID = try container.decode(Equipment.ID.self, forKey: .equipmentID)
        inputPort = try container.decode(Int.self, forKey: .inputPort)
        labelOverride = try container.decodeIfPresent(String.self, forKey: .labelOverride)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(connector, forKey: .connector)
        try container.encode(equipmentID, forKey: .equipmentID)
        try container.encode(inputPort, forKey: .inputPort)
        try container.encodeIfPresent(labelOverride, forKey: .labelOverride)
    }
}

extension StudioConnectionIssue.Kind {
    var stableID: String {
        switch self {
        case .duplicateInputConnector(let connector): "duplicate-input-connector-\(connector)"
        case .duplicateOutputConnector(let connector): "duplicate-output-connector-\(connector)"
        case .inputConnectorOutOfRange(let connector): "input-connector-out-of-range-\(connector)"
        case .outputConnectorOutOfRange(let connector): "output-connector-out-of-range-\(connector)"
        case .missingEquipment(let id): "missing-equipment-\(id.uuidString.lowercased())"
        case .invalidOutputPort(let id, let port): "invalid-output-port-\(id.uuidString.lowercased())-\(port)"
        case .invalidInputPort(let id, let port): "invalid-input-port-\(id.uuidString.lowercased())-\(port)"
        case .conflictingOutputPort(let id, let port): "conflicting-output-port-\(id.uuidString.lowercased())-\(port)"
        case .conflictingInputPort(let id, let port): "conflicting-input-port-\(id.uuidString.lowercased())-\(port)"
        case .unconfiguredInstrument(let id): "unconfigured-instrument-\(id.uuidString.lowercased())"
        case .missingStereoInputLeg(let id): "missing-stereo-input-leg-\(id.uuidString.lowercased())"
        case .unlinkedEffect(let id): "unlinked-effect-\(id.uuidString.lowercased())"
        case .unconfiguredEffectInput(let id): "unconfigured-effect-input-\(id.uuidString.lowercased())"
        case .unconfiguredEffectOutput(let id): "unconfigured-effect-output-\(id.uuidString.lowercased())"
        }
    }
}
