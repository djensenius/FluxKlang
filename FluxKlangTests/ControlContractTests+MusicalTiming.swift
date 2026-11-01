import Foundation
import Testing
@testable import FluxKlang
extension ControlContractTests {
    struct MusicalTimingValidation {
        let fixture = MusicalFoundationFixture()
        @Test func retroactiveWindowUsesExactFrameAndLatestProjectionAnchor() throws {
            let ledger = try fixture.ledger(); var timeline = try fixture.timeline(ledger)
            try fixture.observe(&timeline, .primary, ledger, frame: 100)
            let exact = try timeline.reserve(.grid(33), origin: timeline.origin(atFrame: 100), retroactiveMs: 1)
            // Tick 33 is frame 51.5625, NOT 52 when testing a 48-frame retroactive window.
            #expect(exact.occurrence == .init(pass: 0, ticks: 66)); let delayed = try timeline.origin(atFrame: 90)
            try fixture.observe(&timeline, .running(false), ledger, frame: 150, ticks: 96)
            try fixture.observe(&timeline, .running(true), ledger, frame: 1_000, ticks: 96)
            let resumed = try timeline.reserve(.grid(33), origin: delayed, retroactiveMs: 1)
            #expect(resumed.occurrence == MusicalOccurrence(pass: 0, ticks: 66))
        }
        @Test func delayedOriginUsesActualPassAndAnchorButCurrentResolutionMap() throws {
            var ledger = try fixture.ledger(); var timeline = try fixture.timeline(ledger)
            try fixture.observe(&timeline, .primary, ledger, frame: 500); let origin = try timeline.origin(atFrame: 500)
            try fixture.observe(&timeline, .musical, ledger, frame: 750, ticks: 480)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 1_000_000)])), ledger, frame: 750)
            let pin = try timeline.reserve(.grid(240), origin: origin)
            #expect(pin.occurrence == .init(pass: 0, ticks: 240)); #expect(try timeline.project(pin).frame == 0)
        }
        @Test func delayedOriginDoesNotAcquireHypotheticalPassesAfterTempoEdit() throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1_920))
            try fixture.observe(&timeline, .primary, ledger, frame: 2_500)
            let origin = try timeline.origin(atFrame: 2_500)
            try fixture.observe(&timeline, .wrap, ledger, frame: 3_000, ticks: 0, pass: 1)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 60_000)])), ledger, frame: 3_000)
            let pin = try timeline.reserve(.absolute(0), origin: origin)
            #expect(pin.occurrence == .init(pass: 0, ticks: 0)); #expect(try timeline.project(pin).frame == 0)
            #expect(throws: MusicalTimingError.outsideLoop) {
                try timeline.reserve(.grid(1_440), origin: origin)
            }
            #expect(timeline.pinCount == 1) // Never silently reinterpret the old origin as virtual pass 6.
        }
        @Test func initialAndFallbackQuantizationCrossWrapWithoutRetargeting() throws {
            let ledger = try fixture.ledger(); let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            var timeline = try fixture.timeline(ledger, loop: loop)
            try fixture.observe(&timeline, .primary, ledger, frame: 2_500)
            let pin = try timeline.reserve(.grid(1_440), origin: timeline.origin(atFrame: 2_500))
            #expect(pin.occurrence == .init(pass: 1, ticks: 0)); #expect(try timeline.project(pin).frame == 3_000)
            #expect(try timeline.project(pin).assumesFuture)
            #expect(try timeline.nextBoundary(at: 2_500, grid: 1_440).frame == 3_000)
            try fixture.observe(&timeline, .wrap, ledger, frame: 3_000, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 6_000, ticks: 0, pass: 2)
            try fixture.observe(&timeline, .primary, ledger, frame: 6_001)
            #expect(try timeline.project(pin).frame == 3_000); #expect(try !timeline.project(pin).assumesFuture)
        }
        @Test func latestRunningAnchorAndCurrentMapResolveOnlyThePinnedPass() throws {
            var ledger = try fixture.ledger(); let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            var timeline = try fixture.timeline(ledger, loop: loop, history: 1)
            let pin = try timeline.reserve(.absolute(960), origin: timeline.origin(atFrame: 0))
            try fixture.observe(&timeline, .musical, ledger, frame: 750, ticks: 480)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 1_000_000)])), ledger, frame: 750)
            #expect(try timeline.project(pin).frame == 2_250)
            try fixture.observe(&timeline, .wrap, ledger, frame: 5_250, ticks: 0, pass: 1)
            #expect(try timeline.project(pin).frame == 2_250) // Not 3_000, nor the current pass's 8_250.
            #expect(try timeline.project(pin).musicalMap == (try Generation(2)))
        }
        @Test func samePassResumeReprojectsIdentityNotPhysicalPastFrame() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1_920))
            let pin = try timeline.reserve(.absolute(480), origin: timeline.origin(atFrame: 0))
            try fixture.observe(&timeline, .running(false), ledger, frame: 1_500, ticks: 960)
            try fixture.observe(&timeline, .primary, ledger, frame: 5_000)
            try fixture.observe(&timeline, .running(true), ledger, frame: 6_000, ticks: 960)
            #expect(try timeline.project(pin).frame == 5_250) // The disputed 750 expectation is NOT canonical.
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 480))
        }
        @Test func historicalResumeAnchorSurvivesWrapAndEviction() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1_920), history: 1)
            let pin = try timeline.reserve(.absolute(1_440), origin: timeline.origin(atFrame: 0))
            try fixture.observe(&timeline, .running(false), ledger, frame: 1_500, ticks: 960)
            try fixture.observe(&timeline, .running(true), ledger, frame: 6_000, ticks: 960)
            try fixture.observe(&timeline, .wrap, ledger, frame: 7_500, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .primary, ledger, frame: 7_501)
            #expect(try timeline.project(pin).frame == 6_750)
        }
        @Test func loopEndAliasesProjectionPassButNeverStoredIdentity() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1_920), history: 1)
            let pin = try timeline.reserve(.absolute(1_920), origin: timeline.origin(atFrame: 0))
            #expect(pin.occurrence == .init(pass: 0, ticks: 1_920)); #expect(try timeline.project(pin).frame == 3_000)
            try fixture.observe(&timeline, .wrap, ledger, frame: 3_000, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .running(false), ledger, frame: 3_000, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .running(true), ledger, frame: 6_000, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 9_000, ticks: 0, pass: 2)
            #expect(try timeline.project(pin).frame == 6_000); #expect(pin.occurrence == .init(pass: 0, ticks: 1_920))
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try fixture.observe(&timeline, .loop(nil), ledger, frame: 9_000)
            }
            #expect(timeline.currentLoop?.endTicks == 1_920 && timeline.pinCount == 1)
        }
        @Test func retroactiveWindowIncludesPreviousPassLastBoundary() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 100, endTicks: 2_000), ticks: 100)
            try fixture.observe(&timeline, .wrap, ledger, frame: 2_969, ticks: 100, pass: 1)
            let origin = try timeline.origin(atFrame: 2_969)
            let prior = try timeline.reserve(.grid(960), origin: origin, retroactiveMs: 3)
            let forward = try timeline.reserve(.grid(960), origin: origin, retroactiveMs: 2)
            #expect(prior.occurrence == MusicalOccurrence(pass: 0, ticks: 1_920))
            #expect(try timeline.project(prior).frame == 2_844)
            #expect(forward.occurrence == MusicalOccurrence(pass: 1, ticks: 960))
            #expect(try timeline.project(forward).frame == 4_313)
            var lost = try fixture.timeline(ledger, loop: LoopRange(startTicks: 100, endTicks: 2_000),
                                           history: 1, ticks: 100)
            try fixture.observe(&lost, .wrap, ledger, frame: 2_969, ticks: 100, pass: 1)
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try lost.reserve(.grid(960), origin: lost.origin(atFrame: 2_969), retroactiveMs: 3)
            }
            #expect(lost.pinCount == 0)
        }
        @Test func loopEndDoesNotAliasAnAnchorBeyondTheLoop() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 100, endTicks: 2_000),
                                                 frame: 2_000, ticks: 3_000)
            let pin = try timeline.reserve(.absolute(2_000), origin: timeline.origin(atFrame: 2_000))
            #expect(pin.occurrence == .init(pass: 0, ticks: 2_000)); #expect(try timeline.project(pin).frame == 438)
        }
        @Test func fractionalOriginsPreservePassAndIndependentRetroactiveChoice() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 3))
            try fixture.observe(&timeline, .wrap, ledger, frame: 5, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 10, ticks: 0, pass: 2)
            for ((host, pass), wrap): ((UInt64, Int128), Int64) in [((2_400, 0), 5), ((4_900, 1), 10)] {
                let origin = try timeline.origin(at: .init(ticks: host))
                #expect(Int128(origin.clock.musical.loopIteration) == pass)
                for grid: Int64 in [1, 2] {
                    for retro in [0, 1] {
                        let pin = try timeline.reserve(.grid(grid), origin: origin, retroactiveMs: retro)
                        let expected = retro > 0 ? MusicalOccurrence(pass: pass, ticks: 2)
                            : MusicalOccurrence(pass: grid == 1 ? pass : pass + 1, ticks: grid == 1 ? 3 : 0)
                        #expect(pin.occurrence == expected)
                        #expect(try timeline.project(pin).frame == (retro > 0 ? wrap - 2 : wrap))
                        try timeline.release(pin)
                    }
                }
            }
            #expect(try timeline.origin(at: .init(ticks: 2_500)).clock.musical.loopIteration == 1)
        }
        @Test func fractionalRetroactiveWindowsDoNotRoundTheOrigin() throws {
            let ledger = try fixture.ledger(); var timeline = try fixture.timeline(ledger)
            try fixture.observe(&timeline, .primary, ledger, frame: 100)
            for (host, ticks): (UInt64, Int64) in [(49_781, 33), (49_782, 66)] {
                let origin = try timeline.origin(at: .init(ticks: host))
                let pin = try timeline.reserve(.grid(33), origin: origin, retroactiveMs: 1)
                #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: ticks))
            }
        }
        @Test func endOnlyGridKeepsPreviousPassAfterSnappingBelowLoopStart() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 1, endTicks: 2), history: 3, ticks: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 2, ticks: 1, pass: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 4, ticks: 1, pass: 2)
            let origin = try timeline.origin(at: .init(ticks: 1_900))
            for retro in [0, 1] {
                let pin = try timeline.reserve(.grid(2), origin: origin, retroactiveMs: retro)
                #expect(pin.occurrence == MusicalOccurrence(pass: retro > 0 ? 0 : 1, ticks: 2))
                #expect(try timeline.project(pin).frame == (retro > 0 ? 2 : 4)); try timeline.release(pin)
            }
            let first = try timeline.reserve(.grid(2), origin: timeline.origin(at: .init(ticks: 900)), retroactiveMs: 1)
            #expect(first.occurrence == .init(pass: 0, ticks: 2)); #expect(try timeline.project(first).frame == 2)
            try fixture.observe(&timeline, .primary, ledger, frame: 5)
            let retained = try timeline.reserve(.grid(2), origin: timeline.origin(at: .init(ticks: 1_900)),
                                                retroactiveMs: 1)
            #expect(try retained.occurrence == first.occurrence && timeline.project(retained).frame == 2)
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try fixture.observe(&timeline, .loop(nil), ledger, frame: 5)
            }
        }
        @Test func pastEndAnchorsRetainAdmissibleRetroactiveBoundaries() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 100, endTicks: 2_000),
                                                 frame: 2_000, ticks: 3_000)
            let origin = try timeline.origin(atFrame: 2_000)
            for retro in [0, 35] {
                #expect(throws: MusicalTimingError.outsideLoop) {
                    try timeline.reserve(.grid(960), origin: origin, retroactiveMs: retro)
                }
                #expect(timeline.pinCount == 0)
            }
            for retro in [36, 50] {
                let pin = try timeline.reserve(.grid(960), origin: origin, retroactiveMs: retro)
                #expect(pin.occurrence == .init(pass: 0, ticks: 1_920)); #expect(try timeline.project(pin).frame == 313)
                try timeline.release(pin)
            }
        }
        @Test func maximumTickKeepsValidRetroactivityBeforeForwardOverflow() throws {
            let ledger = try fixture.ledger(); var timeline = try fixture.timeline(ledger, ticks: .max)
            let origin = try timeline.origin(atFrame: 0)
            #expect(throws: MusicalTimingError.overflow) { try timeline.reserve(.grid(2), origin: origin) }
            #expect(timeline.pinCount == 0)
            let prior = try timeline.reserve(.grid(2), origin: origin, retroactiveMs: 1)
            #expect(prior.occurrence.ticks == Int64.max - 1); #expect(try timeline.project(prior).frame == -2)
            try timeline.release(prior); try fixture.observe(&timeline, .primary, ledger, frame: 2)
            for ((grid, ticks), frame): ((Int64, Int64), Int64) in [((1, .max), 0), ((2, .max - 1), -2)] {
                let pin = try timeline.reserve(.grid(grid), origin: timeline.origin(atFrame: 2), retroactiveMs: 1)
                #expect(pin.occurrence.ticks == ticks); #expect(try timeline.project(pin).frame == frame)
            }
        }
        @Test func fullWidthHostFractionsPreserveValidInt64Projections() throws {
            let rate = 192_000
            let ledger = try GenerationLedger(primaryClock: fixture.primary, musicalClock: fixture.musical,
                                               nominalRate: rate)
            let elapsed = ExactMath.ceilDiv(Int128(UInt64.max) * Int128(rate), ExactMath.nanosPerSecond)
            let first = try fixture.anchor(ledger, frame: MusicalTiming.narrow(Int128(Int64.max) - elapsed), ticks: 0)
            let sample = try SampleClockMap(anchor: first, nominalRate: rate, timebase: .init(numer: .max, denom: .max))
            let map = try fixture.map(ledger)
            var timeline = try MusicalTimeline(sample: sample, anchor: first, map: map, running: true,
                                                historyLimit: 2, pinLimit: 1, ledger: ledger)
            try timeline.observe(.primary, at: fixture.anchor(ledger, frame: .max, host: .max),
                                 sequence: 1, ledger: ledger)
            let origin = try timeline.origin(at: .init(ticks: .max - 1))
            let pin = try timeline.reserve(.grid(1), origin: origin, retroactiveMs: 1)
            let ticks = try MusicalTiming.narrow(Int128(UInt64.max - 1) * 15_360 / 500_000_000)
            let clock = try MusicalClockMap(anchor: first, map: map, nominalRate: rate,
                                            currentSample: .initial, currentTransport: .initial)
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: ticks))
            #expect(try timeline.project(pin).frame == clock.frame(atTicks: ticks))
        }
        @Test func negativeFractionalOriginsDoNotAcquireTheNextAnchor() throws {
            let ledger = try fixture.ledger(); var timeline = try fixture.timeline(ledger, frame: -1)
            try timeline.observe(.musical, at: fixture.anchor(ledger, frame: 0, host: 500, ticks: 1),
                                 sequence: 1, ledger: ledger)
            let origin = try timeline.origin(at: .init(ticks: 250))
            #expect(origin.frame == 0 && origin.clock.musical.ticks == 0)
            #expect(try timeline.origin(atFrame: 0).clock.musical.ticks == 1)
            let pin = try timeline.reserve(.grid(1), origin: origin, retroactiveMs: 1)
            #expect(pin.occurrence == .init(pass: 0, ticks: 0)); #expect(try timeline.project(pin).frame == -2)
        }
        @Test func virtualWrapsEqualExplicitRoundedAnchors() throws {
            let ledger = try fixture.ledger(); let loop = try LoopRange(startTicks: 0, endTicks: 3)
            let clock = try fixture.clock(ledger); var timeline = try fixture.timeline(ledger, loop: loop)
            #expect(try timeline.nextBoundary(at: 10, grid: 2).frame == 10)
            for pass in 1...8 {
                for tick: Int64 in [0, 2, 3] {
                    let virtual = try MusicalTiming.frame(of: .init(pass: Int128(pass), ticks: tick),
                                                          from: clock, loop: loop)
                    let explicit = try fixture.clock(ledger, frame: Int64(pass * 5), pass: UInt32(pass))
                    #expect(try MusicalTiming.frame(of: .init(pass: Int128(pass), ticks: tick),
                                                     from: explicit, loop: loop) == virtual)
                }
                try fixture.observe(&timeline, .wrap, ledger, frame: Int64(pass * 5), ticks: 0, pass: UInt32(pass))
            }
            let distant = try MusicalTiming.frame(of: .init(pass: 1_000_000_000, ticks: 2), from: clock, loop: loop)
            #expect(distant == 5_000_000_003)
        }
        @Test func segmentedLoopRoundingAndFullRangeFramesRemainChecked() throws {
            let ledger = try fixture.ledger(); let segments: [(Int64, Int64)] = [(0, 500_000), (1, 1_000_000)]
            let clock = try fixture.clock(ledger, segments: segments)
            let loop = try LoopRange(startTicks: 0, endTicks: 3)
            for pass in 1...8 {
                let occurrence = MusicalOccurrence(pass: Int128(pass), ticks: 2)
                let explicit = try fixture.clock(ledger, frame: Int64(pass * 8), pass: UInt32(pass), segments: segments)
                #expect(try MusicalTiming.frame(of: occurrence, from: clock, loop: loop) == Int64(pass * 8 + 5))
                #expect(try MusicalTiming.frame(of: occurrence, from: explicit, loop: loop) == Int64(pass * 8 + 5))
            }
            for frame: Int64 in [.min, .max] {
                let extreme = try fixture.clock(ledger, frame: frame)
                #expect(try MusicalTiming.frame(of: .init(pass: 0, ticks: 0), from: extreme, loop: nil) == frame)
            }
        }
        @Test func zeroRoundedPeriodPreservesBoundariesAndFailsWithoutWalking() throws {
            let ledger = try fixture.ledger(); let clock = try fixture.clock(ledger, segments: [(0, 60_000)])
            for ((start, end), (horizon, expected)): ((Int64, Int64), (Int64, Int64)) in [
                ((0, 1), (0, 0)), ((100, 101), (18, 19)), ((100, 101), (19, 19))
            ] {
                let loop = try LoopRange(startTicks: start, endTicks: end)
                let occurrence = try MusicalTiming.nextBoundary(at: horizon, grid: max(start, 1),
                                                                clock: clock, loop: loop)
                #expect(try MusicalTiming.frame(of: occurrence, from: clock, loop: loop) == expected)
                #expect(throws: MusicalTimingError.nonAdvancingLoop) {
                    try MusicalTiming.nextBoundary(at: expected + 1, grid: max(start, 1), clock: clock, loop: loop)
                }
            }
        }
        @Test func futurePassAtTheSameFrameRemainsHypotheticalUntilObserved() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1),
                                                 segments: [(0, 60_000)])
            let next = try timeline.nextBoundary(at: 0, grid: 1)
            #expect(next.occurrence == .init(pass: 1, ticks: 0) && next.frame == 0 && next.assumesFuture)
            let origin = try timeline.origin(atFrame: 0)
            let current = try timeline.reserve(.grid(1), origin: origin, retroactiveMs: 1)
            let end = try timeline.reserve(.absolute(1), origin: origin)
            #expect(current.occurrence == MusicalOccurrence(pass: 0, ticks: 0))
            #expect(try !timeline.project(current).assumesFuture); #expect(try timeline.project(end).assumesFuture)
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 0, pass: 1)
            #expect(try !timeline.project(end).assumesFuture)
            let delayed = try timeline.reserve(.grid(1), origin: origin, retroactiveMs: 1)
            #expect(delayed.occurrence == MusicalOccurrence(pass: 0, ticks: 0))
            let observed = try timeline.reserve(.grid(1), origin: timeline.origin(atFrame: 0), retroactiveMs: 1)
            #expect(observed.occurrence == MusicalOccurrence(pass: 1, ticks: 0))
            let subsequent = try timeline.nextBoundary(at: 0, grid: 1)
            #expect(subsequent.occurrence == MusicalOccurrence(pass: 2, ticks: 0))
            #expect(subsequent.frame == 0 && subsequent.assumesFuture)
        }
        @Test func nearMaximumFrameResolvesBeforeUnrepresentableWrap() throws {
            let ledger = try fixture.ledger(); let base = Int64.max - 2_000
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920); let clock = try fixture.clock(ledger, frame: base)
            let occurrence = try MusicalTiming.nextBoundary(at: base + 1, grid: 960, clock: clock, loop: loop)
            #expect(occurrence == MusicalOccurrence(pass: 0, ticks: 960))
            #expect(try MusicalTiming.frame(of: occurrence, from: clock, loop: loop) == Int64.max - 500)
            #expect(throws: MusicalTimingError.overflow) {
                try MusicalTiming.frame(of: .init(pass: 1, ticks: 0), from: clock, loop: loop)
            }
        }
        @Test func fullWidthGridAndLegalMaximumLoopRemainExact() throws {
            let ledger = try fixture.ledger(); let end = Int64.max
            let loop = try LoopRange(startTicks: end - 4, endTicks: end)
            var timeline = try fixture.timeline(ledger, loop: loop, ticks: end - 4)
            try fixture.observe(&timeline, .wrap, ledger, frame: 6, ticks: end - 4, pass: 1)
            let prior = try timeline.reserve(.grid(2), origin: timeline.origin(atFrame: 6), retroactiveMs: 1)
            #expect(prior.occurrence == .init(pass: 0, ticks: end - 1)); #expect(try timeline.project(prior).frame == 5)
            #expect(try timeline.nextBoundary(at: 6, grid: 2).frame == 8)
            let huge = try LoopRange(startTicks: 0, endTicks: end); let clock = try fixture.clock(ledger)
            #expect(try MusicalTiming.frame(of: .init(pass: 0, ticks: 960), from: clock, loop: huge) == 1_500)
            #expect(throws: MusicalTimingError.overflow) {
                try MusicalTiming.frame(of: .init(pass: .max, ticks: 0), from: clock, loop: huge)
            }
            #expect(throws: MusicalTimingError.overflow) {
                try MusicalTiming.frame(of: .init(pass: .max, ticks: end), from: clock, loop: huge)
            }
        }
        @Test func invalidContextsAndOutOfLoopGridsFailControlled() throws {
            let ledger = try fixture.ledger()
            #expect(throws: MusicalTimingError.invalidContext) { try fixture.timeline(ledger, ticks: -1) }
            let negative = try fixture.clock(ledger, ticks: -1)
            #expect(throws: MusicalTimingError.invalidContext) {
                try MusicalTiming.nextBoundary(at: 0, grid: 1, clock: negative, loop: nil)
            }
            let clock = try fixture.clock(ledger, ticks: 100); let loop = try LoopRange(startTicks: 100, endTicks: 200)
            #expect(throws: MusicalTimingError.outsideLoop) {
                try MusicalTiming.nextBoundary(at: 1, grid: 960, clock: clock, loop: loop)
            }
            #expect(throws: MusicalTimingError.invalidTarget) {
                try MusicalTiming.nextBoundary(at: 0, grid: 0, clock: clock, loop: loop)
            }
            let maximumPass = try fixture.clock(ledger, pass: .max)
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try MusicalTiming.frame(of: .init(pass: 0, ticks: 100), from: maximumPass, loop: loop)
            }
        }
        @Test func exactSegmentIntegrationAndSignedHalfUpRounding() throws {
            let ledger = try fixture.ledger()
            let clock = try fixture.clock(ledger, frame: 72_000, ticks: 30_720,
                                          segments: [(0, 500_000), (15_360, 1_000_000)])
            for (tick, frame): (Int64, Int64) in [(0, 0), (7_680, 12_000), (15_360, 24_000), (30_720, 72_000)] {
                #expect(try MusicalTiming.frame(of: .init(pass: 0, ticks: tick), from: clock, loop: nil) == frame)
            }
            let half = MusicalTiming.unitsPerFrame / 2
            #expect(MusicalTiming.rounded(half) == 1 && MusicalTiming.rounded(-half) == 0)
            #expect(MusicalTiming.rounded(-half - 1) == -1)
            #expect(MusicalTiming.rounded(.max) > 0 && MusicalTiming.rounded(.min) < 0)
            let boundary = try MusicalTiming.nextBoundary(at: 30_000, grid: 15_360,
                                                          clock: fixture.clock(ledger), loop: nil)
            #expect(try MusicalTiming.frame(of: boundary, from: fixture.clock(ledger), loop: nil) == 48_000)
        }
    }
}
extension ControlContractTests.MusicalTimingValidation {
    @Test(arguments: [(2, Int64(15)), (2, 16), (6, 15), (6, 16)], [0, 1])
    func historicalPinGapsCannotChooseAFartherProjection(_ context: (Int, Int64), _ retro: Int) throws {
        let (history, frame) = context; var ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 3), history: history)
        let stored = try timeline.reserve(.absolute(0), origin: timeline.origin(atFrame: 0))
        for pass: UInt32 in 1...3 {
            try fixture.observe(&timeline, .wrap, ledger, frame: Int64(pass) * 5, ticks: 0, pass: pass)
        }
        try ledger.bump(fixture.mapKey, reason: .tempoEdit)
        try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 900_000)])), ledger, frame: 15)
        try fixture.observe(&timeline, .primary, ledger, frame: 16)
        if history == 2 {
            #expect(throws: MusicalTimingError.uncoveredOrigin) { try timeline.origin(atFrame: 11) }
        }
        if history == 2 && frame == 16 {
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try timeline.reserve(.grid(1), origin: timeline.origin(atFrame: frame), retroactiveMs: retro)
            }
            #expect(timeline.pinCount == 1)
        } else {
            let pin = try timeline.reserve(.grid(1), origin: timeline.origin(atFrame: frame), retroactiveMs: retro)
            let previous = frame == 16 && retro > 0
            #expect(pin.occurrence == .init(pass: previous ? 2 : 3, ticks: frame == 15 ? 0 : previous ? 2 : 1))
            #expect(try timeline.project(pin).frame == (frame == 15 ? 15 : previous ? 16 : 18))
        }
        #expect(try timeline.project(stored).frame == 0)
    }
    @Test(arguments: [(13, false), (13, true), (15, false), (15, true)], [0, 1])
    func retroactiveSearchUsesDistantRetainedAnchors(_ retention: (Int, Bool), _ retro: Int) throws {
        var ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 1_001), history: retention.0)
        if retention.1 { _ = try timeline.reserve(.absolute(780), origin: timeline.origin(atFrame: 0)) }
        try fixture.observe(&timeline, .wrap, ledger, frame: 1_564, ticks: 0, pass: 1)
        try fixture.observe(&timeline, .wrap, ledger, frame: 3_128, ticks: 0, pass: 2)
        try ledger.bump(fixture.mapKey, reason: .tempoEdit)
        try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 1_280_000)])), ledger, frame: 3_128)
        for index: Int64 in 1...11 {
            try fixture.observe(&timeline, .musical, ledger, frame: 3_128 + 100 * index, ticks: 26 * index, pass: 2)
        }
        if retention.0 == 13 && retention.1 {
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try timeline.reserve(.grid(4), origin: timeline.origin(atFrame: 3_128), retroactiveMs: retro)
            }
            #expect(timeline.pinCount == 1)
            return
        }
        let pin = try timeline.reserve(.grid(4), origin: timeline.origin(atFrame: 3_128), retroactiveMs: retro)
        let earlier = retro > 0 && (retention.1 || retention.0 == 15)
        #expect(pin.occurrence == .init(pass: earlier ? 0 : 2, ticks: retro == 0 ? 0 : earlier ? 780 : 8))
        #expect(try timeline.project(pin).frame == (retro == 0 ? 3_084 : earlier ? 3_120 : 3_116))
    }
    @Test(arguments: [0, 1]) func retroactiveSearchComparesEarlierPassesAfterValidReanchors(_ retro: Int) throws {
        let ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1_001), history: 12)
        try fixture.observe(&timeline, .wrap, ledger, frame: 1_564, ticks: 0, pass: 1)
        for index: Int64 in 1...10 {
            try fixture.observe(&timeline, .musical, ledger, frame: 1_564 + 100 * index, ticks: 65 * index, pass: 1)
        }
        let pin = try timeline.reserve(.grid(4), origin: timeline.origin(atFrame: 1_564), retroactiveMs: retro)
        // Pass 1 tick 8 projects to 1560.875; pass 0 tick 1000 is closer at 1562.5.
        #expect(pin.occurrence == MusicalOccurrence(pass: retro == 0 ? 1 : 0, ticks: retro == 0 ? 0 : 1_000))
        #expect(try timeline.project(pin).frame == (retro == 0 ? 1_548 : 1_563))
    }
    @Test(arguments: [Int64(0), 100])
    func stoppedOriginsKeepBothHeldTickAndFrameBounds(_ resumeFrame: Int64) throws {
        let ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger, running: false, history: 16, ticks: 10)
        if resumeFrame > 0 {
            try fixture.observe(&timeline, .primary, ledger, frame: resumeFrame)
        }
        let origin = try timeline.origin(atFrame: resumeFrame)
        try fixture.observe(&timeline, .running(true), ledger, frame: resumeFrame, ticks: 10)
        for offset: Int64 in 1...6 {
            try fixture.observe(&timeline, .musical, ledger, frame: resumeFrame + offset, ticks: 10 + offset)
        }
        let pin = try timeline.reserve(.grid(3), origin: origin, retroactiveMs: 1)
        #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: resumeFrame == 0 ? 9 : 12))
        #expect(try timeline.project(pin).frame == (resumeFrame == 0 ? -5 : 100))
    }
    @Test func maximumObservedPassMathKeepsMatchingAndFutureOccurrences() throws {
        let ledger = try fixture.ledger(); let clock = try fixture.clock(ledger, pass: .max)
        let loop = try LoopRange(startTicks: 0, endTicks: 1_920); let pass = Int128(UInt32.max)
        let current = MusicalOccurrence(pass: pass, ticks: 960)
        #expect(try MusicalTiming.frame(of: current, from: clock, loop: loop) == 1_500)
        let future = try MusicalTiming.nextBoundary(at: 3_001, grid: 960, clock: clock, loop: loop)
        #expect(future == MusicalOccurrence(pass: pass + 1, ticks: 960))
        #expect(try MusicalTiming.frame(of: future, from: clock, loop: loop) == 4_500)
    }
    @Test(arguments: [-1, 1], [Int64(500), 501])
    func retroactiveSearchSkipsFutureProjectionsWithoutWalkingGridTicks(_ drift: Int, _ frame: Int64) throws {
        let ledger = try fixture.ledger()
        for count in [1, 40] {
            var timeline = try fixture.timeline(ledger, history: count + 2)
            try fixture.observe(&timeline, .primary, ledger, frame: frame)
            let origin = try timeline.origin(atFrame: frame)
            for index in 1...count {
                try fixture.observe(&timeline, .musical, ledger, frame: Int64(index * 1_000),
                                    ticks: Int64(index * (640 + drift)))
            }
            let forward = try timeline.reserve(.grid(1), origin: origin)
            let prior = try timeline.reserve(.grid(1), origin: origin, retroactiveMs: 1)
            #expect(forward.occurrence == .init(pass: 0, ticks: frame == 500 ? Int64(320 + count * drift) : 321))
            #expect(prior.occurrence == MusicalOccurrence(pass: 0, ticks: Int64(320 + count * drift)))
            #expect(try timeline.project(prior).frame == 500)
            if frame == 500 { #expect(try timeline.project(forward).frame == 500) }
            if count == 1 && drift == 1 && frame == 500 {
                let midpoint = try timeline.reserve(.grid(6), origin: origin)
                #expect(midpoint.occurrence == .init(pass: 0, ticks: 324))
                #expect(try timeline.project(midpoint).frame == 505)
            }
        }
    }
    @Test func retroactiveSearchChecksAnEndAliasMovedBeforeTheOrigin() throws {
        let ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 3))
        try fixture.observe(&timeline, .wrap, ledger, frame: 5, ticks: 0, pass: 1)
        try fixture.observe(&timeline, .musical, ledger, frame: 6, ticks: 1, pass: 1)
        let pin = try timeline.reserve(.grid(1), origin: timeline.origin(at: .init(ticks: 2_250)), retroactiveMs: 1)
        #expect(pin.occurrence == .init(pass: 0, ticks: 3)); #expect(try timeline.project(pin).frame == 4)
    }
    @Test func aMovedEndAliasDoesNotMaskACloserInteriorProjection() throws {
        let ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 100), history: 110)
        try fixture.observe(&timeline, .wrap, ledger, frame: 156, ticks: 0, pass: 1)
        for tick: Int64 in 1...99 {
            try fixture.observe(&timeline, .musical, ledger, frame: 156 + tick, ticks: tick, pass: 1)
        }
        let pin = try timeline.reserve(.grid(1), origin: timeline.origin(at: .init(ticks: 77_500)), retroactiveMs: 1)
        #expect(pin.occurrence == .init(pass: 0, ticks: 99)); #expect(try timeline.project(pin).frame == 155)
    }
}
