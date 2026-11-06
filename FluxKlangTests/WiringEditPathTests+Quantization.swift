//
//  WiringEditPathTests+Quantization.swift
//  FluxKlangTests
//
//  Non-finite quantization regression.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WiringEditPathTests {
    @Test func largeFineNudgesMatchNumericTies() throws {
        let oddOffset = 0x1p-13
        let bases = [1e12, 1e12 + oddOffset, -1e12, -(1e12 + oddOffset)]
        for base in bases {
            try Self.checkLargeTie(base: base, horizontal: true)
            try Self.checkLargeTie(base: base, horizontal: false)
        }
    }

    @Test func stepValueUsesFifteenDigitRule() throws {
        #expect(WiringMoveComposer.stepValue(of: 0.1) == Decimal(string: "0.1"))
        #expect(WiringMoveComposer.stepValue(of: 0.000006103515625) == Decimal(string: "6.103515625e-06"))
        #expect(WiringMoveComposer.stepValue(of: 0.123456789012345) == Decimal(string: "0.123456789012345"))
        #expect(WiringMoveComposer.stepValue(of: 0x1p-31)
            == Decimal(string: "4.656612873077392578125e-10"))
        #expect(WiringMoveComposer.stepValue(of: 0) == .zero)
        #expect(WiringMoveComposer.stepValue(of: .nan) == nil)
        #expect(WiringMoveComposer.stepValue(of: .infinity) == nil)

        let graph = try Self.keys(at: 0)
        let state = try WiringMoveComposer.nudge(
            Self.keys, WiringNudge(.leftward, fine: true), grid: WiringEditFixture.grid(step: 0.1, fineStep: 0.1),
            in: WiringMoveState(draft: WiringEditFixture.draft(on: graph)), active: graph
        )
        #expect(Self.movedX(state.draft) == -0.1)
    }

    private static func checkLargeTie(base: Double, horizontal: Bool) throws {
        let positive = base > 0
        let direction: WiringNudgeDirection
        let opposite: WiringNudgeDirection
        if horizontal {
            direction = positive ? .rightward : .leftward
            opposite = positive ? .leftward : .rightward
        } else {
            direction = positive ? .downward : .upward
            opposite = positive ? .upward : .downward
        }
        let delta = (positive ? 1.0 : -1.0) * 0.00006103515625
        let graph = try Self.keys(at: base, base)
        let draft = WiringEditFixture.draft(on: graph)
        let grid = WiringEditFixture.grid(step: 0.1, fineStep: 0.000006103515625)
        var state = WiringMoveState(draft: draft)
        for _ in 0..<10 {
            state = try WiringMoveComposer.nudge(
                Self.keys, WiringNudge(direction, fine: true), grid: grid, in: state, active: graph
            )
        }
        let numeric = try WiringMoveComposer.move(
            Self.keys, x: horizontal ? base + delta : base, y: horizontal ? base : base + delta,
            in: draft, active: graph
        )
        #expect(state.draft == numeric)
        if base.magnitude == 1e12 { #expect(state.draft == draft) }
        for _ in 0..<10 {
            state = try WiringMoveComposer.nudge(
                Self.keys, WiringNudge(opposite, fine: true), grid: grid, in: state, active: graph
            )
        }
        #expect(state.draft == draft)
    }

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
