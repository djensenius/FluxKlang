enum CapabilityTag: ContractIDTag {}
typealias CapabilityID = ContractID<CapabilityTag>

/// A portable catalog definition shared by graph requirements and device advertisements.
/// A definition alone establishes neither host availability nor activation authority.
struct CapabilityDefinition: Codable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case label
        case extensions
    }

    var id: CapabilityID
    var label: String
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(id: CapabilityID, label: String, extensions: [String: JSONValue]? = nil) {
        self.id = id
        self.label = label
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CapabilityID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}
