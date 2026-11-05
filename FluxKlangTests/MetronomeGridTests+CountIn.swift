import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MetronomeGridTests {
    static func countIn(_ bars: Int, _ configuration: MetronomeConfiguration,
                        _ clock: MusicalClockMap) throws -> [MetronomeCountInClick] {
        try MetronomeCountIn.clicks(bars: bars, configuration: configuration, clock: clock, current: live)
    }

    @Test
    func countInBarEndsAtTheAnchor() throws {
        let clicks = try Self.countIn(1, Self.configuration(), Self.clock(frame: 10_000))
        #expect(clicks.map(\.framesBeforeAnchor) == [96_000, 72_000, 48_000, 24_000])
        #expect(clicks.map(\.accent) == [.bar, .beat, .beat, .beat])
        #expect(clicks.map(\.beat) == [0, 1, 2, 3])
        #expect(try Self.countIn(0, Self.configuration(), Self.clock()).isEmpty)
    }

    @Test
    func countInAllowsFourBarsAndRefusesFive() throws {
        let four = try Self.countIn(4, Self.configuration(), Self.clock())
        #expect(four.count == 16 && four.first?.framesBeforeAnchor == 384_000)
        #expect(four.map(\.bar) == (0..<4).flatMap { Array(repeating: $0, count: 4) })
        #expect(four.filter { $0.accent == .bar }.map(\.framesBeforeAnchor) == [384_000, 288_000, 192_000, 96_000])
        #expect(Self.refusal { try Self.countIn(5, Self.configuration(), Self.clock()) } == .countInBarsOutOfRange(5))
        #expect(Self.refusal { try Self.countIn(-1, Self.configuration(), Self.clock()) }
            == .countInBarsOutOfRange(-1))
    }

    @Test
    func countInUsesTheTempoAtTickZero() throws {
        // The anchor sits in the faster second segment; the count-in still uses the first.
        let clock = try Self.clock(ticks: 2 * Self.quarter, segments: [(0, 500_000), (Self.quarter, 250_000)])
        let clicks = try Self.countIn(1, Self.configuration(2, 4), clock)
        #expect(clicks.map(\.framesBeforeAnchor) == [48_000, 24_000])
    }

    @Test
    func countInSubdivisionsRoundTheAbsoluteFrameHalfUp() throws {
        let grid = try Self.configuration(6, 8, unit: .dottedCompound, subdivisions: 3)
        let clicks = try Self.countIn(1, grid, Self.clock(rate: 44_100, segments: [(0, 400_000)]))
        // An eighth at 150 BPM and 44.1 kHz is 8,820 frames.
        #expect(clicks.map(\.framesBeforeAnchor) == [52_920, 44_100, 35_280, 26_460, 17_640, 8820])
        #expect(clicks.map(\.accent) == [.bar, .subdivision, .subdivision, .beat, .subdivision, .subdivision])
        let sixteenths = try Self.countIn(1, Self.configuration(1, 4, subdivisions: 4), Self.clock(rate: 44_100))
        // The sixteenth before the anchor is 5,512.5 frames back: anchor − 5,512.5 rounds half-up to anchor − 5,512.
        #expect(sixteenths.map(\.framesBeforeAnchor) == [22_050, 16_537, 11_025, 5512])
        #expect(sixteenths.allSatisfy { $0.framesBeforeAnchor > 0 })
    }

    @Test
    func countInLeadsExactlyIntoBarZero() throws {
        let clock = try Self.clock(frame: 1001, rate: 44_100, segments: [(0, 500_000), (Self.quarter, 250_000)])
        let grid = try Self.configuration(3, 4, subdivisions: 4)
        let anchor = try clock.frame(atTicks: 0)
        let countIn = try Self.countIn(2, grid, clock)
        let placed = countIn.map { anchor - Int64($0.framesBeforeAnchor) }
        // Placed count-in clicks are the map extrapolated before tick 0 at the first segment's tempo.
        let ticks = (0..<countIn.count).map { Int64($0 - countIn.count) * 3840 }
        #expect(placed == (try ticks.map { try clock.frame(atTicks: $0) }))
        let bar = try Self.clicks(placed.first ?? 0, anchor + 30_000, grid, clock)
        #expect(bar.first?.frame == anchor && bar.first?.ticks == 0 && bar.first?.accent == .bar)
        let frames = placed + bar.map(\.frame)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0 < $1 })
        #expect(bar.first.map { $0.frame - (placed.last ?? 0) } == 5512)
        #expect(countIn.count == 24 && countIn.first?.accent == .bar)
    }

    @Test
    func countInKeepsTheClocksFractionalPhase() throws {
        // Tick 1 on frame 10,000 at 44.1 kHz and 120 BPM: tick 0 is at 9,998.56 (frame 9,999) and the last
        // sixteenth, tick −3,840, at 4,486.06. Rounding the 5,512.5-frame duration alone gave 4,487.
        let clock = try Self.clock(frame: 10_000, ticks: 1, rate: 44_100)
        let clicks = try Self.countIn(1, Self.configuration(1, 4, subdivisions: 4), clock)
        #expect(try clock.frame(atTicks: 0) == 9999)
        #expect(clicks.map { 9999 - Int64($0.framesBeforeAnchor) } == [-12_051, -6539, -1026, 4486])
    }

    /// The exact frame of a negative tick, rounded half-up: written independently of the map's segment walk.
    static func reference(ticks: Int64, frame: Int64, anchorTicks: Int64, rate: Int,
                          segments: [(Int64, Int64)]) -> Int64? {
        let unitsPerFrame = Int128(Self.quarter) * 1_000_000
        func cost(_ index: Int) -> Int128 { Int128(segments[index].1) * Int128(rate) }
        var anchorUnits = Int128(min(anchorTicks, 0)) * cost(0)
        for index in segments.indices where anchorTicks > 0 {
            let end = index + 1 < segments.count ? segments[index + 1].0 : Int64.max
            anchorUnits += Int128(max(0, min(anchorTicks, end) - segments[index].0)) * cost(index)
        }
        let numerator = 2 * (Int128(frame) * unitsPerFrame + Int128(ticks) * cost(0) - anchorUnits) + unitsPerFrame
        let denominator = 2 * unitsPerFrame
        var quotient = numerator / denominator
        if numerator % denominator != 0, numerator < 0 { quotient -= 1 }
        return Int64(exactly: quotient)
    }

    @Test
    func everyCountInClickIsTheExactRoundedExtrapolation() throws {
        let grid = try Self.configuration(4, 4, subdivisions: 7)
        var checked = 0
        var mismatches = 0
        for rate in [44_100, 48_000, 88_200, 96_000, 176_400, 192_000] {
            for tempo: Int64 in [60_000, 333_333, 500_000, 2_999_999] {
                for (frame, ticks) in [(Int64(10_000), Int64(1)), (-7, 7777), (123_457, -5), (3, 46_081)] {
                    let maps: [[(Int64, Int64)]] = [[(0, tempo)], [(0, tempo), (Self.quarter, 250_000)]]
                    for segments in maps {
                        let clock = try Self.clock(frame: frame, ticks: ticks, rate: rate, segments: segments)
                        let anchor = try clock.frame(atTicks: 0)
                        let clicks = try Self.countIn(1, grid, clock)
                        for (number, click) in clicks.enumerated() {
                            let tick = (Int64(number / 7) - 4) * Self.quarter + grid.offset(ofSubdivision: number % 7)
                            let exact = Self.reference(ticks: tick, frame: frame, anchorTicks: ticks, rate: rate,
                                                       segments: segments)
                            let placed = anchor - Int64(click.framesBeforeAnchor)
                            let mapped = try clock.frame(atTicks: tick)
                            if placed != exact || placed != mapped { mismatches += 1 }
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == 6 * 4 * 4 * 2 * 28 && mismatches == 0)
    }

    @Test
    func countInBelowInt64MinIsRefused() throws {
        // One 4/4 bar at 120 BPM and 48 kHz starts 96,000 frames before the anchor.
        let lowest = try Self.countIn(1, Self.configuration(), Self.clock(frame: Int64.min + 96_000))
        #expect(lowest.first?.framesBeforeAnchor == 96_000)
        #expect(Self.refusal { try Self.countIn(1, Self.configuration(), Self.clock(frame: Int64.min + 95_999)) }
            == .clock(.overflow))
    }
}
