import Foundation
import Testing
@testable import FluxKlang

extension ControlContractTests {
    struct MusicalLoopTransitionValidation {
        let fixture = MusicalFoundationFixture()

        @Test(arguments: [(Int64(0), Int64(1)), (100, 101)])
        func anObservedZeroPeriodWrapCanBeStopped(_ range: (Int64, Int64)) throws {
            let ledger = try fixture.ledger()
            let loop = try LoopRange(startTicks: range.0, endTicks: range.1)
            var timeline = try fixture.timeline(ledger, loop: loop, segments: [(0, 60_000)])
            let stored = try timeline.reserve(.absolute(loop.endTicks), origin: timeline.origin(atFrame: 0))
            let frame = try MusicalTiming.narrow(MusicalTiming.wrapFrame(timeline.currentClock, loop: loop))
            try fixture.observe(&timeline, .wrap, ledger, frame: frame, ticks: loop.startTicks, pass: 1)
            #expect(throws: Never.self) {
                try fixture.observe(&timeline, .running(false), ledger, frame: frame, ticks: loop.startTicks, pass: 1)
            }
            #expect(!timeline.isRunning && timeline.observationSequence == 2)
            #expect(timeline.currentClock.musical.loopIteration == 1 && timeline.latestPrimary.sample.frame == frame)
            #expect(throws: MusicalTimingError.stopped) { try timeline.project(stored) }
            try fixture.observe(&timeline, .primary, ledger, frame: frame + 1)
            #expect(timeline.currentClock.anchor.sample.frame == frame && timeline.pinCount == 1)
        }

        @Test(arguments: [(Int64(0), Int64(1)), (100, 101)])
        func anObservedZeroPeriodWrapCanRemoveItsLoop(_ range: (Int64, Int64)) throws {
            let ledger = try fixture.ledger()
            let loop = try LoopRange(startTicks: range.0, endTicks: range.1)
            var timeline = try fixture.timeline(ledger, loop: loop, segments: [(0, 60_000)])
            let frame = try MusicalTiming.narrow(MusicalTiming.wrapFrame(timeline.currentClock, loop: loop))
            try fixture.observe(&timeline, .wrap, ledger, frame: frame, ticks: loop.startTicks, pass: 1)
            #expect(throws: Never.self) { try fixture.observe(&timeline, .loop(nil), ledger, frame: frame) }
            #expect(timeline.currentLoop == nil && timeline.observationSequence == 2)
            #expect(timeline.isRunning && timeline.currentClock.musical.loopIteration == 1)
            try fixture.observe(&timeline, .primary, ledger, frame: frame + 1)
            #expect(timeline.latestPrimary.sample.frame == frame + 1)
        }

