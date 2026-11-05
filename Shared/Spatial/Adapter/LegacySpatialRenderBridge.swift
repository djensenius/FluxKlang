//
//  LegacySpatialRenderBridge.swift
//  FluxKlang
//
//  The legacy-golden preservation bridge (#113 S1): maps legacy speakers,
//  sources and speaker mutes onto a neutral `SpatialRenderRequest` with a
//  deterministic identity mapping (plan column i is legacy speaker i; rows follow
//  legacy sources and their channels in order). It never enables survivor
//  renormalisation, never evaluates route loss and applies no calibration, so the
//  plan gains are the legacy DBAP law. It does not replace `SpatialPanner`, which
//  remains the default panning path.
//

import Foundation

/// Why a legacy → neutral render mapping was refused.
enum LegacySpatialMappingError: Error, Equatable, Sendable {
    /// A raw legacy ID is neither a UUID nor a valid neutral contract ID.
    case invalidLegacyID(ContractIDError)
    /// The legacy speakers or sources could not be imported; the whole bridge is
    /// refused. A non-finite speaker or source position arrives here as
    /// `.speaker`/`.source(index:, .nonFiniteCoordinate)`.
    case importRefused(LegacySpatialImportError)
    /// A mask names a speaker UUID that is not in the legacy layout.
    case unknownMaskSpeaker(UUID)
    /// The neutral planner refused the mapped request.
    case render(SpatialRenderError)
}

/// The stable legacy ID → neutral ID migration. A legacy UUID becomes its
/// canonical (uppercase) `uuidString`, exactly as `ContractID(uuid:)` and
/// Foundation's JSON coding write it. The migration is idempotent: an already
/// migrated ID (or any other valid neutral ID) is returned unchanged, so running
/// it twice equals running it once. A raw UUID string in any letter case maps to
/// the same neutral ID; two such spellings of one UUID therefore collide, and the
/// layout's duplicate check refuses them rather than silently keeping both.
enum LegacySpatialIDMigration {
    static func speakerID(_ legacy: UUID) -> SpeakerID {
        SpeakerID(uuid: legacy)
    }

    static func sourceID(_ legacy: UUID) -> SpatialSourceID {
        SpatialSourceID(uuid: legacy)
    }

    static func groupID(_ legacy: UUID) -> SpeakerGroupID {
        SpeakerGroupID(uuid: legacy)
    }

    /// Migrates a raw stored ID: a UUID string → its canonical neutral ID; a valid
    /// neutral ID → itself; anything else is refused.
    static func migrate<Tag: ContractIDTag>(
        _ raw: String, as _: Tag.Type = Tag.self
    ) throws(LegacySpatialMappingError) -> ContractID<Tag> {
        if let uuid = UUID(uuidString: raw) { return ContractID(uuid: uuid) }
        do {
            return try ContractID<Tag>(raw)
        } catch {
            throw .invalidLegacyID(error)
        }
    }
}

/// A user mask on one legacy speaker, keyed by its legacy UUID.
struct LegacySpeakerMask: Hashable, Sendable {
    let speaker: UUID
    let state: SpeakerMaskState

    init(speaker: UUID, state: SpeakerMaskState = .muted) {
        self.speaker = speaker
        self.state = state
    }
}

/// One plan row: a legacy source and the index of its channel (0 = mono/left).
struct LegacySpatialRow: Hashable, Sendable {
    let source: UUID
    let channel: Int
}

/// A validated legacy → neutral render mapping. Only `make` can build one (the
/// storage and initialiser are private, so not even a same-module extension can
/// forge one), so the request always has renormalisation off, no route-loss
/// evaluation, an empty calibration and the default rolloff, and the column/row
/// maps always match it.
struct LegacySpatialRenderBridge: Hashable, Sendable {
    private let mappedRequest: SpatialRenderRequest
    private let mappedColumns: [UUID]
    private let mappedRows: [LegacySpatialRow]

    /// The neutral planner input.
    var request: SpatialRenderRequest { mappedRequest }
    /// Legacy speaker UUIDs in plan column order (identical to the input order).
    var speakerColumns: [UUID] { mappedColumns }
    /// Legacy source/channel of each plan row, in plan row order.
    var rows: [LegacySpatialRow] { mappedRows }

