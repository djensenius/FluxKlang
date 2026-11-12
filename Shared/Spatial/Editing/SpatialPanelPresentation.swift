//
//  SpatialPanelPresentation.swift
//  FluxKlang
//
//  The spatial panel's speaker table, banner, mask line and Calibrate reason as a value (#116 SPT1), from
//  docs/transformation/workspace-ux/spatial.md lines 14 to 31 and 184 to 193. It wraps
//  `SpatialSpeakerStates.classify` and does not re-derive its precedence. No view, I/O, clock, presence read
//  or command. Nothing calls it yet.
//

import Foundation

struct SpatialPanelPresentation: Hashable, Sendable {
    /// One row per layout speaker, in layout order.
    let rows: [SpatialPanelSpeakerRow]
    /// `LOST / MUTED` when at least one row is lost.
    let banner: String?
    /// The mask line; nil when the mask set holds no mask.
    let maskText: String?
    /// The Calibrate button's disabled reason; nil when calibration is not unavailable.
    let calibrateDisabledReason: String?

    private init(
        rows: [SpatialPanelSpeakerRow], banner: String?, maskText: String?, calibrateDisabledReason: String?
    ) {
        self.rows = rows
        self.banner = banner
        self.maskText = maskText
        self.calibrateDisabledReason = calibrateDisabledReason
    }

    func row(for speaker: SpeakerID) -> SpatialPanelSpeakerRow? {
        rows.first { $0.speaker == speaker }
    }

    /// Refuses only what `classify` refuses (`unknownMaskSpeaker`, the first in mask order), before
    /// `routeText` is called. `routeText` is called once per routed speaker in layout order, never for an
    /// unmapped one; a nil or empty answer falls back to the raw route ID.
    static func make( // swiftlint:disable:this function_parameter_count
        layout: SpatialLayout,
        availability: SpatialRouteAvailability,
        masks: SpatialMaskSet,
        routeText: (RouteID) -> String?,
        calibrationUnavailable: SpatialCalibrationUnavailableReason?,
        calibrationDeviceName: String
    ) throws(SpatialRouteRefusal) -> SpatialPanelPresentation {
        let states = try SpatialSpeakerStates.classify(layout: layout, availability: availability, masks: masks)
        let rows = layout.speakers.compactMap { speaker -> SpatialPanelSpeakerRow? in
            guard let state = states.row(for: speaker.id)?.state else { return nil }
            let text = speaker.route.map { route in
                let given = routeText(route)
                return given.flatMap { $0.utf8.isEmpty ? nil : $0 } ?? route.rawValue
            }
            return SpatialPanelSpeakerRow.make(speaker: speaker, routeText: text, state: state)
        }
        let hasLost = rows.contains { if case .lost = $0.state { true } else { false } }
        return SpatialPanelPresentation(
            rows: rows,
            banner: hasLost ? SpatialPanelText.banner : nil,
            maskText: maskText(layout: layout, masks: masks),
            calibrateDisabledReason: calibrationUnavailable.map {
                SpatialPanelText.calibrateDisabledReason($0, deviceName: calibrationDeviceName)
            }
        )
    }

    /// Muted and soloed names come from the mask set in layout order; mute wins over solo.
    private static func maskText(layout: SpatialLayout, masks: SpatialMaskSet) -> String? {
        let muted = Set(masks.masks.filter { $0.state == .muted }.map(\.speaker))
        let soloed = Set(masks.masks.filter { $0.state == .soloed }.map(\.speaker))
        func names(_ ids: Set<SpeakerID>) -> [String] {
            layout.speakers.filter { ids.contains($0.id) }.map { $0.name ?? $0.id.rawValue }
        }
        return SpatialPanelText.maskLine(
            muted: names(muted),
            soloed: names(soloed.subtracting(muted)),
            renormalizeSurvivors: masks.renormalizeSurvivors
        )
    }
}
