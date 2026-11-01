import Testing
@testable import FluxKlang

/// B2 boundary rows: late `nextBoundary` fallbacks across wraps, full-width frames, per-wrap rounding,
/// tempo segments, the maximum pass and the retroactive previous-pass boundary (V3, V5, V8, V18, T8, T9).
private extension SchedulerFixture {
    /// A timeline at an explicit physical/musical anchor, for frames whose default host would overflow.
    mutating func prepareMusical(at anchor: ClockAnchor, loop: LoopRange?,
                                 segments: [(Int64, Int64)] = [(0, 500_000)]) throws {
        let map = try MusicalMap(clock: Self.musical, revision: #require(ledger.generation(Self.mapKey)),
                                 segments: segments.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) })
        try scheduler.prepareMusical(SchedulerMusicalSetup(anchor: anchor, map: map, loop: loop, running: true,
                                                           historyLimit: 4), ledger: ledger)
    }

    /// One late sample-frame request resolved through the fallback, with the full post-state checked.
    mutating func fallback(_ target: Int64, grid: Int64, at horizon: Int64) throws -> TriggerOutcome {
        let outcome = try resolveMusical(boundaryStamp("trg.fallback", .sample(atFrame: target), grid: grid),
                                         at: horizon)
        #expect(try snapshot().horizon?.frame == horizon && scheduler.reservedOutcomeCount == 0)
        try outcome.validateMediaShape()
        return outcome
    }
}

extension ControlContractTests {
    struct SchedulerBoundaryAcceptance {
        private static func fired(_ outcome: TriggerOutcome, at frame: Int64,
                                  map: Generation = .initial) -> TriggerOutcome {
            TriggerOutcome(trigger: outcome.trigger, result: .fired, assignedFrame: frame, frame: frame,
                           musicalMap: map)
        }

