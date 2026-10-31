enum CapabilityTag: ContractIDTag {}
typealias CapabilityID = ContractID<CapabilityTag>

/// A portable catalog definition shared by graph requirements and device advertisements.
/// A definition alone establishes neither host availability nor activation authority.
struct CapabilityDefinition: Codable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case label
    }

    var id: CapabilityID
    var label: String
    var unknownFields: [String: JSONValue] = [:]

    init(id: CapabilityID, label: String) {
        self.id = id
        self.label = label
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CapabilityID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}