        @Test(arguments: [(Int64(0), Int64(2)), (1, 2), (0, 8)])
        func anObservedZeroPeriodWrapCanChangeItsLoop(_ range: (Int64, Int64)) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 1),
                                                 segments: [(0, 60_000)])
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 0, pass: 1)
            let clock = timeline.currentClock
            let replacement = try LoopRange(startTicks: range.0, endTicks: range.1)
            try fixture.observe(&timeline, .loop(replacement), ledger, frame: 0)
            #expect(timeline.currentLoop == replacement && timeline.currentClock == clock)
            if range.1 == 8 {
                try fixture.observe(&timeline, .primary, ledger, frame: 1)
                #expect(throws: MusicalTimingError.missingWrap) {
                    try fixture.observe(&timeline, .primary, ledger, frame: 2)
                }
                try fixture.observe(&timeline, .wrap, ledger, frame: 2, ticks: 0, pass: 2)
            } else {
                #expect(throws: MusicalTimingError.missingWrap) {
                    try fixture.observe(&timeline, .primary, ledger, frame: 1)
                }
                try fixture.observe(&timeline, .loop(nil), ledger, frame: 0)
                try fixture.observe(&timeline, .primary, ledger, frame: 1)
            }
            #expect(timeline.observationSequence == 4)
        }

        @Test func zeroPeriodCorrectionsCannotHideUnobservedFramesOrWraps() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 1),
                                                 segments: [(0, 60_000)])
            #expect(throws: MusicalTimingError.missingWrap) {
                try fixture.observe(&timeline, .running(false), ledger, frame: 0, ticks: 0)
            }
            #expect(throws: MusicalTimingError.missingWrap) {
                try fixture.observe(&timeline, .loop(nil), ledger, frame: 0)
            }
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 0, pass: 1)
            let clock = timeline.currentClock
            let primary = timeline.latestPrimary
            let replacement = try LoopRange(startTicks: 0, endTicks: 8)
            for (event, ticks): (MusicalObservation, Int64?) in [
                (.primary, nil), (.running(false), 5), (.loop(nil), nil), (.loop(replacement), nil)
            ] {
                #expect(throws: MusicalTimingError.missingWrap) {
                    try fixture.observe(&timeline, event, ledger, frame: 1, ticks: ticks, pass: 1)
                }
                #expect(timeline.currentClock == clock && timeline.latestPrimary == primary)
                #expect(timeline.observationSequence == 1 && timeline.historyCount == 2)
            }
        }

        @Test func zeroPeriodLoopRemovalStillRefreshesStoredPinsAtomically() throws {
            let ledger = try fixture.ledger()
            let loop = try LoopRange(startTicks: 0, endTicks: 1)
            var timeline = try fixture.timeline(ledger, loop: loop, history: 1, segments: [(0, 60_000)])
            let stored = try timeline.reserve(.absolute(1), origin: timeline.origin(atFrame: 0))
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 0, pass: 1)
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try fixture.observe(&timeline, .loop(nil), ledger, frame: 0)
            }
            #expect(timeline.currentLoop == loop && timeline.observationSequence == 1 && timeline.pinCount == 1)
            #expect(try timeline.project(stored).frame == 0 && !timeline.project(stored).assumesFuture)
            try timeline.release(stored)
            try fixture.observe(&timeline, .loop(nil), ledger, frame: 0)
            #expect(timeline.currentLoop == nil && timeline.isQuiescent && timeline.observationSequence == 2)
        }

        @Test func anEndTickResumeAllowsTheImmediatelyDueWrap() throws {
            let ledger = try fixture.ledger()
            let loop = try LoopRange(startTicks: 0, endTicks: 3)
            var timeline = try fixture.timeline(ledger, loop: loop, history: 1, pins: 1)
            let stored = try timeline.reserve(.absolute(3), origin: timeline.origin(atFrame: 0))
            try fixture.observe(&timeline, .running(false), ledger, frame: 4, ticks: 3)
            let held = timeline.currentClock
            #expect(throws: MusicalTimingError.invalidTransition) {
                try fixture.observe(&timeline, .wrap, ledger, frame: 4, ticks: 0, pass: 1)
            }
            #expect(timeline.currentClock == held && !timeline.isRunning && timeline.observationSequence == 1)
            try fixture.observe(&timeline, .running(true), ledger, frame: 6, ticks: 3)
            #expect(timeline.isRunning && timeline.currentClock.musical.loopIteration == 0)
            #expect(timeline.currentClock.musical.ticks == 3 && timeline.currentClock.anchor.sample.frame == 6)
            #expect(stored.occurrence == MusicalOccurrence(pass: 0, ticks: 3))
            #expect(try timeline.project(stored).frame == 6 && timeline.project(stored).assumesFuture)
            let clock = timeline.currentClock
            let primary = timeline.latestPrimary
            #expect(throws: MusicalTimingError.missingWrap) {
                try fixture.observe(&timeline, .musical, ledger, frame: 6, ticks: 3)
            }
            for (event, ticks): (MusicalObservation, Int64?) in [
                (.primary, nil), (.running(false), 4), (.loop(nil), nil)
            ] {
                #expect(throws: MusicalTimingError.missingWrap) {
                    try fixture.observe(&timeline, event, ledger, frame: 7, ticks: ticks)
                }
                #expect(timeline.currentClock == clock && timeline.latestPrimary == primary && timeline.isRunning)
                #expect(timeline.observationSequence == 2 && timeline.historyCount == 1 && timeline.pinCount == 1)
                #expect(timeline.currentLoop == loop && stored.occurrence == MusicalOccurrence(pass: 0, ticks: 3))
                #expect(try timeline.project(stored).frame == 6 && timeline.project(stored).assumesFuture)
            }
            try fixture.observe(&timeline, .wrap, ledger, frame: 6, ticks: 0, pass: 1)
            #expect(try timeline.project(stored).frame == 6 && !timeline.project(stored).assumesFuture)
            try fixture.observe(&timeline, .primary, ledger, frame: 7)
            #expect(timeline.observationSequence == 4 && timeline.currentClock.musical.loopIteration == 1)
        }

        @Test(arguments: [false, true], [Int64(0), 2])
        func stoppedZeroPeriodLoopsCanResumeBeforeWrapping(_ wrapped: Bool, _ frame: Int64) throws {
            let ledger = try fixture.ledger()
            let loop = try LoopRange(startTicks: 0, endTicks: 1)
            var timeline = try fixture.timeline(ledger, loop: loop, running: wrapped, history: 1, pins: 1,
                                                 segments: [(0, 60_000)])
            let pass: UInt32 = wrapped ? 1 : 0
            if wrapped {
                try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 0, pass: pass)
                try fixture.observe(&timeline, .running(false), ledger, frame: 0, ticks: 0, pass: pass)
            }
            let stored = try timeline.reserve(.absolute(1), origin: timeline.origin(atFrame: 0))
            let sequence = timeline.observationSequence
            #expect(throws: MusicalTimingError.invalidTransition) {
                try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 0, pass: pass + 1)
            }
            try fixture.observe(&timeline, .running(true), ledger, frame: frame, ticks: 0, pass: pass)
            #expect(timeline.isRunning && timeline.currentClock.musical.loopIteration == pass)
            #expect(timeline.currentClock.musical.ticks == 0 && timeline.currentClock.anchor.sample.frame == frame)
            #expect(stored.occurrence == MusicalOccurrence(pass: Int128(pass), ticks: 1))
            #expect(try timeline.project(stored).frame == frame && timeline.project(stored).assumesFuture)
            let clock = timeline.currentClock
            let primary = timeline.latestPrimary
            // Reflect the whole value, including private provenance, record IDs, epochs and reservations.
            let before = String(reflecting: timeline)
            let replacement = try LoopRange(startTicks: 0, endTicks: 8)
            for (event, ticks): (MusicalObservation, Int64?) in [
                (.running(false), 0), (.loop(nil), nil), (.loop(replacement), nil)
            ] {
                var rejected = timeline
                #expect(throws: MusicalTimingError.missingWrap) {
                    try fixture.observe(&rejected, event, ledger, frame: frame, ticks: ticks, pass: pass)
                }
                #expect(String(reflecting: rejected) == before)
                #expect(throws: MusicalTimingError.missingWrap) {
                    try fixture.observe(&rejected, .primary, ledger, frame: frame + 1)
                }
                #expect(String(reflecting: rejected) == before)
            }
            for (event, ticks): (MusicalObservation, Int64?) in [
                (.primary, nil), (.running(false), 5), (.loop(nil), nil)
            ] {
                #expect(throws: MusicalTimingError.missingWrap) {
                    try fixture.observe(&timeline, event, ledger, frame: frame + 1, ticks: ticks, pass: pass)
                }
                #expect(String(reflecting: timeline) == before)
                #expect(timeline.currentClock == clock && timeline.latestPrimary == primary && timeline.isRunning)
                #expect(timeline.observationSequence == sequence + 1 && timeline.historyCount == 1)
                #expect(timeline.pinCount == 1 && timeline.currentLoop == loop)
                #expect(try timeline.project(stored).frame == frame && timeline.project(stored).assumesFuture)
            }
            try fixture.observe(&timeline, .wrap, ledger, frame: frame, ticks: 0, pass: pass + 1)
            #expect(try timeline.project(stored).frame == frame && !timeline.project(stored).assumesFuture)
            try timeline.release(stored)
            try fixture.observe(&timeline, .running(false), ledger, frame: frame, ticks: 0, pass: pass + 1)
            try fixture.observe(&timeline, .loop(nil), ledger, frame: frame)
            try fixture.observe(&timeline, .primary, ledger, frame: frame + 1)
            #expect(!timeline.isRunning && timeline.currentLoop == nil && timeline.observationSequence == sequence + 5)
        }

        @Test func aNonBoundaryResumeKeepsItsLaterWrap() throws {
            let ledger = try fixture.ledger()
            let loop = try LoopRange(startTicks: 0, endTicks: 3)
            var timeline = try fixture.timeline(ledger, loop: loop, history: 1, pins: 1)
            let stored = try timeline.reserve(.absolute(3), origin: timeline.origin(atFrame: 0))
            try fixture.observe(&timeline, .running(false), ledger, frame: 4, ticks: 2)
            try fixture.observe(&timeline, .running(true), ledger, frame: 6, ticks: 2)
            #expect(timeline.isRunning && timeline.currentClock.musical.loopIteration == 0)
            #expect(try timeline.project(stored).frame == 8 && timeline.project(stored).assumesFuture)
            try fixture.observe(&timeline, .primary, ledger, frame: 7)
            let clock = timeline.currentClock
            let primary = timeline.latestPrimary
            for frame: Int64 in [8, 9] {
                #expect(throws: MusicalTimingError.missingWrap) {
                    try fixture.observe(&timeline, .primary, ledger, frame: frame)
                }
                #expect(timeline.currentClock == clock && timeline.latestPrimary == primary)
                #expect(timeline.observationSequence == 3 && timeline.historyCount == 1 && timeline.pinCount == 1)
                #expect(try timeline.project(stored).frame == 8 && timeline.project(stored).assumesFuture)
            }
            try fixture.observe(&timeline, .wrap, ledger, frame: 8, ticks: 0, pass: 1)
            #expect(stored.occurrence == MusicalOccurrence(pass: 0, ticks: 3))
            #expect(try timeline.project(stored).frame == 8 && !timeline.project(stored).assumesFuture)
            try fixture.observe(&timeline, .primary, ledger, frame: 9)
            #expect(timeline.observationSequence == 5 && timeline.currentClock.musical.loopIteration == 1)
        }

        @Test func onlyAResumeCanMakeAnUnobservedWrapImmediatelyDue() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 3), history: 1, pins: 1)
            let stored = try timeline.reserve(.absolute(3), origin: timeline.origin(atFrame: 0))
            let clock = timeline.currentClock
            let primary = timeline.latestPrimary
            #expect(throws: MusicalTimingError.missingWrap) {
                try fixture.observe(&timeline, .musical, ledger, frame: 4, ticks: 3)
            }
            #expect(timeline.currentClock == clock && timeline.latestPrimary == primary && timeline.isRunning)
            #expect(timeline.observationSequence == 0 && timeline.historyCount == 1 && timeline.pinCount == 1)
            #expect(stored.occurrence == MusicalOccurrence(pass: 0, ticks: 3))
            #expect(try timeline.project(stored).frame == 5 && timeline.project(stored).assumesFuture)
        }
    }
}
