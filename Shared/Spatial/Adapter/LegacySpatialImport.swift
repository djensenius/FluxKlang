//
//  LegacySpatialImport.swift
//  FluxKlang
//
//  The explicit, versioned transform from the legacy 0…1 spatial values (origin
//  Front L, y toward the rear) into the neutral −1…1 plane (front = +y):
//  x′ = 2x − 1, y′ = 1 − 2y. Distances double, so the blur and stereo width
//  offset double too, preserving the DBAP law. Imported speakers carry no route
//  (inert until reviewed); console references survive only as opaque evidence.
//

import Foundation

/// Identifies the legacy → neutral coordinate transform that produced a value.
enum LegacySpatialTransformVersion: String, Codable, Hashable, Sendable, CaseIterable {
    case unitSquareV1 = "legacy.unit-square.v1"
}

/// A legacy speaker as plain values (`Speaker.id`, `name`, `position`, and the
/// node reference rendered as text for evidence only). `drivesPanning` is false
/// for speakers the legacy routing drops (a non-bus node, see
/// `SpatialRouting.settings`); the caller decides it, evidence is never parsed.
struct LegacySpeakerInput: Hashable, Sendable {
    let id: UUID
    let name: String?
    let legacyX: Double
    let legacyY: Double
    let drivesPanning: Bool
    let evidence: String?

    init(
        id: UUID, name: String? = nil, x legacyX: Double, y legacyY: Double,
        drivesPanning: Bool = true, evidence: String? = nil
    ) {
        self.id = id
        self.name = name
        self.legacyX = legacyX
        self.legacyY = legacyY
        self.drivesPanning = drivesPanning
        self.evidence = evidence
    }
}

/// A legacy stereo speaker pair as plain values.
struct LegacySpeakerPairInput: Hashable, Sendable {
    let id: UUID
    let name: String?
    let left: UUID
    let right: UUID

    init(id: UUID, name: String? = nil, left: UUID, right: UUID) {
        self.id = id
        self.name = name
        self.left = left
        self.right = right
    }
}

/// A legacy source as plain values. `isStereo` is the legacy `isStereo`
/// (stereo mode with a right channel present).
struct LegacySourceInput: Hashable, Sendable {
    let id: UUID
    let name: String?
    let legacyX: Double
    let legacyY: Double
    let width: Double
    let isStereo: Bool
    let evidence: [String]

    init(
        id: UUID, name: String? = nil, x legacyX: Double, y legacyY: Double,
        width: Double = 0.5, isStereo: Bool = false, evidence: [String] = []
    ) {
        self.id = id
        self.name = name
        self.legacyX = legacyX
        self.legacyY = legacyY
        self.width = width
        self.isStereo = isStereo
        self.evidence = evidence
    }
}

/// Why a whole legacy import was refused, naming the offending item.
enum LegacySpatialImportError: Error, Equatable, Sendable {
    /// The speaker at `index` in the input is invalid.
    case speaker(index: Int, SpatialLayoutError)
    /// The source at `index` in the input is invalid.
    case source(index: Int, SpatialLayoutError)
    /// The assembled layout or source list is invalid (the error names the ID).
    case collection(SpatialLayoutError)
}

/// The neutral values produced by one legacy import, tagged with the transform.
/// Sources are capped at `maximumSources` with unique IDs; decoding re-validates
/// the layout, the cap and source ID uniqueness.
struct LegacySpatialImportResult: Hashable, Sendable, Codable {
    static let maximumSources = 64

    let transform: LegacySpatialTransformVersion
    let layout: SpatialLayout
    let sources: [SpatialSourcePlacement]

    init(
        transform: LegacySpatialTransformVersion,
        layout: SpatialLayout,
        sources: [SpatialSourcePlacement]
    ) throws(SpatialLayoutError) {
        guard sources.count <= Self.maximumSources else { throw .tooManySources(sources.count) }
        var seen = Set<SpatialSourceID>()
        for source in sources where !seen.insert(source.sourceID).inserted {
            throw .duplicateSource(source.sourceID)
        }
        self.transform = transform
        self.layout = layout
        self.sources = sources
    }

    private enum CodingKeys: String, CodingKey { case transform, layout, sources }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let transform = try container.decode(LegacySpatialTransformVersion.self, forKey: .transform)
        let layout = try container.decode(SpatialLayout.self, forKey: .layout)
        let sources = try container.decode([SpatialSourcePlacement].self, forKey: .sources)
        do {
            try self.init(transform: transform, layout: layout, sources: sources)
        } catch {
            throw SpatialDecoding.corrupted(decoder, error)
        }
    }
}

