//
//  ProjectRecords.swift
//  FluxKlang
//
//  The records a `fluxklang.project` document holds: portable roles, graph and
//  patch references, and media assets. Roles live here, not in the graph;
//  host-local device routes for them belong to the device contract (#55).
//

import Foundation

/// A portable, inert input or output intent such as "Mains" or "Vocal Mic In".
struct ProjectRole: Codable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, direction, signal, channels, extensions
    }

    var id: RoleID
    var label: String
    var direction: PortDirection
    var signal: PortSignal
    /// Audio channel count (1...64); nil for non-audio roles.
    var channels: Int?
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(id: RoleID, label: String, direction: PortDirection, signal: PortSignal, channels: Int? = nil) {
        self.id = id
        self.label = label
        self.direction = direction
        self.signal = signal
        self.channels = channels
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(RoleID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        direction = try container.decode(PortDirection.self, forKey: .direction)
        signal = try container.decode(PortSignal.self, forKey: .signal)
        channels = try container.decodeIfPresent(Int.self, forKey: .channels)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(direction, forKey: .direction)
        try container.encode(signal, forKey: .signal)
        try container.encodeIfPresent(channels, forKey: .channels)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

/// A graph (main or shared) the project uses, pinned to a revision.
struct ProjectGraphReference: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case graph, revision, extensions
    }

    var graph: GraphID
    var revision: ContractRevision
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(graph: GraphID, revision: ContractRevision) {
        self.graph = graph
        self.revision = revision
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        graph = try container.decode(GraphID.self, forKey: .graph)
        revision = try container.decode(ContractRevision.self, forKey: .revision)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(graph, forKey: .graph)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

/// A patch, referenced by ID. Its variations and deltas are #104's; until then
/// they round-trip through `extensions` or `unknownFields`.
struct ProjectPatch: Codable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, graph, extensions
    }

    var id: PatchID
    var label: String
    var graph: GraphID
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(id: PatchID, label: String, graph: GraphID, extensions: [String: JSONValue]? = nil) {
        self.id = id
        self.label = label
        self.graph = graph
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PatchID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        graph = try container.decode(GraphID.self, forKey: .graph)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(graph, forKey: .graph)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}

/// Asset media. `audio` and `midi` follow G-MEDIA; `document` is untimed.
enum AssetMedia: String, Codable, Hashable, Sendable, CaseIterable {
    case audio, midi, document

    /// The policies G-MEDIA allows for `media`; documents allow none.
    var allowedTimePolicies: Set<MediaTimePolicy> {
        switch self {
        case .audio: [.fixedRate, .timeStretch]
        case .midi: [.tempoFollowing, .fixedRate]
        case .document: []
        }
    }
}

/// Offsets from the asset's recorded origin (G-MEDIA
/// M13): sample frames, musical ticks (15360 per quarter note) or nanoseconds.
/// Host-clock ticks are never persisted, so they have no field here.
struct AssetTiming: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case startFrame, startTicks, startOffsetNs, extensions
    }

    var startFrame: Int64?
    var startTicks: Int64?
    var startOffsetNs: Int64?
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(startFrame: Int64? = nil, startTicks: Int64? = nil, startOffsetNs: Int64? = nil) {
        self.startFrame = startFrame
        self.startTicks = startTicks
        self.startOffsetNs = startOffsetNs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startFrame = try container.decodeIfPresent(Int64.self, forKey: .startFrame)
        startTicks = try container.decodeIfPresent(Int64.self, forKey: .startTicks)
        startOffsetNs = try container.decodeIfPresent(Int64.self, forKey: .startOffsetNs)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(startFrame, forKey: .startFrame)
        try container.encodeIfPresent(startTicks, forKey: .startTicks)
        try container.encodeIfPresent(startOffsetNs, forKey: .startOffsetNs)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }

    var isEmpty: Bool { startFrame == nil && startTicks == nil && startOffsetNs == nil }
}

/// A media or document asset, identified by content rather than file location.
struct ProjectAsset: Codable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, media, contentDigest, byteCount, timePolicy, timing, extensions
    }

    var id: AssetID
    var label: String
    var media: AssetMedia
    /// Content identity: `sha256:` and 64 lowercase hex digits.
    var contentDigest: String
    var byteCount: Int?
    /// Required for audio and MIDI so a future default never changes a saved show.
    var timePolicy: MediaTimePolicy?
    var timing: AssetTiming?
    /// G-MEDIA §12 bag: unknown media fields go here.
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]

    init(
        id: AssetID,
        label: String,
        media: AssetMedia,
        contentDigest: String,
        byteCount: Int? = nil,
        timePolicy: MediaTimePolicy? = nil,
        timing: AssetTiming? = nil,
        extensions: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.label = label
        self.media = media
        self.contentDigest = contentDigest
        self.byteCount = byteCount
        self.timePolicy = timePolicy
        self.timing = timing
        self.extensions = extensions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AssetID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        media = try container.decode(AssetMedia.self, forKey: .media)
        contentDigest = try container.decode(String.self, forKey: .contentDigest)
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount)
        timePolicy = try container.decodeIfPresent(MediaTimePolicy.self, forKey: .timePolicy)
        timing = try container.decodeIfPresent(AssetTiming.self, forKey: .timing)
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(media, forKey: .media)
        try container.encode(contentDigest, forKey: .contentDigest)
        try container.encodeIfPresent(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(timePolicy, forKey: .timePolicy)
        try container.encodeIfPresent(timing, forKey: .timing)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }
}
