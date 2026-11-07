import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialMixerTests {
    /// Streams one impulse per input row through a long run and returns the column of each speaker.
    static func impulseResponse(_ mixer: inout SpatialBlockMixer, rows: [Int], total: Int, block: Int) -> [[Float]] {
        let speakers = mixer.outputSpeakerCount
        var columns = [[Float]](repeating: [], count: speakers)
        var start = 0
        while start < total {
            let frames = min(block, total - start)
            let input = rows.map { position in
                (0..<frames).map { start + $0 == position ? Float(1) : 0 }
            }
            let result = run(&mixer, input, frames: frames)
            for (speaker, column) in result.columns.prefix(speakers).enumerated() { columns[speaker] += column }
            start += frames
        }
        return columns
    }

    @Test func eachSpeakerDelaysEveryRowByItsOwnFrames() throws {
        let delays = [Delay(speaker: 0, frames: 0), Delay(speaker: 1, frames: 1), Delay(speaker: 2, frames: 17)]
        let plan = try Self.plan([0, 1, 2], of: 3, [Self.source("a", -0.5), Self.source("b", 0.5)], delays: delays)
        #expect(plan.delayFrames == [0, 1, 17])
        var mixer = try Self.mixer(plan)
        let columns = Self.impulseResponse(&mixer, rows: [0, 2], total: 40, block: 40)
        try #require(columns.count == 3)
        for speaker in 0..<3 {
            var expected = Self.constant(0, 40)
            let shift = delays[speaker].frames
            expected[shift] = Float(plan.gain(row: 0, speaker: speaker))
            expected[shift + 2] = Float(plan.gain(row: 1, speaker: speaker))
            #expect(columns[speaker] == expected)
        }
    }

    @Test func delayedOutputIsTheInputShiftedAcrossBlocksOfSeven() throws {
        let plan = try Self.unitPlan([Self.source("a", 0)], delay: 17)
        var mixer = try Self.mixer(plan)
        var collected: [Float] = []
        var next = 1
        for _ in 0..<9 {
            let samples = (0..<7).map { Float(next + $0) }
            next += 7
            let block = Self.run(&mixer, [samples], frames: 7)
            try #require(block.columns.count == 1)
            collected += block.columns[0]
        }
        let expected: [Float] = (0..<63).map { $0 >= 17 ? Float($0 - 17 + 1) : 0 }
        #expect(collected == expected)
        #expect(Self.snapshot(mixer).write == 63)
    }

    @Test func aDelayEqualToTheCapacityIsAcceptedAndExact() throws {
        let plan = try Self.unitPlan([Self.source("a", 0)], delay: 400, rate: 8_000)
        #expect(plan.delayFrames == [400])
        var mixer = try Self.mixer(plan, rate: 8_000)
        let columns = Self.impulseResponse(&mixer, rows: [3], total: 450, block: 64)
        #expect(columns == [Self.impulse(at: 403, count: 450)])
    }

    @Test func aDelayOneBeyondTheCapacityIsRefusedAtInitAndAtTransition() throws {
        let over = try Self.unitPlan([Self.source("a", 0)], delay: 401, rate: 8_020)
        #expect(over.delayFrames == [401])
        #expect(throws: SpatialMixerRefusal.delayTooLong(401)) { _ = try Self.mixer(over, rate: 8_000) }
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0)], delay: 400, rate: 8_000), rate: 8_000)
        let before = Self.snapshot(mixer)
        #expect(throws: SpatialMixerRefusal.delayTooLong(401)) { try mixer.transition(to: over, rampFrames: 8) }
        #expect(Self.snapshot(mixer) == before)
    }

    @Test func theCapacityAt44100HertzIsExactAcrossOneLongBlock() throws {
        let plan = try Self.unitPlan([Self.source("a", 0)], delay: 2_205, rate: 44_100)
        var mixer = try Self.mixer(plan, maxFrames: 8_192, rate: 44_100, rows: 1, speakers: 1)
        let columns = Self.impulseResponse(&mixer, rows: [5], total: 2_300, block: 2_300)
        #expect(columns == [Self.impulse(at: 2_210, count: 2_300)])
    }

    @Test func theCapacityAt384KilohertzIsExactAcrossThreeFullBlocks() throws {
        let plan = try Self.unitPlan([Self.source("a", 0)], delay: 19_200, rate: 384_000)
        var mixer = try Self.mixer(plan, maxFrames: 8_192, rate: 384_000, rows: 1, speakers: 1)
        let total = 3 * 8_192
        let columns = Self.impulseResponse(&mixer, rows: [100], total: total, block: 8_192)
        #expect(columns == [Self.impulse(at: 19_300, count: total)])
    }

    @Test func aSpeakerWithZeroDelayPassesTheSameFrameThrough() throws {
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0)]))
        #expect(Self.run(&mixer, [Self.counting(5)], frames: 5).columns == [Self.counting(5)])
    }
}
