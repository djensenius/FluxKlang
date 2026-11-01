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
    }
}
