import Foundation
import Testing
@testable import FluxKlang

extension ControlContractTests {
    struct MusicalRetentionValidation {
        let fixture = MusicalFoundationFixture()

        @Test(arguments: [false, true])
        func discardedLeadingPassesCannotChooseAFartherPredecessor(_ retainEndPin: Bool) throws {
            var (complete, _) = try distantHistory(limit: 15, retainEndPin: retainEndPin)
            let closest = try complete.reserve(.grid(4), origin: complete.origin(atFrame: 3_128), retroactiveMs: 1)
            #expect(closest.occurrence == MusicalOccurrence(pass: 0, ticks: 780))
            #expect(try complete.project(closest).frame == 3_120)

            var (limited, stored) = try distantHistory(limit: 13, retainEndPin: retainEndPin)
            let clock = limited.currentClock
            let count = limited.pinCount
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try limited.reserve(.grid(4), origin: limited.origin(atFrame: 3_128), retroactiveMs: 1)
            }
            #expect(limited.pinCount == count)
            #expect(limited.currentClock == clock && limited.observationSequence == 14 && limited.historyCount == 13)
            if let stored {
                #expect(stored.occurrence == MusicalOccurrence(pass: 0, ticks: 1_001))
                #expect(try limited.project(stored).frame == 1_564)
            }
        }

