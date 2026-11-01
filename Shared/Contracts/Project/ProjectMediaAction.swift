import Foundation

/// Persisted action intent. Policy is #55's G-MEDIA value, never a prepared trigger
/// or a runtime clock stamp. One asset can be used by actions with different policies.
struct ProjectMediaAction: Codable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, asset, policy, extensions
    }

    var id: ActionID
    var asset: AssetID
    var policy: ActionPolicy
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(id: ActionID, asset: AssetID, policy: ActionPolicy, extensions: [String: JSONValue]? = nil) {
        self.id = id
        self.asset = asset
        self.policy = policy
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ActionID.self, forKey: .id)
        asset = try container.decode(AssetID.self, forKey: .asset)
        policy = try container.decode(ActionPolicy.self, forKey: .policy)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(asset, forKey: .asset)
        try container.encode(policy, forKey: .policy)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}
