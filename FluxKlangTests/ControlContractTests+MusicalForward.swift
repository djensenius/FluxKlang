import Foundation
import Testing
@testable import FluxKlang

extension ControlContractTests {
    struct MusicalForwardValidation {
        let fixture = MusicalFoundationFixture()

        @Test(arguments: [
            ((Int64(641), Int64(500)), (Int64(2), Int64(322))),
            ((641, 501), (1, 322)), ((639, 501), (2, 320)), ((640, 499), (1, 320))
        ])
        func forwardGridUsesTheLatestProjection(_ input: ((Int64, Int64), (Int64, Int64))) throws {
            let ((later, frame), (grid, ticks)) = input
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger)
            try fixture.observe(&timeline, .musical, ledger, frame: 1_000, ticks: later)
            let origin = try timeline.origin(at: .init(ticks: UInt64(frame) * 500))
            let pin = try timeline.reserve(.grid(grid), origin: origin)
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: ticks))
            #expect(try timeline.project(pin).frame == (later == 640 ? 500 : 502))
            let assigned = try MusicalTiming.frameUnits(of: pin.occurrence, from: timeline.currentClock, loop: nil)
            let previous = MusicalOccurrence(pass: 0, ticks: pin.occurrence.ticks - grid)
            let skipped = try MusicalTiming.frameUnits(of: previous, from: timeline.currentClock, loop: nil)
            #expect(MusicalFrame(units: assigned) >= origin.exactFrame)
            #expect(MusicalFrame(units: skipped) < origin.exactFrame)
        }

        @Test(arguments: [
            ((Int64(644), Int64(0)), false), ((645, 0), true), ((645, 100), true), ((645, 150), true)
        ])
        func forwardPassZeroKeepsItsLoopStartWhenAlreadyInside(_ input: ((Int64, Int64), Bool)) throws {
            let ((later, frame), edited) = input
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 5, endTicks: 2_000), ticks: 5)
            try fixture.observe(&timeline, .musical, ledger, frame: 1_000, ticks: later)
            if edited {
                try ledger.bump(fixture.mapKey, reason: .tempoEdit)
                try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 400_000)])),
                                    ledger, frame: 1_000)
            }
            let origin = try timeline.origin(atFrame: frame)
            let pin = try timeline.reserve(.grid(1), origin: origin)
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 5))
            #expect(try timeline.project(pin).frame == (edited ? 200 : 2))
            let units = try MusicalTiming.frameUnits(of: pin.occurrence, from: timeline.currentClock,
                                                     loop: timeline.currentLoop)
            #expect(MusicalFrame(units: units) >= origin.exactFrame)
        }

        @Test(arguments: [(Int64(0), UInt64(0)), (0, 4_300), (50, 0)])
        func forwardPassZeroPreservesPreLoopAndPastEndAdmission(_ context: (Int64, UInt64)) throws {
            let (ticks, host) = context
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 5, endTicks: ticks == 0 ? 4_000 : 10),
                                                 ticks: ticks)
            if ticks == 0 {
                try fixture.observe(&timeline, .musical, ledger, frame: 1_000, ticks: 639)
                try fixture.observe(&timeline, .musical, ledger, frame: 2_000, ticks: 1_278)
            } else {
                try fixture.observe(&timeline, .musical, ledger, frame: 1_000, ticks: 690)
                try ledger.bump(fixture.mapKey, reason: .tempoEdit)
                try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 250_000)])),
                                    ledger, frame: 1_000)
            }
            let origin = try timeline.origin(at: .init(ticks: host))
            if host == 4_300 {
                let pin = try timeline.reserve(.grid(1), origin: origin)
                #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 5))
                #expect(try timeline.project(pin).frame == 11)
            } else {
                #expect(throws: MusicalTimingError.outsideLoop) { try timeline.reserve(.grid(1), origin: origin) }
                #expect(timeline.pinCount == 0)
            }
        }

        @Test(arguments: [Int64(240_000), 500_000])
        func passZeroFloorKeepsTheCoveredOriginPassAfterMapEdits(_ tempo: Int64) throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 1, endTicks: 3), history: 10,
                                                 segments: [(0, 640_000)])
            for frame: Int64 in 5...10 { try fixture.observe(&timeline, .musical, ledger, frame: frame, ticks: 2) }
            try fixture.observe(&timeline, .wrap, ledger, frame: 12, ticks: 1, pass: 1)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, tempo)])), ledger, frame: 12)
            let origin = try timeline.origin(at: .init(ticks: 2_400))
            #expect(origin.clock.musical.loopIteration == 0) // Covered pass 0, not a current-map virtual origin.
            if tempo == 240_000 {
                let pin = try timeline.reserve(.grid(1), origin: origin)
                #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 1))
                #expect(try timeline.project(pin).frame == 9)
            } else {
                // Current-map tick 3.072 is past the exact end, but frame 4.8 is before the rounded wrap at 5.
                #expect(throws: MusicalTimingError.outsideLoop) { try timeline.reserve(.grid(1), origin: origin) }
                #expect(timeline.pinCount == 0)
            }
        }

        @Test(arguments: [0, 1])
        func anEndAliasBeforeTheOriginDoesNotMaskItsSuccessor(_ retro: Int) throws {
            let ledger = try fixture.ledger()
            let loop = try LoopRange(startTicks: 0, endTicks: 3)
            var timeline = try fixture.timeline(ledger, loop: loop)
            try fixture.observe(&timeline, .wrap, ledger, frame: 5, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .musical, ledger, frame: 6, ticks: 1, pass: 1)
            let origin = try timeline.origin(at: .init(ticks: 2_250))
            let pin = try timeline.reserve(.grid(1), origin: origin, retroactiveMs: retro)
            #expect(pin.occurrence == MusicalOccurrence(pass: retro == 0 ? 1 : 0, ticks: retro == 0 ? 1 : 3))
            #expect(try timeline.project(pin).frame == (retro == 0 ? 6 : 4))
        }

        @Test(arguments: [false, true])
        func forwardSearchComparesEveryLaterRetainedPass(_ anotherWrap: Bool) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1_001), history: 10)
            try fixture.observe(&timeline, .wrap, ledger, frame: 1_564, ticks: 0, pass: 1)
            for tick: Int64 in 1...6 {
                try fixture.observe(&timeline, .musical, ledger, frame: 1_564 + tick, ticks: tick, pass: 1)
            }
            if anotherWrap { try fixture.observe(&timeline, .wrap, ledger, frame: 3_125, ticks: 0, pass: 2) }
            let pin = try timeline.reserve(.grid(4), origin: timeline.origin(atFrame: 1_559))
            // Pass 1 tick 0 is 1560.625; origin-pass tick 1000 is farther away at 1562.5.
            #expect(pin.occurrence == MusicalOccurrence(pass: 1, ticks: 0))
            #expect(try timeline.project(pin).frame == 1_561)
        }

        @Test func forwardEndAliasIsComparedSeparatelyAndWinsItsSuccessorTie() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 100), history: 102)
            try fixture.observe(&timeline, .wrap, ledger, frame: 156, ticks: 0, pass: 1)
            for tick: Int64 in 1...99 {
                try fixture.observe(&timeline, .musical, ledger, frame: 156 + tick, ticks: tick, pass: 1)
            }
            let pin = try timeline.reserve(.grid(1), origin: timeline.origin(at: .init(ticks: 50_125)))
            // The qualified end and pass 1 tick 0 tie at 100.3125; tick 65 is later at 101.5625.
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 100))
            #expect(try timeline.project(pin).frame == 100)
        }

        @Test func forwardSelectionDoesNotNarrowUnchosenFutureFrames() throws {
            let ledger = try fixture.ledger()
            let base = Int64.max - 2_000
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1_920), frame: base)
            try timeline.observe(.primary, at: fixture.anchor(ledger, frame: base + 1, host: 500),
                                 sequence: 1, ledger: ledger)
            let pin = try timeline.reserve(.grid(960), origin: timeline.origin(atFrame: base + 1))
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 960))
            #expect(try timeline.project(pin).frame == Int64.max - 500)
        }

        @Test func zeroPeriodForwardTiesKeepTheEarlierEndOccurrence() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 100, endTicks: 101),
                                                 segments: [(0, 60_000)])
            try fixture.observe(&timeline, .primary, ledger, frame: 18)
            let pin = try timeline.reserve(.grid(101), origin: timeline.origin(atFrame: 18))
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 101))
            #expect(try timeline.project(pin).frame == 19)
            #expect(try timeline.project(pin).assumesFuture)
        }
    }
}
