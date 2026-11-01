import Testing
@testable import FluxKlang

/// B2 history rows: a pinned occurrence survives tempo edits, wraps, delayed delivery and
/// physical-only progress, and is projected through its own pass's retained anchor (V6, V7, V15, T10).
/// Loop 0..1_920 at 0.64 ticks/frame wraps every 3_000 frames unless the tempo changes.
private extension SchedulerFixture {
    static func looped(capacity: Int = 1) throws -> SchedulerFixture {
        var fixture = try SchedulerFixture(capacity: capacity)
        try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920))
        return fixture
    }

    /// Commits, drains the single outcome and checks the terminal post-state: no pin, no pending
    /// request, no reserved slot and the committed horizon published as the clock floor.
    mutating func terminal(_ handle: TriggerHandle, at frame: Int64) throws -> TriggerOutcome {
        #expect(try commitMusical(handle, at: frame) == .completed)
        #expect(scheduler.musicalSummary?.pinCount == 0 && scheduler.pendingMusic(handle) == nil)
        let outcome = try drainOne(handle)
        #expect(scheduler.pendingCount == 0 && scheduler.reservedOutcomeCount == 0)
        #expect(try snapshot().horizon?.frame == frame)
        return outcome
    }
}

extension ControlContractTests {
    struct SchedulerHistoryAcceptance {
        /// V6: grid 1_440 from origin frame 2_500 (ticks 1_600) is frozen at pass 1, ticks 0 (frame 3_000).
        /// Foundation rule: a `.map` observation carries no ticks (`checkAnchor` refuses a musical payload)
        /// and `replaceMap` re-reads from the last musical anchor, so the edit observed at 2_500 keeps the
        /// frame-0/ticks-0 anchor, and the one observed at 3_000 keeps the wrap's frame-3_000/ticks-0 anchor.
        /// (Chronology repaired: the edit is observed after the origin.) Re-quantizing the same host origin
        /// on the half-speed map would choose ticks 1_440 / frame 4_500 instead of pass 1's start at 6_000.
        @Test(arguments: [false, true])
        func pendingGridRetainsItsOccurrenceAcrossTempoEditsAndWraps(wrapped: Bool) throws {
            var fixture = try SchedulerFixture.looped()
            try fixture.observeMusical(.primary, 2_500)
            let handle = try fixture.submitMusical(fixture.musicalStamp("trg.grid", .grid(ticks: 1_440),
                                                                        originHost: 1_250_000, arrival: 2_500))
            let frozen = SchedulerPendingMusic.pinned(MusicalOccurrence(pass: 1, ticks: 0))
            #expect(fixture.scheduler.pendingMusic(handle) == frozen)
            if wrapped { try fixture.observeMusical(.wrap, 3_000, ticks: 0, pass: 1) }
            let revision = try fixture.ledger.bump(SchedulerFixture.mapKey, reason: .tempoEdit)
            #expect(try fixture.scheduler.cancelStale(ledger: fixture.ledger).isEmpty)
            try fixture.observeMusical(.map(fixture.map(microsPerQuarter: 1_000_000)), wrapped ? 3_000 : 2_500)
            #expect(fixture.scheduler.pendingMusic(handle) == frozen && fixture.scheduler.pendingCount == 1)
            let outcome = try fixture.terminal(handle, at: wrapped ? 3_001 : 2_500)
            if wrapped {
                #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .dropped, reason: .late,
                                                  assignedFrame: 3_000, musicalMap: revision))
            } else {
                #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .fired, assignedFrame: 6_000,
                                                  frame: 6_000, musicalMap: revision))
            }
            try outcome.validateMediaShape()
        }

        /// V7: grid 960 from origin frame 1_000 keeps pass 0 (frame 1_500) when delivered after the wrap,
        /// whether it was submitted before the wrap or (delayed) after it from retained origin coverage.
        @Test(arguments: [false, true])
        func gridBeforeWrapKeepsItsOriginPassWhenDeliveredAfterWrap(delayed: Bool) throws {
            var fixture = try SchedulerFixture.looped()
            try fixture.observeMusical(.primary, 1_000)
            let stamp = fixture.musicalStamp("trg.delayed", .grid(ticks: 960), originHost: 500_000, arrival: 1_000)
            var handle: TriggerHandle?
            if !delayed { handle = try fixture.submitMusical(stamp) }
            try fixture.observeMusical(.wrap, 3_000, ticks: 0, pass: 1)
            if delayed { handle = try fixture.submitMusical(stamp) }
            let pending = try #require(handle)
            #expect(fixture.scheduler.pendingMusic(pending) == .pinned(MusicalOccurrence(pass: 0, ticks: 960)))
            let outcome = try fixture.terminal(pending, at: 3_001)
            #expect(outcome == TriggerOutcome(trigger: pending.trigger, result: .dropped, reason: .late,
                                              assignedFrame: 1_500, musicalMap: .initial))
            try outcome.validateMediaShape()
        }

        /// V15: the frozen pass-1 start (frame 3_000) survives a second wrap; fireLate 100 ms at 6_001.
        @Test func frozenNextPassTargetSurvivesAnotherWrap() throws {
            var fixture = try SchedulerFixture.looped()
            try fixture.observeMusical(.primary, 2_500)
            let handle = try fixture.submitMusical(fixture.musicalStamp(
                "trg.frozen", .grid(ticks: 1_440), originHost: 1_250_000, policy: .fireLate(maxLatenessMs: 100)))
            try fixture.observeMusical(.wrap, 3_000, ticks: 0, pass: 1)
            try fixture.observeMusical(.wrap, 6_000, ticks: 0, pass: 2)
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 1, ticks: 0)))
            #expect(fixture.scheduler.musicalSummary?.pinCount == 1)
            let outcome = try fixture.terminal(handle, at: 6_001)
            #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .firedLate, assignedFrame: 3_000,
                                              frame: 6_001, musicalMap: .initial))
            try outcome.validateMediaShape()
        }

        /// T10 (finding 1285; inventory name `finding1285TempoReanchorBeforeWrapIsLost`, no longer lost):
        /// a running re-anchor at 750 (ticks 480) then a half-speed edit moves ticks 960 to 2_250
        /// and the wrap to 5_250. At 5_251, 3_001 frames (62.5 ms) exceed the 60 ms limit: late drop.
        @Test func finding1285TempoReanchoredOccurrenceDropsLateBeyondItsLimit() throws {
            var fixture = try SchedulerFixture.looped()
            let handle = try fixture.submitMusical(fixture.musicalStamp(
                "trg.1285", .musical(atTicks: 960), originHost: 0, policy: .fireLate(maxLatenessMs: 60)))
            try fixture.observeMusical(.musical, 750, ticks: 480)
            let revision = try fixture.ledger.bump(SchedulerFixture.mapKey, reason: .tempoEdit)
            try fixture.observeMusical(.map(fixture.map(microsPerQuarter: 1_000_000)), 750)
            // The old map would have wrapped at 3_000; the edited one wraps only at 5_250.
            #expect(throws: MusicalTimingError.invalidTransition) {
                try fixture.observeMusical(.wrap, 3_000, ticks: 0, pass: 1)
            }
            try fixture.observeMusical(.wrap, 5_250, ticks: 0, pass: 1)
            #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 960)))
            let outcome = try fixture.terminal(handle, at: 5_251)
            #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .dropped, reason: .late,
                                              assignedFrame: 2_250, musicalMap: revision))
            try outcome.validateMediaShape()
        }

        /// The same projection is still within a 63 ms limit: firedLate at the horizon, pin released.
        @Test func tempoReanchoredOccurrenceFiresLateWithinItsLimit() throws {
            var fixture = try SchedulerFixture.looped()
            let handle = try fixture.submitMusical(fixture.musicalStamp(
                "trg.1285.ok", .musical(atTicks: 960), originHost: 0, policy: .fireLate(maxLatenessMs: 63)))
            try fixture.observeMusical(.musical, 750, ticks: 480)
            let revision = try fixture.ledger.bump(SchedulerFixture.mapKey, reason: .tempoEdit)
            try fixture.observeMusical(.map(fixture.map(microsPerQuarter: 1_000_000)), 750)
            try fixture.observeMusical(.wrap, 5_250, ticks: 0, pass: 1)
            let outcome = try fixture.terminal(handle, at: 5_251)
            #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .firedLate, assignedFrame: 2_250,
                                              frame: 5_251, musicalMap: revision))
            try outcome.validateMediaShape()
        }

        /// A newer physical-only anchor (even one carrying a musical payload) changes neither the pin, the
        /// timeline nor the projection: re-quantizing at frame 1_600 (ticks 1_024) would pick 1_920 / 3_000.
        @Test func physicalOnlyObservationNeverRequantizesAPinnedOccurrence() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0)
            try fixture.observeMusical(.primary, 500)
            let handle = try fixture.submitMusical(fixture.musicalStamp(
                "trg.physical", .grid(ticks: 960), originHost: 250_000, policy: .fireLate(maxLatenessMs: 100)))
            let pinned = SchedulerPendingMusic.pinned(MusicalOccurrence(pass: 0, ticks: 960))
            #expect(fixture.scheduler.pendingMusic(handle) == pinned)
            let music = fixture.scheduler.musicalSummary
            let payload = MusicalStamp(transport: .initial, musicalMap: .initial, ticks: 1_100, loopIteration: 7)
            try fixture.observe(1_600, host: 800_000, musical: payload)
            #expect(fixture.scheduler.musicalSummary == music && fixture.scheduler.pendingMusic(handle) == pinned)
            #expect(try fixture.snapshot().latestAnchor?.sample.frame == 1_600)
            let outcome = try fixture.terminal(handle, at: 1_600)
            #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .firedLate, assignedFrame: 1_500,
                                              frame: 1_600, musicalMap: .initial))
        }
    }
}
