import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private struct HostGolden {
    let frame: Int64
    let ticks: Int64
    let quarters: Int64
    let rest: Int64
}

/// Builds the real accepted ledger and timeline of the host context tests from the contract constructors, so the file
/// needs no other test file: 48,000 Hz nominal rate, timebase 125 over 3, one tempo map.
private struct HostTimelineSource {
    let primary = ClockID(validated: "sample.foundation")
    let musical = ClockID(validated: "musical.foundation")

    func timeline(
        loop: LoopRange?, running: Bool, frame: Int64, ticks: Int64, segments: [(Int64, Int64)]
    ) throws -> MusicalTimeline {
        let ledger = try GenerationLedger(primaryClock: primary, musicalClock: musical, nominalRate: 48_000)
        let transport = try #require(ledger.generation(GenerationKey(.transport, musical)))
        let revision = try #require(ledger.generation(GenerationKey(.musicalMap, musical)))
        let sample = SampleStamp(
            clock: primary, generation: try #require(ledger.generation(ledger.primaryClock)), frame: frame)
        let sampleAnchor = ClockAnchor(sample: sample, host: .init(ticks: 0), musical: nil)
        let musicalAnchor = ClockAnchor(
            sample: sample, host: .init(ticks: 0),
            musical: .init(transport: transport, musicalMap: revision, ticks: ticks, loopIteration: 0))
        let map = try MusicalMap(
            clock: musical, revision: revision,
            segments: segments.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) })
        return try MusicalTimeline(
            sample: SampleClockMap(anchor: sampleAnchor, nominalRate: 48_000, timebase: .init(numer: 125, denom: 3)),
            anchor: musicalAnchor, map: map, loop: loop, running: running, historyLimit: 8, pinLimit: 4,
            ledger: ledger)
    }
}

/// AU host musical context for one render block (#73, slice BRC1a). Golden numbers are typed by hand: 120 BPM
/// (500,000 us per quarter) at 48,000 Hz is 24,000 frames per quarter, so 0.64 tick per frame; 250,000 us per quarter
/// is 1.28 ticks per frame.
extension AUEventBridgeTests {
    private static func hostSummary(
        running: Bool = true, loop: LoopRange? = nil, frame: Int64 = 0, ticks: Int64 = 0,
        segments: [(Int64, Int64)] = [(0, 500_000)]
    ) throws -> SchedulerMusicalSummary {
        let timeline = try HostTimelineSource().timeline(
            loop: loop, running: running, frame: frame, ticks: ticks, segments: segments)
        return SchedulerMusicalSummary(timeline)
    }

    private static func hostNegotiated(
        rate: Int, frames: Int = 512, at generation: CapabilityGeneration = .initial
    ) throws -> NegotiatedRender {
        let stereo = [try RenderBusSpec(channels: 2)]
        let spec = try RenderResourceSpec(
            sampleRateHz: rate, maximumFrames: frames, format: .float32, inputs: stereo, outputs: stereo)
        let capabilities = try HostedRenderCapabilities(
            maximumFramesToRender: 16_384, minimumSampleRateHz: 8_000, maximumSampleRateHz: 384_000,
            formats: [.float32, .float64])
        return try RenderResourceNegotiator.negotiate(
            spec, layout: try PluginBusLayout(inputChannels: [2], outputChannels: [2]), capabilities: capabilities,
            generation: generation)
    }

    /// Builds at a 48,000 Hz negotiation of 512 frames made at `.initial` unless told otherwise.
    private static func hostBuild(
        _ summary: SchedulerMusicalSummary, frame: Int64 = 0, frames: Int = 64,
        negotiated: NegotiatedRender? = nil, live: CapabilityGeneration = .initial
    ) throws -> AUHostContext {
        try AUHostContext.make(
            summary, negotiated: try negotiated ?? Self.negotiated(frames: 512), live: live,
            blockStartFrame: frame, blockFrames: frames)
    }

