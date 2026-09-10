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

    @Test func requestNewPresetSelectsMixScenes() {
        let model = AppModel()
        model.section = .studio
        model.requestNewPreset()
        #expect(model.section == .mix)
        #expect(model.mixDestination == .scenes)
    }

    @Test func selectingStripUsesMixFaders() {
        let model = AppModel()
        let strip = FaderStrip(node: .channel(1))

        model.mixDestination = .scenes
        model.selectStrip(strip)

        #expect(model.section == .mix)
        #expect(model.mixDestination == .faders)
    }
}