        /// V3: no wrap is observed; virtual passes give the boundary at or after each horizon.
        @Test(arguments: [(Int64(2_500), Int64(3_000)), (3_000, 3_000), (6_000, 6_000),
                          (3_000_000_000, 3_000_000_000)])
        func fallbackCrossesWrapWithoutAnAlreadyAnchoredNextPass(horizon: Int64, expected: Int64) throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920))
            let outcome = try fixture.fallback(1_000, grid: 1_440, at: horizon)
            #expect(outcome == Self.fired(outcome, at: expected))
            #expect(fixture.scheduler.musicalSummary?.clock.musical.loopIteration == 0)
        }

        /// V3's empty grid: no 1_440 line in 100..200 is a diagnosis keeping the late reference frame.
        @Test func fallbackWithAnEmptyLoopGridIsDiagnosed() throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0, loop: LoopRange(startTicks: 100, endTicks: 200))
            let outcome = try fixture.resolveMusical(fixture.boundaryStamp("trg.empty", .sample(atFrame: 1_000),
                                                                           grid: 1_440), at: 2_500)
            #expect(outcome == TriggerOutcome(trigger: outcome.trigger, result: .dropped, reason: .outsideLoop,
                                              assignedFrame: 1_000, musicalMap: .initial))
            #expect(try fixture.snapshot().horizon?.frame == 2_500 && fixture.scheduler.reservedOutcomeCount == 0)
        }

        /// V5: the current pass's 960 line is representable even though the loop's wrap is not.
        @Test func currentPassFallbackDoesNotNarrowAnUnrepresentableWrap() throws {
            let base = Int64.max - 2_000
            var fixture = try SchedulerFixture(capacity: 1, frame: base, host: 0)
            let loop = try LoopRange(startTicks: 0, endTicks: 1_920)
            try fixture.prepareMusical(at: fixture.anchor(base, host: 0, ticks: 0), loop: loop)
            let clock = try #require(fixture.scheduler.musicalSummary?.clock)
            #expect(throws: MusicalTimingError.overflow) {
                try MusicalTiming.frame(of: MusicalOccurrence(pass: 1, ticks: 0), from: clock, loop: loop)
            }
            let outcome = try fixture.fallback(base, grid: 960, at: base + 1)
            #expect(outcome == Self.fired(outcome, at: .max - 500))
        }

        /// V8: the fractional 4.6875-frame loop 0..3 advances every virtual pass by one rounded 5-frame period
        /// (5, 10, 15, matching T9's explicit wraps; adapted from the inventory's 13/18).
        @Test(arguments: [(Int64(5), Int64(5)), (10, 10), (15, 15)])
        func virtualFallbackPassesUseOneRoundedPeriod(horizon: Int64, expected: Int64) throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 3))
            let outcome = try fixture.fallback(0, grid: 2, at: horizon)
            #expect(outcome == Self.fired(outcome, at: expected))
        }

        /// V8 segmented: ticks 0..960 take 1_500 frames and 960..1_920 take 3_000 (a 4_500-frame loop).
        /// 12_500 skips whole virtual passes: with the segmented period it is pass 3's start (13_500);
        /// a first-segment-only 3_000-frame period would choose pass 3's 1_440 line at 16_500.
        @Test(arguments: [(Int64(4_000), Int64(4_500)), (5_000, 7_500), (12_500, 13_500)])
        func virtualFallbackPassesKeepTempoSegments(horizon: Int64, expected: Int64) throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(at: fixture.anchor(0, ticks: 0), loop: LoopRange(startTicks: 0, endTicks: 1_920),
                                       segments: [(0, 500_000), (960, 1_000_000)])
            let outcome = try fixture.fallback(0, grid: 1_440, at: horizon)
            #expect(outcome == Self.fired(outcome, at: expected))
        }

        /// T9: explicitly observed wraps must land on the same rounded frames the virtual passes use;
        /// each wrap observation is itself validated against the per-wrap rounded frame.
        @Test(arguments: [Int64(5), 10, 15])
        func finding1271RoundEveryVirtualWrap(frame: Int64) throws {
            var fixture = try SchedulerFixture(capacity: 1)
            try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 3))
            let handle = try fixture.submitMusical(fixture.boundaryStamp("trg.1271", .sample(atFrame: 0), grid: 2))
            for pass in 1..<UInt32(frame / 5) {
                let before = try fixture.admissionState()
                // The unrounded 4.6875-frame period would put this wrap one frame earlier.
                #expect(throws: MusicalTimingError.invalidTransition) {
                    try fixture.observeMusical(.wrap, Int64(pass) * 5 - 1, ticks: 0, pass: pass)
                }
                #expect(try fixture.admissionState() == before)
                try fixture.observeMusical(.wrap, Int64(pass) * 5, ticks: 0, pass: pass)
            }
            #expect(try fixture.commitMusical(handle, at: frame) == .completed)
            let outcome = try fixture.drainOne(handle)
            #expect(outcome == Self.fired(outcome, at: frame))
            #expect(fixture.scheduler.pendingCount == 0 && fixture.scheduler.reservedOutcomeCount == 0)
            #expect(try fixture.snapshot().horizon?.frame == frame && fixture.scheduler.musicalSummary?.pinCount == 0)
            #expect(fixture.scheduler.musicalSummary?.clock.musical.loopIteration == UInt32(frame / 5) - 1)
        }
    }
}

