import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension SpatialMixerTests {
    struct RefusalCase {
        let plan: SpatialRenderPlan
        let ramp: Int
        let expected: SpatialMixerRefusal
    }

    struct Lcg {
        var seed: UInt64

        mutating func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 33
        }

        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    static let longDelayRate = 48_200.0

    static func fiveSources() -> [Source] { ["a", "b", "c", "d", "e"].map { source($0, 0.2) } }

    static func midRampPlans() throws -> (start: SpatialRenderPlan, target: SpatialRenderPlan) {
        let delays = [Delay(speaker: 1, frames: 2), Delay(speaker: 2, frames: 3)]
        return try (plan([0, 1, 2], of: 3, base, delays: delays),
                    plan([0, 1, 2], of: 3, base, masks: [mute(1)], delays: delays))
    }

    /// A mixer with a non-default state: a ramp of 12 frames, 5 frames in, ring history in every delay line.
    static func midRamp(maxRows: Int = 4, maxSpeakers: Int = 3) throws -> SpatialBlockMixer {
        let plans = try midRampPlans()
        var mixer = try mixer(plans.start, rows: maxRows, speakers: maxSpeakers)
        _ = stream(&mixer, total: 9, block: 9)
        try mixer.transition(to: plans.target, rampFrames: 12)
        _ = stream(&mixer, total: 5, block: 5)
        return mixer
    }

    /// True when both mixers report the same state and produce the same output for the next 40 frames.
    static func sameFuture(_ lhs: inout SpatialBlockMixer, _ rhs: inout SpatialBlockMixer) -> Bool {
        let equalState = snapshot(lhs) == snapshot(rhs)
        return equalState && stream(&lhs, total: 40, block: 6) == stream(&rhs, total: 40, block: 6)
    }

    static func longDelayPlan(
        _ sources: [Source], ids: [Int] = [0, 1, 2], delays: [Delay]
    ) throws -> SpatialRenderPlan {
        try plan(ids, of: 4, sources, delays: delays, rate: longDelayRate)
    }

    @Test func aRefusedTransitionChangesNothingWhateverTheReason() throws {
        let fine = try Self.plan([0, 1, 2], of: 3, [Self.base[0]])
        let tooManyRows = try Self.plan([0, 1, 2], of: 3, Self.fiveSources())
        let tooManySpeakers = try Self.plan([0, 1, 2, 3], of: 4, [Self.base[0]])
        let late = try Self.longDelayPlan([Self.base[0]], delays: [Delay(speaker: 2, frames: 2_405)])
        let refusals = [
            RefusalCase(plan: fine, ramp: 48_001, expected: .invalidRampFrames(48_001)),
            RefusalCase(plan: fine, ramp: -1, expected: .invalidRampFrames(-1)),
            RefusalCase(plan: fine, ramp: 4, expected: .transitionInProgress),
            RefusalCase(plan: tooManyRows, ramp: 4, expected: .planTooLarge),
            RefusalCase(plan: tooManySpeakers, ramp: 4, expected: .planTooLarge),
            RefusalCase(plan: late, ramp: 4, expected: .delayTooLong(2_405))
        ]
        for refusal in refusals {
            var touched = try Self.midRamp()
            var twin = try Self.midRamp()
            #expect(Self.snapshot(touched).progress == 5 && Self.snapshot(touched).write == 14)
            #expect(throws: refusal.expected) { try touched.transition(to: refusal.plan, rampFrames: refusal.ramp) }
            #expect(Self.sameFuture(&touched, &twin), "\(refusal.expected)")
        }
    }

    @Test func aRampOutsideTheRangeBeatsEveryOtherDefectInBothDirections() throws {
        let broken = try Self.longDelayPlan(Self.fiveSources(), delays: [Delay(speaker: 0, frames: 2_405)])
        for ramp in [48_001, -1, Int.max, Int.min] {
            var mixer = try Self.midRamp()
            #expect(throws: SpatialMixerRefusal.invalidRampFrames(ramp)) {
                try mixer.transition(to: broken, rampFrames: ramp)
            }
        }
        var legal = try Self.midRamp()
        #expect(throws: SpatialMixerRefusal.planTooLarge) { try legal.transition(to: broken, rampFrames: 48_000) }
    }

    @Test func aPlanThatIsTooLargeBeatsATooLongDelayAndABusyRamp() throws {
        let rows = try Self.longDelayPlan(Self.fiveSources(), delays: [Delay(speaker: 0, frames: 2_405)])
        let speakers = try Self.longDelayPlan(
            [Self.base[0]], ids: [0, 1, 2, 3], delays: [Delay(speaker: 3, frames: 2_405)]
        )
        for plan in [rows, speakers] {
            var mixer = try Self.midRamp()
            #expect(throws: SpatialMixerRefusal.planTooLarge) { try mixer.transition(to: plan, rampFrames: 6) }
        }
    }

    @Test func aTooLongDelayBeatsABusyRampAndReportsTheFirstOffendingSpeaker() throws {
        let cases: [([Delay], Int)] = [
            ([Delay(speaker: 1, frames: 2_405), Delay(speaker: 2, frames: 2_410)], 2_405),
            ([Delay(speaker: 1, frames: 2_410), Delay(speaker: 2, frames: 2_405)], 2_410),
            ([Delay(speaker: 2, frames: 2_405)], 2_405)
        ]
        for (delays, first) in cases {
            var mixer = try Self.midRamp()
            let plan = try Self.longDelayPlan([Self.base[0]], delays: delays)
            #expect(throws: SpatialMixerRefusal.delayTooLong(first)) { try mixer.transition(to: plan, rampFrames: 6) }
        }
    }

    @Test func aDelayEqualToTheCapacityIsAcceptedByATransition() throws {
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0)]))
        try mixer.transition(to: Self.unitPlan([Self.source("a", 0)], delay: 2_400), rampFrames: 0)
        #expect(Self.snapshot(mixer).plan.delayFrames == [2_400])
    }

    @Test func framesOutsideTheLimitSilenceTheWholeOutputAndLeaveTheStateAlone() throws {
        for bad in [-1, 65, Int.max, Int.min] {
            var touched = try Self.midRamp()
            var twin = try Self.midRamp()
            let rows = touched.inputRowCount
            let input = [Float](repeating: 1, count: rows * 64)
            var output = [Float](repeating: Self.sentinel, count: touched.outputSpeakerCount * 64)
            let result = input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { touched.process(frames: bad, input: source, output: $0) }
            }
            #expect(result == .refused(.invalidFrames(bad)))
            #expect(output.allSatisfy { $0 == 0 })
            #expect(Self.sameFuture(&touched, &twin), "frames \(bad)")
        }
    }

    @Test func zeroFramesDoNothingAndOneOrMaximumFramesAreProcessed() throws {
        var touched = try Self.midRamp()
        var twin = try Self.midRamp()
        let input = [Float](repeating: 1, count: touched.inputRowCount * 64)
        var output = [Float](repeating: Self.sentinel, count: touched.outputSpeakerCount * 64)
        let none = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { touched.process(frames: 0, input: source, output: $0) }
        }
        #expect(none == .processed(sanitizedSamples: 0))
        #expect(output.allSatisfy { $0 == Self.sentinel })
        #expect(Self.sameFuture(&touched, &twin))
        var single = try Self.mixer(Self.unitPlan([Self.source("a", 0)]))
        let one = Self.run(&single, [[3]], frames: 1)
        #expect(one.result == .processed(sanitizedSamples: 0) && one.columns == [[3]])
        let full = Self.run(&single, [Self.counting(64)], frames: 64)
        #expect(full.columns == [Self.counting(64)])
        #expect(Self.snapshot(single).write == 65)
    }

    @Test func aBufferOneElementTooLongOrShortIsRefusedWithoutTouchingMemory() throws {
        for (extraInput, extraOutput) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            var mixer = try Self.midRamp()
            var twin = try Self.midRamp()
            let shape = Self.snapshot(mixer)
            let input = [Float](repeating: 1, count: shape.rows * 64 + extraInput)
            var output = [Float](repeating: Self.sentinel, count: shape.columns * 64 + extraOutput)
            let result = input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { mixer.process(frames: 8, input: source, output: $0) }
            }
            #expect(result == .refused(.geometryMismatch))
            #expect(output.allSatisfy { $0 == Self.sentinel })
            #expect(Self.snapshot(mixer).progress == 5 && Self.snapshot(mixer).transitioning)
            #expect(Self.sameFuture(&mixer, &twin))
        }
    }

    /// One slab holding input at `0..<64` and output at `offset..<(offset + 64)` (both one row, one speaker).
    static func overlapResult(
        offset: Int, frames: Int = 8, inputCount: Int = 64
    ) throws -> (SpatialMixerResult, [Float]) {
        var mixer = try mixer(unitPlan([source("a", 0)]))
        var slab = (0..<256).map { Float($0 % 5) + 1 }
        let result = slab.withUnsafeMutableBufferPointer { buffer -> SpatialMixerResult in
            let base = buffer.baseAddress
            let source = UnsafeBufferPointer(start: base.map { $0 + max(0, -offset) }, count: inputCount)
            let output = UnsafeMutableBufferPointer(start: base.map { $0 + max(0, offset) }, count: 64)
            return mixer.process(frames: frames, input: source, output: output)
        }
        return (result, slab)
    }

    @Test func overlappingBuffersAreRefusedByOneElementAndAdjacentBuffersAreAccepted() throws {
        let pristine = (0..<256).map { Float($0 % 5) + 1 }
        for offset in [0, 1, 32, 63, -1, -32, -63] {
            let outcome = try Self.overlapResult(offset: offset)
            #expect(outcome.0 == .refused(.overlappingBuffers), "offset \(offset)")
            #expect(outcome.1 == pristine, "offset \(offset)")
        }
        for offset in [64, -64, 100] {
            let outcome = try Self.overlapResult(offset: offset)
            #expect(outcome.0 == .processed(sanitizedSamples: 0), "offset \(offset)")
        }
    }

    @Test func geometryIsRefusedBeforeOverlapAndOverlapBeforeFrames() throws {
        let pristine = (0..<256).map { Float($0 % 5) + 1 }
        let wrongCount = try Self.overlapResult(offset: 1, inputCount: 63)
        #expect(wrongCount.0 == .refused(.geometryMismatch) && wrongCount.1 == pristine)
        let badFrames = try Self.overlapResult(offset: 1, frames: -1)
        #expect(badFrames.0 == .refused(.overlappingBuffers) && badFrames.1 == pristine)
        let lateFrames = try Self.overlapResult(offset: 64, frames: 65)
        #expect(lateFrames.0 == .refused(.invalidFrames(65)))
        var mixer = try Self.mixer(Self.unitPlan([Self.source("a", 0)]))
        var output = [Float](repeating: Self.sentinel, count: 64)
        let countAndFrames = [Float](repeating: 1, count: 63).withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { mixer.process(frames: 99, input: source, output: $0) }
        }
        #expect(countAndFrames == .refused(.geometryMismatch) && output.allSatisfy { $0 == Self.sentinel })
    }

    @Test func theLargestLimitsInitialiseProcessAndTransitionToAnEntirelyDifferentPlan() throws {
        let oldSources = (0..<64).map { Self.source("o\($0)", Double($0) / 64 - 0.5, channels: 2) }
        let newSources = (0..<64).map { Self.source("n\($0)", 0.5 - Double($0) / 64, channels: 2) }
        let old = try Self.plan(Array(0..<64), of: 128, oldSources, rate: 384_000)
        let new = try Self.plan(Array(64..<128), of: 128, newSources, rate: 384_000)
        #expect(old.rowCount == 128 && new.speakerCount == 64)
        let maximum = try SpatialMixerLimits.make(maxFrames: 8_192, sampleRate: 384_000, maxRows: 128, maxSpeakers: 64)
        var fixed = try SpatialBlockMixer(limits: maximum, initial: old)
        var moving = try SpatialBlockMixer(limits: maximum, initial: old)
        try moving.transition(to: new, rampFrames: 48_000)
        #expect(moving.inputRowCount == 256 && moving.outputSpeakerCount == 128)
        let rows = (0..<256).map { Self.constant(Float($0 % 7) + 1, 8) }
        let still = Self.run(&fixed, Array(rows[128..<256]), frames: 8)
        let ramp = Self.run(&moving, rows, frames: 8)
        #expect(still.result == .processed(sanitizedSamples: 0) && ramp.result == .processed(sanitizedSamples: 0))
        try #require(still.columns.count == 64 && ramp.columns.count == 128)
        try #require(still.columns.allSatisfy { $0.count == 8 } && ramp.columns.allSatisfy { $0.count == 8 })
        #expect(still.columns.contains { $0[0] != 0 })
        for speaker in 0..<64 {
            #expect(ramp.columns[speaker][0] == 0)
            #expect(ramp.columns[64 + speaker][0] == still.columns[speaker][0])
        }
        #expect(ramp.columns[0..<64].contains { $0[7] != 0 })
        #expect(ramp.columns.joined().allSatisfy { $0.isFinite })
    }

    @Test func aLongRunOfRandomBlocksPlansAndHostileSamplesStaysFinite() throws {
        var random = Lcg(seed: 0x5EED_0115)
        let plans = try [
            Self.plan([0, 1, 2], of: 3, Self.base, delays: [Delay(speaker: 0, frames: 9)]),
            Self.plan([2, 3], of: 4, [Self.base[2], Self.source("d", 0.4)], delays: [Delay(speaker: 3, frames: 31)]),
            Self.plan([0, 1, 2, 3], of: 4, Self.fiveSources(), masks: [Self.solo(1)], renormalize: true)
        ]
        var mixer = try Self.mixer(plans[0])
        let specials: [Float] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 0]
        var seenRamps = 0
        for _ in 0..<400 {
            if random.below(6) == 0 {
                let ramp = random.below(5) == 0 ? 0 : random.below(70)
                do {
                    try mixer.transition(to: plans[random.below(3)], rampFrames: ramp)
                    seenRamps += 1
                } catch {
                    #expect(error == .transitionInProgress)
                }
            }
            let frames = random.below(65)
            let rows = (0..<mixer.inputRowCount).map { _ in
                (0..<frames).map { _ in
                    random.below(5) == 0
                        ? specials[random.below(specials.count)]
                        : Float(random.below(2_001)) / 1_000 - 1
                }
            }
            let nonFinite = rows.joined().filter { !$0.isFinite }.count
            let block = Self.run(&mixer, rows, frames: frames)
            guard case .processed(let sanitized) = block.result else {
                Issue.record("a legal block was refused")
                return
            }
            #expect(sanitized >= nonFinite)
            #expect(block.columns.joined().allSatisfy { $0.isFinite })
        }
        #expect(seenRamps > 20)
    }

    @Test func anEmptyInputBufferInsideTheOutputRangeIsNotAnOverlap() throws {
        var mixer = try Self.mixer(Self.plan([0, 1], of: 2, []))
        var output = [Float](repeating: Self.sentinel, count: 2 * 64)
        let result = output.withUnsafeMutableBufferPointer { destination -> SpatialMixerResult in
            let inside = UnsafeBufferPointer(start: UnsafePointer(destination.baseAddress.map { $0 + 8 }), count: 0)
            return mixer.process(frames: 4, input: inside, output: destination)
        }
        #expect(result == .processed(sanitizedSamples: 0))
        #expect(Array(output[0..<4]) == Self.constant(0, 4) && Array(output[64..<68]) == Self.constant(0, 4))
    }
}
