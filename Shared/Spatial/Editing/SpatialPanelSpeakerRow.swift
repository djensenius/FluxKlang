//
//  SpatialPanelSpeakerRow.swift
//  FluxKlang
//
//  One row of the spatial panel's speaker table (#116 SPT1): the speaker, its route text, its state and the
//  texts a view draws. Nothing calls it yet. Only `SpatialPanelPresentation.make` builds one.
//

import Foundation

struct SpatialPanelSpeakerRow: Hashable, Sendable, Identifiable {
    let speaker: SpeakerID
    /// The speaker's name, else its raw ID.
    let name: String
    /// The caller's text for the route, else the raw route ID; nil for an unmapped speaker.
    let routeText: String?
    /// The state `SpatialSpeakerStates.classify` gave the speaker, unchanged.
    let state: SpatialSpeakerState
    let stateText: String
    /// True only for `.masked`: a lost speaker is not drawn with the `x`, because lost outranks masked.
    let isMasked: Bool
    let accessibilityLabel: String
    let moveActionTitle: String

    var id: SpeakerID { speaker }

    private init(speaker: SpeakerID, name: String, routeText: String?, state: SpatialSpeakerState) {
        let stateText = SpatialPanelText.stateText(state)
        var isMasked = false
        if case .masked = state { isMasked = true }
        self.speaker = speaker
        self.name = name
        self.routeText = routeText
        self.state = state
        self.stateText = stateText
        self.isMasked = isMasked
        self.accessibilityLabel = SpatialPanelText.accessibilityLabel(
            name: name, routeText: routeText, stateText: stateText
        )
        self.moveActionTitle = SpatialPanelText.moveActionTitle(name: name)
    }

    /// The only way to build a row, for `SpatialPanelPresentation.make`. `routeText` is the resolved route
    /// text (see `make`), so this function reads no route name itself.
    static func make(speaker: SpatialSpeaker, routeText: String?, state: SpatialSpeakerState) -> Self {
        Self(speaker: speaker.id, name: speaker.name ?? speaker.id.rawValue, routeText: routeText, state: state)
    }
}
