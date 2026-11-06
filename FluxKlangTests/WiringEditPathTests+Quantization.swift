//
//  WiringEditPathTests+Quantization.swift
//  FluxKlangTests
//
//  Non-finite quantization regression.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WiringEditPathTests {
    @Test func nudgeOutsideDecimalRangeFallsBackToCoordinateArithmetic() throws {
        let coordinate = 1e200
        let graph = try Self.keys(at: coordinate, coordinate)
        let draft = WiringEditFixture.draft(on: graph), distance = 1e190
        let grid = WiringEditFixture.grid(step: distance, fineStep: distance)
        let state = try WiringMoveComposer.nudge(
            Self.keys, WiringNudge(.rightward), grid: grid,
            in: WiringMoveState(draft: draft), active: graph
        )
        let typed = try WiringMoveComposer.move(
            Self.keys, x: coordinate + distance, y: coordinate, in: draft, active: graph
        )
        #expect(state.draft == typed)
        #expect(Self.movedX(state.draft) == coordinate + distance)
        #expect(state.anchor(for: Self.keys) == WiringMoveAnchor(
            horizontal: coordinate + distance, vertical: coordinate, offsetX: .zero, offsetY: .zero
        ))
    }

    @Test func quantizedPreservesNonFiniteValues() {
        #expect(WiringMoveComposer.quantized(.nan).isNaN)
        #expect(WiringMoveComposer.quantized(.infinity) == .infinity)
        #expect(WiringMoveComposer.quantized(-.infinity) == -.infinity)
    }
}
