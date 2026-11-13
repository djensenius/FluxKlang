//
//  SpatialMaskEditor.swift
//  FluxKlang
//
//  The spatial panel's mask editing model (#116 SMK1): mute, solo and survivor
//  renormalization as one edit path for the speaker menu, the keyboard and the
//  VoiceOver custom action. A value; it builds no text and stages no draft.
//

import Foundation

/// One edit of the user's masks. Edits are absolute, so replaying one is harmless.
enum SpatialMaskEdit: Hashable, Sendable {
    case setMuted(SpeakerID, Bool)
    case setSoloed(SpeakerID, Bool)
    case setRenormalizeSurvivors(Bool)
}

/// The mask set an edit produces, and whether it differs from the current one.
struct SpatialMaskEditOutcome: Hashable, Sendable {
    let masks: SpatialMaskSet
    let changed: Bool
}

/// Edits the masks of one layout. A refused edit throws a `SpatialRenderError`
/// and leaves `masks` unchanged.
struct SpatialMaskEditor: Hashable, Sendable {
    let layout: SpatialLayout
    private(set) var masks: SpatialMaskSet

    /// Refuses a set that names a speaker the layout does not contain.
    init(masks: SpatialMaskSet = .none, layout: SpatialLayout) throws(SpatialRenderError) {
        try masks.validate(against: layout)
        self.masks = masks
        self.layout = layout
    }

    func isMuted(_ speaker: SpeakerID) -> Bool {
        holds(speaker, .muted)
    }

    func isSoloed(_ speaker: SpeakerID) -> Bool {
        holds(speaker, .soloed)
    }

    /// The outcome of `edit` without applying it.
    func preview(_ edit: SpatialMaskEdit) throws(SpatialRenderError) -> SpatialMaskEditOutcome {
        let proposed: SpatialMaskSet
        switch edit {
        case let .setMuted(speaker, enabled):
            proposed = try setting(.muted, of: speaker, to: enabled)
        case let .setSoloed(speaker, enabled):
            proposed = try setting(.soloed, of: speaker, to: enabled)
        case let .setRenormalizeSurvivors(enabled):
            proposed = try SpatialMaskSet(masks: masks.masks, renormalizeSurvivors: enabled)
        }
        return SpatialMaskEditOutcome(masks: proposed, changed: proposed != masks)
    }

    /// Applies `edit`, or throws and changes nothing.
    @discardableResult
    mutating func apply(_ edit: SpatialMaskEdit) throws(SpatialRenderError) -> SpatialMaskEditOutcome {
        let outcome = try preview(edit)
        masks = outcome.masks
        return outcome
    }

    private func holds(_ speaker: SpeakerID, _ state: SpeakerMaskState) -> Bool {
        masks.masks.contains(SpatialOutputMask(speaker: speaker, state: state))
    }

    private func setting(
        _ state: SpeakerMaskState, of speaker: SpeakerID, to enabled: Bool
    ) throws(SpatialRenderError) -> SpatialMaskSet {
        guard layout.speaker(speaker) != nil else { throw .unknownMaskSpeaker(speaker) }
        let mask = SpatialOutputMask(speaker: speaker, state: state)
        var list = masks.masks
        if enabled {
            if !list.contains(mask) { list.append(mask) }
        } else {
            list.removeAll { $0 == mask }
        }
        return try SpatialMaskSet(masks: list, renormalizeSurvivors: masks.renormalizeSurvivors)
    }
}
