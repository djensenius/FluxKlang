//
//  Preset.swift
//  FluxKlang
//
//  A named snapshot of WING settings (fader levels, mutes, routing) that can be
//  re-applied with one tap.
//

import Foundation

/// A single address/value pair to send to the WING.
struct WingSetting: Codable, Hashable, Sendable {
    var address: String
    var value: WingValue
}

/// A named collection of settings, optionally tied to a WING scene number.
struct Preset: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var settings: [WingSetting]
    var wingScene: Int?

    init(id: UUID = UUID(), name: String, settings: [WingSetting] = [], wingScene: Int? = nil) {
        self.id = id
        self.name = name
        self.settings = settings
        self.wingScene = wingScene
    }
}