    @Test func hostContextGoldenRunningBlocksCarryTheExactTempoBeatAndBinding() throws {
        let summary = try Self.hostSummary()
        let live = try Self.generation(2, 3, 4)
        let negotiated = try Self.negotiated(frames: 512, at: live)
        let cases = [
            HostGolden(frame: 0, ticks: 0, quarters: 0, rest: 0), HostGolden(frame: 1, ticks: 1, quarters: 0, rest: 1),
            HostGolden(frame: 100, ticks: 64, quarters: 0, rest: 64),
            HostGolden(frame: 24_000, ticks: 15_360, quarters: 1, rest: 0),
            HostGolden(frame: 36_000, ticks: 23_040, quarters: 1, rest: 7_680)
        ]
        for item in cases {
            let context = try Self.hostBuild(
                summary, frame: item.frame, frames: 480, negotiated: negotiated, live: live)
            #expect(context.beatPositionTicks == item.ticks)
            #expect(context.quarterNotes == item.quarters)
            #expect(context.ticksIntoQuarter == item.rest)
            #expect(context.microsPerQuarter == 500_000)
            #expect(context.isTransportMoving)
            #expect(context.sampleRateHz == 48_000)
            #expect(context.blockStartFrame == item.frame)
            #expect(context.blockFrames == 480)
            #expect(context.generation == live)
        }
        let anchored = try Self.hostSummary(frame: 48_000, ticks: 15_360)
        let atZero = try Self.hostBuild(anchored, frame: 24_000)
        #expect(atZero.beatPositionTicks == 0)
    }

    @Test func hostContextTempoChangesAtTheSegmentBoundaryTick() throws {
        let two: [(Int64, Int64)] = [(0, 500_000), (15_360, 250_000)]
        let summary = try Self.hostSummary(segments: two)
        let before = try Self.hostBuild(summary, frame: 23_999)
        #expect(before.beatPositionTicks == 15_359)
        #expect(before.microsPerQuarter == 500_000)
        let atBoundary = try Self.hostBuild(summary, frame: 24_000)
        #expect(atBoundary.beatPositionTicks == 15_360)
        #expect(atBoundary.microsPerQuarter == 250_000)
        let inSecond = try Self.hostBuild(summary, frame: 36_000)
        #expect(inSecond.beatPositionTicks == 30_720)
        #expect(inSecond.microsPerQuarter == 250_000)
        let three: [(Int64, Int64)] = [(0, 500_000), (15_360, 250_000), (30_720, 1_000_000)]
        let third = try Self.hostBuild(try Self.hostSummary(segments: three), frame: 36_000)
        #expect(third.beatPositionTicks == 30_720)
        #expect(third.microsPerQuarter == 1_000_000)
        let backward = try Self.hostSummary(frame: 36_000, ticks: 30_720, segments: three)
        let across = try Self.hostBuild(backward, frame: 24_000)
        #expect(across.beatPositionTicks == 15_360)
        #expect(across.microsPerQuarter == 250_000)
    }

    @Test func hostContextStoppedTransportHoldsTheAnchorTickAndIgnoresTheFrame() throws {
        let stopped = try Self.hostSummary(running: false, ticks: 7_680)
        for frame: Int64 in [0, 1_000_000, Int64.max] {
            let held = try Self.hostBuild(stopped, frame: frame)
            #expect(held.beatPositionTicks == 7_680)
            #expect(held.microsPerQuarter == 500_000)
            #expect(!held.isTransportMoving)
            #expect(held.blockStartFrame == frame)
        }
        let running = try Self.hostSummary(running: true, ticks: 7_680)
        let moved = try Self.hostBuild(running, frame: 1_000_000)
        #expect(moved.beatPositionTicks == 647_680)
        #expect(moved.isTransportMoving)
    }

