import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Automation block rendering")
struct AutomationRenderTests {
    static let primary = ClockID(validated: "smp.main")
    static let musical = ClockID(validated: "mus.main")
    static let level = ParameterID(validated: "ch.01.fdr")
    static let fader = ControlSourceID(validated: "ctl.fader")
    static let live = ClockGenerationSnapshot(sample: .initial, transport: .initial, musicalMap: .initial)
    static let quarter = MusicalTime.ticksPerQuarter

    /// A clock whose anchor puts `ticks` on `frame`; 120 BPM at 48 kHz by default.
    static func clock(frame: Int64 = 0, ticks: Int64 = 0, rate: Int = 48_000, revision: Generation = .initial,
                      segments: [(Int64, Int64)] = [(0, 500_000)]) throws -> MusicalClockMap {
        let anchor = ClockAnchor(
            sample: SampleStamp(clock: primary, generation: .initial, frame: frame), host: HostStamp(ticks: 0),
            musical: MusicalStamp(transport: .initial, musicalMap: revision, ticks: ticks, loopIteration: 0)
        )
        let map = try MusicalMap(clock: musical, revision: revision,
                                 segments: segments.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) })
        return try MusicalClockMap(anchor: anchor, map: map, nominalRate: rate,
                                   currentSample: .initial, currentTransport: .initial)
    }

    static func lane(_ points: [AutomationBreakpoint]) throws -> AutomationLane {
        let descriptor = try ParameterDescriptor(.init(
            id: level, unit: .normalized, lower: 0, upper: 1, defaultValue: 0, ceiling: nil, curve: .linear,
            ramp: .step, controlClass: .live, verification: .unverified
        ))
        return try AutomationLane(descriptor: descriptor, breakpoints: points)
    }

    /// 0 → 1 linear over 0…1000, holds 1 until it jumps to 0.2 at 2000, then 0.2 → 0.8 linear to 3000.
    static func ramp() throws -> AutomationLane {
        try lane([.init(ticks: 0, value: 0), .init(ticks: 1_000, value: 1, interpolation: .step),
                  .init(ticks: 2_000, value: 0.2), .init(ticks: 3_000, value: 0.8)])
    }

    static func renderer(_ lane: AutomationLane, mode: AutomationMode = .touch,
                         resume: AutomationResume = .glide(ticks: 100),
                         loop: LoopRange? = nil) throws -> AutomationBlockRenderer {
        AutomationBlockRenderer(arbiter: try ParameterArbiter(lane: lane, mode: mode, resume: resume), loop: loop)
    }

    /// Renders `[start, start + sum(blocks))` block by block and returns every event.
    static func render(_ renderer: inout AutomationBlockRenderer, from start: Int64, blocks: [Int64],
                       clock: MusicalClockMap) throws -> [AutomationRampEvent] {
        var events: [AutomationRampEvent] = []
        var frame = start
        for length in blocks {
            let block = try renderer.render(from: frame, to: frame + length, clock: clock, current: live)
            #expect(block.allSatisfy { $0.frame >= frame && $0.frame < frame + length })
            #expect(block.allSatisfy { Int64($0.offset) == $0.frame - frame })
            events += block
            frame += length
        }
        return events
    }

    /// The exact musical position of `frame`, as the renderer reads it.
    static func position(_ clock: MusicalClockMap, _ frame: Int64) -> Double {
        let exact = clock.exactTicks(atFrame: frame)
        return AutomationExactTicks(numerator: exact.numerator, denominator: exact.denominator).position
    }

    /// Random block lengths in `1...maximum` that add up to `total`.
    static func splits(_ total: Int64, seed: UInt64, maximum: Int = 4_096) -> [Int64] {
        var random = SplitMix(state: seed)
        var blocks: [Int64] = []
        var left = total
        while left > 0 {
            let length = min(left, Int64(random.int(1...maximum)))
            blocks.append(length)
            left -= length
        }
        return blocks
    }

    /// The value a host following `events` holds at each frame of `[start, end)`, from `initial`.
    static func trajectory(_ events: [AutomationRampEvent], from start: Int64, to end: Int64,
                           initial: Double = 0) -> [Double] {
        var from = initial, target = initial, rampStart = start, rampEnd = start
        func value(at frame: Int64) -> Double {
            guard frame < rampEnd else { return target }
            return from + (target - from) * Double(frame - rampStart) / Double(rampEnd - rampStart)
        }
        var values: [Double] = []
        var index = 0
        for frame in start..<end {
            while index < events.count, events[index].frame == frame {
                from = value(at: frame)
                target = events[index].value
                rampStart = frame
                rampEnd = frame + events[index].rampFrames
                index += 1
            }
            values.append(value(at: frame))
        }
        return values
    }

    struct SplitMix {
        var state: UInt64

        mutating func int(_ range: ClosedRange<Int>) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return range.lowerBound + Int((mixed ^ (mixed >> 31)) % UInt64(range.count))
        }
    }

    @Test func firstBlockStartsAtTheLaneValueAndRampsBetweenMappedBreakpoints() throws {
        var renderer = try Self.renderer(Self.ramp())
        let events = try renderer.render(from: 0, to: 4_096, clock: Self.clock(), current: Self.live)
        // One tick is 1.5625 frames: breakpoints map to frames 0, 1563 (half-up), 3125 and 4688.
        #expect(events == [
            AutomationRampEvent(frame: 0, offset: 0, value: 0, rampFrames: 0, reason: .start),
            AutomationRampEvent(frame: 0, offset: 0, value: 1, rampFrames: 1_563, reason: .start),
            AutomationRampEvent(frame: 3_125, offset: 3_125, value: 0.2, rampFrames: 0, reason: .curve),
            AutomationRampEvent(frame: 3_125, offset: 3_125, value: 0.8, rampFrames: 1_563, reason: .curve)
        ])
        #expect(renderer.cursor == 4_096)
        #expect(renderer.binding == Self.live)
        #expect(renderer.isRenderingLane)
    }

    @Test func aFirstBlockInsideARampStartsThereAndHeadsForTheNextBreakpoint() throws {
        var renderer = try Self.renderer(Self.ramp())
        let clock = try Self.clock()
        let events = try renderer.render(from: 800, to: 1_000, clock: clock, current: Self.live)
        let start = try #require(try Self.ramp().value(at: Self.position(clock, 800)))
        #expect(events == [
            AutomationRampEvent(frame: 800, offset: 0, value: start, rampFrames: 0, reason: .start),
            AutomationRampEvent(frame: 800, offset: 0, value: 1, rampFrames: 763, reason: .start)
        ])
    }

    @Test func coincidentBreakpointsJumpAtTheirSharedFrame() throws {
        var renderer = try Self.renderer(Self.lane([.init(ticks: 0, value: 0), .init(ticks: 1_000, value: 1),
                                                    .init(ticks: 1_000, value: 0.2), .init(ticks: 2_000, value: 0.8)]))
        let events = try renderer.render(from: 0, to: 4_096, clock: Self.clock(), current: Self.live)
        #expect(events == [
            AutomationRampEvent(frame: 0, offset: 0, value: 0, rampFrames: 0, reason: .start),
            AutomationRampEvent(frame: 0, offset: 0, value: 1, rampFrames: 1_563, reason: .start),
            AutomationRampEvent(frame: 1_563, offset: 1_563, value: 0.2, rampFrames: 0, reason: .curve),
            AutomationRampEvent(frame: 1_563, offset: 1_563, value: 0.8, rampFrames: 1_562, reason: .curve)
        ])
    }

    static func splitLanes() throws -> [AutomationLane] {
        try [
            Self.ramp(),
            Self.lane([.init(ticks: 100, value: 0.1, interpolation: .power(0.25)), .init(ticks: 2_100, value: 0.9),
                       .init(ticks: 2_100, value: 0.3, interpolation: .power(4)), .init(ticks: 7_000, value: 1)]),
            Self.lane((0..<64).map { .init(ticks: Int64($0) * 97, value: Double($0 % 5) / 4, interpolation: .step) })
        ]
    }

    @Test func singleFrameBlocksRenderTheSameEventsAsOneBlock() throws {
        let clock = try Self.clock(rate: 44_100, segments: [(0, 500_000), (1_500, 380_000)])
        for lane in try Self.splitLanes() {
            var whole = try Self.renderer(lane)
            let expected = try whole.render(from: 0, to: 12_000, clock: clock, current: Self.live)
            var split = try Self.renderer(lane)
            let events = try Self.render(&split, from: 0, blocks: Array(repeating: 1, count: 12_000), clock: clock)
            #expect(events.map(\.frame) == expected.map(\.frame))
            #expect(events.map(\.value) == expected.map(\.value))
            #expect(events.map(\.rampFrames) == expected.map(\.rampFrames))
            #expect(events.map(\.reason) == expected.map(\.reason))
        }
    }

    @Test func aFirstBlockOnARoundedBreakpointFrameStartsPastIt() throws {
        // Tick 1000 maps to 1562.5, rounded to frame 1563, whose position is 1000.32 ticks.
        var renderer = try Self.renderer(Self.ramp())
        let events = try renderer.render(from: 1_563, to: 2_000, clock: Self.clock(), current: Self.live)
        #expect(events == [AutomationRampEvent(frame: 1_563, offset: 0, value: 1, rampFrames: 0, reason: .start)])
    }

    @Test func aBlockEndNeverPassesABreakpointItHasNotVisited() throws {
        var renderer = try Self.renderer(Self.ramp(), mode: .latch)
        let clock = try Self.clock()
        _ = try renderer.render(from: 0, to: 500, clock: clock, current: Self.live)
        _ = try renderer.perform(.touch(Self.fader, priority: 1))
        _ = try renderer.perform(.move(Self.fader, to: 0.5))
        _ = try renderer.render(from: 500, to: 600, clock: clock, current: Self.live)
        _ = try renderer.perform(.release(Self.fader))
        #expect(renderer.arbiter.owner == .latched(until: 1_000))
        // The block ends on the breakpoint's frame (1563), past its tick, but the breakpoint belongs to the next block.
        _ = try renderer.render(from: 600, to: 1_563, clock: clock, current: Self.live)
        #expect(renderer.arbiter.owner == .latched(until: 1_000))
        _ = try renderer.render(from: 1_563, to: 1_564, clock: clock, current: Self.live)
        #expect(renderer.arbiter.owner != .latched(until: 1_000))
    }

    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6])
    func anySplitIntoBlocksRendersTheSameEvents(seed: UInt64) throws {
        let lanes = try Self.splitLanes()
        let clocks = try [Self.clock(), Self.clock(rate: 44_100, segments: [(0, 500_000), (1_500, 380_000)])]
        for lane in lanes {
            for clock in clocks {
                var whole = try Self.renderer(lane)
                let expected = try whole.render(from: 0, to: 20_000, clock: clock, current: Self.live)
                var split = try Self.renderer(lane)
                let events = try Self.render(&split, from: 0, blocks: Self.splits(20_000, seed: seed), clock: clock)
                #expect(events.map(\.frame) == expected.map(\.frame))
                #expect(events.map(\.value) == expected.map(\.value))
                #expect(events.map(\.rampFrames) == expected.map(\.rampFrames))
                #expect(split.arbiter.value == whole.arbiter.value)
                #expect(split.cursor == whole.cursor)
            }
        }
    }

    @Test(arguments: [44_100, 96_000])
    func breakpointsLandOnTheirMappedFramesWithTheirValuesAtEveryRate(rate: Int) throws {
        let lane = try Self.lane([.init(ticks: 0, value: 0), .init(ticks: 1_000, value: 1),
                                  .init(ticks: 2_000, value: 0.25, interpolation: .step),
                                  .init(ticks: 2_500, value: 0.5), .init(ticks: 4_000, value: 0)])
        let clock = try Self.clock(rate: rate)
        var renderer = try Self.renderer(lane)
        let end = try clock.frame(atTicks: 4_500)
        let events = try Self.render(&renderer, from: 0, blocks: Self.splits(end, seed: 9, maximum: 777), clock: clock)
        let values = Self.trajectory(events, from: 0, to: end)
        for point in lane.breakpoints {
            let frame = try clock.frame(atTicks: point.ticks)
            #expect(abs(values[Int(frame)] - point.value) < 1e-12, "tick \(point.ticks) at \(rate) Hz")
        }
        let reference = try Self.renderer(lane)
        var other = reference
        let others = try other.render(from: 0, to: try Self.clock(rate: 48_000).frame(atTicks: 4_500),
                                      clock: Self.clock(rate: 48_000), current: Self.live)
        #expect(events.map(\.value) == others.map(\.value))
        #expect(events.map(\.reason) == others.map(\.reason))
    }

    @Test func eventsUpToTheLimitAreReturnedAndOneMoreIsRefused() throws {
        func steps(_ count: Int) throws -> AutomationLane {
            try Self.lane((0..<count).map { .init(ticks: Int64($0), value: Double($0 % 2), interpolation: .step) })
        }
        var full = try Self.renderer(steps(AutomationBlockRenderer.maximumEvents))
        #expect(try full.render(from: 0, to: 4_096, clock: Self.clock(), current: Self.live).count
            == AutomationBlockRenderer.maximumEvents)
        var over = try Self.renderer(steps(AutomationBlockRenderer.maximumEvents + 1))
        let before = over
        #expect(throws: AutomationRenderRefusal.tooManyEvents(limit: AutomationBlockRenderer.maximumEvents)) {
            try over.render(from: 0, to: 4_096, clock: Self.clock(), current: Self.live)
        }
        #expect(over == before)
    }

    @Test func blocksUpToTheLimitRenderAndLongerOrEmptyBlocksAreRefused() throws {
        let limit = AutomationBlockRenderer.maximumBlockFrames
        var renderer = try Self.renderer(Self.ramp())
        let clock = try Self.clock()
        let before = renderer
        #expect(throws: AutomationRenderRefusal.windowTooLong(start: 0, end: limit + 1, limit: limit)) {
            try renderer.render(from: 0, to: limit + 1, clock: clock, current: Self.live)
        }
        #expect(throws: AutomationRenderRefusal.invalidWindow(start: 5, end: 5)) {
            try renderer.render(from: 5, to: 5, clock: clock, current: Self.live)
        }
        #expect(throws: AutomationRenderRefusal.windowTooLong(start: .min, end: .max, limit: limit)) {
            try renderer.render(from: .min, to: .max, clock: clock, current: Self.live)
        }
        #expect(renderer == before)
        _ = try renderer.render(from: 0, to: limit, clock: clock, current: Self.live)
        #expect(renderer.cursor == limit)
    }

    @Test func refusedRendersLeaveTheRendererUnchanged() throws {
        var renderer = try Self.renderer(Self.ramp())
        let clock = try Self.clock()
        _ = try renderer.render(from: 0, to: 512, clock: clock, current: Self.live)
        let before = renderer
        #expect(throws: AutomationRenderRefusal.nonContiguousWindow(expected: 512, start: 513)) {
            try renderer.render(from: 513, to: 600, clock: clock, current: Self.live)
        }
        let newer = try Generation(2)
        let staleSample = ClockGenerationSnapshot(sample: newer, transport: .initial, musicalMap: .initial)
        #expect(throws: AutomationRenderRefusal.clock(.staleSampleGeneration)) {
            try renderer.render(from: 512, to: 600, clock: clock, current: staleSample)
        }
        let staleTransport = ClockGenerationSnapshot(sample: .initial, transport: newer, musicalMap: .initial)
        #expect(throws: AutomationRenderRefusal.clock(.staleTransport)) {
            try renderer.render(from: 512, to: 600, clock: clock, current: staleTransport)
        }
        let staleMap = ClockGenerationSnapshot(sample: .initial, transport: .initial, musicalMap: newer)
        #expect(throws: AutomationRenderRefusal.staleMusicalMap) {
            try renderer.render(from: 512, to: 600, clock: clock, current: staleMap)
        }
        #expect(throws: AutomationRenderRefusal.clockRevisionChanged(expected: Self.live, got: staleMap)) {
            try renderer.render(from: 512, to: 600, clock: Self.clock(revision: newer), current: staleMap)
        }
        // One frame is 0.64 ticks: the same whole tick, another fraction.
        #expect(throws: AutomationRenderRefusal.positionMismatch(frame: 512)) {
            try renderer.render(from: 512, to: 600, clock: Self.clock(frame: 1), current: Self.live)
        }
        #expect(renderer == before)
        _ = try renderer.render(from: 512, to: 600, clock: clock, current: Self.live)
        #expect(renderer.cursor == 600)
    }

    @Test func resetForgetsTheBindingSoANewMapStartsAfresh() throws {
        var renderer = try Self.renderer(Self.ramp())
        _ = try renderer.render(from: 0, to: 512, clock: Self.clock(), current: Self.live)
        renderer.reset()
        #expect(renderer.cursor == nil && renderer.binding == nil && !renderer.isRenderingLane)
        let newer = try Generation(2)
        let current = ClockGenerationSnapshot(sample: .initial, transport: .initial, musicalMap: newer)
        let events = try renderer.render(from: 9_000, to: 9_100, clock: Self.clock(revision: newer), current: current)
        #expect(events.first?.reason == .start)
        #expect(renderer.binding == current)
    }

    @Test func aGestureBetweenBlocksOnALaneWithoutBreakpointsIsRenderedWhenAutomationResumesAtOnce() throws {
        let clock = try Self.clock()
        var renderer = try Self.renderer(Self.lane([]))
        #expect(try renderer.render(from: 0, to: 100, clock: clock, current: Self.live).isEmpty)
        // With nothing to resume from, a released touch hands the value straight back: automation owns it again
        // before the next block, which must show what the gesture left, not the value shown before it.
        for (index, value) in [0.25, 0.75, 0.5].enumerated() {
            let start = Int64(100 * (index + 1))
            _ = try renderer.perform(.touch(Self.fader, priority: 1))
            _ = try renderer.perform(.move(Self.fader, to: value))
            #expect(try renderer.perform(.release(Self.fader)).owner == .automation)
            let events = try renderer.render(from: start, to: start + 100, clock: clock, current: Self.live)
            #expect(events == [AutomationRampEvent(frame: start, offset: 0, value: value, rampFrames: 0,
                                                   reason: .resume)])
            #expect(renderer.isRenderingLane)
        }
        #expect(try renderer.render(from: 400, to: 500, clock: clock, current: Self.live).isEmpty)
    }

    @Test func aTouchAfterAnAtOnceHandBackHoldsTheValueAutomationResumedWithNotTheHostsStaleOne() throws {
        let clock = try Self.clock()
        var renderer = try Self.renderer(Self.lane([]))
        #expect(try renderer.render(from: 0, to: 100, clock: clock, current: Self.live).isEmpty)
        _ = try renderer.perform(.touch(Self.fader, priority: 1))
        _ = try renderer.perform(.move(Self.fader, to: 0.25))
        _ = try renderer.perform(.release(Self.fader))
        _ = try renderer.render(from: 100, to: 200, clock: clock, current: Self.live)
        // The host shows 0.25. Within one block the user moves to 0.75, automation resumes with it at once and the
        // user touches again: the touch holds 0.75, which the next block shows, not the 0.25 the host still shows.
        _ = try renderer.perform(.touch(Self.fader, priority: 1))
        _ = try renderer.perform(.move(Self.fader, to: 0.75))
        #expect(try renderer.perform(.release(Self.fader)).owner == .automation)
        #expect(try renderer.perform(.touch(Self.fader, priority: 1)).value == 0.75)
        let events = try renderer.render(from: 200, to: 300, clock: clock, current: Self.live)
        #expect(events == [AutomationRampEvent(frame: 200, offset: 0, value: 0.75, rampFrames: 0, reason: .hold)])
    }
}