        @Test(arguments: [false, true])
        func aDiscardedLeadingAnchorCanWinEvenAtZeroTolerance(_ retainEndPin: Bool) throws {
            var (complete, _) = try distantHistory(limit: 16, retainEndPin: retainEndPin, reanchor: true)
            let exact = try complete.reserve(.grid(4), origin: complete.origin(atFrame: 3_128))
            #expect(exact.occurrence == MusicalOccurrence(pass: 0, ticks: 860))
            #expect(try complete.project(exact).frame == 3_128)
            var (limited, _) = try distantHistory(limit: 13, retainEndPin: retainEndPin, reanchor: true)
            let count = limited.pinCount
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try limited.reserve(.grid(4), origin: limited.origin(atFrame: 3_128))
            }
            #expect(limited.pinCount == count)
        }

        @Test(arguments: [false, true])
        func aKnownExactInteriorBeatsAllMissingLeadingPasses(_ retainEndPin: Bool) throws {
            var (timeline, _) = try distantHistory(limit: 13, retainEndPin: retainEndPin)
            let pin = try timeline.reserve(.grid(4), origin: timeline.origin(atFrame: 4_220))
            #expect(pin.occurrence == MusicalOccurrence(pass: 2, ticks: 284))
            #expect(try timeline.project(pin).frame == 4_220)
        }

        @Test func aKnownExactEndOnlyWinnerDoesNotRequireLeadingAnchors() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 1, endTicks: 2),
                                                 history: 1, ticks: 1, segments: [(0, 60_000)])
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 1, pass: 1)
            let pin = try timeline.reserve(.grid(2), origin: timeline.origin(atFrame: 0))
            #expect(pin.occurrence == MusicalOccurrence(pass: 1, ticks: 2))
            #expect(try timeline.project(pin).frame == 0 && timeline.project(pin).assumesFuture)
        }

        @Test(arguments: [false, true])
        func anEndOnlyPinSummaryCoversItsAliasButNotItsOriginalAnchor(_ resumed: Bool) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 1, endTicks: 2),
                                                 history: resumed ? 3 : 1, ticks: 1)
            let stored = try timeline.reserve(.absolute(2), origin: timeline.origin(atFrame: 0))
            try fixture.observe(&timeline, .wrap, ledger, frame: 2, ticks: 1, pass: 1)
            let origin = try timeline.origin(atFrame: 2)
            if resumed {
                try fixture.observe(&timeline, .running(false), ledger, frame: 2, ticks: 1, pass: 1)
                try fixture.observe(&timeline, .running(true), ledger, frame: 100, ticks: 1, pass: 1)
            }
            let pin = try timeline.reserve(.grid(2), origin: origin)
            #expect(pin.occurrence == MusicalOccurrence(pass: resumed ? 1 : 0, ticks: 2))
            #expect(try timeline.project(pin).frame == (resumed ? 102 : 2))
            #expect(try timeline.project(stored).frame == (resumed ? 100 : 2))
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try fixture.observe(&timeline, .loop(nil), ledger, frame: resumed ? 100 : 2)
            }
            #expect(timeline.currentLoop?.endTicks == 2 && stored.occurrence.pass == 0)
        }

        @Test(arguments: [0, 1])
        func discardedLeadingCandidatesOutsideTheWindowDoNotBlockForward(_ retro: Int) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 1, endTicks: 1_000),
                                                 history: 1, ticks: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 1_561, ticks: 1, pass: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 3_122, ticks: 1, pass: 2)
            try fixture.observe(&timeline, .primary, ledger, frame: 3_222)
            let pin = try timeline.reserve(.grid(1_000), origin: timeline.origin(atFrame: 3_222), retroactiveMs: retro)
            // Missing end aliases are at most 3122 + span(0, 1) = 3123.5625, outside either window.
            #expect(pin.occurrence == MusicalOccurrence(pass: 2, ticks: 1_000))
            #expect(try timeline.project(pin).frame == 4_683)
        }

        @Test(arguments: [0, 1])
        func discardedLeadingPassesDoNotAffectLoopFreeOrigins(_ retro: Int) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 3), history: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 5, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 10, ticks: 0, pass: 2)
            try fixture.observe(&timeline, .loop(nil), ledger, frame: 10)
            try fixture.observe(&timeline, .primary, ledger, frame: 11)
            let pin = try timeline.reserve(.grid(1), origin: timeline.origin(atFrame: 11), retroactiveMs: retro)
            #expect(pin.occurrence == MusicalOccurrence(pass: 2, ticks: retro == 0 ? 1 : 0))
            #expect(try timeline.project(pin).frame == (retro == 0 ? 12 : 10))
        }

        @Test(arguments: [1, 4], [0, 1])
        func aKnownInteriorWinsTheMissingHistoryUpperBoundTie(_ history: Int, _ retro: Int) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 1_920), history: history)
            try fixture.observe(&timeline, .wrap, ledger, frame: 3_000, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 6_000, ticks: 0, pass: 2)
            try fixture.observe(&timeline, .primary, ledger, frame: 6_001)
            let pin = try timeline.reserve(.grid(1_920), origin: timeline.origin(atFrame: 6_001), retroactiveMs: retro)
            // Missing interiors/aliases cannot exceed 6000; the known interior wins even a nonexact tie.
            #expect(pin.occurrence == MusicalOccurrence(pass: 2, ticks: retro == 0 ? 1_920 : 0))
            #expect(try timeline.project(pin).frame == (retro == 0 ? 9_000 : 6_000))
        }

        @Test(arguments: [1, 5], [Int64(1), 2])
        func endOnlySummaryDoesNotCoverAPrecedingEndProjection(_ history: Int, _ ticks: Int64) throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 1, endTicks: 3),
                                                 history: history, ticks: ticks)
            let firstWrap: Int64 = ticks == 1 ? 3 : 2
            let first = try timeline.reserve(.absolute(1), origin: timeline.origin(atFrame: 0))
            try fixture.observe(&timeline, .wrap, ledger, frame: firstWrap, ticks: 1, pass: 1)
            let end = try timeline.reserve(.absolute(3), origin: timeline.origin(atFrame: firstWrap))
            try fixture.observe(&timeline, .wrap, ledger, frame: firstWrap + 3, ticks: 1, pass: 2)
            try fixture.observe(&timeline, .musical, ledger, frame: firstWrap + 3, ticks: 2, pass: 2)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 1_280_000)])),
                                ledger, frame: firstWrap + 3)
            let clock = timeline.currentClock
            let origin = try timeline.origin(atFrame: firstWrap + 3)
            if history == 1 {
                #expect(throws: MusicalTimingError.historyUnavailable) {
                    try timeline.reserve(.grid(3), origin: origin, retroactiveMs: 1)
                }
                #expect(timeline.pinCount == 2)
            } else {
                let pin = try timeline.reserve(.grid(3), origin: origin, retroactiveMs: 1)
                #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 3))
                #expect(try timeline.project(pin).frame == firstWrap)
            }
            #expect(timeline.currentClock == clock && timeline.observationSequence == 4)
            #expect(timeline.historyCount == history)
            #expect(first.occurrence == MusicalOccurrence(pass: 0, ticks: 1))
            #expect(end.occurrence == MusicalOccurrence(pass: 1, ticks: 3))
            #expect(try timeline.project(first).frame == 4 * (1 - ticks))
            #expect(try timeline.project(end).frame == firstWrap - 1)
        }

        @Test(arguments: [1, 3])
        func retainedOriginalTicksBoundMissingInteriorsWithoutBecomingAnchors(_ history: Int) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 1_920),
                                                 history: history, ticks: 1_919)
            let stored = try timeline.reserve(.absolute(1_920), origin: timeline.origin(atFrame: 0))
            try fixture.observe(&timeline, .wrap, ledger, frame: 2, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .primary, ledger, frame: 3)
            let pin = try timeline.reserve(.grid(960), origin: timeline.origin(atFrame: 3), retroactiveMs: 1)
            #expect(pin.occurrence == MusicalOccurrence(pass: 1, ticks: 0))
            #expect(try timeline.project(pin).frame == 2 && !timeline.project(pin).assumesFuture)
            #expect(stored.occurrence == MusicalOccurrence(pass: 0, ticks: 1_920))
            #expect(try timeline.project(stored).frame == 2)
            #expect(timeline.pinCount == 2 && timeline.observationSequence == 2)
            if history == 1 {
                #expect(throws: MusicalTimingError.historyUnavailable) {
                    try fixture.observe(&timeline, .loop(nil), ledger, frame: 3)
                }
                #expect(timeline.currentLoop?.endTicks == 1_920 && timeline.observationSequence == 2)
            }
        }

        @Test(arguments: [0, 1])
        func anUnresolvedEndAliasCannotBeatAnExactLaterEndOnlyWinner(_ retro: Int) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 1, endTicks: 3),
                                                 history: 1, ticks: 1, segments: [(0, 60_000)])
            _ = try timeline.reserve(.absolute(1), origin: timeline.origin(atFrame: 0))
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 1, pass: 1)
            _ = try timeline.reserve(.absolute(3), origin: timeline.origin(atFrame: 0))
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 1, pass: 2)
            let pin = try timeline.reserve(.grid(3), origin: timeline.origin(atFrame: 0), retroactiveMs: retro)
            #expect(pin.occurrence == MusicalOccurrence(pass: 2, ticks: 3))
            #expect(try timeline.project(pin).frame == 0 && timeline.project(pin).assumesFuture)
        }

        @Test(arguments: [1, 6])
        func retainedTicksDoNotConstrainADifferentMissingPass(_ history: Int) throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 1_920), history: history)
            try fixture.observe(&timeline, .wrap, ledger, frame: 3_000, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .musical, ledger, frame: 5_998, ticks: 1_919, pass: 1)
            let stored = try timeline.reserve(.absolute(1_920), origin: timeline.origin(atFrame: 5_998))
            try fixture.observe(&timeline, .wrap, ledger, frame: 6_000, ticks: 0, pass: 2)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 2_000_160)])), ledger, frame: 6_000)
            try fixture.observe(&timeline, .primary, ledger, frame: 6_001)
            let origin = try timeline.origin(atFrame: 6_001)
            if history == 1 {
                #expect(throws: MusicalTimingError.historyUnavailable) {
                    try timeline.reserve(.grid(960), origin: origin, retroactiveMs: 1)
                }
                #expect(timeline.pinCount == 1)
            } else {
                let pin = try timeline.reserve(.grid(960), origin: origin, retroactiveMs: 1)
                // Pass 0 projects to 6000.48, closer than the current interior/end alias at 6000.
                #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 960))
                #expect(try timeline.project(pin).frame == 6_000)
            }
            #expect(timeline.observationSequence == 5 && timeline.historyCount == history)
            #expect(try timeline.project(stored).frame == 6_000)
        }

        @Test(arguments: [1, 8])
        func anUnreachableFutureEndDoesNotHideAKnownHeldPredecessor(_ history: Int) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, history: history)
            try fixture.observe(&timeline, .running(false), ledger, frame: 2, ticks: 2)
            try fixture.observe(&timeline, .loop(.init(startTicks: 0, endTicks: 1)), ledger, frame: 2)
            let origin = try timeline.origin(atFrame: 2)
            let before = String(reflecting: timeline)
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try timeline.reserve(.absolute(1), origin: origin)
            }
            #expect(String(reflecting: timeline) == before)
            if history == 1 {
                #expect(throws: MusicalTimingError.historyUnavailable) {
                    try timeline.reserve(.grid(1), origin: origin, retroactiveMs: 1)
                }
                #expect(String(reflecting: timeline) == before)
                return
            }
            // The latest running anchor qualifies the end, but the held clock cannot project that future pass.
            let pin = try timeline.reserve(.grid(1), origin: origin, retroactiveMs: 1)
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 0))
            #expect(timeline.pinCount == 1 && timeline.observationSequence == 2 && !timeline.isRunning)
            try fixture.observe(&timeline, .running(true), ledger, frame: 2, ticks: 2)
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 0))
            #expect(try timeline.project(pin).frame == -1 && !timeline.project(pin).assumesFuture)
        }

        @Test(arguments: [1, 2], [MusicalTarget.grid(1), .absolute(4)])
        func stoppedOriginsCannotReplaceAnEvictedRunningAnchor(_ history: Int, _ target: MusicalTarget) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, history: history)
            try fixture.observe(&timeline, .musical, ledger, frame: 1, ticks: 1)
            try fixture.observe(&timeline, .running(false), ledger, frame: 7, ticks: 5)
            let origin = try timeline.origin(atFrame: 7)
            let before = String(reflecting: timeline)
            var pin: MusicalPin?
            if history == 1 {
                #expect(throws: MusicalTimingError.historyUnavailable) {
                    pin = try timeline.reserve(target, origin: origin, retroactiveMs: 1)
                }
                #expect(String(reflecting: timeline) == before)
            } else {
                pin = try timeline.reserve(target, origin: origin, retroactiveMs: 1)
            }
            if let pin {
                #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 4))
                try fixture.observe(&timeline, .running(true), ledger, frame: 11, ticks: 5)
                #expect(try timeline.project(pin).frame == 9)
            }
        }

        @Test func aRetainedRunningPinKeepsStoppedSelectionUsable() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, history: 1, pins: 2)
            try fixture.observe(&timeline, .musical, ledger, frame: 1, ticks: 1)
            let stored = try timeline.reserve(.absolute(0), origin: timeline.origin(atFrame: 1))
            try fixture.observe(&timeline, .running(false), ledger, frame: 7, ticks: 5)
            let pin = try timeline.reserve(.grid(1), origin: timeline.origin(atFrame: 7), retroactiveMs: 1)
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 4))
            try fixture.observe(&timeline, .running(true), ledger, frame: 11, ticks: 5)
            #expect(try timeline.project(pin).frame == 9)
            #expect(stored.occurrence == MusicalOccurrence(pass: 0, ticks: 0))
            #expect(try timeline.project(stored).frame == 3 && timeline.historyCount == 1 && timeline.pinCount == 2)
        }

        @Test func anInitiallyHeldContextIsUsableOnlyBeforeItsFirstRun() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, running: false, history: 1, ticks: 5)
            try fixture.observe(&timeline, .primary, ledger, frame: 7)
            let pin = try timeline.reserve(.grid(1), origin: timeline.origin(atFrame: 7), retroactiveMs: 1)
            #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 5))
            try timeline.release(pin)
            try fixture.observe(&timeline, .running(true), ledger, frame: 11, ticks: 5)
            try fixture.observe(&timeline, .running(false), ledger, frame: 13, ticks: 6)
            let before = String(reflecting: timeline)
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try timeline.reserve(.grid(1), origin: timeline.origin(atFrame: 13), retroactiveMs: 1)
            }
            #expect(String(reflecting: timeline) == before)
        }

        @Test func rotatingStoppedHistoryCannotRestoreRunningProvenance() throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, history: 2)
            try fixture.observe(&timeline, .musical, ledger, frame: 1, ticks: 1)
            try fixture.observe(&timeline, .running(false), ledger, frame: 7, ticks: 5)
            try timeline.rotate()
            let before = String(reflecting: timeline)
            #expect(throws: MusicalTimingError.historyUnavailable) {
                try timeline.reserve(.grid(1), origin: timeline.origin(atFrame: 7), retroactiveMs: 1)
            }
            #expect(String(reflecting: timeline) == before)
        }

        @Test(arguments: [1, 3], [0, 1])
        func aStoppedEndAliasCannotHideAnUnknownOrdinaryCompetitor(_ history: Int, _ retro: Int) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 2),
                                                 history: history, segments: [(0, 60_000)])
            try fixture.observe(&timeline, .wrap, ledger, frame: 0, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .running(false), ledger, frame: 0, ticks: 0, pass: 1)
            let origin = try timeline.origin(atFrame: 0)
            let before = String(reflecting: timeline)
            if history == 1 {
                #expect(throws: MusicalTimingError.historyUnavailable) {
                    try timeline.reserve(.grid(1), origin: origin, retroactiveMs: retro)
                }
                #expect(String(reflecting: timeline) == before)
            } else {
                let ordinary = try timeline.reserve(.grid(1), origin: origin, retroactiveMs: retro)
                #expect(ordinary.occurrence == MusicalOccurrence(pass: 1, ticks: 0))
                try timeline.release(ordinary)
            }
            let end = try timeline.reserve(.absolute(2), origin: origin)
            #expect(end.occurrence == MusicalOccurrence(pass: 1, ticks: 2))
            try timeline.release(end) // The alias is known; only the missing ordinary inverse blocks the grid.
            try fixture.observe(&timeline, .running(true), ledger, frame: 0, ticks: 0, pass: 1)
            let current = try timeline.reserve(.grid(1), origin: timeline.origin(atFrame: 0))
            #expect(current.occurrence == MusicalOccurrence(pass: 1, ticks: 0))
            #expect(try timeline.project(current).frame == 0 && !timeline.project(current).assumesFuture)
        }

        @Test(arguments: [1, 2])
        func anExactStoppedEndStillNeedsItsCompetingInteriorBound(_ history: Int) throws {
            let ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 2),
                                                 history: history, ticks: 1)
            try fixture.observe(&timeline, .running(false), ledger, frame: 1, ticks: 2)
            let origin = try timeline.origin(atFrame: 1)
            let before = String(reflecting: timeline)
            if history == 1 {
                #expect(throws: MusicalTimingError.historyUnavailable) {
                    try timeline.reserve(.grid(1), origin: origin)
                }
                #expect(String(reflecting: timeline) == before)
            } else {
                let pin = try timeline.reserve(.grid(1), origin: origin)
                #expect(pin.occurrence == MusicalOccurrence(pass: 0, ticks: 2))
                try fixture.observe(&timeline, .running(true), ledger, frame: 1, ticks: 2)
                #expect(try timeline.project(pin).frame == 1 && timeline.project(pin).assumesFuture)
            }
        }

        @Test func aStrictlyPastEndAliasStillObeysTheHeldOriginTickCeiling() throws {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 1, endTicks: 3), ticks: 1)
            try fixture.observe(&timeline, .running(false), ledger, frame: 0, ticks: 1)
            let origin = try timeline.origin(atFrame: 0)
            try fixture.observe(&timeline, .running(true), ledger, frame: 0, ticks: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 3, ticks: 1, pass: 1)
            try fixture.observe(&timeline, .musical, ledger, frame: 3, ticks: 2, pass: 1)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 2_000_000)])), ledger, frame: 3)
            let past = try timeline.reserve(.absolute(3), origin: origin)
            #expect(try timeline.project(past).frame == -3) // Its exact -3.25 is before the held frame.
            let pin = try timeline.reserve(.grid(3), origin: origin, retroactiveMs: 1)
            #expect(pin.occurrence == MusicalOccurrence(pass: 1, ticks: 3))
            #expect(try timeline.project(pin).frame == 9 && timeline.project(pin).assumesFuture)
        }

        private func distantHistory(limit: Int, retainEndPin: Bool, reanchor: Bool = false)
            throws -> (MusicalTimeline, MusicalPin?) {
            var ledger = try fixture.ledger()
            var timeline = try fixture.timeline(ledger, loop: .init(startTicks: 0, endTicks: 1_001),
                                                 history: limit, pins: 2)
            let stored: MusicalPin?
            if retainEndPin {
                stored = try timeline.reserve(.absolute(1_001), origin: timeline.origin(atFrame: 0))
            } else {
                stored = nil
            }
            if reanchor { try fixture.observe(&timeline, .musical, ledger, frame: 200, ticks: 128) }
            try fixture.observe(&timeline, .wrap, ledger, frame: 1_564, ticks: 0, pass: 1)
            try fixture.observe(&timeline, .wrap, ledger, frame: 3_128, ticks: 0, pass: 2)
            try ledger.bump(fixture.mapKey, reason: .tempoEdit)
            try fixture.observe(&timeline, .map(fixture.map(ledger, segments: [(0, 1_280_000)])),
                                ledger, frame: 3_128)
            for index: Int64 in 1...11 {
                try fixture.observe(&timeline, .musical, ledger, frame: 3_128 + 100 * index,
                                    ticks: 26 * index, pass: 2)
            }
            return (timeline, stored)
        }
    }
}
