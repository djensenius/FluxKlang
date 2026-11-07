//
//  SpatialSpeakerState.swift
//  FluxKlang
//
//  The state of every speaker of a layout on this host (#114 SP1, also the #116 state rows):
//  active, lost (its route is unavailable), unmapped (no route) or masked (muted or soloed out).
//

import Foundation

/// One speaker's state. Precedence, first match: no route is `unmapped`; a route that is not
/// available is `lost`; muted (mute wins over solo) or soloed out is `masked`; otherwise `active`.
///
/// Deliberate difference from `SpatialMaskSet.passes`: that function reports `.masked` before
/// `.lost`, so a speaker that is both masked and unroutable is `.masked` there and `lost`/`unmapped`
/// here. Both are silent; this label never hides that the speaker has no usable route.
enum SpatialSpeakerState: Hashable, Sendable {
    case active
    case lost(SpatialRouteAvailability.Reason)
    case unmapped
    /// `.muted` for a muted speaker, `.soloed` for a speaker silenced because another one is soloed.
    case masked(SpeakerMaskState)
}

/// One speaker's row. Only `SpatialSpeakerStates.classify` can build one.
struct SpatialSpeakerRow: Hashable, Sendable {
    let speaker: SpeakerID
    let route: RouteID?
    let state: SpatialSpeakerState

    fileprivate init(speaker: SpeakerID, route: RouteID?, state: SpatialSpeakerState) {
        self.speaker = speaker
        self.route = route
        self.state = state
    }
}

/// The rows of a layout, sorted by raw speaker id (not layout order). Built only by `classify`.
struct SpatialSpeakerStates: Hashable, Sendable {
    private(set) var rows: [SpatialSpeakerRow]

    private init(rows: [SpatialSpeakerRow]) {
        self.rows = rows
    }

    func row(for speaker: SpeakerID) -> SpatialSpeakerRow? {
        rows.first { $0.speaker == speaker }
    }

    /// Classifies every speaker. A mask naming a speaker that is not in `layout` is refused
    /// (`unknownMaskSpeaker`, the first in mask order). An empty layout and empty masks are legal.
    static func classify(
        layout: SpatialLayout,
        availability: SpatialRouteAvailability,
        masks: SpatialMaskSet
    ) throws(SpatialRouteRefusal) -> SpatialSpeakerStates {
        let known = Set(layout.speakers.map(\.id))
        for mask in masks.masks where !known.contains(mask.speaker) {
            throw .unknownMaskSpeaker(mask.speaker)
        }
        let muted = Set(masks.masks.filter { $0.state == .muted }.map(\.speaker))
        let soloed = Set(masks.masks.filter { $0.state == .soloed }.map(\.speaker))
        let rows = layout.speakers.map { speaker in
            SpatialSpeakerRow(
                speaker: speaker.id,
                route: speaker.route,
                state: state(of: speaker, availability: availability, muted: muted, soloed: soloed)
            )
        }
        return SpatialSpeakerStates(rows: rows.sorted { $0.speaker < $1.speaker })
    }

    private static func state(
        of speaker: SpatialSpeaker,
        availability: SpatialRouteAvailability,
        muted: Set<SpeakerID>,
        soloed: Set<SpeakerID>
    ) -> SpatialSpeakerState {
        guard let route = speaker.route else { return .unmapped }
        if let reason = availability.reason(for: route) { return .lost(reason) }
        if muted.contains(speaker.id) { return .masked(.muted) }
        if !soloed.isEmpty, !soloed.contains(speaker.id) { return .masked(.soloed) }
        return .active
    }
}
