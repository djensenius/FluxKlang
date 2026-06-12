//
//  AppNavigationTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

@MainActor
struct AppNavigationTests {
    @Test func requestSpatialPlacementSelectsSpatialSection() {
        let model = AppModel()
        model.section = .environments
        model.requestSpatialPlacement()
        #expect(model.section == .spatial)
    }

    @Test func requestNewPresetSelectsPresetsSection() {
        let model = AppModel()
        model.section = .faders
        model.requestNewPreset()
        #expect(model.section == .presets)
    }
}
