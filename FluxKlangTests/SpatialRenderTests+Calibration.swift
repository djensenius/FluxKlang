import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialRenderTests {
    static func calibration(_ raw: String, trim: Double = 0, delay: Double = 0) throws -> SpeakerCalibration {
        try SpeakerCalibration(speaker: id(raw), trimDecibels: trim, delaySeconds: delay)
    }

    @Test func trimIsAttenuateOnlyWithExactEdges() throws {
        let speaker = try Self.id("spk.fl")
        for trim in [-60.0, -6, 0, -0.0] {
            #expect(try Self.calibration("spk.fl", trim: trim).trimDecibels == trim)
        }
        for trim in [(-60.0).nextDown, Double(0.0).nextUp, 1e-9, 6, .nan, .infinity, -.infinity] {
            #expect(throws: SpatialRenderError.invalidTrim(speaker)) { try Self.calibration("spk.fl", trim: trim) }
        }
        #expect(try Self.calibration("spk.fl").linearTrim == 1)
        #expect(abs(try Self.calibration("spk.fl", trim: -60).linearTrim - 0.001) < 1e-15)
        let law = try Self.unmasked(0.2, 0.4)
        let set = try SpatialCalibrationSet(entries: [Self.calibration("spk.fr", trim: -6)])
        let row = try Self.plan(Self.quad(), [Self.source(0.2, 0.4)], calibration: set).row(0)
        #expect(row == [law[0], law[1] * pow(10, -0.3), law[2], law[3]])
    }

    @Test func delayBoundsAndHalfUpRounding() throws {
        let speaker = try Self.id("spk.fl")
        for delay in [0.0, -0.0, 0.05] {
            #expect(try Self.calibration("spk.fl", delay: delay).delaySeconds == delay)
        }
        for delay in [Double(0.05).nextUp, Double(0.0).nextDown, -1e-12, .nan, .infinity] {
            #expect(throws: SpatialRenderError.invalidDelay(speaker)) { try Self.calibration("spk.fl", delay: delay) }
        }
        // 2^-15 s at 16,384 Hz is exactly half a frame.
        let half = 1.0 / 32_768
        let frames = try [half.nextDown, half, 3 * half, 5 * half].map {
            try Self.calibration("spk.fl", delay: $0).delayFrames(sampleRate: 16_384)
        }
        #expect(frames == [0, 1, 2, 3])
        #expect(try Self.calibration("spk.fl", delay: 0.001).delayFrames(sampleRate: 48_000) == 48)
        #expect(try Self.calibration("spk.fl", delay: 0.05).delayFrames(sampleRate: 384_000) == 19_200)
        let entry = try Self.calibration("spk.fl", delay: 0.01)
        #expect(try entry.delayFrames(sampleRate: 8_000) == 80)
        for rate in [Double(8_000.0).nextDown, Double(384_000.0).nextUp, 0, .nan, .infinity] {
            #expect(throws: SpatialRenderError.invalidSampleRate) { try entry.delayFrames(sampleRate: rate) }
            let request = SpatialRenderRequest(layout: try Self.quad(), placements: [], sampleRate: rate)
            #expect(throws: SpatialRenderError.invalidSampleRate) { try SpatialRenderer.plan(request) }
        }
        let set = try SpatialCalibrationSet(entries: [Self.calibration("spk.rl", delay: 0.05)])
        let request = SpatialRenderRequest(layout: try Self.quad(), placements: [], calibration: set,
                                           sampleRate: 384_000)
        #expect(try SpatialRenderer.plan(request).delayFrames == [0, 0, 19_200, 0])
    }

    @Test func calibrationSetBounds() throws {
        #expect(throws: SpatialRenderError.invalidGeneration(-1)) { try SpatialCalibrationSet(generation: -1) }
        #expect(try SpatialCalibrationSet(generation: 0) == .empty)
        let names = (0..<64).map { "spk.\($0)" }
        let layout = try Self.layout(names.indices.map { (Double($0) / 64, 0.0) }, names: names)
        let entries = try names.map { try Self.calibration($0, trim: -1) }
        let full = try SpatialCalibrationSet(generation: 1, entries: entries)
        #expect(try Self.plan(layout, [Self.source(0, 0)], calibration: full).calibrationGeneration == 1)
        #expect(throws: SpatialRenderError.tooManyCalibrationEntries(65)) {
            try SpatialCalibrationSet(entries: entries + [Self.calibration("spk.x")])
        }
        #expect(throws: SpatialRenderError.duplicateCalibration(try Self.id("spk.3"))) {
            try SpatialCalibrationSet(entries: [Self.calibration("spk.3"), Self.calibration("spk.3", trim: -2)])
        }
        let ghost = try SpatialCalibrationSet(entries: [Self.calibration("spk.ghost")])
        #expect(throws: SpatialRenderError.unknownCalibrationSpeaker(try Self.id("spk.ghost"))) {
            try Self.plan(Self.quad(), [Self.source(0, 0)], calibration: ghost)
        }
    }

    @Test func stagedCalibrationNeverMixesWithApplied() throws {
        let law = try Self.unmasked(0.2, 0.4)
        var stage = SpatialCalibrationStage()
        let next = try SpatialCalibrationSet(generation: 1, entries: [
            Self.calibration("spk.fl", trim: -6, delay: 0.001), Self.calibration("spk.fr", trim: -12)
        ])
        try stage.stage(next)
        #expect(stage.pending == next && stage.applied == .empty)
        let before = try Self.plan(Self.quad(), [Self.source(0.2, 0.4)], calibration: stage.applied)
        #expect(before.row(0) == law && before.calibrationGeneration == 0 && before.delayFrames == [0, 0, 0, 0])
        let other = try SpatialCalibrationSet(generation: 1, entries: [Self.calibration("spk.fl", trim: -6)])
        #expect(throws: SpatialRenderError.pendingMismatch) { try stage.promote(expected: other) }
        #expect(stage.applied == .empty)
        try stage.promote(expected: next)
        #expect(stage.applied == next && stage.pending == nil)
        let after = try Self.plan(Self.quad(), [Self.source(0.2, 0.4)], calibration: stage.applied)
        #expect(after.row(0) == [law[0] * pow(10, -0.3), law[1] * pow(10, -0.6), law[2], law[3]])
        #expect(after.calibrationGeneration == 1 && after.delayFrames == [48, 0, 0, 0])
        #expect(throws: SpatialRenderError.noPendingCalibration) { try stage.promote(expected: next) }
        #expect(throws: SpatialRenderError.staleCalibration(expected: 2, found: 1)) { try stage.stage(next) }
        #expect(throws: SpatialRenderError.staleCalibration(expected: 2, found: 3)) {
            try stage.stage(SpatialCalibrationSet(generation: 3))
        }
        try stage.stage(SpatialCalibrationSet(generation: 2))
        stage.discard()
        #expect(stage.pending == nil && stage.applied == next)
        let third = try SpatialCalibrationSet(generation: 2, entries: [Self.calibration("spk.rl", trim: -1)])
        try stage.stage(third)
        try stage.promote(expected: third)
        let replaced = try Self.plan(Self.quad(), [Self.source(0.2, 0.4)], calibration: stage.applied)
        #expect(replaced.row(0) == [law[0], law[1], law[2] * pow(10, -0.05), law[3]])
        #expect(replaced.delayFrames == [0, 0, 0, 0] && stage.applied == third)
        var last = SpatialCalibrationStage(applied: try SpatialCalibrationSet(generation: .max))
        #expect(throws: SpatialRenderError.invalidGeneration(0)) { try last.stage(.empty) }
    }

    @Test func calibrationCodable() throws {
        let set = try SpatialCalibrationSet(generation: 4, entries: [
            Self.calibration("spk.rr", trim: -3, delay: 0.002), Self.calibration("spk.fl", trim: -60)
        ])
        #expect(try JSONDecoder().decode(SpatialCalibrationSet.self, from: JSONEncoder().encode(set)) == set)
        #expect(try JSONDecoder().decode(SpatialCalibrationSet.self, from: Data(#"{"generation":0}"#.utf8)) == .empty)
        let speaker = try Self.id("a")
        let cases: [(String, SpatialRenderError)] = [
            (#"{"speaker":"a","trimDecibels":0.5,"delaySeconds":0}"#, .invalidTrim(speaker)),
            (#"{"speaker":"a","trimDecibels":-61,"delaySeconds":0}"#, .invalidTrim(speaker)),
            (#"{"speaker":"a","trimDecibels":0,"delaySeconds":0.051}"#, .invalidDelay(speaker)),
            (#"{"speaker":"a","trimDecibels":0,"delaySeconds":-1}"#, .invalidDelay(speaker))
        ]
        for (json, error) in cases {
            #expect(Self.renderDecodeError(SpeakerCalibration.self, json) == error)
            let wrapped = #"{"generation":1,"entries":[\#(json)]}"#
            #expect(Self.renderDecodeError(SpatialCalibrationSet.self, wrapped) == error)
        }
        #expect(Self.renderDecodeError(SpatialCalibrationSet.self, #"{"generation":-1}"#) == .invalidGeneration(-1))
        let entry = #"{"speaker":"a","trimDecibels":0,"delaySeconds":0}"#
        #expect(Self.renderDecodeError(SpatialCalibrationSet.self, #"{"generation":0,"entries":[\#(entry),\#(entry)]}"#)
                == .duplicateCalibration(speaker))
    }

    @Test func rampBoundsShapeAndInterpolation() throws {
        let layout = try Self.quad()
        let from = try Self.plan(layout, [Self.source(-1, 1)])
        let to = try Self.plan(layout, [Self.source(1, 1)])
        for frames in [0, 1, 48_000] {
            #expect(try SpatialGainRamp(from: from, to: to, frames: frames).frames == frames)
        }
        for frames in [-1, 48_001] {
            #expect(throws: SpatialRenderError.invalidRampFrames(frames)) {
                try SpatialGainRamp(from: from, to: to, frames: frames)
            }
        }
        let other = try Self.plan(layout, [Self.source("src.b", 1, 1)])
        #expect(throws: SpatialRenderError.shapeMismatch) { try SpatialGainRamp(from: from, to: other, frames: 4) }
        let triangle = try Self.plan(Self.layout(Array(Self.quadPoints.prefix(3))), [Self.source(1, 1)])
        #expect(throws: SpatialRenderError.shapeMismatch) { try SpatialGainRamp(from: from, to: triangle, frames: 4) }
        let jump = try SpatialGainRamp(from: from, to: to, frames: 0)
        #expect((0..<4).allSatisfy { jump.gain(row: 0, speaker: $0, frame: 0) == to.gain(row: 0, speaker: $0) })
        let ramp = try SpatialGainRamp(from: from, to: to, frames: 100)
        for speaker in 0..<4 {
            let start = from.gain(row: 0, speaker: speaker)
            let end = to.gain(row: 0, speaker: speaker)
            #expect(ramp.gain(row: 0, speaker: speaker, frame: 0) == start)
            #expect(ramp.gain(row: 0, speaker: speaker, frame: -5) == start)
            #expect(ramp.gain(row: 0, speaker: speaker, frame: 100) == end)
            #expect(ramp.gain(row: 0, speaker: speaker, frame: 500) == end)
            #expect(ramp.gain(row: 0, speaker: speaker, frame: 50) == start + (end - start) / 2)
            #expect((0...100).allSatisfy {
                let value = ramp.gain(row: 0, speaker: speaker, frame: $0)
                return value >= min(start, end) && value <= max(start, end)
            })
        }
        // Linear amplitude ramps dip in power mid-way and never exceed unit power.
        let midPower = (0..<4).map { ramp.gain(row: 0, speaker: $0, frame: 50) }.reduce(0) { $0 + $1 * $1 }
        #expect(midPower < 1 && midPower > 0.5)
    }
}
