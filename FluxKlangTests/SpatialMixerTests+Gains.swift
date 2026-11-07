import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialMixerTests {
    static func unitPlan(_ sources: [Source], delay: Int = 0, rate: Double = 48_000) throws -> SpatialRenderPlan {
        try plan([0], of: 1, sources, delays: delay == 0 ? [] : [Delay(speaker: 0, frames: delay)], rate: rate)
    }

    @Test func aSingleSpeakerPlanHasUnitGainForEveryRow() throws {
        let plan = try Self.unitPlan([Self.source("a", 0), Self.source("b", 0.5, channels: 2)])
        #expect(plan.gains == [1, 1, 1])
    }

    @Test func staticPlanAppliesTheGainMatrixToOneImpulsePerRow() throws {
        let plan = try Self.plan([0, 1, 2], of: 3, [Self.source("a", -0.8), Self.source("b", 0.6, channels: 2)])
        var mixer = try Self.mixer(plan)
        let impulses: [[Float]] = [
            Self.impulse(at: 0, 0.5, count: 5), Self.impulse(at: 1, -2, count: 5), Self.impulse(at: 2, 4, count: 5)
        ]
        let block = Self.run(&mixer, impulses, frames: 5)
        #expect(block.result == .processed(sanitizedSamples: 0))
        try #require(block.columns.count == 3 && block.columns.allSatisfy { $0.count == 5 })
        let values: [Float] = [0.5, -2, 4]
        for speaker in 0..<3 {
            for row in 0..<3 {
                #expect(block.columns[speaker][row] == Float(plan.gain(row: row, speaker: speaker)) * values[row])
            }
            #expect(block.columns[speaker][3] == 0 && block.columns[speaker][4] == 0)
        }
        #expect(plan.rowCount == 3 && plan.speakerCount == 3)
        #expect(plan.gain(row: 0, speaker: 0) != plan.gain(row: 0, speaker: 2))
    }

    @Test func everySpeakerSumsAllRowsAtTheSameFrame() throws {
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0), Self.source("b", 0), Self.source("c", 0)]))
        let rows = [Self.constant(0.25, 4), Self.constant(0.5, 4), Self.constant(0.125, 4)]
        let block = Self.run(&mixer, rows, frames: 4)
        #expect(block.columns == [[0.875, 0.875, 0.875, 0.875]])
    }

    @Test func aGainIsClampedToTheUnitIntervalAndANonFiniteGainBecomesZero() {
        let cases: [(Double, Float)] = [
            (1.5, 1), (-0.5, 0), (.nan, 0), (.infinity, 0), (-.infinity, 0), (0, 0), (1, 1), (0.25, 0.25),
            (.greatestFiniteMagnitude, 1), (-.greatestFiniteMagnitude, 0)
        ]
        for (value, expected) in cases {
            #expect(SpatialPlanTransition.floatGain(value) == expected, "\(value)")
        }
    }

    @Test func aMutedSpeakerColumnIsExactlySilent() throws {
        let plan = try Self.plan([0, 1, 2], of: 3, [Self.source("a", -0.9)], masks: [Self.mute(1)])
        var mixer = try Self.mixer(plan)
        let block = Self.run(&mixer, [Self.constant(1, 6)], frames: 6)
        try #require(block.columns.count == 3 && block.columns.allSatisfy { $0.count == 6 })
        #expect(block.columns[1] == Self.constant(0, 6))
        #expect(block.columns[0] == Self.constant(Float(plan.gain(row: 0, speaker: 0)), 6))
        #expect(block.columns[0][0] > 0 && block.columns[2][0] > 0)
    }

    @Test func slabPaddingBeyondTheFramesAndTheInputAreNeverTouched() throws {
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0), Self.source("b", 0)]))
        let stride = 64
        var input = [Float](repeating: 9, count: 2 * stride)
        for frame in 0..<5 { input[frame] = Float(frame + 1) }
        let before = input
        var output = [Float](repeating: Self.sentinel, count: stride)
        let result = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { mixer.process(frames: 5, input: source, output: $0) }
        }
        #expect(result == .processed(sanitizedSamples: 0))
        #expect(input == before)
        #expect(Array(output[0..<5]) == [10, 11, 12, 13, 14])
        #expect(Array(output[5...]) == Self.constant(Self.sentinel, stride - 5))
    }

    @Test func nonFiniteInputIsReadAsZeroAndCountedPerSample() throws {
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0), Self.source("b", 0)]))
        let first: [Float] = [1, .nan, .infinity, -.infinity, 2]
        let second: [Float] = [.nan, 0.5, 0.25, 0.125, .nan]
        let block = Self.run(&mixer, [first, second], frames: 5)
        #expect(block.result == .processed(sanitizedSamples: 5))
        #expect(block.columns == [[1, 0.5, 0.25, 0.125, 2]])
    }

    @Test func nonFiniteInputCountsAcrossBlocksOnlyForTheBlockProcessed() throws {
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0)]))
        let bad: [Float] = [.nan, .nan, .nan, 1]
        #expect(Self.run(&mixer, [bad], frames: 2).result == .processed(sanitizedSamples: 2))
        #expect(Self.run(&mixer, [bad], frames: 4).result == .processed(sanitizedSamples: 3))
        #expect(Self.run(&mixer, [Self.constant(1, 4)], frames: 4).result == .processed(sanitizedSamples: 0))
    }

    @Test func overflowingSumsAreSilencedAndCounted() throws {
        let plan = try Self.plan(
            [0], of: 1, [Self.source("a", 0), Self.source("b", 0)], delays: [Delay(speaker: 0, frames: 2)]
        )
        var mixer = try Self.mixer(plan)
        let big = Float.greatestFiniteMagnitude
        let block = Self.run(&mixer, [[big, 1, 1, 1, 1], [big, 1, 1, 1, 1]], frames: 5)
        #expect(block.result == .processed(sanitizedSamples: 1))
        #expect(block.columns == [[0, 0, 0, 2, 2]])
        for sample in block.columns.joined() { #expect(sample.isFinite) }
    }

    @Test func extremeFiniteInputStaysFiniteAndExact() throws {
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0)]))
        let extremes: [Float] = [.greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNonzeroMagnitude, 0]
        let block = Self.run(&mixer, [extremes], frames: 4)
        #expect(block.result == .processed(sanitizedSamples: 0))
        #expect(block.columns == [extremes])
    }

    @Test func sourcesInAnotherOrderGiveTheSameOutputWhenInputFollowsThePlan() throws {
        let sources = [Self.source("a", -0.7), Self.source("b", 0.2, channels: 2), Self.source("c", 0.9)]
        let natural = try Self.plan([0, 1, 2], of: 3, sources)
        let permuted = try Self.plan([0, 1, 2], of: 3, [sources[2], sources[0], sources[1]])
        var first = try Self.mixer(natural)
        var second = try Self.mixer(permuted)
        let signals: [String: [Float]] = ["a#0": Self.counting(8), "b#0": Self.constant(0.5, 8),
                                          "b#1": Self.impulse(at: 3, 2, count: 8), "c#0": Self.constant(-1, 8)]
        func rows(_ mixer: borrowing SpatialBlockMixer) -> [[Float]] {
            mixer.inputRowKeys.map { signals["\($0.source.rawValue)#\($0.channel)"] ?? [] }
        }
        let one = Self.run(&first, rows(first), frames: 8)
        let two = Self.run(&second, rows(second), frames: 8)
        #expect(one.columns == two.columns)
        #expect(one.columns.joined().contains { $0 != 0 })
        #expect(first.inputRowKeys.map(\.source.rawValue) == ["a", "b", "b", "c"])
        #expect(second.inputRowKeys.map(\.source.rawValue) == ["c", "a", "b", "b"])
    }
}
