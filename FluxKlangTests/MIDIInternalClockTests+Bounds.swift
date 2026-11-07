import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIInternalClockTests {
    // MARK: - Windows

    @Test
    func aWindowAcceptsOneFrameUpToTheMaximumLookaheadAndRefusesBothSidesOfThatRange() throws {
        for count in [Int64(1), 384_000] {
            let window = try Self.window(10, count)
            #expect(window.frameCount == count)
            #expect(window.endFrame == 10 + count)
        }
        for count in [Int64(0), 384_001, -1, Int64.min, Int64.max] {
            #expect(throws: MIDIInternalClockError.windowOutOfRange(startFrame: 10, frameCount: count)) {
                try Self.window(10, count)
            }
        }
    }

    @Test
    func aWindowMayEndExactlyAtTheLargestFrameAndRefusesAnEndPastIt() throws {
        let atEdge = try Self.window(Int64.max - 1, 1)
        #expect(atEdge.endFrame == Int64.max)
        let lowest = try Self.window(Int64.min, 1)
        #expect(lowest.endFrame == Int64.min + 1)
        #expect(throws: MIDIInternalClockError.windowOutOfRange(startFrame: Int64.max - 1, frameCount: 2)) {
            try Self.window(Int64.max - 1, 2)
        }
        #expect(throws: MIDIInternalClockError.windowOutOfRange(startFrame: Int64.max, frameCount: 1)) {
            try Self.window(Int64.max, 1)
        }
    }

    @Test
    func aWindowRecordsItsSampleGenerationStartCountAndExclusiveEnd() throws {
        let second = try Generation(2)
        let window = try Self.window(-100, 300, sampleGeneration: second)
        #expect(window.sampleGeneration == second)
        #expect(window.startFrame == -100)
        #expect(window.frameCount == 300)
        #expect(window.endFrame == 200)
    }

    @Test
    func aWindowOfTheMaximumLookaheadPlansThreeHundredEightyFourPulsesAtOneTwentyBPM() throws {
        let running = try Self.started()
        let window = try Self.window(0, MIDIInternalClockPlan.maximumLookaheadFrames)
        let plan = try Self.plan(running, Self.map(for: running), window)
        #expect(plan.events.count == 385)
        #expect(plan.events.first == Self.event(0, .start))
        #expect(plan.events.last == Self.clock(383_000, 383))
    }

    // MARK: - Plan capacity (192 kHz at 60,000 microseconds per quarter: one pulse every 480 frames)

    @Test
    func aWindowOfOnlyPulsesHoldsFiveHundredTwelveAndRefusesFiveHundredThirteen() throws {
        let running = try Self.started()
        let map = try Self.map(for: running, rate: 192_000, tempos: [(0, 60_000)])
        let full = try Self.plan(running, map, Self.window(480, 245_760))
        #expect(full.events.count == 512)
        #expect(full.events.first == Self.clock(480, 1))
        #expect(full.events.last == Self.clock(245_760, 512))
        #expect(throws: MIDIInternalClockError.capacityExceeded(maximum: 512)) {
            try Self.plan(running, map, Self.window(480, 246_240))
        }
    }

    @Test
    func aStartPlusFiveHundredElevenPulsesFitsAndFiveHundredTwelvePulsesAreRefused() throws {
        let running = try Self.started()
        let map = try Self.map(for: running, rate: 192_000, tempos: [(0, 60_000)])
        let full = try Self.plan(running, map, Self.window(0, 244_801))
        #expect(full.events.count == 512)
        #expect(full.events.first == Self.event(0, .start))
        #expect(full.events.last == Self.clock(244_800, 510))
        #expect(throws: MIDIInternalClockError.capacityExceeded(maximum: 512)) {
            try Self.plan(running, map, Self.window(0, 245_281))
        }
    }

    @Test
    func aSongPositionPlusContinuePlusFiveHundredTenPulsesFitsAndFiveHundredElevenAreRefused() throws {
        let running = try Self.continued(fromTicks: 3_840, atFrame: 0)
        let map = try Self.map(for: running, rate: 192_000, tempos: [(0, 60_000)], anchorTicks: 3_840)
        let full = try Self.plan(running, map, Self.window(0, 244_321))
        #expect(full.events.count == 512)
        #expect(full.events.first == Self.event(0, .songPosition(1)))
        #expect(full.events.last == Self.clock(244_320, 515))
        #expect(throws: MIDIInternalClockError.capacityExceeded(maximum: 512)) {
            try Self.plan(running, map, Self.window(0, 244_801))
        }
    }

    @Test
    func fiveHundredElevenPulsesPlusAStopFitAndFiveHundredTwelveAreRefused() throws {
        let running = try Self.started()
        let startMap = try Self.map(for: running, rate: 192_000, tempos: [(0, 60_000)])
        let fitting = try running.stopping(atFrame: 245_281, in: startMap)
        let fittingMap = try Self.map(for: fitting, rate: 192_000, tempos: [(0, 60_000)])
        let full = try Self.plan(fitting, fittingMap, Self.window(480, 244_802))
        #expect(full.events.count == 512)
        #expect(full.events.first == Self.clock(480, 1))
        #expect(full.events.last == Self.event(245_281, .stop))
        let overfull = try running.stopping(atFrame: 245_761, in: startMap)
        let overfullMap = try Self.map(for: overfull, rate: 192_000, tempos: [(0, 60_000)])
        #expect(throws: MIDIInternalClockError.capacityExceeded(maximum: 512)) {
            try Self.plan(overfull, overfullMap, Self.window(480, 245_282))
        }
    }
}
