import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct MetronomeGridTests {
    static let primary = ClockID(validated: "smp.main")
    static let musical = ClockID(validated: "mus.main")
    static let live = ClockGenerationSnapshot(sample: .initial, transport: .initial, musicalMap: .initial)
    static let quarter = MusicalTime.ticksPerQuarter

    static func meter(_ numerator: Int, _ denominator: Int) throws -> MusicalMeter {
        try MusicalMeter(MeterFields(numerator: numerator, denominator: denominator))
    }

    static func configuration(_ numerator: Int = 4, _ denominator: Int = 4, unit: MetronomeBeatUnit = .denominator,
                              subdivisions: Int = 1) throws -> MetronomeConfiguration {
        try MetronomeConfiguration(meter: meter(numerator, denominator), beatUnit: unit, subdivisions: subdivisions)
    }

    /// A clock whose anchor puts `ticks` on `frame`; 120 BPM by default.
    static func clock(frame: Int64 = 0, ticks: Int64 = 0, rate: Int = 48_000,
                      segments: [(Int64, Int64)] = [(0, 500_000)]) throws -> MusicalClockMap {
        let anchor = ClockAnchor(
            sample: SampleStamp(clock: primary, generation: .initial, frame: frame), host: HostStamp(ticks: 0),
            musical: MusicalStamp(transport: .initial, musicalMap: .initial, ticks: ticks, loopIteration: 0)
        )
        let map = try MusicalMap(clock: musical, revision: .initial,
                                 segments: segments.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) })
        return try MusicalClockMap(anchor: anchor, map: map, nominalRate: rate,
                                   currentSample: .initial, currentTransport: .initial)
    }

    static func clicks(_ start: Int64, _ end: Int64, _ configuration: MetronomeConfiguration,
                       _ clock: MusicalClockMap) throws -> [MetronomeClick] {
        try MetronomeGrid.clicks(from: start, to: end, configuration: configuration, clock: clock, current: live)
    }

    static func refusal(_ body: () throws -> some Any) -> MetronomeRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? MetronomeRefusal
        }
    }

    @Test
    func beatLengthComesFromTheDenominator() throws {
        for (denominator, beat) in [(1, 61_440), (2, 30_720), (4, 15_360), (8, 7680), (16, 3840), (32, 1920)] {
            let grid = try Self.configuration(3, denominator)
            #expect(grid.beatTicks == Int64(beat))
            #expect(grid.beatsPerBar == 3)
            #expect(grid.barTicks == Int64(3 * beat))
        }
        let sixEight = try Self.configuration(6, 8)
        #expect(sixEight.beatTicks == 7680 && sixEight.beatsPerBar == 6)
    }

    @Test
    func dottedCompoundNeedsANumeratorDivisibleByThreeAboveThree() throws {
        for (numerator, beats) in [(6, 2), (9, 3), (12, 4)] {
            let grid = try Self.configuration(numerator, 8, unit: .dottedCompound, subdivisions: 3)
            #expect(grid.beatTicks == 23_040 && grid.beatsPerBar == beats && grid.offset(ofSubdivision: 1) == 7680)
            #expect(grid.barTicks == Int64(numerator) * 7680)
        }
        for numerator in [3, 1, 4, 7, 8, 10] {
            #expect(Self.refusal { try Self.configuration(numerator, 8, unit: .dottedCompound) }
                == .invalidCompoundMeter(numerator: numerator, denominator: 8))
        }
    }

    @Test
    func subdivisionsAreBounded() throws {
        #expect(try Self.configuration(4, 32, subdivisions: 8).offset(ofSubdivision: 1) == 240)
        #expect(try Self.configuration(subdivisions: 5).offset(ofSubdivision: 1) == 3072)
        #expect(try Self.configuration(subdivisions: 7).subdivisions == 7)
        #expect(Self.refusal { try Self.configuration(subdivisions: 9) } == .subdivisionsOutOfRange(9))
        #expect(Self.refusal { try Self.configuration(subdivisions: 0) } == .subdivisionsOutOfRange(0))
    }

    @Test
    func clicksLandExactlyOnEachBeatWithBarAccents() throws {
        // Tick 7680 sits on frame 5000, so tick 0 is on frame -7000 and bar 0 starts before the window.
        let clock = try Self.clock(frame: 5000, ticks: 7680)
        let clicks = try Self.clicks(0, 96_000, Self.configuration(), clock)
        #expect(clicks.map(\.ticks) == [1, 2, 3, 4].map { $0 * Self.quarter })
        for click in clicks { #expect(click.frame == (try clock.frame(atTicks: click.ticks))) }
        #expect(clicks.map(\.frame) == [17_000, 41_000, 65_000, 89_000])
        #expect(clicks.map(\.bar) == [0, 0, 0, 1])
        #expect(clicks.map(\.beat) == [1, 2, 3, 0])
        #expect(clicks.map(\.accent) == [.beat, .beat, .beat, .bar])
    }

    @Test
    func subdivisionAccentsNeverOutrankBeats() throws {
        let clicks = try Self.clicks(0, 48_000, Self.configuration(3, 4, subdivisions: 2), Self.clock())
        #expect(clicks.map(\.accent) == [.bar, .subdivision, .beat, .subdivision])
        #expect(clicks.map(\.subdivision) == [0, 1, 0, 1])
        #expect(clicks.map(\.frame) == [0, 12_000, 24_000, 36_000])
        let bar = try Self.clicks(0, 72_000, Self.configuration(3, 4), Self.clock())
        #expect(bar.map(\.accent) == [.bar, .beat, .beat])
    }

    @Test
    func compoundMetersClickDottedBeatsWithDenominatorSubdivisions() throws {
        let grid = try Self.configuration(6, 8, unit: .dottedCompound, subdivisions: 3)
        let clicks = try Self.clicks(0, 72_000, grid, Self.clock())
        #expect(clicks.map(\.frame) == [0, 12_000, 24_000, 36_000, 48_000, 60_000])
        #expect(clicks.map(\.accent) == [.bar, .subdivision, .subdivision, .beat, .subdivision, .subdivision])
        #expect(clicks.map(\.beat) == [0, 0, 0, 1, 1, 1])
        let plain = try Self.clicks(0, 72_000, Self.configuration(6, 8, unit: .dottedCompound), Self.clock())
        #expect(plain.map(\.frame) == [0, 36_000] && plain.map(\.accent) == [.bar, .beat])
    }

    @Test
    func clicksFollowTheMapAcrossATempoChange() throws {
        let clock = try Self.clock(segments: [(0, 500_000), (2 * Self.quarter, 250_000)])
        let clicks = try Self.clicks(0, 84_000, Self.configuration(), clock)
        #expect(clicks.map(\.frame) == [0, 24_000, 48_000, 60_000, 72_000])
        for click in clicks { #expect(click.frame == (try clock.frame(atTicks: click.ticks))) }
        #expect(clicks.map(\.accent) == [.bar, .beat, .beat, .beat, .bar])
    }

    @Test
    func windowStartIsInclusiveAndEndExclusive() throws {
        let clock = try Self.clock()
        let grid = try Self.configuration()
        #expect(try Self.clicks(24_000, 48_000, grid, clock).map(\.frame) == [24_000])
        #expect(try Self.clicks(24_000, 48_001, grid, clock).map(\.frame) == [24_000, 48_000])
        #expect(try Self.clicks(24_001, 48_000, grid, clock).isEmpty)
        #expect(try Self.clicks(23_999, 24_000, grid, clock).isEmpty)
    }

    @Test
    func aClickRoundedOntoTheWindowStartIsIncluded() throws {
        // At 44.1 kHz a sixteenth is 5,512.5 frames, so tick 3840 rounds up onto frame 5513.
        let clock = try Self.clock(rate: 44_100)
        let grid = try Self.configuration(subdivisions: 4)
        let clicks = try Self.clicks(5513, 11_026, grid, clock)
        #expect(clicks.map(\.ticks) == [3840, 7680])
        #expect(clicks.map(\.frame) == [5513, 11_025])
        #expect(try Self.clicks(5512, 5513, grid, clock).isEmpty)
    }

    @Test
    func emptyAndInvertedWindows() throws {
        let grid = try Self.configuration()
        #expect(try Self.clicks(24_000, 24_000, grid, Self.clock()).isEmpty)
        #expect(Self.refusal { try Self.clicks(24_001, 24_000, grid, Self.clock()) }
            == .invalidWindow(start: 24_001, end: 24_000))
    }

    @Test
    func noClicksPrecedeTickZero() throws {
        let clock = try Self.clock(frame: 100_000)
        let grid = try Self.configuration()
        #expect(try Self.clicks(0, 100_000, grid, clock).isEmpty)
        let first = try Self.clicks(0, 100_001, grid, clock)
        #expect(first.map(\.ticks) == [0] && first.map(\.frame) == [100_000])
    }

    @Test
    func clickCapRefusesRatherThanTruncates() throws {
        // Thirty-second notes at 120 BPM and 48 kHz: one click every 3,000 frames.
        let grid = try Self.configuration(subdivisions: 8)
        let limit = Int64(MetronomeGrid.maximumClicks)
        #expect(limit == 4096)
        let full = try Self.clicks(0, limit * 3000, grid, Self.clock())
        #expect(full.count == 4096 && full.last?.frame == (limit - 1) * 3000)
        #expect(Self.refusal { try Self.clicks(0, limit * 3000 + 1, grid, Self.clock()) }
            == .tooManyClicks(limit: 4096))
    }

    @Test
    func staleGenerationsAreRefused() throws {
        let second = try Generation(2)
        let grid = try Self.configuration()
        let clock = try Self.clock()
        let stale = [
            (ClockGenerationSnapshot(sample: second, transport: .initial, musicalMap: .initial),
             MetronomeRefusal.clock(.staleSampleGeneration)),
            (ClockGenerationSnapshot(sample: .initial, transport: second, musicalMap: .initial),
             .clock(.staleTransport)),
            (ClockGenerationSnapshot(sample: .initial, transport: .initial, musicalMap: second), .staleMusicalMap)
        ]
        for (current, refusal) in stale {
            #expect(Self.refusal {
                try MetronomeGrid.clicks(from: 0, to: 0, configuration: grid, clock: clock, current: current)
            } == refusal)
            #expect(Self.refusal {
                try MetronomeCountIn.clicks(bars: 1, configuration: grid, clock: clock, current: current)
            } == refusal)
        }
    }

    @Test
    func clockMapOverflowPassesThrough() throws {
        let clock = try Self.clock(frame: Int64.max - 10)
        let grid = try Self.configuration(subdivisions: 8)
        #expect(Self.refusal { try Self.clicks(Int64.max - 20, Int64.max, grid, clock) } == .clock(.overflow))
        #expect(try Self.clicks(Int64.max - 20, Int64.max - 10, grid, clock).isEmpty)
    }

    @Test
    func tickOverflowRefusesTheWholeWindow() throws {
        // The last whole beat that fits in Int64 sits on frame 0; the beat after it does not exist.
        let last = Int64.max / Self.quarter * Self.quarter
        let clock = try Self.clock(ticks: last)
        let grid = try Self.configuration()
        #expect(Self.refusal { try Self.clicks(-24_000, 100_000, grid, clock) } == .clock(.overflow))
        let before = try Self.clicks(-24_000, 0, grid, clock)
        #expect(before.map(\.ticks) == [last - Self.quarter] && before.map(\.frame) == [-24_000])
        // Int64.max is 2,047 ticks past `last`: of eight 1,920-tick clicks, the third no longer fits.
        let eighths = try Self.configuration(subdivisions: 8)
        #expect(try Self.clicks(0, 3000, eighths, clock).map(\.ticks) == [last])
        // The second click (frame 3,000) is in the window, but the third is met before the end is found.
        #expect(Self.refusal { try Self.clicks(0, 3001, eighths, clock) } == .clock(.overflow))
        #expect(Self.refusal { try Self.clicks(0, 100_000, eighths, clock) } == .clock(.overflow))
    }

    @Test
    func tickUnderflowBeforeTheFirstBeatIsRefused() throws {
        // The first whole beat above Int64.min sits on frame 0; the beat before it does not exist.
        let first = Int64.min / Self.quarter * Self.quarter
        #expect(Self.refusal { try Self.clicks(0, 1, Self.configuration(), Self.clock(ticks: first)) }
            == .clock(.overflow))
        // At the slowest frames per tick, a wrapped beat start (~2⁶⁴ ticks later) would still map to a frame.
        let slow = try Self.clock(ticks: first, rate: 44_100, segments: [(0, 60_000)])
        #expect(Self.refusal { try Self.clicks(0, 1, Self.configuration(), slow) } == .clock(.overflow))
    }

    @Test
    func abuttingWindowsGiveTheUnionWithoutDuplicatesOrGaps() throws {
        let clock = try Self.clock(frame: 1001, rate: 44_100, segments: [(0, 500_000), (2 * Self.quarter, 250_000)])
        for grid in try [Self.configuration(subdivisions: 7), Self.configuration(6, 8, subdivisions: 3)] {
            let end: Int64 = 120_000
            let whole = try Self.clicks(0, end, grid, clock)
            // Splits fall mid-beat, on a click, on the tempo change (tick 30,720 = frame 45,101) and either side.
            let splits: [Int64] = [0, 3_151, 6_301, 23_051, 45_100, 45_101, 45_102, 57_000, 90_000, end]
            var union: [MetronomeClick] = []
            for (start, stop) in zip(splits, splits.dropFirst()) {
                union += try Self.clicks(start, stop, grid, clock)
            }
            #expect(union == whole)
            #expect(whole.count > 20 && zip(whole, whole.dropFirst()).allSatisfy { $0.frame < $1.frame })
        }
    }
}