    private init(request: SpatialRenderRequest, speakerColumns: [UUID], rows: [LegacySpatialRow]) {
        mappedRequest = request
        mappedColumns = speakerColumns
        mappedRows = rows
    }

    /// Maps legacy speakers, pairs, sources and masks. Masks only remove energy:
    /// survivors keep their unmasked law gains exactly (no renormalisation).
    ///
    /// Neutral import rules (#113 S1 rulings; outside the legacy-golden domain,
    /// which is finite positions and widths in `0…1`). Legacy `SpatialPanner`
    /// stays the default rendering path; each rule below is an intentional
    /// divergence of this compile-time model → plan bridge only.
    /// - A finite position outside `0…1` is clamped into `0…1` per axis, and a
    ///   stereo width outside `0…1` is clamped likewise. Legacy pans the raw values.
    /// - A non-finite (NaN or ±∞) speaker position refuses the whole bridge with
    ///   `.importRefused(.speaker(index:, .nonFiniteCoordinate))`. Legacy instead
    ///   zeroes only that speaker's column at ±∞, and every gain at NaN.
    /// - A non-finite source position refuses the whole bridge with
    ///   `.importRefused(.source(index:, .nonFiniteCoordinate))`. Legacy instead
    ///   pans only that source to all-zero gains.
    /// Apart from the documented 0…1 clamp, the bridge never silently drops,
    /// zeroes or repositions a speaker or source:
    /// every refusal is typed and covers the whole compile, and the caller keeps
    /// its previous plan. Legacy speakers are 2-D, so there is no z input.
    /// Limits: 64 speakers, 64 pairs, 64 sources and 128 masks (one mute and one
    /// solo per speaker); one more of any is refused with a typed error.
    static func make(
        speakers: [LegacySpeakerInput],
        pairs: [LegacySpeakerPairInput] = [],
        sources: [LegacySourceInput] = [],
        masks: [LegacySpeakerMask] = []
    ) throws(LegacySpatialMappingError) -> Self {
        let imported: LegacySpatialImportResult
        do {
            imported = try LegacySpatialImport.importLegacy(speakers: speakers, pairs: pairs, sources: sources)
        } catch {
            throw .importRefused(error)
        }
        guard masks.count <= SpatialMaskSet.maximumMasks else { throw .render(.tooManyMasks(masks.count)) }
        let known = Set(speakers.map(\.id))
        if let unknown = masks.first(where: { !known.contains($0.speaker) }) {
            throw .unknownMaskSpeaker(unknown.speaker)
        }
        let maskSet: SpatialMaskSet
        do {
            maskSet = try SpatialMaskSet(
                masks: masks.map {
                    SpatialOutputMask(speaker: LegacySpatialIDMigration.speakerID($0.speaker), state: $0.state)
                },
                renormalizeSurvivors: false
            )
        } catch {
            throw .render(error)
        }
        let request = SpatialRenderRequest(
            layout: imported.layout, placements: imported.sources, masks: maskSet, availableRoutes: nil
        )
        let rows = zip(sources, imported.sources).flatMap { input, placement in
            (0..<placement.channelCount).map { LegacySpatialRow(source: input.id, channel: $0) }
        }
        return Self(request: request, speakerColumns: speakers.map(\.id), rows: rows)
    }

    /// The plan column of a legacy speaker, if present.
    func column(forLegacySpeaker id: UUID) -> Int? {
        speakerColumns.firstIndex(of: id)
    }

    /// The plan rows of a legacy source (one for mono, two for stereo), if present.
    func rows(forLegacySource id: UUID) -> Range<Int>? {
        guard let first = rows.firstIndex(where: { $0.source == id }) else { return nil }
        let count = rows[first...].prefix { $0.source == id }.count
        return first..<(first + count)
    }

    /// Plans the mapped request with the neutral renderer.
    func plan() throws(LegacySpatialMappingError) -> SpatialRenderPlan {
        do {
            return try SpatialRenderer.plan(request)
        } catch {
            throw .render(error)
        }
    }
}
