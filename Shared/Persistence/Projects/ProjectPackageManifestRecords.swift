import Foundation

/// A member-byte claim, not proof of membership, length, digest or successful IO.
struct ProjectPackageMember: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case path, byteCount, extensions
    }

    var path: String
    var byteCount: Int?
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(path: String, byteCount: Int? = nil, extensions: [String: JSONValue]? = nil) {
        self.path = path
        self.byteCount = byteCount
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

struct ProjectPackageProjectReference: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, revision, member, extensions
    }

    var id: ProjectID
    var revision: ContractRevision
    var member: ProjectPackageMember
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(
        id: ProjectID, revision: ContractRevision, member: ProjectPackageMember,
        extensions: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.revision = revision
        self.member = member
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProjectID.self, forKey: .id)
        revision = try container.decode(ContractRevision.self, forKey: .revision)
        member = try container.decode(ProjectPackageMember.self, forKey: .member)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(revision, forKey: .revision)
        try container.encode(member, forKey: .member)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

struct ProjectPackageGraphReference: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case graph, revision, member, extensions
    }

    var graph: GraphID
    var revision: ContractRevision
    var member: ProjectPackageMember
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(
        graph: GraphID, revision: ContractRevision, member: ProjectPackageMember,
        extensions: [String: JSONValue]? = nil
    ) {
        self.graph = graph
        self.revision = revision
        self.member = member
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        graph = try container.decode(GraphID.self, forKey: .graph)
        revision = try container.decode(ContractRevision.self, forKey: .revision)
        member = try container.decode(ProjectPackageMember.self, forKey: .member)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(graph, forKey: .graph)
        try container.encode(revision, forKey: .revision)
        try container.encode(member, forKey: .member)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

/// Bookmark order is preserved but grants no preference or access authority.
/// Bookmark member lengths describe bookmark bytes, never external content bytes.
struct ProjectPackageResource: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case contentDigest, media, bookmarks, extensions
    }

    var contentDigest: String
    var media: ProjectPackageMember?
    var bookmarks: [ProjectPackageMember]
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(
        contentDigest: String, media: ProjectPackageMember? = nil,
        bookmarks: [ProjectPackageMember], extensions: [String: JSONValue]? = nil
    ) {
        self.contentDigest = contentDigest
        self.media = media
        self.bookmarks = bookmarks
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentDigest = try container.decode(String.self, forKey: .contentDigest)
        media = try container.decodeIfPresent(ProjectPackageMember.self, forKey: .media)
        bookmarks = try container.decode([ProjectPackageMember].self, forKey: .bookmarks)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentDigest, forKey: .contentDigest)
        try container.encodeIfPresent(media, forKey: .media)
        try container.encode(bookmarks, forKey: .bookmarks)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}
