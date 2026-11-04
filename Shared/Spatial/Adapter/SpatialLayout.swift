//
//  SpatialLayout.swift
//  FluxKlang
//
//  The neutral spatial layout value model (#114): speakers placed in a
//  normalized −1…1 plane (front = +y) with host-local route references. It never
//  names a console; a speaker without a confirmed route stays inert.
//

import Foundation

// swiftlint:disable identifier_name
/// A point in the neutral plane. Both axes are finite and within `−1…1`.
struct NeutralPoint: Hashable, Sendable, Codable {
    static let range: ClosedRange<Double> = -1...1

    let x: Double
    let y: Double

    /// Lenient path for import and live edits: refuses non-finite coordinates and
    /// clamps finite ones into `range`.
    init(x: Double, y: Double) throws(SpatialLayoutError) {
        guard x.isFinite, y.isFinite else { throw .nonFiniteCoordinate }
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
    }

    /// Strict path (used by decoding): refuses non-finite and out-of-range values.
    init(validatingX x: Double, y: Double) throws(SpatialLayoutError) {
        guard x.isFinite, y.isFinite else { throw .nonFiniteCoordinate }
        guard Self.range.contains(x), Self.range.contains(y) else { throw .coordinateOutOfRange }
        self.x = x
        self.y = y
    }

    /// Builds from inputs already known finite (sums of in-range finite values).
    init(clampingFinite x: Double, y: Double) {
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private enum CodingKeys: String, CodingKey { case x, y }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawX = try container.decode(Double.self, forKey: .x)
        let rawY = try container.decode(Double.self, forKey: .y)
        do {
            try self.init(validatingX: rawX, y: rawY)
        } catch {
            throw SpatialDecoding.corrupted(decoder, error)
        }
    }
}
// swiftlint:enable identifier_name

/// One speaker: a neutral position plus an optional host-local route.
struct SpatialSpeaker: Hashable, Sendable, Codable {
    let id: SpeakerID
    let name: String?
    let position: NeutralPoint
    /// The output route driving this speaker, or `nil` while unmapped (inert).
    let route: RouteID?
    /// Whether the panner distributes energy to this speaker. A non-participating
    /// speaker (e.g. a legacy non-bus node) always receives gain 0 and is excluded
    /// from power normalisation.
    let participatesInPanning: Bool
    /// Opaque legacy evidence; never used to route.
    let evidence: String?

    init(
        id: SpeakerID,
        name: String? = nil,
        position: NeutralPoint,
        route: RouteID? = nil,
        participatesInPanning: Bool = true,
        evidence: String? = nil
    ) throws(SpatialLayoutError) {
        try SpatialEvidence.validate(evidence)
        self.id = id
        self.name = SpatialName.normalize(name)
        self.position = position
        self.route = route
        self.participatesInPanning = participatesInPanning
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, position, route, participatesInPanning, evidence
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(SpeakerID.self, forKey: .id)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let position = try container.decode(NeutralPoint.self, forKey: .position)
        let route = try container.decodeIfPresent(RouteID.self, forKey: .route)
        let participates = try container.decodeIfPresent(Bool.self, forKey: .participatesInPanning) ?? true
        let evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
        do {
            try self.init(id: id, name: name, position: position, route: route,
                          participatesInPanning: participates, evidence: evidence)
        } catch {
            throw SpatialDecoding.corrupted(decoder, error)
        }
    }
}

/// Speakers controlled together (e.g. a legacy stereo pair), in member order.
/// Membership is validated by the owning `SpatialLayout`.
struct SpeakerGroup: Hashable, Sendable, Codable {
    let id: SpeakerGroupID
    let name: String?
    let speakers: [SpeakerID]

    init(id: SpeakerGroupID, name: String? = nil, speakers: [SpeakerID]) {
        self.id = id
        self.name = SpatialName.normalize(name)
        self.speakers = speakers
    }

    private enum CodingKeys: String, CodingKey { case id, name, speakers }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(SpeakerGroupID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            speakers: try container.decode([SpeakerID].self, forKey: .speakers)
        )
    }
}

/// A bounded, validated speaker layout. Speaker and group order is preserved
/// exactly, so per-speaker gains align with `speakers`.
struct SpatialLayout: Hashable, Sendable, Codable {
    static let currentVersion = ContractVersion(contract: "fluxklang.spatial-layout", version: 1)
    static let maximumSpeakers = 64
    static let maximumGroups = 64

    let version: ContractVersion
    let speakers: [SpatialSpeaker]
    let groups: [SpeakerGroup]

    init(
        version: ContractVersion = currentVersion,
        speakers: [SpatialSpeaker],
        groups: [SpeakerGroup] = []
    ) throws(SpatialLayoutError) {
        try Self.validate(version: version)
        guard speakers.count <= Self.maximumSpeakers else { throw .tooManySpeakers(speakers.count) }
        guard groups.count <= Self.maximumGroups else { throw .tooManyGroups(groups.count) }
        var known = Set<SpeakerID>()
        for speaker in speakers where !known.insert(speaker.id).inserted {
            throw .duplicateSpeaker(speaker.id)
        }
        try Self.validate(groups: groups, known: known)
        self.version = version
        self.speakers = speakers
        self.groups = groups
    }

    /// Applies the standard contract policy; older or unversioned layouts are
    /// refused because no migration path exists yet.
    private static func validate(version: ContractVersion) throws(SpatialLayoutError) {
        let compatibility: ContractVersion.Compatibility
        do {
            compatibility = try version.check(supported: currentVersion)
        } catch {
            throw .version(error)
        }
        guard compatibility == .current else { throw .noMigrationPath(version) }
    }

    private static func validate(groups: [SpeakerGroup], known: Set<SpeakerID>) throws(SpatialLayoutError) {
        var groupIDs = Set<SpeakerGroupID>()
        for group in groups {
            guard groupIDs.insert(group.id).inserted else { throw .duplicateGroup(group.id) }
            guard !group.speakers.isEmpty else { throw .emptyGroup(group.id) }
            var members = Set<SpeakerID>()
            for member in group.speakers {
                guard known.contains(member) else { throw .unknownGroupMember(group.id, member) }
                guard members.insert(member).inserted else { throw .duplicateGroupMember(group.id, member) }
            }
        }
    }

    /// The speaker with `id`, if present.
    func speaker(_ id: SpeakerID) -> SpatialSpeaker? {
        speakers.first { $0.id == id }
    }

    /// The route for `id`, or `nil` (inert) when the speaker is unknown or unmapped.
    func route(for id: SpeakerID) -> RouteID? {
        speaker(id)?.route
    }

    /// The route for `id` only if that route is present on this host; a missing
    /// route is inert (`nil`) and is never substituted.
    func route(for id: SpeakerID, available: Set<RouteID>) -> RouteID? {
        guard let route = route(for: id), available.contains(route) else { return nil }
        return route
    }

    private enum CodingKeys: String, CodingKey { case version, speakers, groups }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(ContractVersion.self, forKey: .version)
        let speakers = try container.decode([SpatialSpeaker].self, forKey: .speakers)
        let groups = try container.decodeIfPresent([SpeakerGroup].self, forKey: .groups) ?? []
        do {
            try self.init(version: version, speakers: speakers, groups: groups)
        } catch {
            throw SpatialDecoding.corrupted(decoder, error)
        }
    }
}