extension ControlContractTests.SchedulerBoundaryAcceptance {
    /// V18 positive (pure math; no counterfeit timeline can reach pass UInt32.max): a matching maximum
    /// pass projects through its own anchor even with the maximum legal loop end; a regressed one is refused.
    @Test func matchingMaximumPassProjectsThroughItsOwnAnchor() throws {
        let fixture = try SchedulerFixture(capacity: 1)
        let loop = try LoopRange(startTicks: 0, endTicks: .max)
        let anchor = try fixture.anchor(0, ticks: 0, pass: .max)
        let clock = try MusicalClockMap(anchor: anchor, map: fixture.map(), nominalRate: 48_000,
                                        currentSample: .initial, currentTransport: .initial)
        let matching = MusicalOccurrence(pass: Int128(UInt32.max), ticks: 0)
        #expect(try MusicalTiming.frame(of: matching, from: clock, loop: loop) == 0)
        #expect(try MusicalTiming.frame(of: MusicalOccurrence(pass: Int128(UInt32.max), ticks: 960),
                                        from: clock, loop: loop) == 1_500)
        #expect(throws: MusicalTimingError.historyUnavailable) {
            try MusicalTiming.frame(of: MusicalOccurrence(pass: 0, ticks: 0), from: clock, loop: loop)
        }
    }

    /// V18 regressed context at the scheduler: after a wrap, neither a pass-0 observation nor a pass-0
    /// stamp can regress the pinned pass-1 occurrence; each refusal is atomic and the pin still projects.
    @Test func regressedMusicalPassIsRefusedAtomically() throws {
        var fixture = try SchedulerFixture(capacity: 2)
        try fixture.prepareMusical(0, loop: LoopRange(startTicks: 0, endTicks: 1_920))
        try fixture.observeMusical(.wrap, 3_000, ticks: 0, pass: 1)
        var stamp = fixture.musicalStamp("trg.pass1", .musical(atTicks: 0), originHost: 1_500_000, arrival: 3_000)
        stamp.loopIteration = 1
        let handle = try fixture.submitMusical(stamp)
        let pinned = SchedulerPendingMusic.pinned(MusicalOccurrence(pass: 1, ticks: 0))
        #expect(fixture.scheduler.pendingMusic(handle) == pinned)
        let before = try fixture.admissionState()
        for (event, pass): (MusicalObservation, UInt32) in [(.musical, 0), (.wrap, 0), (.musical, 2)] {
            #expect(throws: MusicalTimingError.invalidTransition) {
                try fixture.observeMusical(event, 3_000, ticks: 0, pass: pass)
            }
            #expect(try fixture.admissionState() == before && fixture.scheduler.pendingMusic(handle) == pinned)
        }
        var regressed = fixture.musicalStamp("trg.regressed", .musical(atTicks: 0), originHost: 1_500_000)
        regressed.loopIteration = 0
        #expect(throws: TriggerSchedulerError.musicalPassMismatch) { try fixture.submitMusical(regressed) }
        #expect(try fixture.admissionState() == before && fixture.scheduler.drain().isEmpty)
        #expect(try fixture.commitMusical(handle, at: 3_000) == .completed)
        let outcome = try fixture.drainOne(handle)
        #expect(outcome == Self.fired(outcome, at: 3_000))
        try outcome.validateMediaShape()
        #expect(fixture.scheduler.musicalSummary?.pinCount == 0 && fixture.scheduler.pendingCount == 0)
        #expect(try fixture.snapshot().horizon?.frame == 3_000 && fixture.scheduler.reservedOutcomeCount == 0)
    }

    /// T8: loop 100..2_000; at the wrap (2_969, pass 1, ticks 100) a 5 ms window reaches back to the
    /// previous pass's 1_920 line at 2_844 (125 frames = 2.6 ms), not forward to pass 1's 960.
    @Test func finding1262RetroactiveBoundaryBeforeLoopStart() throws {
        var fixture = try SchedulerFixture(capacity: 1)
        let loop = try LoopRange(startTicks: 100, endTicks: 2_000)
        try fixture.prepareMusical(0, ticks: 100, loop: loop)
        try fixture.observeMusical(.wrap, 2_969, ticks: 100, pass: 1)
        var stamp = fixture.musicalStamp("trg.1262", .grid(ticks: 960), originHost: 2_969 * 500,
                                         policy: .fireLate(maxLatenessMs: 100), arrival: 2_969)
        stamp.loopIteration = 1
        stamp.retroactiveMs = 5
        let handle = try fixture.submitMusical(stamp)
        #expect(fixture.scheduler.pendingMusic(handle) == .pinned(MusicalOccurrence(pass: 0, ticks: 1_920)))
        #expect(try fixture.commitMusical(handle, at: 2_969) == .completed)
        let outcome = try fixture.drainOne(handle)
        #expect(outcome == TriggerOutcome(trigger: handle.trigger, result: .firedLate, assignedFrame: 2_844,
                                          frame: 2_969, musicalMap: .initial))
        try outcome.validateMediaShape()
        #expect(fixture.scheduler.musicalSummary?.pinCount == 0 && fixture.scheduler.pendingCount == 0)
        #expect(try fixture.snapshot().horizon?.frame == 2_969)
        // Without the window the same origin forward-chooses pass 1's 960 line.
        var plain = fixture.musicalStamp("trg.1262.plain", .grid(ticks: 960), originHost: 2_969 * 500,
                                         policy: .fireLate(maxLatenessMs: 100), arrival: 2_969)
        plain.loopIteration = 1
        let forward = try fixture.submitMusical(plain)
        #expect(fixture.scheduler.pendingMusic(forward) == .pinned(MusicalOccurrence(pass: 1, ticks: 960)))
    }
}
