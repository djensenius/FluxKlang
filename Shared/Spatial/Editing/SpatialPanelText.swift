//
//  SpatialPanelText.swift
//  FluxKlang
//
//  The fixed texts and text builders of the spatial panel's speaker table (#116 SPT1). Nothing calls it yet.
//  Strings quoted from docs/transformation/workspace-ux/spatial.md: the headings (line 24), `Lost` and `Masked`
//  (lines 25 to 28, 191, 193), `Map outputs...` (192), `LOST / MUTED` (17), `Mask: ... muted.` and
//  `Survivors are not boosted` (30, 75 to 77), `Interface B missing` (184) and `Move to Front Left` (43).
//  `Active`, the soloed sentence, the renormalized sentence and `route not confirmed` are not in the document.
//

import Foundation

enum SpatialPanelText {
    static let speakersHeading = "Speakers"
    static let routeHeading = "Route (this host)"
    static let stateHeading = "State"
    static let lost = "Lost"
    static let masked = "Masked"
    static let active = "Active"
    static let mapOutputs = "Map outputs..."
    static let noRoute = "no route"
    static let banner = "LOST / MUTED"
    static let maskPrefix = "Mask: "
    static let survivorsNotBoosted = "Survivors are not boosted"
    static let survivorsRenormalized = "Survivors are renormalized"

    /// The State column. Every lost reason reads `Lost`, and muted and soloed out both read `Masked`.
    static func stateText(_ state: SpatialSpeakerState) -> String {
        switch state {
        case .active: active
        case .lost: lost
        case .unmapped: mapOutputs
        case .masked: masked
        }
    }

    /// `{name}, {route}, {state}.`, or `{name}, no route, {state}.` for an unmapped speaker.
    static func accessibilityLabel(name: String, routeText: String?, stateText: String) -> String {
        "\(name), \(routeText ?? noRoute), \(stateText)."
    }

    static func moveActionTitle(name: String) -> String {
        "Move to \(name)"
    }

    /// The mask line, or nil when no speaker is masked. `muted` and `soloed` are names in layout order; a
    /// speaker that is muted is not in `soloed`.
    static func maskLine(muted: [String], soloed: [String], renormalizeSurvivors: Bool) -> String? {
        var sentences: [String] = []
        if !muted.isEmpty { sentences.append("\(muted.joined(separator: ", ")) muted.") }
        if !soloed.isEmpty { sentences.append("\(soloed.joined(separator: ", ")) soloed.") }
        guard !sentences.isEmpty else { return nil }
        sentences.append("\(renormalizeSurvivors ? survivorsRenormalized : survivorsNotBoosted).")
        return maskPrefix + sentences.joined(separator: " ")
    }

    /// The Calibrate button's disabled reason; `deviceName` is used verbatim.
    static func calibrateDisabledReason(_ reason: SpatialCalibrationUnavailableReason, deviceName: String) -> String {
        switch reason {
        case .deviceMissing: "\(deviceName) missing"
        case .routeUnconfirmed: "\(deviceName) route not confirmed"
        }
    }
}
