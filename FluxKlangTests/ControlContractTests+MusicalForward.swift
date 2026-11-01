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
            let pin = try timeline.reserve(.grid(1), origin: origin)
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 1))
            #expect(try timeline.project(pin).frame == (tempo == 240_000 ? 9 : 8))
        }

        @Test(arguments: [UInt64(781), 782, 2_400])
        func passZeroFloorUsesTheExactRecordedOriginAtLoopStart(_ host: UInt64) throws {
            var ledger = try fixture.ledger()
            let loop = try LoopRange(startTicks: 1, endTicks: 3)
            var timeline = try fixture.timeline(ledger, loop: loop, history: 10, pins: 1,
                                                 segments: [(0, 640_000)])
            for frame: Int64 in 5...10 { try fixture.observe(&timeline, .musical, ledger, frame: frame, ticks: 2) }
            let latest = timeline.currentClock.anchor
            try fixture.observe(&timeline, .wrap, ledger, frame: 12, ticks: 1, pass: 1)
            let revision = try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger)), ledger, frame: 12)
            let origin = try timeline.origin(at: .init(ticks: host))
            #expect(origin.exactFrame == MusicalFrame(units: Int128(host) * MusicalTiming.unitsPerFrame / 500))
            #expect(origin.clock.anchor.sample.frame == 0 && origin.clock.musical.loopIteration == 0)
            let recorded = try MusicalTiming.reanchor(origin.clock.anchor, using: timeline.currentClock)
            let start = MusicalFrame(units: MusicalTiming.units(recorded, from: 0, to: loop.startTicks))
            if host == 781 {
                #expect(origin.exactFrame < start) // 1.562 is just below the exact start at 1.5625.
                let before = String(reflecting: timeline)
                #expect(throws: MusicalTimingError.outsideLoop) { try timeline.reserve(.grid(1), origin: origin) }
                #expect(String(reflecting: timeline) == before)
            } else {
                #expect(origin.exactFrame > start)
                if host == 2_400 {
                    let end = MusicalFrame(units: MusicalTiming.units(recorded, from: 0, to: loop.endTicks))
                    #expect(origin.exactFrame > end) // Exact end 4.6875 < origin 4.8 < rounded wrap 5.
                    let wrap = try MusicalTiming.wrapFrame(recorded, loop: loop)
                    #expect(origin.exactFrame < MusicalFrame(integer: wrap))
                }
                let pin = try timeline.reserve(.grid(1), origin: origin)
                #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 1))
                let projection = try timeline.project(pin)
                #expect(projection.frame == 8 && !projection.assumesFuture && timeline.pinCount == 1)
                #expect(projection.musicalMap == revision)
                #expect(revision == (try Generation.initial.next()))
                let clock = try MusicalTiming.reanchor(latest, using: timeline.currentClock)
                let units = try MusicalTiming.projectedUnits(of: pin.occurrence, from: clock, loop: loop)
                #expect(units == 135 * MusicalTiming.unitsPerFrame / 16) // 8.4375, before horizon 12.
            }
        }

        @Test(arguments: [UInt64(375), 468, 469, 750, 875, 1_000, 1_375, 1_875, 2_375])
        func recordedLoopFloorDoesNotRepeatWithTheVirtualPhase(_ host: UInt64) throws {
            var timeline = try fastEditedLoop(LoopRange(startTicks: 5, endTicks: 8))
            let origin = try timeline.origin(at: .init(ticks: host))
            #expect(origin.clock.anchor.sample.frame == 0 && origin.clock.musical.loopIteration == 0)
            if host < 469 { // 0.75 and 0.936 are below the exact start at 0.9375.
                let before = String(reflecting: timeline)
                #expect(throws: MusicalTimingError.outsideLoop) { try timeline.reserve(.grid(1), origin: origin) }
                #expect(String(reflecting: timeline) == before)
            } else {
                let pin = try timeline.reserve(.grid(1), origin: origin)
                #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 5))
                let units = try MusicalTiming.projectedUnits(of: pin.occurrence, from: timeline.currentClock,
                                                             loop: timeline.currentLoop)
                #expect(units == 611 * MusicalTiming.unitsPerFrame / 16) // Exact 38.1875, not a virtual pass.
                #expect(try timeline.project(pin).frame == 38)
            }
        }

        @Test(arguments: [UInt64(500), 625, 750])
        func zeroPeriodOriginsStayInTheirRecordedPass(_ host: UInt64) throws {
            var timeline = try fastEditedLoop(LoopRange(startTicks: 6, endTicks: 7))
            let origin = try timeline.origin(at: .init(ticks: host))
            #expect(origin.clock.anchor.sample.frame == 0 && origin.clock.musical.loopIteration == 0)
            if host == 500 { // Frame 1 is below exact start 1.125, despite a rounded wrap at 1.
                let before = String(reflecting: timeline)
                #expect(throws: MusicalTimingError.outsideLoop) { try timeline.reserve(.grid(1), origin: origin) }
                #expect(String(reflecting: timeline) == before)
            } else {
                let pin = try timeline.reserve(.grid(1), origin: origin)
                #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 6))
                let units = try MusicalTiming.projectedUnits(of: pin.occurrence, from: timeline.currentClock,
                                                             loop: timeline.currentLoop)
                #expect(units == 307 * MusicalTiming.unitsPerFrame / 8) // Exact 38.375 at origins 1.25/1.5.
                #expect(try timeline.project(pin).frame == 38)
            }
        }

        @Test(arguments: [Int64(0), 1])
        func passZeroFloorCannotReinterpretAnEvictedOrReplacedOrigin(_ frame: Int64) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 5, endTicks: 2_000),
                                                 history: 1, pins: 2, ticks: 5)
            let old = try timeline.origin(atFrame: 0)
            let stored = try timeline.reserve(.grid(1), origin: old)
            #expect(stored.occurrence == MusicalOccurrence(pass: 0, ticks: 5))
            try fixture.observe(&timeline, .musical, ledger, frame: frame, ticks: 6)
            #expect(timeline.firstMusicalAnchor.musical?.ticks == 5 && timeline.currentClock.musical.ticks == 6)
            let before = String(reflecting: timeline)
            #expect(throws: MusicalTimingError.expiredOrigin) { try timeline.reserve(.grid(1), origin: old) }
            #expect(String(reflecting: timeline) == before)
            // At frame 0 coverage still exists, but the replaced record cannot authenticate the old token.
            let fresh = try timeline.reserve(.grid(1), origin: timeline.origin(atFrame: frame))
            #expect(fresh.occurrence == MusicalOccurrence(pass: 0, ticks: 6))
            #expect(try timeline.project(fresh).frame == frame && timeline.pinCount == 2)
            #expect(stored.occurrence == MusicalOccurrence(pass: 0, ticks: 5))
            #expect(try timeline.project(stored).frame == frame - 2)
        }

        @Test(arguments: [1, 3], [0, 1])
        func stoppedEndOnlyGridKeepsTheExactFutureAlias(_ history: Int, _ retro: Int) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 1, endTicks: 2),
                                                 history: history, ticks: 1, segments: [(0, 60_000)])
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 1, pass: 1)
            try fixture.observe(&timeline, .running(false), ledger, frame: 0, ticks: 1, pass: 1)
            let pin = try timeline.reserve(.grid(2), origin: timeline.origin(atFrame: 0), retroactiveMs: retro)
            #expect(pin.occurrence == MusicalOccurrence(pass: 1, ticks: 2))
            #expect(throws: MusicalTimingError.stopped) { try timeline.project(pin) }
            try fixture.observe(&timeline, .running(true), ledger, frame: 0, ticks: 1, pass: 1)
            #expect(try timeline.project(pin).frame == 0 && timeline.project(pin).assumesFuture)
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 1, pass: 2)
            #expect(try timeline.project(pin).frame == 0 && !timeline.project(pin).assumesFuture)
        }

        @Test(arguments: [1, 3])
        func stoppedEndOnlyAbsoluteAliasRemainsTheParityControl(_ history: Int) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 1, endTicks: 2),
                                                 history: history, ticks: 1, segments: [(0, 60_000)])
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 1, pass: 1)
            try fixture.observe(&timeline, .running(false), ledger, frame: 0, ticks: 1, pass: 1)
            let pin = try timeline.reserve(.absolute(2), origin: timeline.origin(atFrame: 0))
            #expect(pin.occurrence == MusicalOccurrence(pass: 1, ticks: 2))
            try fixture.observe(&timeline, .running(true), ledger, frame: 0, ticks: 1, pass: 1)
            #expect(try timeline.project(pin).frame == 0 && timeline.project(pin).assumesFuture)
        }

        @Test(arguments: [1, 2])
        func stoppedEndOnlyForwardAliasDoesNotNeedAnInverseAnchor(_ history: Int) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 1, endTicks: 2),
                                                 history: history, ticks: 1)
            try fixture.observe(&timeline, .running(false), ledger, frame: 0, ticks: 1)
            let pin = try timeline.reserve(.grid(2), origin: timeline.origin(atFrame: 0))
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 2))
            try fixture.observe(&timeline, .running(true), ledger, frame: 0, ticks: 1)
            #expect(try timeline.project(pin).frame == 2 && timeline.project(pin).assumesFuture)
            try fixture.observe(&timeline, .wrap, ledger, frame: 2, ticks: 1, pass: 1)
            #expect(try timeline.project(pin).frame == 2 && !timeline.project(pin).assumesFuture)
        }

        @Test(arguments: [1, 2])
        func aStoppedForwardEndCannotHideAnUnknownOrdinaryInverse(_ history: Int) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 2),
                                                 history: history, ticks: 1)
            try fixture.observe(&timeline, .running(false), ledger, frame: 0, ticks: 0)
            let origin = try timeline.origin(atFrame: 0)
            let before = String(reflecting: timeline)
            if history == 1 {
                #expect(throws: MusicalTimingError.historyUnavailable) {
                    try timeline.reserve(.grid(1), origin: origin)
                }
                #expect(String(reflecting: timeline) == before)
            } else {
                // The held tick caps the predecessor, not the next inverse; its tick 1 beats the end at frame 3.
                let pin = try timeline.reserve(.grid(1), origin: origin)
                #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 1))
                try fixture.observe(&timeline, .running(true), ledger, frame: 0, ticks: 0)
                #expect(try timeline.project(pin).frame == 2)
            }
        }

        @Test(arguments: [1, 3], [false, true])
        func anExactStoppedEndCannotBypassAnOrdinaryBoundary(_ history: Int, _ addingLoop: Bool) throws {
            var (timeline, ledger) = try stoppedExactAlias(history: history, addingLoop: addingLoop)
            let origin = try timeline.origin(atFrame: 0)
            #expect(!origin.isRunning && origin.clock.musical.ticks == 0)
            let before = String(reflecting: timeline)
            if history == 1 {
                #expect(throws: MusicalTimingError.historyUnavailable) {
                    try timeline.reserve(.grid(1), origin: origin)
                }
                #expect(String(reflecting: timeline) == before)
                #expect(timeline.pinCount == 0)
            } else {
                let pin = try timeline.reserve(.grid(1), origin: origin)
                #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 1))
                #expect(throws: MusicalTimingError.stopped) { try timeline.project(pin) }
                try fixture.observe(&timeline, .running(true), ledger, frame: 0, ticks: 0)
                #expect(try timeline.project(pin).frame == 0 && !timeline.project(pin).assumesFuture)
            }
        }

        @Test(arguments: [1, 3], [false, true])
        func anExactStoppedEndKeepsTheProofForOrdinaryTicksBelowTheCeiling(_ history: Int, _ addingLoop: Bool) throws {
            // Tick 0's missing inverse is bounded strictly before frame 0; no ordinary grid tick is above held 0.
            for tempo: Int64 in [60_000, 100_000] {
                for target in [MusicalTarget.absolute(2), .grid(2)] {
                    var (timeline, ledger) = try stoppedExactAlias(history: history, addingLoop: addingLoop,
                                                                 tempo: tempo)
                    let pin = try timeline.reserve(target, origin: timeline.origin(atFrame: 0))
                    #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 2))
                    try fixture.observe(&timeline, .running(true), ledger, frame: 0, ticks: 0)
                    let assigned: Int64 = tempo == 60_000 ? 0 : 1
                    #expect(try timeline.project(pin).frame == assigned && timeline.project(pin).assumesFuture)
                }
            }
        }

        @Test func anExactHeldEndCannotBeReplacedByALaterOrdinaryBoundary() throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 2), ticks: 1)
            try fixture.observe(&timeline, .running(false), ledger, frame: 0, ticks: 0)
            let origin = try timeline.origin(atFrame: 0)
            try fixture.observe(&timeline, .running(true), ledger, frame: 1, ticks: 0)
            try fixture.observe(&timeline, .wrap, ledger, frame: 4, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .musical, ledger, frame: 4, ticks: 1, pass: 1)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 1_280_000)])), ledger, frame: 4)
            let later = try timeline.reserve(.absolute(1), origin: origin)
            #expect(try timeline.project(later).frame == 5)
            let pin = try timeline.reserve(.grid(1), origin: origin)
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 2))
            #expect(try timeline.project(pin).frame == 0 && !timeline.project(pin).assumesFuture)
        }

        @Test func anExactHeldEndCannotHideAPreLoopForwardRefusal() throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 4, endTicks: 12),
                                                 ticks: 1, segments: [(0, 1_000_000)])
            try fixture.observe(&timeline, .running(false), ledger, frame: 0, ticks: 0)
            let origin = try timeline.origin(atFrame: 0)
            try fixture.observe(&timeline, .running(true), ledger, frame: 0, ticks: 0)
            try fixture.observe(&timeline, .musical, ledger, frame: 8, ticks: 3)
            try fixture.observe(&timeline, .wrap, ledger, frame: 36, ticks: 4, pass: 1)
            try fixture.observe(&timeline, .musical, ledger, frame: 56, ticks: 11, pass: 1)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 2_560_000)])), ledger, frame: 56)
            let before = String(reflecting: timeline)
            // Tick 2 ties the exact end, but remains pre-loop; the alias must not make it admissible.
            #expect(throws: MusicalTimingError.outsideLoop) { try timeline.reserve(.grid(1), origin: origin) }
            #expect(String(reflecting: timeline) == before)
            #expect(timeline.pinCount == 0)
        }

        @Test func anEarlierPassEndDoesNotBorrowTheOriginPassHeldCeiling() throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 6),
                                                 history: 1, ticks: 4, segments: [(0, 60_000)])
            _ = try timeline.reserve(.absolute(4), origin: timeline.origin(atFrame: 0))
            _ = try timeline.reserve(.absolute(6), origin: timeline.origin(atFrame: 0))
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 1, ticks: 0, pass: 2)
            try fixture.observe(&timeline, .musical, ledger, frame: 1, ticks: 1, pass: 2)
            try fixture.observe(&timeline, .musical, ledger, frame: 1, ticks: 2, pass: 2)
            try fixture.observe(&timeline, .running(false), ledger, frame: 1, ticks: 1, pass: 2)
            try fixture.observe(&timeline, .loop(.init(startTicks: 1, endTicks: 6)), ledger, frame: 1)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 320_000)])), ledger, frame: 1)
            // The held ceiling excludes pass 2's tick 2, not the independently proven pass 0 end.
            let pin = try timeline.reserve(.grid(2), origin: timeline.origin(atFrame: 1))
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 6))
            #expect(throws: MusicalTimingError.stopped) { try timeline.project(pin) }
            try fixture.observe(&timeline, .running(true), ledger, frame: 1, ticks: 1, pass: 2)
            #expect(try timeline.project(pin).frame == 1 && !timeline.project(pin).assumesFuture)
        }

        private func fastEditedLoop(_ loop: LoopRange) throws -> MusicalTimeline {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: loop, segments: [(0, 3_000_000)])
            try fixture.observe(&timeline, .musical, ledger, frame: 38, ticks: 4)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 60_000)])), ledger, frame: 38)
            return timeline
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

