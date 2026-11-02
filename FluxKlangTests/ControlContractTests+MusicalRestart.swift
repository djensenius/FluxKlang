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

    @Test(arguments: [false, true])
    func restartUsesTheLoopInForceAtRestart(_ removeLoop: Bool) throws {
        var ledger = try fixture.ledger()
        let loop = try LoopRange(startTicks: 0, endTicks: 3)
        var timeline = try fixture.timeline(ledger, loop: loop)
        try fixture.observe(&timeline, .primary, ledger, frame: 4)
        try fixture.observe(&timeline, .wrap, ledger, frame: 5, ticks: 0, pass: 1)
        try fixture.observe(&timeline, .wrap, ledger, frame: 10, ticks: 0, pass: 2)
        if removeLoop { try fixture.observe(&timeline, .loop(nil), ledger, frame: 10) }
        try ledger.bump(fixture.mapKey, reason: .tempoEdit)
        let map = try fixture.map(ledger, segments: [(0, 200_000)])
        try fixture.observe(&timeline, .map(map), ledger, frame: 10)
        let sequence = timeline.observationSequence + 1
        let generation = try ledger.bump(ledger.primaryClock, reason: .wake)
        try ledger.bump(fixture.transport, reason: .clockRestart)
        try ledger.recordClockRestart(.init(start: .init(clock: fixture.primary, generation: generation, frame: 0),
                                             host: .init(ticks: 1_000_000), previousFrame: 4))
        let sample = try SampleClockMap(anchor: fixture.anchor(ledger, host: 1_000_000), nominalRate: 48_000,
                                        timebase: timeline.sample.timebase)
        var rejected = timeline
        #expect(throws: MusicalTimingError.invalidContext) {
            try rejected.reset(sample: sample,
                               anchor: fixture.anchor(ledger, host: 1_000_000, ticks: removeLoop ? 0 : 6),
                               map: map, sequence: sequence, ledger: ledger)
        }
        #expect(rejected.observationSequence == timeline.observationSequence)
        #expect(rejected.currentClock == timeline.currentClock && rejected.historyCount == timeline.historyCount)
        try timeline.reset(sample: sample,
                           anchor: fixture.anchor(ledger, host: 1_000_000, ticks: removeLoop ? 6 : 0),
                           map: map, sequence: sequence, ledger: ledger)
        #expect(timeline.currentClock.musical.ticks == (removeLoop ? 6 : 0))
        #expect(timeline.currentLoop == (removeLoop ? nil : loop))
    }

    @Test(arguments: [HostTimebase(numer: 250, denom: 3), .init(numer: 125, denom: 6)],
          [GenerationBumpReason.wake, .rateChange(nominalRate: 96_000)])
    func restartCannotChangeTheProcessHostTimebase(_ timebase: HostTimebase, _ reason: GenerationBumpReason) throws {
        var ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger)
        let oldOrigin = try timeline.origin(atFrame: 0)
        var scheduler = try SchedulerClock(ledger: ledger, timebase: timeline.sample.timebase)
        let point = try restartAtZero(&ledger, reason: reason)
        let anchor = try fixture.anchor(ledger, host: point.host.ticks, ticks: 0)
        let changed = try SampleClockMap(anchor: point, nominalRate: ledger.nominalRate, timebase: timebase)
        let valid = try SampleClockMap(anchor: point, nominalRate: ledger.nominalRate,
                                      timebase: timeline.sample.timebase)
        let expected = Int64(ledger.nominalRate / 960)
        let host = HostStamp(ticks: point.host.ticks + 25_000)
        #expect(try valid.frame(atHost: host, current: point.sample.generation) == expected)
        #expect(try changed.frame(atHost: host, current: point.sample.generation)
                == (timebase.numer == 250 ? 2 * expected : expected / 2))
        var rejected = timeline
        let before = String(reflecting: rejected)
        #expect(throws: MusicalTimingError.invalidContext) {
            try rejected.reset(sample: changed, anchor: anchor, map: fixture.map(ledger), sequence: 1, ledger: ledger)
        }
        #expect(String(reflecting: rejected) == before)
        #expect(throws: Never.self) { _ = try rejected.reserve(.absolute(0), origin: oldOrigin) }
        let priorScheduler = scheduler
        #expect(throws: SchedulerClockError.declarationChanged) {
            try scheduler.observe(anchor, nominalRate: ledger.nominalRate, timebase: timebase, ledger: ledger)
        }
        #expect(scheduler == priorScheduler)
        try timeline.reset(sample: valid, anchor: anchor, map: fixture.map(ledger), sequence: 1, ledger: ledger)
        try timeline.observe(.primary, at: fixture.anchor(ledger, frame: expected, host: host.ticks),
                             sequence: 2, ledger: ledger)
        #expect(try timeline.origin(at: host).exactFrame == MusicalFrame(expected))
    }

    @Test(arguments: [Int64(49), 96])
    func restartValidatesTheActualAnchorAgainstOneAllowance(_ frame: Int64) throws {
        var ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger)
        let oldOrigin = try timeline.origin(atFrame: 0)
        var scheduler = try SchedulerClock(ledger: ledger, timebase: timeline.sample.timebase)
        let point = try restartAtZero(&ledger)
        let sample = try SampleClockMap(anchor: fixture.anchor(ledger, frame: 48, host: point.host.ticks),
                                       nominalRate: 48_000, timebase: timeline.sample.timebase)
        let anchor = try fixture.anchor(ledger, frame: frame, host: point.host.ticks, ticks: 0)
        #expect(ledger.acceptsFirstAnchor(sample.anchor, nominalRate: 48_000, timebase: sample.timebase))
        #expect(sample.agrees(anchor))
        #expect(!ledger.acceptsFirstAnchor(anchor, nominalRate: 48_000, timebase: sample.timebase))
        let before = String(reflecting: timeline)
        #expect(throws: MusicalTimingError.invalidContext) {
            try timeline.reset(sample: sample, anchor: anchor, map: fixture.map(ledger), sequence: 1, ledger: ledger)
        }
        #expect(String(reflecting: timeline) == before)
        #expect(throws: Never.self) { _ = try timeline.reserve(.absolute(0), origin: oldOrigin) }
        let priorScheduler = scheduler
        #expect(throws: SchedulerClockError.invalidAnchor) {
            try scheduler.observe(anchor, nominalRate: 48_000, timebase: sample.timebase, ledger: ledger)
        }
        #expect(scheduler == priorScheduler)
    }

    @Test(arguments: [Int64(0), 24, 48])
    func restartPreservesTheRecordBaselineAndFrozenOldEpoch(_ baselineFrame: Int64) throws {
        var ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger)
        let oldOrigin = try timeline.origin(atFrame: 0)
        let oldPin = try timeline.reserve(.absolute(960), origin: oldOrigin)
        let frozen = timeline
        try timeline.release(oldPin)
        var scheduler = try SchedulerClock(ledger: ledger, timebase: timeline.sample.timebase)
        let point = try restartAtZero(&ledger)
        let supplied = try SampleClockMap(
            anchor: fixture.anchor(ledger, frame: baselineFrame, host: point.host.ticks),
            nominalRate: 48_000, timebase: timeline.sample.timebase)
        let anchor = try fixture.anchor(ledger, frame: 48, host: point.host.ticks, ticks: 0)
        try timeline.reset(sample: supplied, anchor: anchor, map: fixture.map(ledger), sequence: 1, ledger: ledger)
        try scheduler.observe(anchor, nominalRate: 48_000, timebase: supplied.timebase, ledger: ledger)
        #expect(try timeline.sample == scheduler.snapshot(ledger: ledger).baseline)
        #expect(timeline.sample.anchor == point && timeline.firstMusicalAnchor == anchor)
        #expect(timeline.currentClock.anchor == anchor && timeline.latestPrimary == anchor)
        #expect(throws: MusicalTimingError.uncoveredOrigin) { try timeline.origin(atFrame: 0) }
        #expect(try timeline.origin(at: point.host).exactFrame == MusicalFrame(48))
        #expect(throws: MusicalTimingError.expiredOrigin) { try timeline.reserve(.absolute(0), origin: oldOrigin) }
        #expect(try frozen.project(oldPin).frame == 1_500)
        #expect(frozen.sample.anchor.sample.generation == .initial && frozen.observationSequence == 0)
        #expect(try frozen.origin(atFrame: 0).clock == oldOrigin.clock)
        let valid = try fixture.anchor(ledger, frame: 49, host: point.host.ticks + 500)
        try timeline.observe(.primary, at: valid, sequence: 2, ledger: ledger)
        try scheduler.observe(valid, nominalRate: 48_000, timebase: supplied.timebase, ledger: ledger)
        #expect(try timeline.sample == scheduler.snapshot(ledger: ledger).baseline)
        let pin = try timeline.reserve(.absolute(0), origin: timeline.origin(atFrame: 48))
        #expect(try timeline.project(pin).frame == 48)
    }

    @Test(arguments: [Int64(50), 97])
    func restartCannotShiftTheSubsequentDriftAllowance(_ frame: Int64) throws {
        var ledger = try fixture.ledger()
        var timeline = try fixture.timeline(ledger)
        var scheduler = try SchedulerClock(ledger: ledger, timebase: timeline.sample.timebase)
        let point = try restartAtZero(&ledger)
        let anchor = try fixture.anchor(ledger, frame: 48, host: point.host.ticks, ticks: 0)
        let supplied = try SampleClockMap(anchor: anchor, nominalRate: 48_000, timebase: timeline.sample.timebase)
        try timeline.reset(sample: supplied, anchor: anchor, map: fixture.map(ledger), sequence: 1, ledger: ledger)
        try scheduler.observe(anchor, nominalRate: 48_000, timebase: supplied.timebase, ledger: ledger)
        let drifting = try fixture.anchor(ledger, frame: frame, host: point.host.ticks + 500)
        #expect(supplied.agrees(drifting))
        #expect(!ledger.acceptsFirstAnchor(drifting, nominalRate: 48_000, timebase: supplied.timebase))
        let before = String(reflecting: timeline)
        #expect(throws: MusicalTimingError.invalidContext) {
            try timeline.observe(.primary, at: drifting, sequence: 2, ledger: ledger)
        }
        #expect(String(reflecting: timeline) == before)
        let priorScheduler = scheduler
        #expect(throws: SchedulerClockError.invalidAnchor) {
            try scheduler.observe(drifting, nominalRate: 48_000, timebase: supplied.timebase, ledger: ledger)
        }
        #expect(scheduler == priorScheduler)
    }

    @Test func locateInitializationSharesTheRestartAnchorAndBaselineChecks() throws {
        var ledger = try fixture.ledger()
        let point = try restartAtZero(&ledger)
        try ledger.bump(fixture.transport, reason: .locate(ticks: 0))
        let sample = try SampleClockMap(anchor: fixture.anchor(ledger, frame: 48, host: point.host.ticks),
                                       nominalRate: 48_000, timebase: .init(numer: 125, denom: 3))
        let invalid = try fixture.anchor(ledger, frame: 96, host: point.host.ticks, ticks: 0)
        #expect(throws: MusicalTimingError.invalidContext) {
            _ = try MusicalTimeline(sample: sample, anchor: invalid, map: fixture.map(ledger),
                                    running: true, historyLimit: 8, pinLimit: 4, ledger: ledger)
        }
        let anchor = try fixture.anchor(ledger, frame: 48, host: point.host.ticks, ticks: 0)
        let valid = try MusicalTimeline(sample: sample, anchor: anchor, map: fixture.map(ledger),
                                        running: true, historyLimit: 8, pinLimit: 4, ledger: ledger)
        #expect(valid.sample.anchor == point && valid.currentClock.anchor == anchor)
    }

    private func restartAtZero(_ ledger: inout GenerationLedger, reason: GenerationBumpReason = .wake)
        throws -> ClockAnchor {
        try ledger.bump(ledger.primaryClock, reason: reason)
        try ledger.bump(fixture.transport, reason: .clockRestart)
        let point = try fixture.anchor(ledger, host: 1_000_000)
        try ledger.recordClockRestart(.init(start: point.sample, host: point.host, previousFrame: 0))
        return point
    }
}
