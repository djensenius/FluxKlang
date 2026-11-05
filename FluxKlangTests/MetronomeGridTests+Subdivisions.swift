import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MetronomeGridTests {
    /// Twice the error of `offset`, in units of `1 / subdivisions` tick, against the exact `index · beat / n`.
    static func doubledError(_ grid: MetronomeConfiguration, beatStart: Int64, index: Int, ticks: Int64) -> Int64 {
        let divisor = Int64(grid.subdivisions)
        return 2 * abs(ticks * divisor - (beatStart * divisor + Int64(index) * grid.beatTicks))
    }

    @Test
    func septupletOffsetsRoundOncePerClick() throws {
        let grid = try Self.configuration(subdivisions: 7)
        #expect((0..<7).map { grid.offset(ofSubdivision: $0) } == [0, 2194, 4389, 6583, 8777, 10_971, 13_166])
    }

    @Test(arguments: [3, 5, 6, 7])
    func subdivisionErrorStaysWithinHalfATick(subdivisions: Int) throws {
        let meters = [(4, 1), (3, 2), (4, 4), (7, 8), (5, 16), (4, 32)]
        var grids = try meters.map { try Self.configuration($0.0, $0.1, subdivisions: subdivisions) }
        grids += try [8, 16, 32].map {
            try Self.configuration(6, $0, unit: .dottedCompound, subdivisions: subdivisions)
        }
        for grid in grids {
            let offsets = (0..<subdivisions).map { grid.offset(ofSubdivision: $0) }
            #expect(offsets.first == 0)
            #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 } && offsets.last ?? 0 < grid.beatTicks)
            for (index, offset) in offsets.enumerated() {
                #expect(Self.doubledError(grid, beatStart: 0, index: index, ticks: offset) <= Int64(subdivisions))
            }
        }
    }

    @Test
    func septupletsDoNotDriftOverTenThousandBeats() throws {
        let grid = try Self.configuration(subdivisions: 7)
        let clock = try Self.clock()
        var clicks: [MetronomeClick] = []
        // 500 beats of 24,000 frames per window: 3,500 clicks, under the cap.
        for window in Int64(0)..<20 {
            clicks += try Self.clicks(window * 12_000_000, (window + 1) * 12_000_000, grid, clock)
        }
        #expect(clicks.count == 70_000)
        #expect(zip(clicks, clicks.dropFirst()).allSatisfy { $0.ticks < $1.ticks && $0.frame < $1.frame })
        var failures = 0
        for (number, click) in clicks.enumerated() {
            let beat = Int64(number / 7)
            let index = number % 7
            let beatStart = beat * Self.quarter
            let frame = try clock.frame(atTicks: click.ticks)
            if click.subdivision != index || (index == 0 && click.ticks != beatStart)
                || Self.doubledError(grid, beatStart: beatStart, index: index, ticks: click.ticks) > 7
                || click.frame != frame {
                failures += 1
            }
        }
        #expect(failures == 0)
        #expect(clicks.last?.ticks == 9999 * Self.quarter + 13_166)
    }

    @Test
    func clicksOfThePreviousBeatStillCountAtTheWindowStart() throws {
        let grid = try Self.configuration(subdivisions: 7)
        let clock = try Self.clock()
        let start = try clock.frame(atTicks: 13_166)
        let clicks = try Self.clicks(start, 24_001, grid, clock)
        #expect(clicks.map(\.ticks) == [13_166, 15_360])
        #expect(clicks.map(\.accent) == [.subdivision, .beat])
        #expect(clicks.map(\.subdivision) == [6, 0])
    }
}
