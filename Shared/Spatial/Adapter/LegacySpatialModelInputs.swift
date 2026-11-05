//
//  LegacySpatialModelInputs.swift
//  FluxKlang
//
//  Plain-value inputs (#113 S1) built from the legacy app models, applying the
//  legacy routing rule exactly once: only a bus-driven speaker receives sends
//  (`SpatialRouting.settings`), so only it drives panning. Console references
//  are kept as opaque evidence and never parsed.
//

import Foundation

extension LegacySpeakerInput {
    init(legacy speaker: Speaker) {
        self.init(
            id: speaker.id, name: speaker.name,
            x: Double(speaker.position.x), y: Double(speaker.position.y),
            drivesPanning: speaker.node.kind == .bus, evidence: speaker.node.id
        )
    }
}

extension LegacySpeakerPairInput {
    init(legacy pair: SpeakerPair) {
        self.init(id: pair.id, name: pair.name, left: pair.left, right: pair.right)
    }
}

extension LegacySourceInput {
    /// One evidence entry per legacy channel placement (mono: one; stereo: two).
    /// A `.stereo` source with no right channel falls back to mono, exactly as
    /// legacy `isStereo` and `channelPlacements()` do: one row at `position`.
    init(legacy source: SpatialSource) {
        self.init(
            id: source.id, name: source.name,
            x: Double(source.position.x), y: Double(source.position.y),
            width: source.width, isStereo: source.isStereo,
            evidence: source.channelPlacements().map(\.channel.id)
        )
    }
}

extension LegacySpatialRenderBridge {
    /// Maps a legacy speaker array and sources, muting `muted` speakers. Muting
    /// one speaker twice is refused (`.render(.duplicateMask(_:))`), not merged.
    static func make(
        array: SpeakerArray, sources: [SpatialSource], muted: [Speaker.ID] = []
    ) throws(LegacySpatialMappingError) -> Self {
        try make(
            speakers: array.speakers.map(LegacySpeakerInput.init(legacy:)),
            pairs: array.pairs.map(LegacySpeakerPairInput.init(legacy:)),
            sources: sources.map(LegacySourceInput.init(legacy:)),
            masks: muted.map { LegacySpeakerMask(speaker: $0) }
        )
    }
}
