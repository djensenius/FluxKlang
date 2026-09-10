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