extension ControlContractTests.MusicalForwardValidation {
    @Test(arguments: [1, 3], [false, true])
    func aForwardEndStillNeedsAnExactOrdinaryInverseAfterMapEdits(_ history: Int, _ addingLoop: Bool) throws {
        var (timeline, ledger) = try stoppedExactAlias(history: history, addingLoop: addingLoop, tempo: 100_000)
        let origin = try timeline.origin(atFrame: 0)
        let before = String(reflecting: timeline)
        if history == 1 {
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try timeline.reserve(.grid(1), origin: origin)
            }
            #expect(String(reflecting: timeline) == before && timeline.pinCount == 0)
        } else {
            let pin = try timeline.reserve(.grid(1), origin: origin)
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 1))
            try fixture.observe(&timeline, .running(true), ledger, frame: 0, ticks: 0)
            #expect(try timeline.project(pin).frame == 0 && !timeline.project(pin).assumesFuture)
        }
    }

    private func stoppedExactAlias(history: Int, addingLoop: Bool, tempo: Int64 = 60_000)
        throws -> (MusicalTimeline, GenerationLedger) {
        var ledger = try fixture.ledger()
        let loop = try LoopRange(startTicks: 0, endTicks: 2)
        var timeline = try fixture.timeline(ledger, loop: addingLoop ? nil : loop, history: history,
                                             ticks: 1, segments: [(0, addingLoop ? tempo : 500_000)])
        try fixture.observe(&timeline, .running(false), ledger, frame: 0, ticks: 0)
        if addingLoop {
            try fixture.observe(&timeline, .loop(loop), ledger, frame: 0)
        } else {
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, tempo)])), ledger, frame: 0)
        }
        return (timeline, ledger)
    }
}
