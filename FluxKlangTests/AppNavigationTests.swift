//
//  AppNavigationTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

@MainActor
struct AppNavigationTests {
    @Test func appStartsInStudio() {
        let model = AppModel()
        #expect(model.section == .studio)
    }

    @Test func requestSpatialPlacementReturnsToStudio() {
        let model = AppModel()
        model.section = .advanced
        model.requestSpatialPlacement()
        #expect(model.section == .studio)
    }

    @Test func requestNewPresetSelectsPresetsSection() {
        let model = AppModel()
        model.section = .faders
        model.requestNewPreset()
        #expect(model.section == .presets)
    }
}
