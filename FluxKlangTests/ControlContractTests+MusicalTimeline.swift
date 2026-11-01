import Foundation
import Testing
@testable import FluxKlang

/// Shared only by the two foundation suites; all clocks and generations are real accepted contract values.
struct MusicalFoundationFixture {
    let primary = ClockID(validated: "sample.foundation")
    let musical = ClockID(validated: "musical.foundation")
    var transport: GenerationKey { GenerationKey(.transport, musical) }
    var mapKey: GenerationKey { GenerationKey(.musicalMap, musical) }

    func ledger() throws -> GenerationLedger {
        try GenerationLedger(primaryClock: primary, musicalClock: musical, nominalRate: 48_000)
    }

    func anchor(_ ledger: GenerationLedger, frame: Int64 = 0, host: UInt64 = 0,
                ticks: Int64? = nil, pass: UInt32 = 0) throws -> ClockAnchor {
        ClockAnchor(sample: .init(clock: primary, generation: try #require(ledger.generation(ledger.primaryClock)),
                                 frame: frame), host: .init(ticks: host),
                    musical: try ticks.map {
                        .init(transport: try #require(ledger.generation(transport)),
                              musicalMap: try #require(ledger.generation(mapKey)), ticks: $0, loopIteration: pass)
                    })
    }

    func map(_ ledger: GenerationLedger, segments: [(Int64, Int64)] = [(0, 500_000)]) throws -> MusicalMap {
        try MusicalMap(clock: musical, revision: #require(ledger.generation(mapKey)),
                       segments: segments.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) })
    }

    func clock(_ ledger: GenerationLedger, frame: Int64 = 0, ticks: Int64 = 0, pass: UInt32 = 0,
               segments: [(Int64, Int64)] = [(0, 500_000)]) throws -> MusicalClockMap {
        try MusicalClockMap(anchor: anchor(ledger, frame: frame, ticks: ticks, pass: pass),
                            map: map(ledger, segments: segments), nominalRate: 48_000,
                            currentSample: #require(ledger.generation(ledger.primaryClock)),
                            currentTransport: #require(ledger.generation(transport)))
    }

    func timeline(_ ledger: GenerationLedger, loop: LoopRange? = nil, running: Bool = true,
                  history: Int = 8, pins: Int = 4, frame: Int64 = 0, ticks: Int64 = 0,
                  segments: [(Int64, Int64)] = [(0, 500_000)]) throws -> MusicalTimeline {
        try MusicalTimeline(
            sample: SampleClockMap(anchor: anchor(ledger, frame: frame), nominalRate: 48_000,
                                   timebase: .init(numer: 125, denom: 3)),
            anchor: anchor(ledger, frame: frame, ticks: ticks), map: map(ledger, segments: segments), loop: loop,
            running: running, historyLimit: history, pinLimit: pins, ledger: ledger
        )
    }

    func observe(_ timeline: inout MusicalTimeline, _ event: MusicalObservation, _ ledger: GenerationLedger,
                 frame: Int64, ticks: Int64? = nil, pass: UInt32 = 0) throws {
        try timeline.observe(event, at: anchor(ledger, frame: frame, host: UInt64(frame) * 500,
                                              ticks: ticks, pass: pass),
                             sequence: timeline.observationSequence + 1, ledger: ledger)
    }
}

extension ControlContractTests {
    struct MusicalTimelineValidation {
        let fixture = MusicalFoundationFixture()

        @Test func explicitBudgetsHaveNoEagerAllocation() throws {
            let ledger = try fixture.ledger()
            #expect(throws: MusicalTimingError.invalidBudget) { try fixture.timeline(ledger, history: 0) }
            #expect(throws: MusicalTimingError.invalidBudget) { try fixture.timeline(ledger, pins: -1) }
            var large = try fixture.timeline(ledger, history: .max, pins: .max)
            #expect(large.historyCount == 1 && large.pinCount == 0)
            let pin = try large.reserve(.absolute(960), origin: large.origin(atFrame: 0))
            #expect(large.pinCount == 1)
            #expect(try large.project(pin).frame == 1_500)
            var zero = try fixture.timeline(ledger, pins: 0)
            #expect(throws: MusicalTimingError.pinCapacity) {
                try zero.reserve(.absolute(0), origin: zero.origin(atFrame: 0))
            }
        }