/// The pure legacy → neutral spatial transform.
enum LegacySpatialImport {
    static let version = LegacySpatialTransformVersion.unitSquareV1
    /// Legacy `SpatialPanner.spatialBlur`, in legacy units.
    static let legacyBlur = 0.15
    /// Legacy `channelPlacements()` offset per unit of width, in legacy units.
    static let legacyWidthOffsetFactor = 0.25
    /// Neutral units per legacy unit.
    static let scale = 2.0

    /// The documented legacy coordinate domain.
    static let legacyRange: ClosedRange<Double> = 0...1

    /// Maps a legacy position: x′ = 2x − 1, y′ = 1 − 2y. Finite inputs are
    /// clamped to `legacyRange` *before* the transform, so a huge finite value
    /// (e.g. `greatestFiniteMagnitude`) cannot overflow to infinity. The result is
    /// then exactly inside `−1…1`, so the strict initialiser is used: a missing
    /// clamp would surface as an error rather than be hidden by a second clamp.
    /// Non-finite inputs are refused.
    static func point(x legacyX: Double, y legacyY: Double) throws(SpatialLayoutError) -> NeutralPoint {
        guard legacyX.isFinite, legacyY.isFinite else { throw .nonFiniteCoordinate }
        let clampedX = min(max(legacyX, legacyRange.lowerBound), legacyRange.upperBound)
        let clampedY = min(max(legacyY, legacyRange.lowerBound), legacyRange.upperBound)
        return try NeutralPoint(validatingX: scale * clampedX - 1, y: 1 - scale * clampedY)
    }

    /// Scales a legacy distance (e.g. a blur) into neutral units.
    static func distance(_ legacy: Double) -> Double {
        legacy * scale
    }

    static func speaker(_ input: LegacySpeakerInput) throws(SpatialLayoutError) -> SpatialSpeaker {
        try SpatialSpeaker(
            id: SpeakerID(uuid: input.id),
            name: input.name,
            position: point(x: input.legacyX, y: input.legacyY),
            route: nil,
            participatesInPanning: input.drivesPanning,
            evidence: input.evidence
        )
    }

    /// One neutral source per legacy source; a stereo source has two channels.
    /// A finite legacy width is clamped to `0…1` before any arithmetic, so the
    /// channel offset (`width × 0.5`) and offset positions stay bounded.
    /// Legacy blur is the fixed constant 0.15, imported as 0.30 (inside
    /// `SpatialSourcePlacement.blurRange`), so import never clamps or refuses blur.
    static func source(_ input: LegacySourceInput) throws(SpatialLayoutError) -> SpatialSourcePlacement {
        guard input.width.isFinite else { throw .invalidWidth }
        return try SpatialSourcePlacement(
            sourceID: SpatialSourceID(uuid: input.id),
            name: input.name,
            position: point(x: input.legacyX, y: input.legacyY),
            blur: distance(legacyBlur),
            width: min(max(input.width, 0), 1),
            channelCount: input.isStereo ? 2 : 1,
            evidence: input.evidence
        )
    }

    /// Imports a whole legacy layout and its sources. Every speaker is unmapped.
    ///
    /// All-or-nothing: the first invalid item refuses the whole import with an
    /// error naming its index (or, for collection checks, its ID). Follow-up:
    /// per-item import diagnostics are needed before persistence calls this.
    static func importLegacy(
        speakers: [LegacySpeakerInput],
        pairs: [LegacySpeakerPairInput] = [],
        sources: [LegacySourceInput] = []
    ) throws(LegacySpatialImportError) -> LegacySpatialImportResult {
        var neutralSpeakers: [SpatialSpeaker] = []
        for (index, input) in speakers.enumerated() {
            do { try neutralSpeakers.append(speaker(input)) } catch { throw .speaker(index: index, error) }
        }
        var placements: [SpatialSourcePlacement] = []
        for (index, input) in sources.enumerated() {
            do { try placements.append(source(input)) } catch { throw .source(index: index, error) }
        }
        let groups = pairs.map { pair in
            SpeakerGroup(
                id: SpeakerGroupID(uuid: pair.id),
                name: pair.name,
                speakers: [SpeakerID(uuid: pair.left), SpeakerID(uuid: pair.right)]
            )
        }
        do {
            let layout = try SpatialLayout(speakers: neutralSpeakers, groups: groups)
            return try LegacySpatialImportResult(transform: version, layout: layout, sources: placements)
        } catch {
            throw .collection(error)
        }
    }
}