    @Test func hostContextRateBindingRefusesANegotiationAtAnotherRate() throws {
        let summary = try Self.hostSummary()
        for rate in [44_100, 96_000] {
            let other = try Self.hostNegotiated(rate: rate)
            #expect(throws: AUHostContextRefusal.rateMismatch(summaryHz: 48_000, negotiatedHz: rate)) {
                try Self.hostBuild(summary, negotiated: other)
            }
        }
        let same = try Self.hostNegotiated(rate: 48_000)
        #expect(try Self.hostBuild(summary, negotiated: same).sampleRateHz == 48_000)
        let stopped = try Self.hostSummary(running: false, ticks: 7_680)
        let other = try Self.hostNegotiated(rate: 44_100)
        #expect(throws: AUHostContextRefusal.rateMismatch(summaryHz: 48_000, negotiatedHz: 44_100)) {
            try Self.hostBuild(stopped, negotiated: other)
        }
    }

    @Test func hostContextGenerationBindingRefusesStaleAxesAtBuild() throws {
        let summary = try Self.hostSummary()
        let planned = try Self.generation(1, 1, 1)
        let negotiated = try Self.negotiated(frames: 512, at: planned)
        let rateChanged = try Self.generation(1, 2, 1)
        #expect(throws: AUHostContextRefusal.negotiationStale([.sampleRate])) {
            try Self.hostBuild(summary, negotiated: negotiated, live: rateChanged)
        }
        let resourcesChanged = try Self.generation(2, 1, 1)
        #expect(throws: AUHostContextRefusal.negotiationStale([.resources])) {
            try Self.hostBuild(summary, negotiated: negotiated, live: resourcesChanged)
        }
        let both = try Self.generation(2, 2, 1)
        #expect(throws: AUHostContextRefusal.negotiationStale([.resources, .sampleRate])) {
            try Self.hostBuild(summary, negotiated: negotiated, live: both)
        }
        let latencyOnly = try Self.generation(1, 1, 2)
        let accepted = try Self.hostBuild(summary, negotiated: negotiated, live: latencyOnly)
        #expect(accepted.generation == latencyOnly)
        let stopped = try Self.hostSummary(running: false, ticks: 7_680)
        #expect(throws: AUHostContextRefusal.negotiationStale([.resources, .sampleRate])) {
            try Self.hostBuild(stopped, negotiated: negotiated, live: both)
        }
        #expect(try Self.hostBuild(stopped, negotiated: negotiated, live: latencyOnly).generation == latencyOnly)
    }

    @Test func hostContextValidateRefusesAStaleContextButNotALatencyChange() throws {
        let summary = try Self.hostSummary()
        let built = try Self.generation(1, 2, 3)
        let negotiated = try Self.negotiated(frames: 512, at: try Self.generation(1, 2, 1))
        let context = try Self.hostBuild(summary, negotiated: negotiated, live: built)
        try context.validate(against: built)
        try context.validate(against: try Self.generation(1, 2, 9))
        #expect(throws: AUHostContextRefusal.contextStale([.sampleRate])) {
            try context.validate(against: try Self.generation(1, 3, 3))
        }
        #expect(throws: AUHostContextRefusal.contextStale([.resources])) {
            try context.validate(against: try Self.generation(4, 2, 3))
        }
        #expect(throws: AUHostContextRefusal.contextStale([.resources, .sampleRate])) {
            try context.validate(against: try Self.generation(4, 3, 3))
        }
        #expect(throws: AUHostContextRefusal.contextStale([.sampleRate])) {
            try context.validate(against: try Self.generation(1, 3, 9))
        }
    }

    @Test func hostContextBlockAndFrameLimitsHoldAtTheirEdges() throws {
        let summary = try Self.hostSummary()
        for frames in [0, -1] {
            #expect(throws: AUHostContextRefusal.invalidBlock(frames)) { try Self.hostBuild(summary, frames: frames) }
        }
        #expect(try Self.hostBuild(summary, frames: 1).blockFrames == 1)
        #expect(try Self.hostBuild(summary, frames: 512).blockFrames == 512)
        let tooBig = AUHostContextRefusal.blockExceedsNegotiated(blockFrames: 513, maximumFrames: 512)
        #expect(throws: tooBig) { try Self.hostBuild(summary, frames: 513) }
        let huge = AUHostContextRefusal.blockExceedsNegotiated(blockFrames: Int.max, maximumFrames: 512)
        #expect(throws: huge) { try Self.hostBuild(summary, frames: Int.max) }
        #expect(RenderNegotiationLimits.maximumFrames == 16_384)
        let wide = try Self.hostNegotiated(rate: 48_000, frames: 16_384)
        #expect(try Self.hostBuild(summary, frames: 16_384, negotiated: wide).blockFrames == 16_384)
        let beyond = AUHostContextRefusal.blockExceedsNegotiated(blockFrames: 16_385, maximumFrames: 16_384)
        #expect(throws: beyond) { try Self.hostBuild(summary, frames: 16_385, negotiated: wide) }
        #expect(throws: AUHostContextRefusal.negativeFrame(-1)) { try Self.hostBuild(summary, frame: -1) }
        #expect(throws: AUHostContextRefusal.negativeFrame(Int64.min)) { try Self.hostBuild(summary, frame: .min) }
        #expect(try Self.hostBuild(summary, frame: 0).blockStartFrame == 0)
        let stopped = try Self.hostSummary(running: false, ticks: 7_680)
        #expect(throws: AUHostContextRefusal.negativeFrame(-1)) { try Self.hostBuild(stopped, frame: -1) }
        #expect(try Self.hostBuild(stopped, frame: 0).blockStartFrame == 0)
    }

    @Test func hostContextActiveLoopIsRefusedWhetherTheTransportRunsOrStops() throws {
        let loop = try LoopRange(startTicks: 0, endTicks: 15_360)
        for running in [true, false] {
            let summary = try Self.hostSummary(running: running, loop: loop)
            #expect(throws: AUHostContextRefusal.loopActive) { try Self.hostBuild(summary) }
        }
    }

    @Test func hostContextBeforeTheOriginAndOverflowAreTypedRefusals() throws {
        let behind = try Self.hostSummary(frame: 48_000, ticks: 15_360)
        let origin = AUHostContextRefusal.beforeMusicalOrigin(ticks: -7_680)
        #expect(throws: origin) { try Self.hostBuild(behind, frame: 12_000) }
        let fast: [(Int64, Int64)] = [(0, 60_000)]
        let running = try Self.hostSummary(segments: fast)
        #expect(throws: AUHostContextRefusal.ticksOverflow) { try Self.hostBuild(running, frame: .max) }
        let stopped = try Self.hostSummary(running: false, segments: fast)
        #expect(try Self.hostBuild(stopped, frame: .max).beatPositionTicks == 0)
    }

    @Test func hostContextRefusalOrderHoldsWithAllDefectsInOneFixture() throws {
        let loop = try LoopRange(startTicks: 0, endTicks: 15_360)
        let planned = try Self.generation(1, 1, 1)
        let live = try Self.generation(1, 2, 1)
        let otherRate = try Self.hostNegotiated(rate: 44_100, at: planned)
        for running in [true, false] {
            try Self.expectOrder(running: running, loop: loop, planned: planned, live: live, otherRate: otherRate)
        }
        let fast = try Self.hostSummary(loop: loop, segments: [(0, 60_000)])
        #expect(throws: AUHostContextRefusal.loopActive) { try Self.hostBuild(fast, frame: .max) }
    }

    private static func expectOrder(
        running: Bool, loop: LoopRange, planned: CapabilityGeneration, live: CapabilityGeneration,
        otherRate: NegotiatedRender
    ) throws {
        let summary = try hostSummary(running: running, loop: loop)
        let cases: [(frames: Int, expected: AUHostContextRefusal)] = [
            (0, .invalidBlock(0)),
            (513, .blockExceedsNegotiated(blockFrames: 513, maximumFrames: 512)),
            (64, .negotiationStale([.sampleRate]))
        ]
        for item in cases {
            #expect(throws: item.expected) {
                try hostBuild(summary, frame: -1, frames: item.frames, negotiated: otherRate, live: live)
            }
        }
        #expect(throws: AUHostContextRefusal.rateMismatch(summaryHz: 48_000, negotiatedHz: 44_100)) {
            try hostBuild(summary, frame: -1, negotiated: otherRate, live: planned)
        }
        #expect(throws: AUHostContextRefusal.loopActive) { try hostBuild(summary, frame: -1) }
        let flat = try hostSummary(running: running)
        #expect(throws: AUHostContextRefusal.negativeFrame(-1)) { try hostBuild(flat, frame: -1) }
    }

    @Test func hostContextEqualInputsBuildEqualValues() throws {
        let summary = try Self.hostSummary()
        let first = try Self.hostBuild(summary, frame: 100)
        let second = try Self.hostBuild(summary, frame: 100)
        #expect(first == second)
        let later = try Self.hostBuild(summary, frame: 200)
        #expect(first != later)
    }
}