        @Test func sequenceCoverageAndFailureAtomicity() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1_920))
            let origin = try timeline.origin(atFrame: 0)
            let pin = try timeline.reserve(.absolute(960), origin: origin)
            #expect(throws: MusicalTimingError.observationGap) {
                try timeline.observe(.primary, at: fixture.anchor(ledger, frame: 1_000, host: 500_000),
                                     sequence: 2, ledger: ledger)
            }
            #expect(timeline.observationSequence == 0 && timeline.historyCount == 1 && timeline.pinCount == 1)
            #expect(throws: MusicalTimingError.uncoveredOrigin) { try timeline.origin(atFrame: 1) }
            try fixture.observe(&timeline, .primary, ledger, frame: 1_000)
            #expect(try timeline.origin(at: .init(ticks: 250_000)).frame == 500)
            #expect(throws: MusicalTimingError.missingWrap) {
                try fixture.observe(&timeline, .primary, ledger, frame: 3_001)
            }
            #expect(timeline.observationSequence == 1 && timeline.latestPrimary.sample.frame == 1_000)
            #expect(try timeline.project(pin).frame == 1_500)
            #expect(throws: MusicalTimingError.invalidTransition) {
                try fixture.observe(&timeline, .wrap, ledger, frame: 3_000, ticks: 0, pass: 2)
            }
            try fixture.observe(&timeline, .wrap, ledger, frame: 3_000, ticks: 0, pass: 1)
            #expect(timeline.currentClock.musical.loopIteration == 1)
        }

        @Test func originUsesRecordedStateRatherThanLatestPassSummary() throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger)
            try fixture.observe(&timeline, .musical, ledger, frame: 750, ticks: 480)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 1_000_000)])), ledger, frame: 750)
            try fixture.observe(&timeline, .primary, ledger, frame: 2_250)
            let old = try timeline.origin(at: .init(ticks: 250_000))
            let new = try timeline.origin(atFrame: 1_000)
            #expect(old.clock.anchor.sample.frame == 0 && old.clock.map.revision == .initial)
            #expect(new.clock.anchor.sample.frame == 750)
            #expect(new.clock.map.revision == (try Generation(2)))
            let pin = try timeline.reserve(.grid(960), origin: old)
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 960))
            #expect(try timeline.project(pin).frame == 2_250)
        }

        @Test func evictionPreservesFirstAnchorAndPinnedLatestRunningSummary() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1_920),
                                                 history: 1, pins: 1)
            let old = try timeline.origin(atFrame: 0)
            let pin = try timeline.reserve(.absolute(480), origin: old)
            try fixture.observe(&timeline, .musical, ledger, frame: 1_500, ticks: 960)
            try fixture.observe(&timeline, .wrap, ledger, frame: 3_000, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .primary, ledger, frame: 3_001)
            #expect(timeline.historyCount == 1 && timeline.firstMusicalAnchor.sample.frame == 0)
            #expect(timeline.sample.anchor.sample.frame == 0)
            #expect(throws: MusicalTimingError.uncoveredOrigin) { try timeline.origin(atFrame: 1_500) }
            #expect(throws: MusicalTimingError.expiredOrigin) { try timeline.reserve(.absolute(0), origin: old) }
            #expect(try timeline.project(pin).frame == 750)
            try timeline.release(pin)
            #expect(timeline.isQuiescent && timeline.pinCount == 0)
            #expect(throws: MusicalTimingError.invalidPin) { try timeline.project(pin) }
            #expect(throws: MusicalTimingError.invalidPin) { try timeline.release(pin) }
        }

        @Test func foreignExpiredAndForkedProvenanceCannotReserveOrProject() throws {
            let ledger = try fixture.ledger()
            var first = try fixture.timeline(ledger)
            var other = try fixture.timeline(ledger)
            let origin = try first.origin(atFrame: 0)
            #expect(throws: MusicalTimingError.expiredOrigin) { try other.reserve(.absolute(0), origin: origin) }
            let pin = try first.reserve(.absolute(0), origin: origin)
            #expect(throws: MusicalTimingError.invalidPin) { try other.project(pin) }
            #expect(throws: MusicalTimingError.pinsOutstanding) { try first.rotate() }
            try first.release(pin)
            var copy = first
            let copyPin = try copy.reserve(.absolute(0), origin: origin)
            #expect(try copy.project(copyPin).frame == 0) // Same logical instance snapshot, not another authority.
            #expect(throws: MusicalTimingError.invalidPin) { try first.project(copyPin) }
            try first.rotate()
            #expect(throws: MusicalTimingError.expiredOrigin) { try first.reserve(.absolute(0), origin: origin) }
            #expect(first.firstMusicalAnchor.sample.frame == 0 && first.sample.anchor.sample.frame == 0)
        }

        @Test func currentAndResumeCoordinatesUseCanonicalTolerance() throws {
            let ledger = try fixture.ledger()
            for ((host, frame), accepted): ((UInt64, Int64), Bool) in [
                ((3_000_000, 6_000), true), ((3_000_000, 0), false),
                ((3_000_000, 5_946), true), ((3_000_000, 6_054), true),
                ((3_000_000, 5_945), false), ((3_000_000, 6_055), false),
                ((3_000_250, 6_001), true), ((3_000_250, 5_946), false), ((3_000_250, 6_054), true)
            ] {
                for stopped in [false, true] {
                    var timeline = try fixture.timeline(ledger, running: !stopped)
                    let ticks = try stopped ? 0 : timeline.currentClock.ticks(atFrame: frame)
                    let candidate = try fixture.anchor(ledger, frame: frame, host: host, ticks: ticks)
                    let event: MusicalObservation = stopped ? .running(true) : .musical
                    if accepted {
                        try timeline.observe(event, at: candidate, sequence: 1, ledger: ledger)
                        #expect(timeline.currentClock.anchor == candidate)
                    } else {
                        #expect(throws: MusicalTimingError.invalidContext) {
                            try timeline.observe(event, at: candidate, sequence: 1, ledger: ledger)
                        }
                        #expect(timeline.observationSequence == 0 && timeline.historyCount == 1)
                    }
                }
            }
            var wide = try fixture.timeline(ledger, frame: .min)
            #expect(throws: MusicalTimingError.invalidContext) {
                try wide.observe(.primary, at: fixture.anchor(ledger, frame: 6_000, host: 3_000_000),
                                 sequence: 1, ledger: ledger)
            }
        }

        @Test func stoppedIsExplicitAndHeldOriginDoesNotAdvance() throws {
            let ledger = try fixture.ledger()
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            var timeline = try fixture.timeline(ledger, loop: loop, running: false, history: 2)
            try fixture.observe(&timeline, .primary, ledger, frame: 5_000)
            let pin = try timeline.reserve(.grid(1_440), origin: timeline.origin(atFrame: 5_000))
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 0))
            #expect(throws: MusicalTimingError.stopped) { try timeline.project(pin) }
            #expect(throws: MusicalTimingError.stopped) { try timeline.nextBoundary(at: 5_000, grid: 960) }
            try fixture.observe(&timeline, .running(true), ledger, frame: 6_000, ticks: 0)
            try fixture.observe(&timeline, .wrap, ledger, frame: 9_000, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .primary, ledger, frame: 9_001)
            #expect(try timeline.project(pin).frame == 6_000)
        }

        @Test func restartAndResetAreQuiescentAndProvenanced() throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger)
            let oldOrigin = try timeline.origin(atFrame: 0)
            let pin = try timeline.reserve(.absolute(0), origin: oldOrigin)
            let generation = try ledger.bump(ledger.primaryClock, reason: .wake)
            let baseline = try SampleClockMap(
                anchor: fixture.anchor(ledger, host: 1_000_000), nominalRate: 48_000,
                timebase: .init(numer: 125, denom: 3)
            )
            #expect(throws: MusicalTimingError.invalidContext) {
                try timeline.observe(.primary, at: fixture.anchor(ledger, host: 1_000_000),
                                     sequence: 1, ledger: ledger)
            }
            try ledger.bump(fixture.transport, reason: .clockRestart)
            try ledger.recordClockRestart(.init(start: .init(clock: fixture.primary, generation: generation, frame: 0),
                                                 host: .init(ticks: 1_000_000), previousFrame: 0))
            let newAnchor = try fixture.anchor(ledger, host: 1_000_000, ticks: 0)
            #expect(throws: MusicalTimingError.pinsOutstanding) {
                try timeline.reset(sample: baseline, anchor: newAnchor, map: fixture.map(ledger),
                                   sequence: 1, ledger: ledger)
            }
            try timeline.release(pin)
            try timeline.reset(sample: baseline, anchor: newAnchor, map: fixture.map(ledger),
                               sequence: 1, ledger: ledger)
            #expect(timeline.observationSequence == 1 && timeline.sample == baseline)
            #expect(throws: MusicalTimingError.expiredOrigin) {
                try timeline.reserve(.absolute(0), origin: oldOrigin)
            }
            let fresh = try timeline.reserve(.absolute(0), origin: timeline.origin(atFrame: 0))
            #expect(try timeline.project(fresh).frame == 0)
        }

        @Test func restartPositionUsesMapInForceAtBumpNotMapAtDelayedFrame() throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger)
            try fixture.observe(&timeline, .primary, ledger, frame: 500)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 1_000_000)])), ledger, frame: 750)
            let generation = try ledger.bump(ledger.primaryClock, reason: .wake)
            try ledger.bump(fixture.transport, reason: .clockRestart)
            try ledger.recordClockRestart(.init(start: .init(clock: fixture.primary, generation: generation, frame: 0),
                                                 host: .init(ticks: 1_000_000), previousFrame: 500))
            let baseline = try SampleClockMap(
                anchor: fixture.anchor(ledger, host: 1_000_000), nominalRate: 48_000,
                timebase: .init(numer: 125, denom: 3)
            )
            #expect(throws: MusicalTimingError.invalidContext) {
                try timeline.reset(sample: baseline,
                                   anchor: fixture.anchor(ledger, host: 1_000_000, ticks: 320),
                                   map: fixture.map(ledger, segments: [(0, 1_000_000)]), sequence: 3, ledger: ledger)
            }
            #expect(timeline.observationSequence == 2)
            try timeline.reset(sample: baseline, anchor: fixture.anchor(ledger, host: 1_000_000, ticks: 160),
                               map: fixture.map(ledger, segments: [(0, 1_000_000)]), sequence: 3, ledger: ledger)
            #expect(timeline.currentClock.musical.ticks == 160)
        }

        @Test func locateResetCannotRegressTimeOrReplaceFirstSampleAnchor() throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger)
            try fixture.observe(&timeline, .primary, ledger, frame: 1_000)
            try ledger.bump(fixture.transport, reason: .locate(ticks: 0))
            let original = timeline.sample
            #expect(throws: MusicalTimingError.timeRegressed) {
                try timeline.reset(sample: original, anchor: fixture.anchor(ledger, ticks: 0),
                                   map: fixture.map(ledger), sequence: 2, ledger: ledger)
            }
            let later = try fixture.anchor(ledger, frame: 1_000, host: 500_000, ticks: 0)
            let counterfeit = try SampleClockMap(anchor: later, nominalRate: 48_000, timebase: original.timebase)
            #expect(throws: MusicalTimingError.invalidContext) {
                try timeline.reset(sample: counterfeit, anchor: later, map: fixture.map(ledger),
                                   sequence: 2, ledger: ledger)
            }
            #expect(timeline.observationSequence == 1)
            try timeline.reset(sample: original, anchor: later, map: fixture.map(ledger), sequence: 2, ledger: ledger)
            #expect(timeline.sample.anchor.sample.frame == 0)
            #expect(timeline.firstMusicalAnchor == later)
        }

        @Test func illegalRunMapLoopAndPassTransitionsAreAtomic() throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger)
            #expect(throws: MusicalTimingError.invalidTransition) {
                try fixture.observe(&timeline, .running(true), ledger, frame: 0, ticks: 0)
            }
            #expect(throws: MusicalTimingError.invalidTransition) {
                try fixture.observe(&timeline, .musical, ledger, frame: 0, ticks: 0, pass: 1)
            }
            try fixture.observe(&timeline, .primary, ledger, frame: 2_000)
            #expect(throws: MusicalTimingError.missingWrap) {
                try fixture.observe(&timeline, .loop(LoopRange(startTicks: 0, endTicks: 960)), ledger, frame: 2_000)
            }
            #expect(timeline.currentLoop == nil && timeline.observationSequence == 1)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            #expect(throws: MusicalTimingError.invalidContext) {
                try fixture.observe(&timeline, .primary, ledger, frame: 2_001)
            }
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 1_000_000)])), ledger, frame: 2_000)
            #expect(timeline.currentClock.map.revision == (try Generation(2)))
        }

        @Test func reservationsAndLoopChangesAreTransactional() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, pins: 1)
            let origin = try timeline.origin(atFrame: 0)
            #expect(throws: MusicalTimingError.invalidTarget) { try timeline.reserve(.absolute(-1), origin: origin) }
            #expect(throws: MusicalTimingError.invalidTarget) {
                try timeline.reserve(.grid(960), origin: origin, retroactiveMs: 121)
            }
            #expect(timeline.pinCount == 0)
            let pin = try timeline.reserve(.absolute(960), origin: origin)
            #expect(throws: MusicalTimingError.pinCapacity) { try timeline.reserve(.absolute(0), origin: origin) }
            #expect(throws: MusicalTimingError.outsideLoop) {
                try fixture.observe(&timeline, .loop(LoopRange(startTicks: 0, endTicks: 480)), ledger, frame: 0)
            }
            #expect(timeline.currentLoop == nil && timeline.observationSequence == 0 && timeline.pinCount == 1)
            #expect(try timeline.project(pin).frame == 1_500)
            try timeline.release(pin)
            try fixture.observe(&timeline, .loop(LoopRange(startTicks: 0, endTicks: 480)), ledger, frame: 0)
            #expect(timeline.currentLoop?.endTicks == 480)
        }

        @Test func missingContextAndRestartCoverageNeverBecomeStoppedDefaults() throws {
            var ledger = try fixture.ledger()
            let baseline = try fixture.timeline(ledger).sample
            #expect(throws: MusicalTimingError.invalidContext) {
                try MusicalTimeline(sample: baseline, anchor: fixture.anchor(ledger), map: fixture.map(ledger),
                                    running: false, historyLimit: 2, pinLimit: 1, ledger: ledger)
            }
            var timeline = try fixture.timeline(ledger, history: 1)
            try fixture.observe(&timeline, .primary, ledger, frame: 1_000)
            let generation = try ledger.bump(ledger.primaryClock, reason: .wake)
            #expect(throws: MusicalTimingError.invalidContext) {
                try fixture.timeline(ledger)
            }
            try ledger.bump(fixture.transport, reason: .clockRestart)
            try ledger.recordClockRestart(.init(start: .init(clock: fixture.primary, generation: generation, frame: 0),
                                                 host: .init(ticks: 1_000_000), previousFrame: 0))
            let sample = try SampleClockMap(anchor: fixture.anchor(ledger, host: 1_000_000), nominalRate: 48_000,
                                            timebase: baseline.timebase)
            #expect(throws: MusicalTimingError.uncoveredOrigin) {
                try timeline.reset(sample: sample, anchor: fixture.anchor(ledger, host: 1_000_000, ticks: 0),
                                   map: fixture.map(ledger), sequence: 2, ledger: ledger)
            }
            #expect(timeline.observationSequence == 1 && timeline.sample == baseline)
            #expect(throws: MusicalTimingError.historyUnavailable) { try fixture.timeline(ledger) }
        }

        @Test func zeroPeriodRefusalsLeaveObservationAndPinStateUsable() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 1),
                                                 segments: [(0, 60_000)])
            let pin = try timeline.reserve(.absolute(0), origin: timeline.origin(atFrame: 0))
            #expect(throws: MusicalTimingError.nonAdvancingLoop) { try timeline.nextBoundary(at: 1, grid: 1) }
            #expect(throws: MusicalTimingError.missingWrap) {
                try fixture.observe(&timeline, .primary, ledger, frame: 1)
            }
            #expect(timeline.observationSequence == 0 && timeline.historyCount == 1 && timeline.pinCount == 1)
            #expect(try timeline.project(pin).frame == 0)
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 0, pass: 1)
            #expect(timeline.observationSequence == 1 && timeline.currentClock.musical.loopIteration == 1)
            #expect(try timeline.project(pin).frame == 0)
            try timeline.release(pin)
            #expect(timeline.isQuiescent)
        }
    }
}
