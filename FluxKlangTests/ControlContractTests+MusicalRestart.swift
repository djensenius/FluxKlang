import Foundation
import Testing
@testable import FluxKlang

extension ControlContractTests.MusicalTimelineValidation {
    @Test(arguments: [Int64(4), 5, 6])
    func restartSelectsThePassBeforeRoundingTicks(_ previousFrame: Int64) throws {
        var ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 3))
        try fixture.observe(&timeline, .primary, ledger, frame: 4)
        try fixture.observe(&timeline, .wrap, ledger, frame: 5, ticks: 0, pass: 1)
        try fixture.observe(&timeline, .primary, ledger, frame: 6)
        let generation = try ledger.bump(ledger.primaryClock, reason: .wake)
        try ledger.bump(fixture.transport, reason: .clockRestart)
        try ledger.recordClockRestart(.init(start: .init(clock: fixture.primary, generation: generation, frame: 0),
                                             host: .init(ticks: 1_000_000), previousFrame: previousFrame))
        let sample = try SampleClockMap(anchor: fixture.anchor(ledger, host: 1_000_000), nominalRate: 48_000,
                                        timebase: timeline.sample.timebase)
        let ticks: Int64 = previousFrame == 4 ? 3 : previousFrame == 5 ? 0 : 1
        var rejected = timeline
        #expect(throws: MusicalTimingError.invalidContext) {
            try rejected.reset(sample: sample,
                               anchor: fixture.anchor(ledger, host: 1_000_000, ticks: previousFrame == 4 ? 0 : 3),
                               map: fixture.map(ledger), sequence: 4, ledger: ledger)
        }
        #expect(rejected.observationSequence == 3 && rejected.historyCount == 4)
        #expect(rejected.sample == timeline.sample && rejected.currentClock == timeline.currentClock)
        try timeline.reset(sample: sample, anchor: fixture.anchor(ledger, host: 1_000_000, ticks: ticks),
                           map: fixture.map(ledger), sequence: 4, ledger: ledger)
        #expect(timeline.currentClock.musical.ticks == ticks)
        #expect(timeline.currentClock.musical.loopIteration == 0 && timeline.historyCount == 1)
    }

    @Test(arguments: [Int64(1), 2, 3, 4])
    func restartPositionUsesRoundedPassesUnderTheOldMapSnapshot(_ previousFrame: Int64) throws {
        var ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger, loop: LoopRange(startTicks: 0, endTicks: 3))
        try fixture.observe(&timeline, .wrap, ledger, frame: 5, ticks: 0, pass: 1)
        try fixture.observe(&timeline, .wrap, ledger, frame: 10, ticks: 0, pass: 2)
        try ledger.bump(fixture.mapKey, reason: .tempoEdit)
        let map = try fixture.map(ledger, segments: [(0, 200_000)])
        try fixture.observe(&timeline, .map(map), ledger, frame: 10)
        let generation = try ledger.bump(ledger.primaryClock, reason: .wake)
        try ledger.bump(fixture.transport, reason: .clockRestart)
        try ledger.recordClockRestart(.init(start: .init(clock: fixture.primary, generation: generation, frame: 0),
                                             host: .init(ticks: 1_000_000), previousFrame: previousFrame))
        let sample = try SampleClockMap(anchor: fixture.anchor(ledger, host: 1_000_000), nominalRate: 48_000,
                                        timebase: timeline.sample.timebase)
        let ticks: Int64 = previousFrame % 2 == 0 ? 0 : 2
        try timeline.reset(sample: sample, anchor: fixture.anchor(ledger, host: 1_000_000, ticks: ticks),
                           map: map, sequence: 4, ledger: ledger)
        #expect(timeline.currentClock.musical.ticks == ticks && timeline.currentClock.map == map)
    }

    @Test func newerPhysicalPrimaryChangesConversionButNotMusicalCoverage() throws {
        let ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger, history: 2)
        try fixture.observe(&timeline, .musical, ledger, frame: 60, ticks: 38)
        try timeline.observe(.primary, at: fixture.anchor(ledger, frame: 100, host: 40_000),
                             sequence: 2, ledger: ledger)
        let latest = try fixture.anchor(ledger, frame: 120, host: 45_000)
        let origin = try timeline.origin(at: .init(ticks: 35_000), latestPrimary: latest)
        #expect(origin.exactFrame == MusicalFrame(100))
        #expect(try timeline.origin(at: .init(ticks: 35_000)).exactFrame == MusicalFrame(90))
        #expect(origin.clock.anchor.sample.frame == 60)
        let pin = try timeline.reserve(.grid(32), origin: origin)
        #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 64))
        #expect(try timeline.project(pin).frame == 101)
        // First case is frame-covered but host-uncovered; second is the reverse.
        for host: UInt64 in [29_000, 40_001, 45_001] {
            #expect(throws: MusicalTimingError.uncoveredOrigin) {
                try timeline.origin(at: .init(ticks: host), latestPrimary: latest)
            }
        }
        #expect(timeline.latestPrimary.sample.frame == 100 && timeline.latestPrimary.host.ticks == 40_000)
        #expect(timeline.observationSequence == 2 && timeline.historyCount == 2)
        #expect(timeline.sample.anchor.sample.frame == 0 && timeline.firstMusicalAnchor.sample.frame == 0)
    }

    @Test func suppliedPrimaryMustAgreeWithTheGenerationBaselineAndCannotRegress() throws {
        let ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger)
        try timeline.observe(.primary, at: fixture.anchor(ledger, frame: 100, host: 40_000),
                             sequence: 1, ledger: ledger)
        for ((frame, host), error): ((Int64, UInt64), MusicalTimingError) in [
            ((99, 41_000), .timeRegressed), ((101, 39_000), .timeRegressed), ((175, 60_000), .invalidContext)
        ] {
            let anchor = try fixture.anchor(ledger, frame: frame, host: host)
            #expect(throws: error) { try timeline.origin(at: .init(ticks: 25_000), latestPrimary: anchor) }
        }
        for (clock, generation) in [(ClockID(validated: "sample.foreign"), Generation.initial),
                                    (fixture.primary, try Generation(2))] {
            let anchor = ClockAnchor(sample: .init(clock: clock, generation: generation, frame: 120),
                                     host: .init(ticks: 45_000))
            #expect(throws: MusicalTimingError.invalidContext) {
                try timeline.origin(at: .init(ticks: 25_000), latestPrimary: anchor)
            }
        }
        let physical = try fixture.anchor(ledger, frame: 140, host: 50_000, ticks: 999, pass: 99)
        let origin = try timeline.origin(at: .init(ticks: 25_000), latestPrimary: physical)
        #expect(origin.exactFrame == MusicalFrame(90))
        #expect(origin.clock == timeline.currentClock) // Optional physical payload never becomes musical history.
        #expect(timeline.observationSequence == 1 && timeline.historyCount == 2 && timeline.isQuiescent)
    }
}
