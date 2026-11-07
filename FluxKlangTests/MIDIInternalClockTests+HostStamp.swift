import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDIInternalClockTests {
    /// A host map on the sample clock: by default 1 ns per host tick at 48 kHz, frame 0 at host tick 1,000,000,000.
    static func hostMap(rate: Int = 48_000, timebase: HostTimebase = HostTimebase(numer: 1, denom: 1),
                        anchorFrame: Int64 = 0, anchorHost: UInt64 = 1_000_000_000,
                        generation: Generation = .initial) throws -> SampleClockMap {
        let anchor = ClockAnchor(sample: .init(clock: sampleClock, generation: generation, frame: anchorFrame),
                                 host: .init(ticks: anchorHost), musical: nil)
        return try SampleClockMap(anchor: anchor, nominalRate: rate, timebase: timebase)
    }

    // MARK: - The inverse of the forward map

    @Test
    func hostStampsAreTheEarliestTickWhoseFrameReachesTheRequestedFrame() throws {
        let map = try Self.hostMap()
        // The forward map rounds half-up, so the stamp of the anchor frame precedes the anchor host tick.
        let expected: [(Int64, UInt64)] = [(0, 999_989_584), (1, 1_000_010_417), (1_000, 1_020_822_917),
                                           (2_000, 1_041_656_250)]
        for (frame, ticks) in expected {
            let stamp = try MIDIHostStamping.hostStamp(forFrame: frame, in: map, current: .initial)
            #expect(stamp == HostStamp(ticks: ticks))
            let reached = try map.frame(atHost: stamp, current: .initial)
            let previous = try map.frame(atHost: HostStamp(ticks: ticks - 1), current: .initial)
            #expect(reached == frame)
            #expect(previous == frame - 1)
        }
    }

    @Test
    func everyNominalRateAndTimebaseRoundTripsBeforeAtAndAfterTheAnchor() throws {
        let timebases = [HostTimebase(numer: 1, denom: 1), HostTimebase(numer: 125, denom: 3)]
        for rate in [44_100, 48_000, 88_200, 96_000, 176_400, 192_000] {
            for timebase in timebases {
                let map = try Self.hostMap(rate: rate, timebase: timebase, anchorFrame: 1_000_000,
                                           anchorHost: 1_000_000_000_000)
                for offset in [Int64(-100_000), -1, 0, 1, 12_345, 10_000_000] {
                    let frame = 1_000_000 + offset
                    let stamp = try MIDIHostStamping.hostStamp(forFrame: frame, in: map, current: .initial)
                    let reached = try map.frame(atHost: stamp, current: .initial)
                    let previous = try map.frame(atHost: HostStamp(ticks: stamp.ticks - 1), current: .initial)
                    #expect(reached >= frame, "rate \(rate), \(timebase), offset \(offset): stamp is late")
                    #expect(previous < frame, "rate \(rate), \(timebase), offset \(offset): stamp is not earliest")
                }
            }
        }
    }

    // MARK: - Bounds

    @Test
    func aStampAtTheLargestHostTickIsAcceptedAndOneTickBeyondIsRefused() throws {
        let atEdge = try Self.hostMap(anchorHost: UInt64.max - 10_417)
        let stamp = try MIDIHostStamping.hostStamp(forFrame: 1, in: atEdge, current: .initial)
        #expect(stamp == HostStamp(ticks: UInt64.max))
        let beyond = try Self.hostMap(anchorHost: UInt64.max - 10_416)
        #expect(throws: ClockMapError.overflow) {
            try MIDIHostStamping.hostStamp(forFrame: 1, in: beyond, current: .initial)
        }
    }

    @Test
    func aStampAtHostTickZeroIsAcceptedAndOneTickBeforeIsRefused() throws {
        let atEdge = try Self.hostMap(anchorHost: 10_416)
        let stamp = try MIDIHostStamping.hostStamp(forFrame: 0, in: atEdge, current: .initial)
        #expect(stamp == HostStamp(ticks: 0))
        let before = try Self.hostMap(anchorHost: 10_415)
        #expect(throws: ClockMapError.overflow) {
            try MIDIHostStamping.hostStamp(forFrame: 0, in: before, current: .initial)
        }
    }

    @Test
    func framesFarOutsideTheHostTickRangeAreRefusedAsOverflow() throws {
        let low = try Self.hostMap(anchorHost: 0)
        #expect(throws: ClockMapError.overflow) {
            try MIDIHostStamping.hostStamp(forFrame: Int64.max, in: low, current: .initial)
        }
        let high = try Self.hostMap(anchorHost: UInt64.max)
        #expect(throws: ClockMapError.overflow) {
            try MIDIHostStamping.hostStamp(forFrame: Int64.min, in: high, current: .initial)
        }
    }

    @Test
    func framesAtTheInt64EdgesStampWhenTheHostTickFits() throws {
        let top = try Self.hostMap(anchorFrame: Int64.max - 1_000, anchorHost: 0)
        let topStamp = try MIDIHostStamping.hostStamp(forFrame: Int64.max, in: top, current: .initial)
        #expect(topStamp == HostStamp(ticks: 20_822_917))
        #expect(try top.frame(atHost: topStamp, current: .initial) == Int64.max)
        let bottom = try Self.hostMap(anchorFrame: Int64.min + 1_000, anchorHost: 1_000_000_000_000)
        let bottomStamp = try MIDIHostStamping.hostStamp(forFrame: Int64.min, in: bottom, current: .initial)
        #expect(bottomStamp == HostStamp(ticks: 999_979_156_250))
        #expect(try bottom.frame(atHost: bottomStamp, current: .initial) == Int64.min)
    }

    @Test
    func aTimebaseTooCoarseForTheFrameRangeIsRefusedWhereTheForwardMapLeavesInt64() throws {
        // Each host tick is about 824,633 frames, so the earliest tick for the last frames lies beyond Int64.max.
        let coarse = try Self.hostMap(rate: 192_000, timebase: HostTimebase(numer: UInt32.max, denom: 1),
                                      anchorHost: 0)
        let accepted = try MIDIHostStamping.hostStamp(forFrame: Int64.max - 687_194, in: coarse, current: .initial)
        #expect(accepted == HostStamp(ticks: 11_184_810_669_270))
        #expect(try coarse.frame(atHost: accepted, current: .initial) == Int64.max - 687_194)
        #expect(throws: ClockMapError.overflow) {
            try MIDIHostStamping.hostStamp(forFrame: Int64.max - 687_193, in: coarse, current: .initial)
        }
        #expect(throws: ClockMapError.overflow) {
            try MIDIHostStamping.hostStamp(forFrame: Int64.max, in: coarse, current: .initial)
        }
    }

    @Test
    func aHostMapOfAnotherSampleGenerationIsRefusedBeforeAnyArithmetic() throws {
        let map = try Self.hostMap()
        let second = try Generation(2)
        #expect(throws: ClockMapError.staleSampleGeneration) {
            try MIDIHostStamping.hostStamp(forFrame: Int64.max, in: map, current: second)
        }
        let secondMap = try Self.hostMap(generation: second)
        #expect(throws: ClockMapError.staleSampleGeneration) {
            try MIDIHostStamping.hostStamp(forFrame: 0, in: secondMap, current: .initial)
        }
        let stamp = try MIDIHostStamping.hostStamp(forFrame: 1_000, in: secondMap, current: second)
        #expect(stamp == HostStamp(ticks: 1_020_822_917))
    }

    // MARK: - Stamping a plan

    @Test
    func stampingAPlanGivesEveryEventItsLookaheadHostTickAndLeavesThePlanUnchanged() throws {
        let running = try Self.started()
        let plan = try Self.plan(running, Self.map(for: running), Self.window(0, 2_500))
        let stamped = try plan.stamped(with: Self.hostMap(), current: .initial)
        let ticks = stamped.events.compactMap { $0.hostStamp?.ticks }
        #expect(ticks == [999_989_584, 999_989_584, 1_020_822_917, 1_041_656_250])
        #expect(stamped.events.map(\.frame) == [0, 0, 1_000, 2_000])
        #expect(stamped.events.map(\.message) == [.start, .clock, .clock, .clock])
        #expect(stamped.events.map(\.pulseIndex) == [nil, 0, 1, 2])
        #expect(stamped.transportGeneration == plan.transportGeneration)
        #expect(stamped.sampleGeneration == plan.sampleGeneration)
        #expect(stamped.sampleClock == plan.sampleClock)
        #expect(stamped.window == plan.window)
        #expect(plan.events.allSatisfy { $0.hostStamp == nil })
    }

    @Test
    func stampingRefusesAStalePlanAWrongClockAStaleHostMapAndAnOverflowingTick() throws {
        let running = try Self.started()
        let plan = try Self.plan(running, Self.map(for: running), Self.window(0, 2_500))
        let second = try Generation(2)
        #expect(throws: MIDIInternalClockError.staleSampleGeneration) {
            try plan.stamped(with: Self.hostMap(generation: second), current: second)
        }
        #expect(throws: MIDIInternalClockError.staleSampleGeneration) {
            try plan.stamped(with: Self.hostMap(generation: second), current: .initial)
        }
        let other = ClockID(validated: "clock.other")
        let anchor = ClockAnchor(sample: .init(clock: other, generation: .initial, frame: 0),
                                 host: .init(ticks: 1_000_000_000), musical: nil)
        let foreign = try SampleClockMap(anchor: anchor, nominalRate: 48_000,
                                         timebase: HostTimebase(numer: 1, denom: 1))
        #expect(throws: MIDIInternalClockError.sampleClockMismatch(expected: Self.sampleClock, found: other)) {
            try plan.stamped(with: foreign, current: .initial)
        }
        #expect(throws: MIDIInternalClockError.clockMap(.overflow)) {
            try plan.stamped(with: Self.hostMap(anchorHost: 0), current: .initial)
        }
        #expect(plan.events.allSatisfy { $0.hostStamp == nil })
    }

    @Test
    func stampingAnEmptyPlanReturnsItUnchangedAndRefusesAStaleHostMapLikeAnyOtherPlan() throws {
        let stopped = MIDIInternalTransport.initial
        let plan = try Self.plan(stopped, Self.map(for: stopped), Self.window(0, 2_500))
        #expect(plan.events.isEmpty)
        #expect(try plan.stamped(with: Self.hostMap(), current: .initial) == plan)
        let second = try Generation(2)
        #expect(throws: MIDIInternalClockError.staleSampleGeneration) {
            try plan.stamped(with: Self.hostMap(generation: second), current: .initial)
        }
        #expect(plan.events.isEmpty)
    }

    @Test
    func aStaleHostMapAndAForeignClockAreRefusedAlikeForAnEmptyAndANonEmptyPlan() throws {
        let stopped = MIDIInternalTransport.initial
        let empty = try Self.plan(stopped, Self.map(for: stopped), Self.window(0, 2_500))
        let running = try Self.started()
        let full = try Self.plan(running, Self.map(for: running), Self.window(0, 2_500))
        #expect(empty.events.isEmpty)
        #expect(full.events.count == 4)
        let second = try Generation(2)
        let other = ClockID(validated: "clock.other")
        let anchor = ClockAnchor(sample: .init(clock: other, generation: second, frame: 0),
                                 host: .init(ticks: 1_000_000_000), musical: nil)
        let foreignAndStale = try SampleClockMap(anchor: anchor, nominalRate: 48_000,
                                                 timebase: HostTimebase(numer: 1, denom: 1))
        let staleMap = try Self.hostMap(generation: second)
        let mismatch = MIDIInternalClockError.sampleClockMismatch(expected: Self.sampleClock, found: other)
        for subject in [empty, full] {
            #expect(throws: MIDIInternalClockError.staleSampleGeneration) {
                try subject.stamped(with: staleMap, current: .initial)
            }
            // A host map that is wrong in both ways reports the clock first.
            #expect(throws: mismatch) { try subject.stamped(with: foreignAndStale, current: .initial) }
        }
    }
}
