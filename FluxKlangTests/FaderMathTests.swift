//
//  FaderMathTests.swift
//  FluxKlangTests
//

import Testing
@testable import FluxKlang

struct FaderMathTests {
    @Test func unityGainSitsAtThreeQuarters() {
        #expect(FaderMath.position(fromDecibels: 0) == 0.75)
        #expect(FaderMath.decibels(fromPosition: 0.75) == 0)
    }

    @Test(arguments: [
        (Float(1.0), Float(10)),
        (Float(0.75), Float(0)),
        (Float(0.5), Float(-10)),
        (Float(0.25), Float(-30)),
        (Float(0.0625), Float(-60))
    ])
    func knownBreakpoints(position: Float, decibels: Float) {
        #expect(abs(FaderMath.decibels(fromPosition: position) - decibels) < 0.0001)
        #expect(abs(FaderMath.position(fromDecibels: decibels) - position) < 0.0001)
    }

    @Test(arguments: [Float(0.05), 0.1, 0.3, 0.6, 0.9, 1.0])
    func positionRoundTripsThroughDecibels(position: Float) {
        let decibels = FaderMath.decibels(fromPosition: position)
        #expect(abs(FaderMath.position(fromDecibels: decibels) - position) < 0.0001)
    }

    @Test func clampsOutOfRangeInputs() {
        #expect(FaderMath.position(fromDecibels: 100) == 1)
        #expect(FaderMath.position(fromDecibels: -200) == 0)
        #expect(FaderMath.decibels(fromPosition: 2) == FaderMath.maximumDecibels)
        #expect(FaderMath.decibels(fromPosition: -1) == FaderMath.minimumDecibels)
    }

    @Test func reportsOffAndFormatsLabels() {
        #expect(FaderMath.isOff(position: 0))
        #expect(FaderMath.isOff(position: 0.5) == false)
        #expect(FaderMath.label(forPosition: 0) == "-∞ dB")
        #expect(FaderMath.label(forPosition: 0.75) == "0.0 dB")
        #expect(FaderMath.label(forPosition: 1.0) == "10.0 dB")
    }
}
